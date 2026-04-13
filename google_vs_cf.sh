#!/usr/bin/env bash

set -euo pipefail

SCRIPT_FILE="google_vs_cf.sh"
SCRIPT_TITLE="google_vs_cf"
SCRIPT_VERSION="0.1"
SCRIPT_AUTHOR="Doudou Zhang"
SCRIPT_DESC="Compare / force apply / restore"

ITERATIONS=8
DIG_TIMEOUT=2
QTYPE="A"

TEST_DNS_SERVERS=("1.1.1.1" "8.8.8.8")
TEST_DNS_LABELS=("Cloudflare Primary" "Google Primary")
DOMAINS=("google.com" "youtube.com" "instagram.com" "telegram.org" "x.com" "netflix.com")

RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="$RESOLVED_DROPIN_DIR/99-google-vs-cf.conf"

LINE="=========================================================================="
SUBLINE="--------------------------------------------------------------------------"

PROFILE_KEY=""
PROFILE_NAME=""
PRIMARY_DNS=""
SECONDARY_DNS=""

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "Run as root: sudo bash $SCRIPT_FILE"
        exit 1
    fi
}

pause_return() {
    echo
    read -r -p "Press Enter to continue..." _dummy
}

print_banner() {
    echo "$LINE"
    echo "$SCRIPT_TITLE  v $SCRIPT_VERSION  |  $SCRIPT_AUTHOR"
    echo "$SCRIPT_DESC"
    echo "$LINE"
}

section() {
    echo "$LINE"
    echo "$1"
    echo "$LINE"
}

subsection() {
    echo "$SUBLINE"
    echo "$1"
    echo "$SUBLINE"
}

have_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

service_exists() {
    have_systemctl && systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

pkg_install() {
    local -a pkgs=("$@")

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "This system does not use apt. Cannot install: ${pkgs[*]}"
        echo "Install them manually and try again."
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    echo "Installing: ${pkgs[*]}"

    if ! apt-get update -y; then
        echo "apt-get update failed."
        echo "Run: apt-get update && apt-get install -y ${pkgs[*]}"
        exit 1
    fi

    if ! apt-get install -y "${pkgs[@]}"; then
        echo "Dependency install failed."
        echo "Run: apt-get install -y ${pkgs[*]}"
        exit 1
    fi
}

ensure_dependencies() {
    local -a missing_pkgs=()

    command -v dig >/dev/null 2>&1 || missing_pkgs+=(dnsutils)
    command -v timeout >/dev/null 2>&1 || missing_pkgs+=(coreutils)
    command -v awk >/dev/null 2>&1 || missing_pkgs+=(gawk)
    command -v sort >/dev/null 2>&1 || missing_pkgs+=(coreutils)
    command -v chattr >/dev/null 2>&1 || missing_pkgs+=(e2fsprogs)
    command -v lsattr >/dev/null 2>&1 || missing_pkgs+=(e2fsprogs)
    command -v getent >/dev/null 2>&1 || missing_pkgs+=(libc-bin)

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | awk '!seen[$0]++')
        pkg_install "${missing_pkgs[@]}"
    fi
}

is_resolv_locked() {
    [[ -e /etc/resolv.conf ]] || return 1
    lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

resolve_mode() {
    if [[ -L /etc/resolv.conf ]]; then
        echo "symlink"
    elif [[ -f /etc/resolv.conf ]]; then
        if is_resolv_locked; then
            echo "locked-file"
        else
            echo "plain-file"
        fi
    else
        echo "missing"
    fi
}

mode_summary() {
    local mode
    mode="$(resolve_mode)"
    case "$mode" in
        locked-file) echo "locked file" ;;
        plain-file)  echo "plain file" ;;
        symlink)     echo "resolved link" ;;
        missing)     echo "missing" ;;
        *)           echo "unknown" ;;
    esac
}

fmt_header() {
    printf "%-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$1" "Min" "Max" "Avg" "Median" "Bad"
}

fmt_row() {
    printf "%-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$1" "$2" "$3" "$4" "$5" "$6"
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
        *)
            return 1
            ;;
    esac
}

show_profile_brief() {
    echo "Profile : $PROFILE_NAME"
    echo "Order   : $PRIMARY_DNS  ->  $SECONDARY_DNS"
}

print_profile_menu() {
    section "DNS profile"
    echo "01) CF Dual                    1.1.1.1  ->  1.0.0.1"
    echo "02) Google Dual                8.8.8.8  ->  8.8.4.4"
    echo "03) CF First, Google Fallback  1.1.1.1  ->  8.8.8.8"
    echo "04) Google First, CF Fallback  8.8.8.8  ->  1.1.1.1"
    echo "0)  Back"
}

