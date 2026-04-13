#!/usr/bin/env bash

set -euo pipefail

APP_NAME="google_vs_cf"
VERSION="0.1.1"
AUTHOR="Doudou Zhang"

TEST_DNS=("1.1.1.1" "8.8.8.8")
TEST_LABELS=("Cloudflare" "Google")
DOMAINS=(
    "x.com"          "bbc.com"        "twitch.tv"        "intel.com"
    "apple.com"      "amazon.com"     "fastly.com"       "akamai.com"
    "google.com"     "github.com"     "youtube.com"      "netflix.com"
    "telegram.org"   "bilibili.com"   "wikipedia.org"    "microsoft.com"
    "instagram.com"  "aws.amazon.com" "steampowered.com"   
)
ITERATIONS=20
DIG_TIMEOUT=2
OUTER_TIMEOUT=$((DIG_TIMEOUT + 1))
QTYPE="A"

RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="$RESOLVED_DROPIN_DIR/99-google-vs-cf.conf"
LEGACY_DOH_DIR="/etc/google-vs-cf"
LEGACY_DOH_SERVICE="/etc/systemd/system/google-vs-cf-doh.service"

PROFILE_NAME=""
DNS1=""
DNS2=""

if [[ -t 1 ]]; then
    C_TITLE=$'\033[1;36m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_ERR=$'\033[1;31m'
    C_INFO=$'\033[1;34m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_TITLE=""; C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_DIM=""; C_RESET=""
fi

LINE="================================================================"
SUBLINE="----------------------------------------------------------------"

say()  { echo "$*"; }
ok()   { echo "${C_OK}$*${C_RESET}"; }
warn() { echo "${C_WARN}$*${C_RESET}"; }
err()  { echo "${C_ERR}$*${C_RESET}"; }
info() { echo "${C_INFO}$*${C_RESET}"; }

print_menu_item() {
    local key="$1"
    local title="$2"
    local desc="$3"
    printf " %b%s%b) %-24s %s\n" "$C_INFO" "$key" "$C_RESET" "$title" "$desc"
}

print_profile_item() {
    local key="$1"
    local title="$2"
    local path="$3"
    printf " %b%s%b) %-14s %s\n" "$C_INFO" "$key" "$C_RESET" "$title" "$path"
}

print_domain_grid() {
    local cols=3
    local width=22
    local i j idx
    for ((i=0; i<${#DOMAINS[@]}; i+=cols)); do
        for ((j=0; j<cols; j++)); do
            idx=$((i + j))
            if (( idx < ${#DOMAINS[@]} )); then
                printf "  %b%02d%b) %b%-*s%b"                     "$C_DIM" "$((idx + 1))" "$C_RESET"                     "$C_INFO" "$width" "${DOMAINS[$idx]}" "$C_RESET"
            fi
        done
        printf "\n"
    done
}

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "Run as root: sudo bash google_vs_cf.sh"
        exit 1
    fi
}

pause() {
    echo
    if ! read -r -p "Press Enter to return..." _dummy; then
        echo
    fi
}

clear_screen() {
    clear 2>/dev/null || true
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

service_state() {
    local unit="$1"
    if ! command_exists systemctl; then
        echo "n/a"
        return 0
    fi
    systemctl is-active "$unit" 2>/dev/null || true
}

enabled_state() {
    local unit="$1"
    if ! command_exists systemctl; then
        echo "n/a"
        return 0
    fi
    systemctl is-enabled "$unit" 2>/dev/null || true
}

resolved_summary_raw() {
    if pkg_installed systemd-resolved; then
        echo "installed|$(enabled_state systemd-resolved)|$(service_state systemd-resolved)"
    else
        echo "not installed|n/a|n/a"
    fi
}

is_locked() {
    [[ -e /etc/resolv.conf ]] || return 1
    command_exists lsattr || return 1
    lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

resolv_mode_raw() {
    if [[ -L /etc/resolv.conf ]]; then
        echo "resolved link"
    elif [[ -f /etc/resolv.conf ]]; then
        if is_locked; then
            echo "locked file"
        else
            echo "plain file"
        fi
    else
        echo "missing"
    fi
}

color_mode() {
    local mode
    mode="$(resolv_mode_raw)"
    case "$mode" in
        "locked file") printf "%s%s%s" "$C_OK" "$mode" "$C_RESET" ;;
        "resolved link") printf "%s%s%s" "$C_INFO" "$mode" "$C_RESET" ;;
        "plain file") printf "%s%s%s" "$C_WARN" "$mode" "$C_RESET" ;;
        *) printf "%s%s%s" "$C_ERR" "$mode" "$C_RESET" ;;
    esac
}

color_resolved() {
    local raw package enabled active
    raw="$(resolved_summary_raw)"
    IFS='|' read -r package enabled active <<< "$raw"

    if [[ "$package" != "installed" ]]; then
        printf "%snot installed%s" "$C_ERR" "$C_RESET"
        return 0
    fi

    if [[ "$active" == "active" ]]; then
        printf "%sinstalled / %s / %s%s" "$C_OK" "$enabled" "$active" "$C_RESET"
    elif [[ "$enabled" == "masked" ]]; then
        printf "%sinstalled / masked / %s%s" "$C_WARN" "$active" "$C_RESET"
    else
        printf "%sinstalled / %s / %s%s" "$C_WARN" "$enabled" "$active" "$C_RESET"
    fi
}

print_header() {
    echo "$LINE"
    echo "${C_TITLE}${APP_NAME}${C_RESET}  v ${VERSION}  |  Designed by ${AUTHOR}"
    echo "$LINE"
    echo
    echo "Mode     : $(color_mode)"
    echo
    echo "Resolved : $(color_resolved)"
    echo
}

pkg_install() {
    local -a pkgs=("$@")
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
}

prompt_install_missing() {
    local -a missing=("$@")
    mapfile -t missing < <(printf '%s\n' "${missing[@]}" | awk 'NF && !seen[$0]++')

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    echo
    warn "Missing packages: ${missing[*]}"
    if ! read -r -p "Install now? [y/N]: " answer; then
        echo
        return 1
    fi
    case "$answer" in
        y|Y) pkg_install "${missing[@]}" ;;
        *) return 1 ;;
    esac
}

need_test_tools() {
    local -a missing=()

    if ! command_exists dig; then
        if command_exists apt-cache && apt-cache show bind9-dnsutils >/dev/null 2>&1; then
            missing+=(bind9-dnsutils)
        else
            missing+=(dnsutils)
        fi
    fi
    command_exists timeout || missing+=(coreutils)
    command_exists awk || missing+=(gawk)
    command_exists sort || missing+=(coreutils)

    prompt_install_missing "${missing[@]}"
}

need_lock_tools() {
    local -a missing=()
    command_exists chattr || missing+=(e2fsprogs)
    command_exists lsattr || missing+=(e2fsprogs)
    prompt_install_missing "${missing[@]}"
}

calc_stats() {
    if [[ $# -eq 0 ]]; then
        echo "N/A N/A N/A N/A N/A"
        return 0
    fi
    printf "%s
" "$@" | sort -n | awk '
    { arr[++count]=$1; sum+=$1 }
    END {
        if (!count) { printf "N/A N/A N/A N/A N/A"; exit }
        min=arr[1]
        max=arr[count]
        avg=sum/count
        median=(count%2==1) ? arr[(count+1)/2] : (arr[count/2]+arr[count/2+1])/2
        p90_index=int((count * 9 + 9) / 10)
        if (p90_index < 1) p90_index=1
        if (p90_index > count) p90_index=count
        p90=arr[p90_index]
        printf "%d %d %.2f %.2f %.2f", min, max, avg, median, p90
    }'
}

calc_score() {
    local avg="$1"
    local median="$2"
    local p90="$3"
    local bad="$4"
    local total_rounds="$5"
    awk -v avg="$avg" -v median="$median" -v p90="$p90" -v bad="$bad" -v total="$total_rounds" 'BEGIN {
        if (avg == "N/A" || median == "N/A" || p90 == "N/A") {
            print "N/A"
            exit
        }
        bad_ratio = (total > 0) ? bad / total : 1
        tail_penalty = (p90 > median) ? (p90 - median) : 0
        skew_penalty = (avg > median) ? (avg - median) : 0
        score = median + (tail_penalty * 0.35) + (skew_penalty * 0.10) + (bad_ratio * 25)
        printf "%.2f", score
    }'
}

calc_bad_ratio() {
    local bad="$1"
    local total="$2"
    awk -v bad="$bad" -v total="$total" 'BEGIN {
        if (total <= 0) {
            printf "1.0000"
            exit
        }
        printf "%.4f", bad / total
    }'
}

dns_a_is_better() {
    local bad_a="$1"
    local total_a="$2"
    local median_a="$3"
    local p90_a="$4"
    local avg_a="$5"
    local score_a="$6"
    local bad_b="$7"
    local total_b="$8"
    local median_b="$9"
    local p90_b="${10}"
    local avg_b="${11}"
    local score_b="${12}"

    awk \
        -v bad_a="$bad_a" -v total_a="$total_a" -v median_a="$median_a" -v p90_a="$p90_a" -v avg_a="$avg_a" -v score_a="$score_a" \
        -v bad_b="$bad_b" -v total_b="$total_b" -v median_b="$median_b" -v p90_b="$p90_b" -v avg_b="$avg_b" -v score_b="$score_b" \
        'BEGIN {
            ratio_a = (total_a > 0) ? bad_a / total_a : 1
            ratio_b = (total_b > 0) ? bad_b / total_b : 1

            if (ratio_a < ratio_b) exit 0
            if (ratio_a > ratio_b) exit 1

            if (median_a < median_b) exit 0
            if (median_a > median_b) exit 1

            if (p90_a < p90_b) exit 0
            if (p90_a > p90_b) exit 1

            if (avg_a < avg_b) exit 0
            if (avg_a > avg_b) exit 1

            if (score_a == "N/A" && score_b == "N/A") exit 0
            if (score_a == "N/A") exit 1
            if (score_b == "N/A") exit 0

            exit !(score_a <= score_b)
        }'
}

fmt_header() {
    printf "%b%-20s%b | %-5s | %-5s | %-7s | %-7s | %-7s | %-4s | %-4s
" \
        "$C_TITLE" "$1" "$C_RESET" "Min" "Max" "Avg" "Median" "P90" "Bad" "0ms"
}

fmt_row() {
    local label="$1"
    local min="$2"
    local max="$3"
    local avg="$4"
    local median="$5"
    local p90="$6"
    local bad="$7"
    local zero="$8"
    local color="${9:-$C_INFO}"

    printf "%b%-20s%b | %-5s | %-5s | %-7s | %-7s | %-7s | %-4s | %-4s
" \
        "$color" "$label" "$C_RESET" "$min" "$max" "$avg" "$median" "$p90" "$bad" "$zero"
}

fmt_summary_header() {
    printf "%b%-22s%b | %-7s | %-7s | %-7s | %-4s | %-4s | %-6s
" \
        "$C_TITLE" "Resolver" "$C_RESET" "Avg" "Median" "P90" "Bad" "0ms" "Score"
}

fmt_summary_row() {
    local label="$1"
    local avg="$2"
    local median="$3"
    local p90="$4"
    local bad="$5"
    local zero="$6"
    local score="$7"
    local color="${8:-$C_INFO}"

    printf "%b%-22s%b | %-7s | %-7s | %-7s | %-4s | %-4s | %-6s
" \
        "$color" "$label" "$C_RESET" "$avg" "$median" "$p90" "$bad" "$zero" "$score"
}

choose_profile() {
    while true; do
        echo "DNS profiles"
        echo "$SUBLINE"
        echo
        print_profile_item "1" "CF Dual"      "1.1.1.1  ->  1.0.0.1"
        echo
        print_profile_item "2" "Google Dual"  "8.8.8.8  ->  8.8.4.4"
        echo
        print_profile_item "3" "CF First"     "1.1.1.1  ->  8.8.8.8"
        echo
        print_profile_item "4" "Google First" "8.8.8.8  ->  1.1.1.1"
        echo
        print_profile_item "0" "Back"         "return to main menu"
        echo
        if ! read -r -p "Choose [0-4]: " choice; then
            echo
            return 1
        fi
        case "$choice" in
            1)
                PROFILE_NAME="CF Dual"
                DNS1="1.1.1.1"
                DNS2="1.0.0.1"
                return 0
                ;;
            2)
                PROFILE_NAME="Google Dual"
                DNS1="8.8.8.8"
                DNS2="8.8.4.4"
                return 0
                ;;
            3)
                PROFILE_NAME="CF First"
                DNS1="1.1.1.1"
                DNS2="8.8.8.8"
                return 0
                ;;
            4)
                PROFILE_NAME="Google First"
                DNS1="8.8.8.8"
                DNS2="1.1.1.1"
                return 0
                ;;
            0)
                return 1
                ;;
            *)
                warn "Invalid choice."
                ;;
        esac
        echo
    done
}

