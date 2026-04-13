#!/usr/bin/env bash

set -euo pipefail

SCRIPT_FILE="google_vs_cf.sh"
SCRIPT_TITLE="google_vs_cf"
SCRIPT_VERSION="0.1"
SCRIPT_AUTHOR="Doudou Zhang"

ITERATIONS=8
DIG_TIMEOUT=2
QTYPE="A"

TEST_DNS_SERVERS=("1.1.1.1" "8.8.8.8")
TEST_DNS_LABELS=("Cloudflare Primary" "Google Primary")
DOMAINS=("google.com" "youtube.com" "instagram.com" "telegram.org" "x.com" "netflix.com")

CF_PRIMARY="1.1.1.1"
CF_SECONDARY="1.0.0.1"
CF_DOT_SNI="cloudflare-dns.com"
CF_DOH_URL="https://cloudflare-dns.com/dns-query"

GOOGLE_PRIMARY="8.8.8.8"
GOOGLE_SECONDARY="8.8.4.4"
GOOGLE_DOT_SNI="dns.google"
GOOGLE_DOH_URL="https://dns.google/dns-query"

RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="$RESOLVED_DROPIN_DIR/99-google-vs-cf.conf"
DOH_DIR="/etc/google-vs-cf"
DOH_CONFIG_FILE="$DOH_DIR/cloudflared.yml"
DOH_SERVICE_FILE="/etc/systemd/system/google-vs-cf-doh.service"
DOH_LISTEN_IP="127.0.0.1"
DOH_LISTEN_PORT="5053"

TRANSPORT_MODE="dot"
TRANSPORT_NAME="DoT"
PROFILE_KEY=""
PROFILE_NAME=""
PRIMARY_DNS=""
SECONDARY_DNS=""
PRIMARY_SNI=""
SECONDARY_SNI=""
DOH_UPSTREAM_1=""
DOH_UPSTREAM_2=""

if [[ -t 1 ]]; then
    C1=$'\033[38;5;45m'
    C2=$'\033[38;5;82m'
    C3=$'\033[38;5;214m'
    C4=$'\033[38;5;203m'
    CB=$'\033[1m'
    CR=$'\033[0m'
else
    C1=""; C2=""; C3=""; C4=""; CB=""; CR=""
fi

LINE="=========================================================================="
SUBLINE="--------------------------------------------------------------------------"

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

clear_screen() {
    clear 2>/dev/null || true
}

print_banner() {
    local resolved_text mode_text
    resolved_text="$(resolved_summary)"
    mode_text="$(mode_summary)"
    echo "$LINE"
    echo "${CB}${C1}${SCRIPT_TITLE}${CR}  ${CB}v ${SCRIPT_VERSION}${CR}  |  ${SCRIPT_AUTHOR}"
    echo "Transport : ${C3}${TRANSPORT_NAME}${CR}"
    echo "Mode      : ${C2}${mode_text}${CR}"
    echo "Resolved  : ${resolved_text}"
    echo "$LINE"
}

section() {
    echo "$LINE"
    echo "${CB}$1${CR}"
    echo "$LINE"
}

subsection() {
    echo "$SUBLINE"
    echo "$1"
    echo "$SUBLINE"
}

info() { echo "${C1}$*${CR}"; }
ok()   { echo "${C2}$*${CR}"; }
warn() { echo "${C3}$*${CR}"; }
err()  { echo "${C4}$*${CR}"; }

have_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