choose_profile() {
    while true; do
        print_profile_menu
        read -r -p "Select [0-4]: " choice
        case "$choice" in
            1|01) choose_profile_by_key cf; break ;;
            2|02) choose_profile_by_key google; break ;;
            3|03) choose_profile_by_key cf-first; break ;;
            4|04) choose_profile_by_key google-first; break ;;
            0) return 1 ;;
            *)
                echo "Invalid choice."
                echo
                continue
                ;;
        esac
        echo
        subsection "Selected profile"
        show_profile_brief
        return 0
    done
}

unlock_resolv_conf_only() {
    section "Unlock only"

    if [[ ! -e /etc/resolv.conf ]]; then
        echo "/etc/resolv.conf is missing."
        return 0
    fi

    if is_resolv_locked; then
        if chattr -i /etc/resolv.conf 2>/dev/null; then
            if is_resolv_locked; then
                echo "Unlock failed. immutable is still set."
                return 1
            fi
            echo "Unlocked."
        else
            echo "Unlock failed. chattr may be unsupported."
            return 1
        fi
    else
        echo "No immutable lock found."
    fi
}

show_test_overview() {
    section "DNS test"
    echo "Script  : $SCRIPT_TITLE v $SCRIPT_VERSION"
    echo "Author  : $SCRIPT_AUTHOR"
    echo "Mode    : fixed compare"
    echo "Compare : 1.1.1.1  vs  8.8.8.8"
    echo "Domains : ${DOMAINS[*]}"
    echo "Runs    : $ITERATIONS per domain"
    echo "Timeout : dig +time=$DIG_TIMEOUT"
}