unlock_resolv() {
    if [[ -e /etc/resolv.conf ]] && command_exists chattr; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
}

cleanup_old_google_vs_cf() {
    rm -f "$RESOLVED_DROPIN_FILE"
    rm -f "$LEGACY_DOH_SERVICE"
    rm -rf "$LEGACY_DOH_DIR"
    systemctl daemon-reload 2>/dev/null || true
}

neutralize_resolved() {
    unlock_resolv
    cleanup_old_google_vs_cf

    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    systemctl mask systemd-resolved 2>/dev/null || true
}

apply_locked_file() {
    if ! need_lock_tools; then
        warn "Canceled."
        return 1
    fi

    echo "Force apply + lock"
    echo "$SUBLINE"
    echo
    echo "Profile : $PROFILE_NAME"
    echo
    echo "DNS     : $DNS1 -> $DNS2"
    echo
    read -r -p "Continue? [y/N]: " answer || { echo; warn "Canceled."; return 1; }
    case "$answer" in
        y|Y) ;;
        *) warn "Canceled."; return 1 ;;
    esac

    neutralize_resolved

    rm -f /etc/resolv.conf
    {
        echo "nameserver $DNS1"
        echo "nameserver $DNS2"
        echo "options timeout:2 attempts:2"
    } > /etc/resolv.conf

    if chattr +i /etc/resolv.conf 2>/dev/null; then
        if is_locked; then
            ok "Locked file applied."
        else
            warn "File written, but immutable lock was not confirmed."
        fi
    else
        warn "File written, but immutable lock failed."
    fi
}