service_exists() {
    have_systemctl && systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pkg_install() {
    local -a pkgs=("$@")

    if ! command -v apt-get >/dev/null 2>&1; then
        err "apt is required: ${pkgs[*]}"
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    info "Installing: ${pkgs[*]}"
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
}

ensure_base_dependencies() {
    local -a missing=()
    command -v dig >/dev/null 2>&1 || missing+=(dnsutils)
    command -v timeout >/dev/null 2>&1 || missing+=(coreutils)
    command -v awk >/dev/null 2>&1 || missing+=(gawk)
    command -v sort >/dev/null 2>&1 || missing+=(coreutils)
    command -v chattr >/dev/null 2>&1 || missing+=(e2fsprogs)
    command -v lsattr >/dev/null 2>&1 || missing+=(e2fsprogs)
    command -v getent >/dev/null 2>&1 || missing+=(libc-bin)
    command -v sed >/dev/null 2>&1 || missing+=(sed)
    command -v dpkg-query >/dev/null 2>&1 || missing+=(dpkg)

    if [[ ${#missing[@]} -gt 0 ]]; then
        mapfile -t missing < <(printf '%s\n' "${missing[@]}" | awk '!seen[$0]++')
        pkg_install "${missing[@]}"
    fi
}

ensure_probe_dependencies() {
    local -a missing=()
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v curl >/dev/null 2>&1 || missing+=(curl)

    if [[ ${#missing[@]} -gt 0 ]]; then
        mapfile -t missing < <(printf '%s\n' "${missing[@]}" | awk '!seen[$0]++')
        pkg_install "${missing[@]}"
    fi
}

ensure_resolved_package() {
    if ! pkg_installed systemd-resolved; then
        pkg_install systemd-resolved
    fi
}

ensure_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        err "apt is required for cloudflared."
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    info "Installing: cloudflared"
    if ! apt-get update -y; then
        err "apt-get update failed for cloudflared."
        return 1
    fi
    if ! apt-get install -y cloudflared; then
        err "cloudflared is not available. Use DoT or locked file mode."
        return 1
    fi

    command -v cloudflared >/dev/null 2>&1
}

is_resolv_locked() {
    [[ -e /etc/resolv.conf ]] || return 1
    lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

resolve_mode() {
    if [[ -L /etc/resolv.conf ]]; then
        echo "resolved link"
    elif [[ -f /etc/resolv.conf ]]; then
        if is_resolv_locked; then
            echo "locked file"
        else
            echo "plain file"
        fi
    else
        echo "missing"
    fi
}

mode_summary() {
    echo "$(resolve_mode)"
}

resolved_summary() {
    if pkg_installed systemd-resolved; then
        if have_systemctl && service_exists systemd-resolved.service; then
            local enabled active
            enabled="$(systemctl is-enabled systemd-resolved 2>/dev/null || true)"
            active="$(systemctl is-active systemd-resolved 2>/dev/null || true)"
            echo "installed / ${enabled:-unknown} / ${active:-unknown}"
        else
            echo "installed / service missing"
        fi
    else
        echo "not installed"
    fi
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

set_profile_meta() {
    PRIMARY_SNI="$CF_DOT_SNI"
    SECONDARY_SNI="$GOOGLE_DOT_SNI"
    DOH_UPSTREAM_1="$CF_DOH_URL"
    DOH_UPSTREAM_2="$GOOGLE_DOH_URL"

    case "$PROFILE_KEY" in
        cf)
            PROFILE_NAME="CF Dual"
            PRIMARY_DNS="$CF_PRIMARY"
            SECONDARY_DNS="$CF_SECONDARY"
            PRIMARY_SNI="$CF_DOT_SNI"
            SECONDARY_SNI="$CF_DOT_SNI"
            DOH_UPSTREAM_1="$CF_DOH_URL"
            DOH_UPSTREAM_2=""
            ;;
        google)
            PROFILE_NAME="Google Dual"
            PRIMARY_DNS="$GOOGLE_PRIMARY"
            SECONDARY_DNS="$GOOGLE_SECONDARY"
            PRIMARY_SNI="$GOOGLE_DOT_SNI"
            SECONDARY_SNI="$GOOGLE_DOT_SNI"
            DOH_UPSTREAM_1="$GOOGLE_DOH_URL"
            DOH_UPSTREAM_2=""
            ;;
        cf-first)
            PROFILE_NAME="CF First, Google Fallback"
            PRIMARY_DNS="$CF_PRIMARY"
            SECONDARY_DNS="$GOOGLE_PRIMARY"
            PRIMARY_SNI="$CF_DOT_SNI"
            SECONDARY_SNI="$GOOGLE_DOT_SNI"
            DOH_UPSTREAM_1="$CF_DOH_URL"
            DOH_UPSTREAM_2="$GOOGLE_DOH_URL"
            ;;
        google-first)
            PROFILE_NAME="Google First, CF Fallback"
            PRIMARY_DNS="$GOOGLE_PRIMARY"
            SECONDARY_DNS="$CF_PRIMARY"
            PRIMARY_SNI="$GOOGLE_DOT_SNI"
            SECONDARY_SNI="$CF_DOT_SNI"
            DOH_UPSTREAM_1="$GOOGLE_DOH_URL"
            DOH_UPSTREAM_2="$CF_DOH_URL"
            ;;
        *)
            return 1
            ;;
    esac
}

choose_profile_by_key() {
    PROFILE_KEY="$1"
    set_profile_meta
}

show_profile_brief() {
    echo "Profile   : $PROFILE_NAME"
    echo "Order     : $PRIMARY_DNS  ->  $SECONDARY_DNS"
    if [[ "$TRANSPORT_MODE" == "dot" ]]; then
        echo "SNI       : $PRIMARY_SNI  ->  $SECONDARY_SNI"
    elif [[ "$TRANSPORT_MODE" == "doh" ]]; then
        echo "Upstream  : $DOH_UPSTREAM_1${DOH_UPSTREAM_2:+  ->  $DOH_UPSTREAM_2}"
    fi
}

print_transport_menu() {
    section "Upstream mode"
    echo "01) Plain DNS"
    echo "02) DoT  (recommended)"
    echo "03) DoH"
    echo "0)  Keep current"
}

choose_transport_mode() {
    while true; do
        print_transport_menu
        read -r -p "Select [0-3]: " choice
        case "$choice" in
            1|01)
                TRANSPORT_MODE="plain"
                TRANSPORT_NAME="Plain DNS"
                return 0
                ;;
            2|02)
                TRANSPORT_MODE="dot"
                TRANSPORT_NAME="DoT"
                return 0
                ;;
            3|03)
                TRANSPORT_MODE="doh"
                TRANSPORT_NAME="DoH"
                return 0
                ;;
            0)
                return 0
                ;;
            *)
                err "Invalid choice."
                echo
                ;;
        esac
    done
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
                err "Invalid choice."
                echo
                continue
                ;;
        esac
    done

    echo
    subsection "Selected"
    show_profile_brief
    return 0
}

