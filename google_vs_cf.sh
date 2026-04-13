#!/usr/bin/env bash

set -euo pipefail

APP_NAME="google_vs_cf"
VERSION="0.1.0"
AUTHOR="Doudou Zhang"

TEST_DNS=("1.1.1.1" "8.8.8.8")
TEST_LABELS=("Cloudflare" "Google")
DOMAINS=(
    "google.com"
    "youtube.com"
    "instagram.com"
    "telegram.org"
    "x.com"
    "netflix.com"
    "wikipedia.org"
    "bbc.com"
    "reuters.com"
)
ITERATIONS=12
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

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "Run as root: sudo bash google_vs_cf.sh"
        exit 1
    fi
}

pause() {
    echo
    read -r -p "Press Enter to return..." _dummy
}

clear_screen() {
    clear 2>/dev/null || true
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
        printf "%spurged or not installed%s" "$C_ERR" "$C_RESET"
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

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

service_state() {
    local unit="$1"
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "n/a"
        return 0
    fi
    systemctl is-active "$unit" 2>/dev/null || true
}

enabled_state() {
    local unit="$1"
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "n/a"
        return 0
    fi
    systemctl is-enabled "$unit" 2>/dev/null || true
}

resolved_summary_raw() {
    if pkg_installed systemd-resolved; then
        echo "installed|$(enabled_state systemd-resolved)|$(service_state systemd-resolved)"
    else
        echo "purged|n/a|n/a"
    fi
}

is_locked() {
    [[ -e /etc/resolv.conf ]] || return 1
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

pkg_install() {
    local -a pkgs=("$@")
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
}

ensure_tools() {
    local -a missing=()
    command -v dig >/dev/null 2>&1 || missing+=(dnsutils)
    command -v timeout >/dev/null 2>&1 || missing+=(coreutils)
    command -v awk >/dev/null 2>&1 || missing+=(gawk)
    command -v sort >/dev/null 2>&1 || missing+=(coreutils)
    command -v chattr >/dev/null 2>&1 || missing+=(e2fsprogs)
    command -v lsattr >/dev/null 2>&1 || missing+=(e2fsprogs)
    command -v dpkg-query >/dev/null 2>&1 || missing+=(dpkg)

    if [[ ${#missing[@]} -gt 0 ]]; then
        mapfile -t missing < <(printf '%s\n' "${missing[@]}" | awk '!seen[$0]++')
        pkg_install "${missing[@]}"
    fi
}

calc_stats() {
    if [[ $# -eq 0 ]]; then
        echo "N/A N/A N/A N/A"
        return 0
    fi
    printf "%s\n" "$@" | sort -n | awk '
    { arr[++count]=$1; sum+=$1 }
    END {
        if (!count) { printf "N/A N/A N/A N/A"; exit }
        min=arr[1]; max=arr[count]; avg=sum/count
        median=(count%2==1) ? arr[(count+1)/2] : (arr[count/2]+arr[count/2+1])/2
        printf "%d %d %.2f %.2f", min, max, avg, median
    }'
}

calc_score() {
    local avg="$1"
    local median="$2"
    local bad="$3"
    local total_rounds="$4"
    awk -v avg="$avg" -v median="$median" -v bad="$bad" -v total="$total_rounds" 'BEGIN {
        if (avg == "N/A" || median == "N/A") {
            print "N/A"
            exit
        }
        bad_ratio = (total > 0) ? bad / total : 1
        score = (median * 0.72) + (avg * 0.23) + (bad_ratio * 18)
        printf "%.2f", score
    }'
}

fmt_header() {
    printf "%-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$1" "Min" "Max" "Avg" "Median" "Bad"
}

fmt_row() {
    printf "%-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$1" "$2" "$3" "$4" "$5" "$6"
}

fmt_summary_header() {
    printf "%-18s | %-7s | %-7s | %-4s | %-6s\n" "DNS" "Avg" "Median" "Bad" "Score"
}

fmt_summary_row() {
    printf "%-18s | %-7s | %-7s | %-4s | %-6s\n" "$1" "$2" "$3" "$4" "$5"
}

choose_profile() {
    while true; do
        echo "DNS profiles"
        echo "$SUBLINE"
        echo
        echo "1) CF Dual        1.1.1.1  ->  1.0.0.1"
        echo
        echo "2) Google Dual    8.8.8.8  ->  8.8.4.4"
        echo
        echo "3) CF First       1.1.1.1  ->  8.8.8.8"
        echo
        echo "4) Google First   8.8.8.8  ->  1.1.1.1"
        echo
        echo "0) Back"
        echo
        read -r -p "Choose [0-4]: " choice
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
    if [[ -e /etc/resolv.conf ]]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
}

cleanup_old_google_vs_cf() {
    rm -f "$RESOLVED_DROPIN_FILE"
    rm -f "$LEGACY_DOH_SERVICE"
    rm -rf "$LEGACY_DOH_DIR"
    systemctl daemon-reload 2>/dev/null || true
}

purge_resolved() {
    unlock_resolv
    cleanup_old_google_vs_cf

    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    systemctl mask systemd-resolved 2>/dev/null || true

    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y systemd-resolved 2>/dev/null || apt-get remove --purge -y systemd-resolved 2>/dev/null || true
}

apply_locked_file() {
    echo "Force apply + lock"
    echo "$SUBLINE"
    echo
    echo "Profile : $PROFILE_NAME"
    echo
    echo "DNS     : $DNS1 -> $DNS2"
    echo
    read -r -p "Continue? [y/N]: " answer
    case "$answer" in
        y|Y) ;;
        *) warn "Canceled."; return 1 ;;
    esac

    purge_resolved

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
    read -r -p "Continue? [y/N]: " answer
    case "$answer" in
        y|Y) ;;
        *) warn "Canceled."; return 1 ;;
    esac

    unlock_resolv
    cleanup_old_google_vs_cf

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install --reinstall -y systemd-resolved

    mkdir -p "$RESOLVED_DROPIN_DIR"
    cat > "$RESOLVED_DROPIN_FILE" <<CFG
[Resolve]
DNS=$DNS1 $DNS2
Domains=~.
DNSSEC=no
CFG

    systemctl unmask systemd-resolved 2>/dev/null || true
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    systemctl restart systemd-resolved

    rm -f /etc/resolv.conf
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    elif [[ -e /run/systemd/resolve/resolv.conf ]]; then
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
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
    local cf_bad="$7"
    local google_bad="$8"
    local cf_zero="$9"
    local google_zero="${10}"

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

    local winner loser winner_score loser_score winner_avg winner_median winner_bad
    if awk -v a="$cf_score" -v b="$google_score" 'BEGIN { exit !(a <= b) }'; then
        winner="Cloudflare"
        loser="Google"
        winner_score="$cf_score"
        loser_score="$google_score"
        winner_avg="$cf_avg"
        winner_median="$cf_median"
        winner_bad="$cf_bad"
    else
        winner="Google"
        loser="Cloudflare"
        winner_score="$google_score"
        loser_score="$cf_score"
        winner_avg="$google_avg"
        winner_median="$google_median"
        winner_bad="$google_bad"
    fi

    local diff level
    diff=$(awk -v a="$winner_score" -v b="$loser_score" 'BEGIN { d=b-a; if (d < 0) d=-d; printf "%.2f", d }')

    if awk -v d="$diff" 'BEGIN { exit !(d < 1.2) }'; then
        level="Slight edge"
    elif awk -v d="$diff" 'BEGIN { exit !(d < 3.2) }'; then
        level="Recommended"
    else
        level="Strongly recommended"
    fi

    ok "$level: $winner"
    echo "Why     : lower median first, lower average second, fewer bad results helps."
    echo "Score   : $winner $winner_score  vs  $loser $loser_score"
    echo "Winner  : median $winner_median ms, avg $winner_avg ms, bad $winner_bad"

    if (( cf_zero > 0 || google_zero > 0 )); then
        echo "Zero ms : ignored in stats and recommendation."
    fi

    if (( cf_bad > 0 || google_bad > 0 )); then
        echo "Note    : bad results add a mild penalty."
    fi
}

test_dns() {
    local dns label domain output rc qtime status bad_count zero_count total_bad total_zero min max avg median score idx i
    local -a times=() all_times=() summary_rows=()
    local cf_score="N/A" google_score="N/A"
    local cf_avg="N/A" google_avg="N/A"
    local cf_median="N/A" google_median="N/A"
    local cf_bad=0 google_bad=0
    local cf_zero=0 google_zero=0
    local total_rounds=$(( ${#DOMAINS[@]} * ITERATIONS ))

    echo "Test DNS"
    echo "$SUBLINE"
    echo
    echo "Targets : 1.1.1.1 vs 8.8.8.8"
    echo
    echo "Domains : ${DOMAINS[*]}"
    echo
    echo "Rounds  : $ITERATIONS"
    echo
    echo "Rule    : 0 ms is ignored in stats and recommendation"
    echo

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

        for domain in "${DOMAINS[@]}"; do
            times=()
            bad_count=0
            zero_count=0

            for ((i=1; i<=ITERATIONS; i++)); do
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
                                times+=("$qtime")
                                all_times+=("$qtime")
                            else
                                zero_count=$((zero_count + 1))
                            fi
                        else
                            bad_count=$((bad_count + 1))
                        fi
                        ;;
                    *)
                        bad_count=$((bad_count + 1))
                        ;;
                esac

                printf "." >&2
                sleep 0.03
            done

            total_bad=$((total_bad + bad_count))
            total_zero=$((total_zero + zero_count))
            printf "\r" >&2

            if [[ ${#times[@]} -gt 0 ]]; then
                read -r min max avg median <<< "$(calc_stats "${times[@]}")"
                fmt_row "$domain" "$min" "$max" "$avg" "$median" "$bad_count"
            else
                fmt_row "$domain" "N/A" "N/A" "N/A" "N/A" "$bad_count"
            fi
        done

        if [[ ${#all_times[@]} -gt 0 ]]; then
            read -r min max avg median <<< "$(calc_stats "${all_times[@]}")"
            score=$(calc_score "$avg" "$median" "$total_bad" "$total_rounds")
            summary_rows+=("$score|$dns|$label|$avg|$median|$total_bad|$total_zero")
            fmt_row "TOTAL" "$min" "$max" "$avg" "$median" "$total_bad"
        else
            score="N/A"
            summary_rows+=("999999|$dns|$label|N/A|N/A|$total_bad|$total_zero")
            fmt_row "TOTAL" "N/A" "N/A" "N/A" "N/A" "$total_bad"
        fi

        echo
        echo "Ignored  : zero ms = $total_zero"
        echo

        if [[ "$label" == "Cloudflare" ]]; then
            cf_score="$score"; cf_avg="$avg"; cf_median="$median"; cf_bad="$total_bad"; cf_zero="$total_zero"
        else
            google_score="$score"; google_avg="$avg"; google_median="$median"; google_bad="$total_bad"; google_zero="$total_zero"
        fi
    done

    echo "Summary"
    echo "$SUBLINE"
    echo
    fmt_summary_header
    echo "$SUBLINE"
    printf "%s\n" "${summary_rows[@]}" | sort -t'|' -k1,1g | while IFS='|' read -r score dns label avg median bad zero; do
        fmt_summary_row "$dns" "$avg" "$median" "$bad" "$score"
    done

    print_recommendation "$cf_score" "$google_score" "$cf_avg" "$google_avg" "$cf_median" "$google_median" "$cf_bad" "$google_bad" "$cf_zero" "$google_zero"
}

show_status() {
    local lock_text package_text mode_text
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
    if is_locked; then
        ok "yes"
    else
        warn "no"
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
    package_text="$(if pkg_installed systemd-resolved; then echo installed; else echo purged; fi)"
    echo -n "package : "
    if [[ "$package_text" == "installed" ]]; then ok "$package_text"; else err "$package_text"; fi
    echo
    echo -n "enabled : "
    case "$(enabled_state systemd-resolved)" in
        enabled) ok "enabled" ;;
        masked) warn "masked" ;;
        *) warn "$(enabled_state systemd-resolved)" ;;
    esac
    echo
    echo -n "active  : "
    case "$(service_state systemd-resolved)" in
        active) ok "active" ;;
        inactive|failed) warn "$(service_state systemd-resolved)" ;;
        *) warn "$(service_state systemd-resolved)" ;;
    esac

    echo
    echo "profile"
    if [[ -f "$RESOLVED_DROPIN_FILE" ]]; then
        cat "$RESOLVED_DROPIN_FILE"
    else
        echo "none"
    fi
}

unlock_only() {
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
        echo "1) Test DNS"
        echo
        echo "2) Force apply + lock"
        echo
        echo "3) Reinstall resolved + apply"
        echo
        echo "4) Unlock only"
        echo
        echo "5) Show status"
        echo
        echo "0) Exit"
        echo
        read -r -p "Choose [0-5]: " action
        echo

        case "$action" in
            1)
                test_dns
                pause
                ;;
            2)
                if choose_profile; then
                    apply_locked_file
                fi
                pause
                ;;
            3)
                if choose_profile; then
                    reinstall_resolved_apply
                fi
                pause
                ;;
            4)
                unlock_only
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
ensure_tools
main_menu