reinstall_resolved_apply() {
    echo "Reinstall resolved + apply"
    echo "$SUBLINE"
    echo
    echo "Profile : $PROFILE_NAME"
    echo
    echo "DNS     : $DNS1 -> $DNS2"
    echo
    read -r -p "Continue? [y/N]: " answer || { echo; warn "Canceled."; return 1; }
    case "$answer" in
        y|Y) ;;
        *) warn "Canceled."; return 1 ;;
    esac

    unlock_resolv
    cleanup_old_google_vs_cf

    systemctl unmask systemd-resolved 2>/dev/null || true

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y systemd-resolved

    mkdir -p "$RESOLVED_DROPIN_DIR"
    cat > "$RESOLVED_DROPIN_FILE" <<CFG
[Resolve]
DNS=$DNS1 $DNS2
Domains=~.
DNSSEC=no
CFG

    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    systemctl restart systemd-resolved

    for _ in {1..15}; do
        if [[ -e /run/systemd/resolve/stub-resolv.conf || -e /run/systemd/resolve/resolv.conf ]]; then
            break
        fi
        sleep 0.2
    done

    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -snf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    elif [[ -e /run/systemd/resolve/resolv.conf ]]; then
        ln -snf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
        warn "resolved is running, but no standard resolv.conf target was found."
    fi

    ok "resolved reinstalled and profile applied."
}