unlock_resolv_conf_only() {
    section "Unlock only"

    if [[ ! -e /etc/resolv.conf ]]; then
        warn "/etc/resolv.conf is missing."
        return 0
    fi

    if is_resolv_locked; then
        chattr -i /etc/resolv.conf
        if is_resolv_locked; then
            err "Unlock failed."
            return 1
        fi
        ok "Unlocked."
    else
        warn "No immutable lock found."
    fi
}

show_plain_test_overview() {
    section "Plain DNS test"
    echo "Compare : 1.1.1.1  vs  8.8.8.8"
    echo "Domains : ${DOMAINS[*]}"
    echo "Runs    : $ITERATIONS per domain"
    echo "Timeout : dig +time=$DIG_TIMEOUT"
}

benchmark_fixed_dns_pair() {
    local outer_timeout=$((DIG_TIMEOUT + 1))
    local dns label domain i output rc qtime status idx
    local -a summary_rows=()

    show_plain_test_overview

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

    while IFS='|' read -r _key dns alias min max avg median bad; do
        printf "%-15s | %-18s | %-6s | %-6s | %-7s | %-7s | %-4s\n" "$dns" "$alias" "$min" "$max" "$avg" "$median" "$bad"
        if [[ "$median" != "N/A" && $first_done -eq 0 ]]; then
            best_dns="$dns"
            best_alias="$alias"
            best_median="$median"
            first_done=1
        fi
    done < <(printf '%s\n' "${summary_rows[@]}" | sort -t'|' -k1,1n)

    echo
    if [[ -n "$best_dns" ]]; then
        ok "Best median: $best_dns  [$best_alias]  (${best_median} ms)"
    else
        err "No valid result."
    fi
}

