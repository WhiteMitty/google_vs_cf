#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="google_vs_cf.sh"
SCRIPT_VERSION="v0.1"
SCRIPT_AUTHOR="Douduo Zhang"

ITERATIONS=8
DIG_TIMEOUT=2
OUTER_TIMEOUT=$((DIG_TIMEOUT + 1))
QTYPE="A"
DOMAINS=("google.com" "youtube.com" "instagram.com" "telegram.org" "x.com" "netflix.com")
TEST_DNS_SERVERS=("1.1.1.1" "8.8.8.8")
TEST_DNS_NAMES=("Cloudflare" "Google")

RESOLVED_PKG="systemd-resolved"
RESOLVED_SERVICE="systemd-resolved.service"
DROPIN_DIR="/etc/systemd/resolved.conf.d"
DROPIN_FILE="$DROPIN_DIR/99-google-vs-cf.conf"
LINE="======================================================================"
SUBLINE="----------------------------------------------------------------------"

PROFILE_KEY=""
PROFILE_NAME=""
PRIMARY_DNS=""
SECONDARY_DNS=""

if [[ -t 1 ]]; then
    R='\033[0m'; B='\033[1m'; D='\033[2m'; C='\033[36m'; G='\033[32m'; Y='\033[33m'; E='\033[31m'; M='\033[35m'
else
    R=''; B=''; D=''; C=''; G=''; Y=''; E=''; M=''
fi

say()  { printf "%b%s%b\n" "$2" "$1" "$R"; }
info() { say "$1" "$C"; }
ok()   { say "$1" "$G"; }
warn() { say "$1" "$Y"; }
fail() { say "$1" "$E"; }
head1(){ echo "$LINE"; say "$1" "$B$C"; echo "$LINE"; }
head2(){ echo "$SUBLINE"; say "$1" "$B"; echo "$SUBLINE"; }

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        fail "Run as root: sudo bash $SCRIPT_NAME"
        exit 1
    fi
}

pause_menu() {
    echo
    read -r -p "Press Enter to continue..." _
}

apt_ok() {
    command -v apt-get >/dev/null 2>&1
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pkg_install() {
    local -a pkgs=("$@")
    apt_ok || { fail "apt is required."; exit 1; }
    export DEBIAN_FRONTEND=noninteractive
    info "Installing: ${pkgs[*]}"
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
}

pkg_purge() {
    local -a pkgs=("$@")
    apt_ok || { fail "apt is required."; exit 1; }
    export DEBIAN_FRONTEND=noninteractive
    info "Purging: ${pkgs[*]}"
    apt-get purge -y "${pkgs[@]}"
}

ensure_dependencies() {
    local -a pkgs=()
    command -v dig >/dev/null 2>&1 || pkgs+=(dnsutils)
    command -v timeout >/dev/null 2>&1 || pkgs+=(coreutils)
    command -v awk >/dev/null 2>&1 || pkgs+=(gawk)
    command -v sort >/dev/null 2>&1 || pkgs+=(coreutils)
    command -v chattr >/dev/null 2>&1 || pkgs+=(e2fsprogs)
    command -v lsattr >/dev/null 2>&1 || pkgs+=(e2fsprogs)
    command -v getent >/dev/null 2>&1 || pkgs+=(libc-bin)
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | awk '!seen[$0]++')
        pkg_install "${pkgs[@]}"
    fi
}

service_exists() {
    command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

resolv_locked() {
    [[ -e /etc/resolv.conf ]] || return 1
    lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

unlock_resolv() {
    [[ -e /etc/resolv.conf ]] || return 0
    chattr -i /etc/resolv.conf 2>/dev/null || true
}

write_resolv_file() {
    rm -f /etc/resolv.conf
    {
        echo "nameserver $PRIMARY_DNS"
        echo "nameserver $SECONDARY_DNS"
        echo "options timeout:2 attempts:2"
    } > /etc/resolv.conf
}

choose_profile_by_key() {
    case "$1" in
        cf)
            PROFILE_KEY="cf"
            PROFILE_NAME="CF Dual"
            PRIMARY_DNS="1.1.1.1"
            SECONDARY_DNS="1.0.0.1"
            ;;
        google)
            PROFILE_KEY="google"
            PROFILE_NAME="Google Dual"
            PRIMARY_DNS="8.8.8.8"
            SECONDARY_DNS="8.8.4.4"
            ;;
        cf-first)
            PROFILE_KEY="cf-first"
            PROFILE_NAME="CF First, Google Fallback"
            PRIMARY_DNS="1.1.1.1"
            SECONDARY_DNS="8.8.8.8"
            ;;
        google-first)
            PROFILE_KEY="google-first"
            PROFILE_NAME="Google First, CF Fallback"
            PRIMARY_DNS="8.8.8.8"
            SECONDARY_DNS="1.1.1.1"
            ;;
        *) return 1 ;;
    esac
}