print_recommendation() {
    local cf_score="$1"
    local google_score="$2"
    local cf_avg="$3"
    local google_avg="$4"
    local cf_median="$5"
    local google_median="$6"
    local cf_p90="$7"
    local google_p90="$8"
    local cf_bad="$9"
    local google_bad="${10}"
    local cf_zero="${11}"
    local google_zero="${12}"
    local total_rounds="${13}"

    echo
    echo "Recommendation"
    echo "$SUBLINE"
    echo

    if [[ "$cf_score" == "N/A" && "$google_score" == "N/A" ]]; then
        warn "No valid result."
        return 0
    fi

    if [[ "$cf_score" == "N/A" ]]; then
        ok "Use Google. Cloudflare had no valid score."
        return 0
    fi

    if [[ "$google_score" == "N/A" ]]; then
        ok "Use Cloudflare. Google had no valid score."
        return 0
    fi

    local winner loser winner_score loser_score winner_avg winner_median winner_p90 winner_bad winner_zero
    local loser_avg loser_median loser_p90 loser_bad loser_zero

    if dns_a_is_better "$cf_bad" "$total_rounds" "$cf_median" "$cf_p90" "$cf_avg" "$cf_score" \
                        "$google_bad" "$total_rounds" "$google_median" "$google_p90" "$google_avg" "$google_score"; then
        winner="Cloudflare"
        loser="Google"
        winner_score="$cf_score"
        loser_score="$google_score"
        winner_avg="$cf_avg"
        winner_median="$cf_median"
        winner_p90="$cf_p90"
        winner_bad="$cf_bad"
        winner_zero="$cf_zero"
        loser_avg="$google_avg"
        loser_median="$google_median"
        loser_p90="$google_p90"
        loser_bad="$google_bad"
        loser_zero="$google_zero"
    else
        winner="Google"
        loser="Cloudflare"
        winner_score="$google_score"
        loser_score="$cf_score"
        winner_avg="$google_avg"
        winner_median="$google_median"
        winner_p90="$google_p90"
        winner_bad="$google_bad"
        winner_zero="$google_zero"
        loser_avg="$cf_avg"
        loser_median="$cf_median"
        loser_p90="$cf_p90"
        loser_bad="$cf_bad"
        loser_zero="$cf_zero"
    fi

    local diff level winner_ratio loser_ratio
    diff=$(awk -v a="$winner_score" -v b="$loser_score" 'BEGIN { d=b-a; if (d < 0) d=-d; printf "%.2f", d }')
    winner_ratio=$(calc_bad_ratio "$winner_bad" "$total_rounds")
    loser_ratio=$(calc_bad_ratio "$loser_bad" "$total_rounds")

    if awk -v d="$diff" 'BEGIN { exit !(d < 0.80) }'; then
        level="Slight edge"
    elif awk -v d="$diff" 'BEGIN { exit !(d < 2.20) }'; then
        level="Recommended"
    else
        level="Strongly recommended"
    fi

    ok "$level: $winner"
    echo "Why     : lower bad ratio first, then lower median, then lower p90, then lower average."
    echo "Score   : $winner $winner_score  vs  $loser $loser_score"
    echo "Winner  : bad $winner_bad/$total_rounds ($winner_ratio), median $winner_median ms, p90 $winner_p90 ms, avg $winner_avg ms"
    echo "Loser   : bad $loser_bad/$total_rounds ($loser_ratio), median $loser_median ms, p90 $loser_p90 ms, avg $loser_avg ms"

    if (( cf_zero > 0 || google_zero > 0 )); then
        echo "Zero ms : ignored in stats and recommendation."
    fi

    echo "Model   : score = median + 0.35*(p90-median) + 0.10*(avg-median) + 25*bad_ratio"
    echo "Method  : round-robin sampling across domains, $ITERATIONS rounds per domain."
}