cleanup_doh_helper() {
    if have_systemctl; then
        systemctl stop google-vs-cf-doh.service 2>/dev/null || true
        systemctl disable google-vs-cf-doh.service 2>/dev/null || true
    fi
    rm -f "$DOH_SERVICE_FILE" "$DOH_CONFIG_FILE"
    rmdir "$DOH_DIR" 2>/dev/null || true
    if have_systemctl; then
        systemctl daemon-reload 2>/dev/null || true
    fi
}

purge_resolved_stack() {
    cleanup_doh_helper
    rm -f "$RESOLVED_DROPIN_FILE"

    if have_systemctl && service_exists systemd-resolved.service; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl mask systemd-resolved 2>/dev/null || true
    fi

    if pkg_installed systemd-resolved; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y systemd-resolved || true
        apt-get autoremove -y || true
    fi
}

write_locked_resolv_conf() {
    rm -f /etc/resolv.conf
    {
        echo "nameserver $PRIMARY_DNS"
        echo "nameserver $SECONDARY_DNS"
        echo "options timeout:2 attempts:2"
    } > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

render_resolved_dropin_plain() {
    cat > "$RESOLVED_DROPIN_FILE" <<EOF2
[Resolve]
DNS=$PRIMARY_DNS $SECONDARY_DNS
FallbackDNS=
Domains=~.
DNSOverTLS=no
EOF2
}

render_resolved_dropin_dot() {
    cat > "$RESOLVED_DROPIN_FILE" <<EOF2
[Resolve]
DNS=$PRIMARY_DNS#$PRIMARY_SNI $SECONDARY_DNS#$SECONDARY_SNI
FallbackDNS=
Domains=~.
DNSOverTLS=yes
EOF2
}

render_cloudflared_config() {
    mkdir -p "$DOH_DIR"
    {
        echo "proxy-dns: true"
        echo "proxy-dns-address: $DOH_LISTEN_IP"
        echo "proxy-dns-port: $DOH_LISTEN_PORT"
        echo "proxy-dns-upstream:"
        echo "  - $DOH_UPSTREAM_1"
        if [[ -n "$DOH_UPSTREAM_2" ]]; then
            echo "  - $DOH_UPSTREAM_2"
        fi
    } > "$DOH_CONFIG_FILE"
}

render_cloudflared_service() {
    cat > "$DOH_SERVICE_FILE" <<EOF2
[Unit]
Description=google_vs_cf local DoH helper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v cloudflared) proxy-dns --config $DOH_CONFIG_FILE
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF2
}

render_resolved_dropin_doh() {
    cat > "$RESOLVED_DROPIN_FILE" <<EOF2
[Resolve]
DNS=$DOH_LISTEN_IP:$DOH_LISTEN_PORT
FallbackDNS=
Domains=~.
DNSOverTLS=no
CacheFromLocalhost=yes
EOF2
}

link_resolv_to_resolved() {
    rm -f /etc/resolv.conf
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    elif [[ -e /run/systemd/resolve/resolv.conf ]]; then
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
        err "No systemd-resolved resolv.conf target found."
        return 1
    fi
}

apply_dns_lock() {
    section "Force apply + lock"
    show_profile_brief
    echo "Transport : locked file"
    echo "Action    : purge systemd-resolved"
    echo
    read -r -p "Continue? [y/N]: " answer
    case "$answer" in
        y|Y) ;;
        *) warn "Cancelled."; return 1 ;;
    esac

    unlock_resolv_conf_only >/dev/null 2>&1 || true
    purge_resolved_stack
    write_locked_resolv_conf

    if is_resolv_locked; then
        ok "Applied and locked."
    else
        warn "Applied, but immutable lock was not confirmed."
    fi
}