benchmark_fixed_dns_pair() {
    local outer_timeout=$((DIG_TIMEOUT + 1))
    local dns label domain i output rc qtime status idx
    local -a summary_rows=()

    show_test_overview

    for idx in "${!TEST_DNS_SERVERS[@]}"; do
        dns="${TEST_DNS_SERVERS[$idx]}"
        label="${TEST_DNS_LABELS[$idx]}"

        echo
        subsection "DNS: @$dns [$label]  Unit: ms"
        fmt_header "Domain"
        echo "$SUBLINE"

        local -a all_times=()
        local -a times=()
        local total_bad=0
        local bad_count min max avg median

        for domain in "${DOMAINS[@]}"; do
            times=()
            bad_count=0

            for ((i=1; i<=ITERATIONS; i++)); do
                output=""
                rc=0
                if output=$(timeout "${outer_timeout}s" dig @"$dns" "$domain" "$QTYPE" \
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
                        status=$(awk '/^;; ->>HEADER<<-/ {
                            s=$0; sub(/.*status: /,"",s); sub(/,.*/,"",s); print s; exit
                        }' <<< "$output")
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

        echo "$SUBLINE"
        if [[ ${#all_times[@]} -gt 0 ]]; then
            read -r min max avg median <<< "$(calc_stats "${all_times[@]}")"
            summary_rows+=("${median/./}|$dns|$label|$min|$max|$avg|$median|$total_bad")
            fmt_row "TOTAL" "$min" "$max" "$avg" "$median" "$total_bad"
        else
            summary_rows+=("999999|$dns|$label|N/A|N/A|N/A|N/A|$total_bad")
            fmt_row "TOTAL" "N/A" "N/A" "N/A" "N/A" "$total_bad"
        fi
    done

    echo
    section "Summary"
    printf "%-15s | %-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "DNS" "Alias" "Min" "Max" "Avg" "Median" "Bad"
    echo "$SUBLINE"

    local best_dns=""
    local best_alias=""
    local best_median=""
    local first_done=0

    if [[ ${#summary_rows[@]} -gt 0 ]]; then
        while IFS='|' read -r _key dns alias min max avg median bad; do
            printf "%-15s | %-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$dns" "$alias" "$min" "$max" "$avg" "$median" "$bad"
            if [[ "$median" != "N/A" && $first_done -eq 0 ]]; then
                best_dns="$dns"
                best_alias="$alias"
                best_median="$median"
                first_done=1
            fi
        done < <(printf '%s\n' "${summary_rows[@]}" | sort -t'|' -k1,1n)
    fi

    echo
    if [[ -n "$best_dns" ]]; then
        echo "Best median: $best_dns  [$best_alias]  (${best_median} ms)"
    else
        echo "No valid result."
    fi
}

apply_dns_lock() {
    section "Force apply + lock"
    show_profile_brief
    echo "Steps  : stop + disable + mask systemd-resolved"
    echo "         overwrite /etc/resolv.conf"
    echo "         chattr +i /etc/resolv.conf"
    echo
    echo "This uses locked file mode. Unlock first if you want to edit it later."
    echo
    read -r -p "Continue? [y/N]: " answer
    case "$answer" in
        y|Y) ;;
        *)
            echo "Cancelled."
            return 1
            ;;
    esac

    unlock_resolv_conf_only >/dev/null 2>&1 || true

    if have_systemctl && service_exists systemd-resolved.service; then
        systemctl stop systemd-resolved || true
        systemctl disable systemd-resolved || true
        systemctl mask systemd-resolved || true
    fi

    rm -f /etc/resolv.conf
    {
        echo "nameserver $PRIMARY_DNS"
        echo "nameserver $SECONDARY_DNS"
        echo "options timeout:2 attempts:2"
    } > /etc/resolv.conf

    if chattr +i /etc/resolv.conf 2>/dev/null && is_resolv_locked; then
        echo "Applied and locked."
    else
        echo "Applied, but the immutable lock was not confirmed."
    fi

    echo
    echo "Mode: $(mode_summary)"
}

apply_resolved_profile() {
    section "Reinstall resolved + apply"
    show_profile_brief
    echo "Steps  : unmask + enable + restart systemd-resolved"
    echo "         write $RESOLVED_DROPIN_FILE"
    echo
    read -r -p "Continue? [y/N]: " answer
    case "$answer" in
        y|Y) ;;
        *)
            echo "Cancelled."
            return 1
            ;;
    esac

    unlock_resolv_conf_only >/dev/null 2>&1 || true

    mkdir -p "$RESOLVED_DROPIN_DIR"
    cat > "$RESOLVED_DROPIN_FILE" <<EOF2
[Resolve]
DNS=$PRIMARY_DNS $SECONDARY_DNS
FallbackDNS=
Domains=~.
EOF2

    if have_systemctl && service_exists systemd-resolved.service; then
        systemctl unmask systemd-resolved || true
        systemctl enable systemd-resolved || true
        systemctl restart systemd-resolved || systemctl start systemd-resolved || true
    fi

    rm -f /etc/resolv.conf
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    elif [[ -e /run/systemd/resolve/resolv.conf ]]; then
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
        echo "Could not find the standard resolved resolv.conf target."
    fi

    echo "systemd-resolved reinstalled and applied."
    echo
    echo "Mode: $(mode_summary)"
}

show_current_dns_state() {
    section "Current DNS status"

    echo "Mode : $(mode_summary)"
    echo

    if [[ -L /etc/resolv.conf ]]; then
        echo "resolv.conf : symlink"
        echo "target      : $(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf 2>/dev/null || true)"
    elif [[ -e /etc/resolv.conf ]]; then
        echo "resolv.conf : regular file"
    else
        echo "resolv.conf : missing"
    fi

    echo
    subsection "/etc/resolv.conf"
    cat /etc/resolv.conf 2>/dev/null || true

    echo
    subsection "Lock status"
    if is_resolv_locked; then
        echo "immutable : yes"
    else
        echo "immutable : no"
    fi
    lsattr /etc/resolv.conf 2>/dev/null || true

    echo
    subsection "systemd-resolved"
    if have_systemctl && service_exists systemd-resolved.service; then
        echo -n "enabled : "
        systemctl is-enabled systemd-resolved 2>/dev/null || true
        echo -n "active  : "
        systemctl is-active systemd-resolved 2>/dev/null || true
    else
        echo "systemd-resolved.service not found"
    fi

    if [[ -f "$RESOLVED_DROPIN_FILE" ]]; then
        echo
        subsection "resolved drop-in"
        cat "$RESOLVED_DROPIN_FILE"
    fi

    if command -v resolvectl >/dev/null 2>&1; then
        echo
        subsection "resolvectl"
        resolvectl status 2>/dev/null | awk '
            /^Global/ || /^Link/ || /Current DNS Server:/ || /DNS Servers:/ || /DNS Domain:/ { print }
        ' || true
    fi
}

print_main_menu() {
    print_banner
    echo "01) Test DNS"
    echo "02) Force apply + lock"
    echo "03) Reinstall resolved + apply"
    echo "04) Unlock only"
    echo "05) Show status"
    echo "00)  Exit"
    echo
    echo "Mode: $(mode_summary)"
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        print_main_menu
        read -r -p "Select [0-5]: " action
        echo

        case "$action" in
            1|01)
                benchmark_fixed_dns_pair
                ;;
            2|02)
                if choose_profile; then
                    echo
                    apply_dns_lock
                fi
                ;;
            3|03)
                if choose_profile; then
                    echo
                    apply_resolved_profile
                fi
                ;;
            4|04)
                unlock_resolv_conf_only
                ;;
            5|05)
                show_current_dns_state
                ;;
            0|00)
                echo "Bye."
                break
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac

        pause_return
    done
}

need_root
ensure_dependencies
main_menu