test_dns() {
    local dns label domain output rc qtime status min max avg median p90 score idx round step domain_count start_offset query_done query_total total_bad total_zero
    local bad_count zero_count
    local -a all_times=() times=() summary_rows=()
    local -A domain_time_map=() domain_bad_map=() domain_zero_map=()
    local cf_score="N/A" google_score="N/A"
    local cf_avg="N/A" google_avg="N/A"
    local cf_median="N/A" google_median="N/A"
    local cf_p90="N/A" google_p90="N/A"
    local cf_bad=0 google_bad=0
    local cf_zero=0 google_zero=0
    local total_rounds=$(( ${#DOMAINS[@]} * ITERATIONS ))

    if ! need_test_tools; then
        warn "Test canceled."
        return 1
    fi

    echo "Test DNS"
    echo "$SUBLINE"
    echo
    echo "Targets : 1.1.1.1 vs 8.8.8.8"
    echo
    echo "Domains :"
    print_domain_grid
    echo
    echo "Rounds  : $ITERATIONS per domain"
    echo
    echo "Method  : round-robin across domains to reduce hot-cache bias"
    echo
    echo "Rule    : 0 ms is ignored in stats and recommendation"
    echo

    domain_count=${#DOMAINS[@]}
    query_total=$(( domain_count * ITERATIONS ))

    for idx in 0 1; do
        dns="${TEST_DNS[$idx]}"
        label="${TEST_LABELS[$idx]}"
        echo "@$dns  ($label)"
        echo
        fmt_header "Domain"
        echo "$SUBLINE"

        all_times=()
        total_bad=0
        total_zero=0
        query_done=0

        for domain in "${DOMAINS[@]}"; do
            domain_time_map["$domain"]=""
            domain_bad_map["$domain"]=0
            domain_zero_map["$domain"]=0
        done

        for ((round=1; round<=ITERATIONS; round++)); do
            start_offset=$(( (round - 1) % domain_count ))
            for ((step=0; step<domain_count; step++)); do
                domain="${DOMAINS[$(((start_offset + step) % domain_count))]}"
                output=""
                rc=0

                if output=$(timeout "${OUTER_TIMEOUT}s" dig @"$dns" "$domain" "$QTYPE" \
                    +tries=1 +time="$DIG_TIMEOUT" \
                    +noquestion +noanswer +noauthority +noadditional +nostats \
                    +comments +stats 2>/dev/null); then
                    rc=0
                else
                    rc=$?
                fi

                case "$rc" in
                    0)
                        qtime=$(awk '/Query time:/ {print $4; exit}' <<< "$output")
                        status=$(awk '/^;; ->>HEADER<<-/ { s=$0; sub(/.*status: /, "", s); sub(/,.*/, "", s); print s; exit }' <<< "$output")
                        if [[ "$status" == "NOERROR" && "$qtime" =~ ^[0-9]+$ ]]; then
                            if (( qtime > 0 )); then
                                domain_time_map["$domain"]+="${qtime} "
                                all_times+=("$qtime")
                            else
                                domain_zero_map["$domain"]=$(( ${domain_zero_map["$domain"]} + 1 ))
                                total_zero=$(( total_zero + 1 ))
                            fi
                        else
                            domain_bad_map["$domain"]=$(( ${domain_bad_map["$domain"]} + 1 ))
                            total_bad=$(( total_bad + 1 ))
                        fi
                        ;;
                    *)
                        domain_bad_map["$domain"]=$(( ${domain_bad_map["$domain"]} + 1 ))
                        total_bad=$(( total_bad + 1 ))
                        ;;
                esac

                query_done=$((query_done + 1))
                printf "${C_DIM}  Progress : %3d/%3d  (round %02d/%02d)${C_RESET}" "$query_done" "$query_total" "$round" "$ITERATIONS" >&2
                sleep 0.03
            done
        done
        printf "%*s" 72 "" >&2

        for domain in "${DOMAINS[@]}"; do
            times=()
            bad_count="${domain_bad_map["$domain"]}"
            zero_count="${domain_zero_map["$domain"]}"

            if [[ -n "${domain_time_map["$domain"]// /}" ]]; then
                read -r -a times <<< "${domain_time_map["$domain"]}"
            fi

            if [[ ${#times[@]} -gt 0 ]]; then
                read -r min max avg median p90 <<< "$(calc_stats "${times[@]}")"
                fmt_row "$domain" "$min" "$max" "$avg" "$median" "$p90" "$bad_count" "$zero_count"
            else
                fmt_row "$domain" "N/A" "N/A" "N/A" "N/A" "N/A" "$bad_count" "$zero_count"
            fi
        done

        if [[ ${#all_times[@]} -gt 0 ]]; then
            read -r min max avg median p90 <<< "$(calc_stats "${all_times[@]}")"
            score=$(calc_score "$avg" "$median" "$p90" "$total_bad" "$total_rounds")
            summary_rows+=("$score|$label|$dns|$avg|$median|$p90|$total_bad|$total_zero")
            fmt_row "TOTAL" "$min" "$max" "$avg" "$median" "$p90" "$total_bad" "$total_zero" "$C_OK"
        else
            score="N/A"
            summary_rows+=("999999|$label|$dns|N/A|N/A|N/A|$total_bad|$total_zero")
            fmt_row "TOTAL" "N/A" "N/A" "N/A" "N/A" "N/A" "$total_bad" "$total_zero" "$C_OK"
        fi

        echo
        echo "Ignored  : zero ms = $total_zero"
        echo

        if [[ "$label" == "Cloudflare" ]]; then
            cf_score="$score"; cf_avg="$avg"; cf_median="$median"; cf_p90="$p90"; cf_bad="$total_bad"; cf_zero="$total_zero"
        else
            google_score="$score"; google_avg="$avg"; google_median="$median"; google_p90="$p90"; google_bad="$total_bad"; google_zero="$total_zero"
        fi
    done

    echo "Summary"
    echo "$SUBLINE"
    echo
    fmt_summary_header
    echo "$SUBLINE"
    printf "%s
" "${summary_rows[@]}" | sort -t'|' -k1,1g | while IFS='|' read -r score label dns avg median p90 bad zero; do
        fmt_summary_row "${label} @${dns}" "$avg" "$median" "$p90" "$bad" "$zero" "$score"
    done

    print_recommendation \
        "$cf_score" "$google_score" \
        "$cf_avg" "$google_avg" \
        "$cf_median" "$google_median" \
        "$cf_p90" "$google_p90" \
        "$cf_bad" "$google_bad" \
        "$cf_zero" "$google_zero" \
        "$total_rounds"
}

show_status() {
    local package_text mode_text enabled_text active_text
    echo "Status"
    echo "$SUBLINE"
    echo

    mode_text="$(resolv_mode_raw)"
    echo -n "Mode    : "
    case "$mode_text" in
        "locked file") ok "$mode_text" ;;
        "resolved link") info "$mode_text" ;;
        "plain file") warn "$mode_text" ;;
        *) err "$mode_text" ;;
    esac

    echo
    echo "resolv.conf"
    if [[ -L /etc/resolv.conf ]]; then
        echo "type   : symlink"
        echo
        echo "target : $(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf 2>/dev/null || true)"
    elif [[ -f /etc/resolv.conf ]]; then
        echo "type   : file"
    else
        echo "type   : missing"
    fi

    echo
    echo -n "lock   : "
    if command_exists lsattr; then
        if is_locked; then
            ok "yes"
        else
            warn "no"
        fi
    else
        warn "unknown (lsattr missing)"
    fi

    echo
    echo "content"
    if [[ -e /etc/resolv.conf ]]; then
        cat /etc/resolv.conf 2>/dev/null || true
    else
        echo "missing"
    fi

    echo
    echo "resolved"
    package_text="$(if pkg_installed systemd-resolved; then echo installed; else echo not installed; fi)"
    echo -n "package : "
    if [[ "$package_text" == "installed" ]]; then ok "$package_text"; else err "$package_text"; fi

    if pkg_installed systemd-resolved; then
        enabled_text="$(enabled_state systemd-resolved)"
        active_text="$(service_state systemd-resolved)"
        echo
        echo -n "enabled : "
        case "$enabled_text" in
            enabled) ok "$enabled_text" ;;
            masked) warn "$enabled_text" ;;
            *) warn "$enabled_text" ;;
        esac
        echo
        echo -n "active  : "
        case "$active_text" in
            active) ok "$active_text" ;;
            inactive|failed) warn "$active_text" ;;
            *) warn "$active_text" ;;
        esac
    fi

    echo
    echo "profile"
    if [[ -f "$RESOLVED_DROPIN_FILE" ]]; then
        cat "$RESOLVED_DROPIN_FILE"
    else
        echo "none"
    fi
}