apply_resolved_profile() {
    section "Reinstall resolved + apply"
    show_profile_brief
    echo "Transport : $TRANSPORT_NAME"
    echo
    read -r -p "Continue? [y/N]: " answer
    case "$answer" in
        y|Y) ;;
        *) warn "Cancelled."; return 1 ;;
    esac

    unlock_resolv_conf_only >/dev/null 2>&1 || true
    ensure_resolved_package
    mkdir -p "$RESOLVED_DROPIN_DIR"

    case "$TRANSPORT_MODE" in
        plain)
            cleanup_doh_helper
            render_resolved_dropin_plain
            ;;
        dot)
            cleanup_doh_helper
            render_resolved_dropin_dot
            ;;
        doh)
            ensure_cloudflared || return 1
            render_cloudflared_config
            render_cloudflared_service
            render_resolved_dropin_doh
            if have_systemctl; then
                systemctl daemon-reload
                systemctl enable google-vs-cf-doh.service
                systemctl restart google-vs-cf-doh.service || systemctl start google-vs-cf-doh.service
            fi
            ;;
        *)
            err "Unknown transport."
            return 1
            ;;
    esac

    if have_systemctl && service_exists systemd-resolved.service; then
        systemctl unmask systemd-resolved || true
        systemctl enable systemd-resolved || true
        systemctl restart systemd-resolved || systemctl start systemd-resolved
    fi

    link_resolv_to_resolved
    ok "Resolved applied."
}

probe_plain_dns() {
    local dns="$1" name="$2" output rc qtime status
    output=""
    rc=0
    if output=$(timeout 4s dig @"$dns" example.com A +tries=1 +time=2 +comments +stats 2>/dev/null); then
        rc=0
    else
        rc=$?
    fi

    if [[ "$rc" -ne 0 ]]; then
        printf "%-15s : FAIL\n" "$name"
        return 1
    fi

    qtime=$(awk '/Query time:/ {print $4; exit}' <<< "$output")
    status=$(awk '/^;; ->>HEADER<<-/ { s=$0; sub(/.*status: /,"",s); sub(/,.*/,"",s); print s; exit }' <<< "$output")
    if [[ "$status" == "NOERROR" && "$qtime" =~ ^[0-9]+$ ]]; then
        printf "%-15s : OK    %sms\n" "$name" "$qtime"
        return 0
    fi

    printf "%-15s : FAIL\n" "$name"
    return 1
}

probe_dot_endpoint() {
    local ip="$1" sni="$2" name="$3" out
    out=$(timeout 6s bash -lc "printf '' | openssl s_client -connect ${ip}:853 -servername ${sni} -verify_hostname ${sni} -brief 2>/dev/null" || true)
    if grep -qiE 'Verification: OK|CONNECTION ESTABLISHED|Protocol *:' <<< "$out"; then
        printf "%-15s : OK\n" "$name"
        return 0
    fi
    printf "%-15s : FAIL\n" "$name"
    return 1
}

probe_doh_endpoint() {
    local name="$1" host="$2" ip="$3" url="$4" cmd_rc=0
    if curl -fsS --connect-timeout 4 --max-time 8 \
        --resolve "${host}:443:${ip}" \
        -H 'accept: application/dns-json' \
        --get --data-urlencode 'name=example.com' --data-urlencode 'type=A' \
        "$url" >/dev/null 2>&1; then
        printf "%-15s : OK\n" "$name"
        return 0
    fi
    printf "%-15s : FAIL\n" "$name"
    return 1
}