profile_menu() {
    head2 "DNS Profile"
    echo "01) CF Dual                    1.1.1.1  ->  1.0.0.1"
    echo "02) Google Dual                8.8.8.8  ->  8.8.4.4"
    echo "03) CF First, Google Fallback  1.1.1.1  ->  8.8.8.8"
    echo "04) Google First, CF Fallback  8.8.8.8  ->  1.1.1.1"
    echo "0)  Back"
}

choose_profile() {
    while true; do
        profile_menu
        read -r -p "Select [0-4]: " x
        case "$x" in
            1|01) choose_profile_by_key cf; return 0 ;;
            2|02) choose_profile_by_key google; return 0 ;;
            3|03) choose_profile_by_key cf-first; return 0 ;;
            4|04) choose_profile_by_key google-first; return 0 ;;
            0) return 1 ;;
            *) warn "Invalid choice." ;;
        esac
        echo
    done
}

profile_brief() {
    echo "Profile : $PROFILE_NAME"
    echo "Order   : $PRIMARY_DNS -> $SECONDARY_DNS"
}

mode_text() {
    if [[ -L /etc/resolv.conf ]]; then
        echo "symlink"
    elif [[ -f /etc/resolv.conf ]]; then
        if resolv_locked; then
            echo "locked file"
        else
            echo "plain file"
        fi
    else
        echo "missing"
    fi
}

resolved_pkg_text() {
    if pkg_installed "$RESOLVED_PKG"; then
        echo "installed"
    else
        echo "not installed"
    fi
}

resolved_service_text() {
    if service_exists "$RESOLVED_SERVICE"; then
        local en ac
        en="$(systemctl is-enabled systemd-resolved 2>/dev/null || true)"
        ac="$(systemctl is-active systemd-resolved 2>/dev/null || true)"
        echo "enabled=$en, active=$ac"
    else
        echo "not found"
    fi
}