unlock_only() {
    if ! need_lock_tools; then
        warn "Canceled."
        return 1
    fi
    unlock_resolv
    if is_locked; then
        warn "Unlock failed."
    else
        ok "Unlocked."
    fi
}

main_menu() {
    while true; do
        clear_screen
        print_header
        print_menu_item "1" "Test DNS"                 "compare Cloudflare vs Google with round-robin sampling"
        echo
        print_menu_item "2" "Force apply + lock"       "write resolv.conf directly and try immutable lock"
        echo
        print_menu_item "3" "Reinstall resolved"       "reinstall systemd-resolved and apply selected profile"
        echo
        print_menu_item "4" "Unlock only"              "remove immutable bit from /etc/resolv.conf"
        echo
        print_menu_item "5" "Show status"              "inspect current mode, lock state, and active profile"
        echo
        print_menu_item "0" "Exit"                     "leave without changing anything"
        echo
        if ! read -r -p "Choose [0-5]: " action; then
            clear_screen
            return 0
        fi
        echo

        case "$action" in
            1)
                test_dns || true
                pause
                ;;
            2)
                if choose_profile; then
                    apply_locked_file || true
                fi
                pause
                ;;
            3)
                if choose_profile; then
                    reinstall_resolved_apply || true
                fi
                pause
                ;;
            4)
                unlock_only || true
                pause
                ;;
            5)
                show_status
                pause
                ;;
            0)
                clear_screen
                return 0
                ;;
            *)
                warn "Invalid choice."
                pause
                ;;
        esac
    done
}

need_root
main_menu