probe_upstream() {
    local good=0 total=0
    section "Probe upstream"
    echo "Transport : $TRANSPORT_NAME"
    echo

    case "$TRANSPORT_MODE" in
        plain)
            total=2
            probe_plain_dns "$CF_PRIMARY" "Cloudflare" && ((good+=1)) || true
            probe_plain_dns "$GOOGLE_PRIMARY" "Google" && ((good+=1)) || true
            ;;
        dot)
            ensure_probe_dependencies
            total=2
            probe_dot_endpoint "$CF_PRIMARY" "$CF_DOT_SNI" "Cloudflare" && ((good+=1)) || true
            probe_dot_endpoint "$GOOGLE_PRIMARY" "$GOOGLE_DOT_SNI" "Google" && ((good+=1)) || true
            ;;
        doh)
            ensure_probe_dependencies
            total=2
            probe_doh_endpoint "Cloudflare" "cloudflare-dns.com" "$CF_PRIMARY" "$CF_DOH_URL" && ((good+=1)) || true
            probe_doh_endpoint "Google" "dns.google" "$GOOGLE_PRIMARY" "$GOOGLE_DOH_URL" && ((good+=1)) || true
            ;;
        *)
            err "Unknown transport."
            return 1
            ;;
    esac

    echo
    if [[ $good -eq $total ]]; then
        ok "Probe looks good for $TRANSPORT_NAME."
    elif [[ $good -gt 0 ]]; then
        warn "Partial pass. Interference may exist."
        warn "If resolved is unstable here, use Force apply + lock."
    else
        err "Encrypted upstream looks blocked or unstable."
        err "Use Force apply + lock instead of resolved mode."
    fi
}

show_current_dns_state() {
    section "Current DNS status"
    echo "Transport : $TRANSPORT_NAME"
    echo "Mode      : $(mode_summary)"
    echo "Resolved  : $(resolved_summary)"
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
    subsection "Lock"
    if is_resolv_locked; then
        ok "immutable : yes"
    else
        echo "immutable : no"
    fi
    lsattr /etc/resolv.conf 2>/dev/null || true

    echo
    subsection "systemd-resolved"
    if pkg_installed systemd-resolved && have_systemctl && service_exists systemd-resolved.service; then
        echo -n "enabled : "
        systemctl is-enabled systemd-resolved 2>/dev/null || true
        echo -n "active  : "
        systemctl is-active systemd-resolved 2>/dev/null || true
    else
        echo "systemd-resolved not installed"
    fi

    if [[ -f "$RESOLVED_DROPIN_FILE" ]]; then
        echo
        subsection "resolved drop-in"
        cat "$RESOLVED_DROPIN_FILE"
    fi

    if [[ -f "$DOH_CONFIG_FILE" || -f "$DOH_SERVICE_FILE" ]]; then
        echo
        subsection "DoH helper"
        [[ -f "$DOH_CONFIG_FILE" ]] && { echo "config:"; cat "$DOH_CONFIG_FILE"; }
        echo
        [[ -f "$DOH_SERVICE_FILE" ]] && { echo "service:"; cat "$DOH_SERVICE_FILE"; }
        if have_systemctl; then
            echo
            echo -n "helper  : "
            systemctl is-active google-vs-cf-doh.service 2>/dev/null || true
        fi
    fi

    if command -v resolvectl >/dev/null 2>&1; then
        echo
        subsection "resolvectl"
        resolvectl status 2>/dev/null | awk '
            /^Global/ || /^Link/ || /Current DNS Server:/ || /DNS Servers:/ || /DNS Domain:/ || /Protocols:/ { print }
        ' || true
    fi
}

main_menu() {
    while true; do
        clear_screen
        print_banner
        echo "1) Test plain DNS"
        echo "2) Probe selected transport"
        echo "3) Force apply + lock"
        echo "4) Reinstall resolved + apply"
        echo "5) Unlock only"
        echo "6) Show status"
        echo "7) Change transport"
        echo "0) Exit"
        echo
        read -r -p "Select [0-7]: " action
        echo

        case "$action" in
            1)
                benchmark_fixed_dns_pair
                pause_return
                ;;
            2)
                probe_upstream
                pause_return
                ;;
            3)
                if choose_profile; then
                    apply_dns_lock
                fi
                pause_return
                ;;
            4)
                if choose_profile; then
                    apply_resolved_profile
                fi
                pause_return
                ;;
            5)
                unlock_resolv_conf_only
                pause_return
                ;;
            6)
                show_current_dns_state
                pause_return
                ;;
            7)
                choose_transport_mode
                pause_return
                ;;
            0)
                break
                ;;
            *)
                err "Invalid choice."
                pause_return
                ;;
        esac
    done
}

need_root
ensure_base_dependencies
clear_screen
print_banner
choose_transport_mode
main_menu
