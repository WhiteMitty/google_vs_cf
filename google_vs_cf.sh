#!/usr/bin/env bash

set -euo pipefail

APP_NAME="google_vs_cf"
VERSION="0.1.0"
AUTHOR="Doudou Zhang"

TEST_DNS=("1.1.1.1" "8.8.8.8")
TEST_LABELS=("Cloudflare" "Google")
DOMAINS=("google.com" "youtube.com" "instagram.com" "telegram.org" "x.com" "netflix.com")
ITERATIONS=8
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
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_TITLE=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RESET=""
fi

LINE="============================================================"
SUBLINE="------------------------------------------------------------"

say()  { echo "$*"; }
ok()   { echo "${C_OK}$*${C_RESET}"; }
warn() { echo "${C_WARN}$*${C_RESET}"; }
err()  { echo "${C_ERR}$*${C_RESET}"; }

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

print_header() {
    echo "$LINE"
    echo "${C_TITLE}${APP_NAME}${C_RESET}  v ${VERSION}  |  ${AUTHOR}"
    echo "Mode     : $(resolv_mode)"
    echo "Resolved : $(resolved_summary)"
    echo "$SUBLINE"
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

resolved_summary() {
    if pkg_installed systemd-resolved; then
        echo "installed / $(enabled_state systemd-resolved) / $(service_state systemd-resolved)"
    else
        echo "purged or not installed"
    fi
}

is_locked() {
    [[ -e /etc/resolv.conf ]] || return 1
    lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

resolv_mode() {
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

fmt_header() {
    printf "%-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$1" "Min" "Max" "Avg" "Median" "Bad"
}

fmt_row() {
    printf "%-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$1" "$2" "$3" "$4" "$5" "$6"
}

choose_profile() {
    while true; do
        echo "$SUBLINE"
        echo "DNS profiles"
        echo "$SUBLINE"
        echo "1) CF Dual              1.1.1.1  ->  1.0.0.1"
        echo "2) Google Dual          8.8.8.8  ->  8.8.4.4"
        echo "3) CF First             1.1.1.1  ->  8.8.8.8"
        echo "4) Google First         8.8.8.8  ->  1.1.1.1"
        echo "0) Back"
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
    echo "$SUBLINE"
    echo "Force apply + lock"
    echo "$SUBLINE"
    echo "Profile : $PROFILE_NAME"
    echo "DNS     : $DNS1 -> $DNS2"
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
    echo "$SUBLINE"
    echo "Reinstall resolved + apply"
    echo "$SUBLINE"
    echo "Profile : $PROFILE_NAME"
    echo "DNS     : $DNS1 -> $DNS2"
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

test_dns() {
    local dns label domain output rc qtime status bad_count total_bad min max avg median
    local -a times=() all_times=() summary_rows=()

    echo "$SUBLINE"
    echo "Test DNS"
    echo "$SUBLINE"
    echo "Targets : 1.1.1.1 vs 8.8.8.8"
    echo "Domains : ${DOMAINS[*]}"
    echo "Rounds  : $ITERATIONS"
    echo

    for idx in 0 1; do
        dns="${TEST_DNS[$idx]}"
        label="${TEST_LABELS[$idx]}"
        echo "@$dns  ($label)"
        fmt_header "Domain"
        echo "$SUBLINE"

        all_times=()
        total_bad=0

        for domain in "${DOMAINS[@]}"; do
            times=()
            bad_count=0

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
                            times+=("$qtime")
                            all_times+=("$qtime")
                        else
                            bad_count=$((bad_count + 1))
                        fi
                        ;;
                    *)
                        bad_count=$((bad_count + 1))
                        ;;
                esac

                printf "." >&2
                sleep 0.05
            done

            total_bad=$((total_bad + bad_count))
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
            summary_rows+=("${median/./}|$dns|$label|$min|$max|$avg|$median|$total_bad")
            fmt_row "TOTAL" "$min" "$max" "$avg" "$median" "$total_bad"
        else
            summary_rows+=("999999|$dns|$label|N/A|N/A|N/A|N/A|$total_bad")
            fmt_row "TOTAL" "N/A" "N/A" "N/A" "N/A" "$total_bad"
        fi

        echo
    done

    echo "$SUBLINE"
    echo "Summary"
    echo "$SUBLINE"
    fmt_header "DNS"
    echo "$SUBLINE"
    printf "%s\n" "${summary_rows[@]}" | sort -t'|' -k1,1n | while IFS='|' read -r _k dns label min max avg median bad; do
        fmt_row "$dns" "$min" "$max" "$avg" "$median" "$bad"
    done
}

show_status() {
    echo "$SUBLINE"
    echo "Status"
    echo "$SUBLINE"
    echo "resolv.conf"
    if [[ -L /etc/resolv.conf ]]; then
        echo "type   : symlink"
        echo "target : $(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf 2>/dev/null || true)"
    elif [[ -f /etc/resolv.conf ]]; then
        echo "type   : file"
    else
        echo "type   : missing"
    fi

    if is_locked; then
        echo "lock   : yes"
    else
        echo "lock   : no"
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
    echo "package : $(if pkg_installed systemd-resolved; then echo installed; else echo purged; fi)"
    echo "enabled : $(enabled_state systemd-resolved)"
    echo "active  : $(service_state systemd-resolved)"

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
        echo "2) Force apply + lock"
        echo "3) Reinstall resolved + apply"
        echo "4) Unlock only"
        echo "5) Show status"
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
                break
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