show_status() {
    head1 "Status"
    echo "Mode                 : $(mode_text)"
    echo "systemd-resolved pkg : $(resolved_pkg_text)"
    echo "systemd-resolved svc : $(resolved_service_text)"
    if resolv_locked; then
        echo "Immutable lock       : yes"
    else
        echo "Immutable lock       : no"
    fi
    echo
    echo "[/etc/resolv.conf]"
    if [[ -e /etc/resolv.conf ]]; then
        ls -l /etc/resolv.conf || true
        echo
        cat /etc/resolv.conf 2>/dev/null || true
    else
        echo "missing"
    fi
    echo
    echo "[lsattr]"
    if [[ -e /etc/resolv.conf ]]; then
        lsattr /etc/resolv.conf 2>/dev/null || true
    else
        echo "n/a"
    fi
    if [[ -f "$DROPIN_FILE" ]]; then
        echo
        echo "[$DROPIN_FILE]"
        cat "$DROPIN_FILE"
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

benchmark_fixed() {
    local idx dns label domain output rc qtime status bad_count total_bad min max avg median
    local -a all_times=() times=() rows=()

    head1 "DNS Benchmark"
    echo "Target  : Cloudflare vs Google"
    echo "Servers : 1.1.1.1 and 8.8.8.8"
    echo "Queries : $ITERATIONS"
    echo "Domains : ${DOMAINS[*]}"

    for idx in 0 1; do
        dns="${TEST_DNS_SERVERS[$idx]}"
        label="${TEST_DNS_NAMES[$idx]}"

        echo
        head2 "$label @$dns (ms)"
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
                        status=$(awk '/^;; ->>HEADER<<-/ { s=$0; sub(/.*status: /,"",s); sub(/,.*/,"",s); print s; exit }' <<< "$output")
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
                sleep 0.04
            done
            printf "\r" >&2
            total_bad=$((total_bad + bad_count))
            if [[ ${#times[@]} -gt 0 ]]; then
                read -r min max avg median <<< "$(calc_stats "${times[@]}")"
                fmt_row "$domain" "$min" "$max" "$avg" "$median" "$bad_count"
            else
                fmt_row "$domain" "N/A" "N/A" "N/A" "N/A" "$bad_count"
            fi
        done

        echo "$SUBLINE"
        if [[ ${#all_times[@]} -gt 0 ]]; then
            read -r min max avg median <<< "$(calc_stats "${all_times[@]}")"
            fmt_row "TOTAL" "$min" "$max" "$avg" "$median" "$total_bad"
            rows+=("${median/./}|$label|$dns|$min|$max|$avg|$median|$total_bad")
        else
            fmt_row "TOTAL" "N/A" "N/A" "N/A" "N/A" "$total_bad"
            rows+=("999999|$label|$dns|N/A|N/A|N/A|N/A|$total_bad")
        fi
    done

    echo
    head2 "Summary"
    printf "%-12s | %-9s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "Provider" "DNS" "Min" "Max" "Avg" "Median" "Bad"
    echo "$SUBLINE"
    printf "%s\n" "${rows[@]}" | sort -t'|' -k1,1n | while IFS='|' read -r _k label dns min max avg median bad; do
        printf "%-12s | %-9s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$label" "$dns" "$min" "$max" "$avg" "$median" "$bad"
    done
}

purge_resolved() {
    unlock_resolv
    if service_exists "$RESOLVED_SERVICE"; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl mask systemd-resolved 2>/dev/null || true
    fi
    if pkg_installed "$RESOLVED_PKG"; then
        pkg_purge "$RESOLVED_PKG"
    fi
    rm -f "$DROPIN_FILE"
}

force_apply() {
    choose_profile || return 0
    head1 "Force Apply"
    profile_brief
    echo
    echo "This will purge systemd-resolved and lock /etc/resolv.conf."
    read -r -p "Continue? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Cancelled."; return 0; }

    purge_resolved
    write_resolv_file
    chattr +i /etc/resolv.conf

    if resolv_locked; then
        ok "Applied and locked."
    else
        fail "Applied, but immutable lock was not confirmed."
        exit 1
    fi
}

write_resolved_dropin() {
    mkdir -p "$DROPIN_DIR"
    case "$PROFILE_KEY" in
        cf)
            cat > "$DROPIN_FILE" <<EOF2
[Resolve]
DNS=$PRIMARY_DNS $SECONDARY_DNS
EOF2
            ;;
        google)
            cat > "$DROPIN_FILE" <<EOF2
[Resolve]
DNS=$PRIMARY_DNS $SECONDARY_DNS
EOF2
            ;;
        cf-first|google-first)
            cat > "$DROPIN_FILE" <<EOF2
[Resolve]
DNS=$PRIMARY_DNS
FallbackDNS=$SECONDARY_DNS
EOF2
            ;;
        *)
            fail "Invalid profile key."
            exit 1
            ;;
    esac
}

restore_resolved_and_apply() {
    choose_profile || return 0
    head1 "Restore systemd-resolved"
    profile_brief
    echo
    echo "This will install systemd-resolved and apply the selected profile."
    read -r -p "Continue? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Cancelled."; return 0; }

    unlock_resolv
    if ! pkg_installed "$RESOLVED_PKG"; then
        pkg_install "$RESOLVED_PKG"
    fi

    write_resolved_dropin

    if service_exists "$RESOLVED_SERVICE"; then
        systemctl unmask systemd-resolved 2>/dev/null || true
        systemctl enable systemd-resolved
        systemctl restart systemd-resolved
    fi

    rm -f /etc/resolv.conf
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    elif [[ -e /run/systemd/resolve/resolv.conf ]]; then
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
        fail "systemd-resolved link target not found."
        exit 1
    fi

    ok "systemd-resolved restored."
}

unlock_only() {
    head1 "Unlock"
    if [[ ! -e /etc/resolv.conf ]]; then
        info "/etc/resolv.conf is missing."
        return 0
    fi
    if resolv_locked; then
        unlock_resolv
        if resolv_locked; then
            fail "Unlock failed."
            exit 1
        else
            ok "Unlocked."
        fi
    else
        info "No immutable lock found."
    fi
}

top_status() {
    echo "Mode    : $(mode_text)"
    echo "Resolved: $(resolved_pkg_text) / $(resolved_service_text)"
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        head1 "$SCRIPT_NAME  $SCRIPT_VERSION"
        echo "Author  : $SCRIPT_AUTHOR"
        top_status
        echo "$SUBLINE"
        echo "1) Test DNS"
        echo "2) Force apply DNS and lock"
        echo "3) Reinstall resolved and apply DNS"
        echo "4) Unlock only"
        echo "5) Show status"
        echo "0) Exit"
        read -r -p "Select [0-5]: " x
        echo
        case "$x" in
            1) benchmark_fixed; pause_menu ;;
            2) force_apply; pause_menu ;;
            3) restore_resolved_and_apply; pause_menu ;;
            4) unlock_only; pause_menu ;;
            5) show_status; pause_menu ;;
            0) break ;;
            *) warn "Invalid choice."; pause_menu ;;
        esac
    done
}

need_root
ensure_dependencies
main_menu
