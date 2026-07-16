#!/usr/bin/env bash

set -Eeuo pipefail

# Chinese text needs a UTF-8 character locale so Bash can calculate terminal
# column widths correctly. C.UTF-8 is available on supported Debian/Ubuntu.
_UTF8_PROBE="测"
if (( ${#_UTF8_PROBE} != 1 )); then
    LC_CTYPE=C.UTF-8
    export LC_CTYPE
fi
unset _UTF8_PROBE

TEST_DNS=("1.1.1.1" "8.8.8.8")
TEST_LABELS=("Cloudflare" "Google")
DOMAINS=(
    "x.com"          "bbc.com"        "twitch.tv"        "intel.com"
    "apple.com"      "amazon.com"     "fastly.com"       "akamai.com"
    "google.com"     "tiktok.com"     "github.com"       "youtube.com"
    "netflix.com"    "telegram.org"   "wikipedia.org"    "microsoft.com"
    "instagram.com"  "aws.amazon.com" "disneyplus.com"   "steampowered.com"
)

ITERATIONS="${ITERATIONS:-20}"
DIG_TIMEOUT="${DIG_TIMEOUT:-2}"
OUTER_TIMEOUT=""
QTYPE="A"

RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="$RESOLVED_DROPIN_DIR/99-google-vs-cf.conf"
LEGACY_DOH_DIR="/etc/google-vs-cf"
LEGACY_DOH_SERVICE="/etc/systemd/system/google-vs-cf-doh.service"

PROFILE_NAME=""
DNS1=""
DNS2=""
RESOLVED_PURGE_PLAN=""
RESOLVED_PURGE_FINGERPRINT=""

# Runtime-only state. No fetched script, PID, log, or temporary file is retained.
ACTIVE_QUERY_PID=""
ACTIVE_QUERY_FD=""
INPUT_FD=0
INPUT_FD_OWNED=0
RUNTIME_TEMP_FILE=""
SELF_PATH=""

if [[ -t 1 ]]; then
    C_TITLE=$'\033[1;93m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_ERR=$'\033[1;31m'
    C_INFO=$'\033[1;36m'
    C_LINE=$'\033[1;34m'
    C_VALUE=$'\033[1;35m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_TITLE=""; C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_LINE=""; C_VALUE=""; C_DIM=""; C_RESET=""
fi

HEADER_WIDTH=78
COMPARE_WIDTH=81
REPORT_WIDTH=84
MENU_PAD="  "
DISPLAY_WIDTH=0
REPEATED_TEXT=""

ok()   { echo "${C_OK}$*${C_RESET}"; }
warn() { echo "${C_WARN}$*${C_RESET}"; }
err()  { echo "${C_ERR}$*${C_RESET}" >&2; }

print_menu_item() {
    local key="$1"
    local title="$2"
    printf '%s%b%s%b) %b%s%b\n' \
        "$MENU_PAD" "$C_INFO" "$key" "$C_RESET" "$C_OK" "$title" "$C_RESET"
}

print_profile_item() {
    local key="$1"
    local title="$2"
    local dns="$3"
    local target_width=20 pad

    measure_display_width "$title"
    pad=$((target_width - DISPLAY_WIDTH))
    (( pad < 1 )) && pad=1

    printf '%s%b%s%b) %b%s%b%*s%b%s%b\n' \
        "$MENU_PAD" "$C_INFO" "$key" "$C_RESET" \
        "$C_OK" "$title" "$C_RESET" "$pad" "" \
        "$C_VALUE" "$dns" "$C_RESET"
}

measure_display_width() {
    local text="$1"
    local char
    local i
    DISPLAY_WIDTH=0

    for ((i=0; i<${#text}; i++)); do
        char="${text:i:1}"
        case "$char" in
            [[:ascii:]]|·|×|→|←|↔)
                DISPLAY_WIDTH=$((DISPLAY_WIDTH + 1))
                ;;
            *)
                DISPLAY_WIDTH=$((DISPLAY_WIDTH + 2))
                ;;
        esac
    done
}

repeat_text() {
    local char="$1"
    local count="$2"
    printf -v REPEATED_TEXT '%*s' "$count" ''
    REPEATED_TEXT="${REPEATED_TEXT// /$char}"
}

print_rule() {
    local width="${1:-$HEADER_WIDTH}"
    local char="${2:--}"
    repeat_text "$char" "$width"
    printf '%b%s%b\n' "$C_LINE" "$REPEATED_TEXT" "$C_RESET"
}

print_banner() {
    local title="$1"
    local available left right

    measure_display_width "$title"
    available=$((HEADER_WIDTH - DISPLAY_WIDTH - 2))
    (( available < 4 )) && available=4
    left=$((available / 2))
    right=$((available - left))

    repeat_text "=" "$left"
    local left_line="$REPEATED_TEXT"
    repeat_text "=" "$right"
    printf '%b%s%b %b%s%b %b%s%b\n' \
        "$C_LINE" "$left_line" "$C_RESET" \
        "$C_TITLE" "$title" "$C_RESET" \
        "$C_LINE" "$REPEATED_TEXT" "$C_RESET"
}

print_section_title() {
    local title="$1"
    printf '%b%s%b\n' "$C_TITLE" "$title" "$C_RESET"
    print_rule
    echo
}

print_report_title() {
    local title="$1"
    local width="${2:-$REPORT_WIDTH}"
    printf '%b%s%b\n' "$C_TITLE" "$title" "$C_RESET"
    print_rule "$width"
    echo
}

print_status_line() {
    local label="$1"
    local value="$2"
    local value_color="${3:-}"
    local target_width=12 pad

    measure_display_width "$label"
    pad=$((target_width - DISPLAY_WIDTH))
    (( pad < 1 )) && pad=1

    printf '%s%b%s%b%*s : %b%s%b\n' \
        "$MENU_PAD" "$C_OK" "$label" "$C_RESET" "$pad" "" \
        "$value_color" "$value" "$C_RESET"
}

print_detail_line() {
    local label="$1"
    local value="$2"
    local value_color="${3:-}"
    local target_width=10 pad

    measure_display_width "$label"
    pad=$((target_width - DISPLAY_WIDTH))
    (( pad < 1 )) && pad=1

    printf '%s%b%s%b%*s : %b%s%b\n' \
        "$MENU_PAD" "$C_INFO" "$label" "$C_RESET" "$pad" "" \
        "$value_color" "$value" "$C_RESET"
}

is_ipv4_address() {
    local address="$1"
    local a b c d extra octet

    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d extra <<< "$address"
    [[ -z "${extra:-}" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

current_ipv4_dns_servers() {
    local out=""
    local line token address key
    local -A seen=()
    local -a servers=()

    if command_exists resolvectl && [[ "$(service_state systemd-resolved)" == "active" ]]; then
        while IFS= read -r line; do
            for token in $line; do
                address="${token%%#*}"
                is_ipv4_address "$address" || continue
                if [[ -z "${seen["$address"]+present}" ]]; then
                    seen["$address"]=1
                    servers+=("$address")
                fi
            done
        done < <(resolvectl dns 2>/dev/null || true)
    fi

    if [[ ${#servers[@]} -eq 0 && -r /etc/resolv.conf ]]; then
        while read -r key address _; do
            [[ "$key" == "nameserver" && -n "${address:-}" ]] || continue
            is_ipv4_address "$address" || continue
            if [[ -z "${seen["$address"]+present}" ]]; then
                seen["$address"]=1
                servers+=("$address")
            fi
        done < /etc/resolv.conf
    fi

    for address in "${servers[@]}"; do
        out+="${out:+ / }$address"
    done
    printf '%s\n' "$out"
}

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "请使用 root 权限运行此脚本。"
        exit 1
    fi
}

pause() {
    local _dummy
    local prompt="${1:-按 Enter 返回...}"

    echo
    if ! read_user _dummy "${MENU_PAD}${prompt}"; then
        echo
    fi
}

clear_screen() {
    [[ -t 1 ]] && printf '\033[H\033[2J'
    return 0
}

pkg_installed() {
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_runtime_settings() {
    local iterations_value timeout_value

    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        err "需要 Bash 4.3 或更高版本。"
        return 1
    fi
    if [[ ! "$ITERATIONS" =~ ^[0-9]+$ || ${#ITERATIONS} -gt 3 ]]; then
        err "ITERATIONS 必须是 1 到 100 的整数。"
        return 1
    fi
    iterations_value=$((10#$ITERATIONS))
    if (( iterations_value < 1 || iterations_value > 100 )); then
        err "ITERATIONS 必须是 1 到 100 的整数。"
        return 1
    fi
    if [[ ! "$DIG_TIMEOUT" =~ ^[0-9]+$ || ${#DIG_TIMEOUT} -gt 2 ]]; then
        err "DIG_TIMEOUT 必须是 1 到 30 的整数。"
        return 1
    fi
    timeout_value=$((10#$DIG_TIMEOUT))
    if (( timeout_value < 1 || timeout_value > 30 )); then
        err "DIG_TIMEOUT 必须是 1 到 30 的整数。"
        return 1
    fi

    ITERATIONS="$iterations_value"
    DIG_TIMEOUT="$timeout_value"
    OUTER_TIMEOUT=$((timeout_value + 1))
}

capture_self_path() {
    local source="${BASH_SOURCE[0]:-}"
    local dir base absolute_dir

    case "$source" in
        ""|-|bash|sh|/dev/fd/*|/proc/*/fd/*)
            return 0
            ;;
    esac
    [[ -f "$source" || -L "$source" ]] || return 0

    dir="${source%/*}"
    base="${source##*/}"
    [[ "$dir" == "$source" ]] && dir="."
    if absolute_dir="$(cd -P -- "$dir" 2>/dev/null && pwd)"; then
        SELF_PATH="$absolute_dir/$base"
    fi
}

setup_input() {
    if [[ -t 0 ]]; then
        INPUT_FD=0
        return 0
    fi

    # Supports both:
    #   bash <(curl -fsSL URL)
    #   curl -fsSL URL | bash
    # The latter shares stdin with the script body, so prompts must use /dev/tty.
    if true 2>/dev/null </dev/tty \
        && { exec {INPUT_FD}<>/dev/tty; } 2>/dev/null; then
        INPUT_FD_OWNED=1
    else
        INPUT_FD=-1
        return 1
    fi
}

read_user() {
    local variable="$1"
    local prompt="${2:-}"
    if (( INPUT_FD < 0 )); then
        return 1
    fi

    # `read -p` is not reliable when input comes from a separately opened
    # /dev/tty descriptor. Restore terminal attributes and write the prompt
    # explicitly so it remains visible after the live test dashboard exits.
    test_ui_end
    if [[ -n "$prompt" ]]; then
        if (( INPUT_FD_OWNED == 1 )); then
            printf '%s' "$prompt" >&"$INPUT_FD"
        elif [[ -t 1 ]]; then
            printf '%s' "$prompt"
        elif [[ -t 2 ]]; then
            printf '%s' "$prompt" >&2
        elif printf '%s' "$prompt" 2>/dev/null > /dev/tty; then
            :
        else
            printf '%s' "$prompt" >&2
        fi
    fi
    IFS= read -r -u "$INPUT_FD" "$variable"
}

close_input_fd() {
    if (( INPUT_FD_OWNED == 1 )); then
        exec {INPUT_FD}<&- 2>/dev/null || true
        INPUT_FD_OWNED=0
        INPUT_FD=0
    fi
}

remove_runtime_script() {
    local path
    local -a paths=()

    [[ -n "$SELF_PATH" ]] && paths+=("$SELF_PATH")
    # Also remove a stale copy left by an older version when this release is
    # launched with `curl | bash` instead of from the downloaded file itself.
    if [[ ${EUID:-$(id -u)} -eq 0 && "$SELF_PATH" != "/root/google_vs_cf.sh" ]]; then
        paths+=("/root/google_vs_cf.sh")
    fi

    SELF_PATH=""
    for path in "${paths[@]}"; do
        case "$path" in
            /*) ;;
            *) continue ;;
        esac
        [[ -f "$path" || -L "$path" ]] || continue
        if ! rm -f -- "$path" 2>/dev/null; then
            printf '%b无法删除运行脚本：%s%b\n' "$C_ERR" "$path" "$C_RESET" >&2 || true
        fi
    done
    return 0
}

stop_active_query() {
    local pid="$ACTIVE_QUERY_PID"
    local fd="$ACTIVE_QUERY_FD"
    local child children=""
    ACTIVE_QUERY_FD=""

    if [[ -z "$pid" ]]; then
        if [[ -n "$fd" ]]; then
            exec {fd}<&- 2>/dev/null || true
        fi
        return 0
    fi

    if kill -0 "$pid" 2>/dev/null; then
        # Stop the monitored dig process first, then its timeout parent. This
        # avoids leaving an orphan if timeout itself must later be force-killed.
        if [[ -r "/proc/$pid/task/$pid/children" ]]; then
            IFS= read -r children < "/proc/$pid/task/$pid/children" || true
        fi
        for child in $children; do
            [[ "$child" =~ ^[0-9]+$ ]] || continue
            kill -TERM "$child" 2>/dev/null || true
        done
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.10 2>/dev/null || true
        for child in $children; do
            [[ "$child" =~ ^[0-9]+$ ]] || continue
            kill -KILL "$child" 2>/dev/null || true
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi

    if [[ -n "$fd" ]]; then
        exec {fd}<&- 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    ACTIVE_QUERY_PID=""
}

cleanup_runtime() {
    stop_active_query || true
    if [[ -n "$RUNTIME_TEMP_FILE" ]]; then
        rm -f -- "$RUNTIME_TEMP_FILE" 2>/dev/null || true
        RUNTIME_TEMP_FILE=""
    fi
    test_ui_end || true
    close_input_fd || true
    remove_runtime_script || true
}

on_exit() {
    local rc="$1"
    trap - EXIT
    trap '' INT TERM HUP QUIT
    cleanup_runtime || true
    trap - INT TERM HUP QUIT
    return "$rc"
}

on_signal() {
    local rc="$1"
    trap - EXIT
    trap '' INT TERM HUP QUIT
    cleanup_runtime || true
    trap - INT TERM HUP QUIT
    printf '\n'
    exit "$rc"
}

service_state() {
    local unit="$1"
    if ! command_exists systemctl; then
        echo "n/a"
        return 0
    fi
    systemctl is-active "$unit" 2>/dev/null || true
}

service_is_stopped_or_absent() {
    local state
    state="$(service_state "$1")"
    case "$state" in
        inactive|failed|unknown|not-found)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_locked() {
    local attrs

    [[ -e /etc/resolv.conf ]] || return 1
    command_exists lsattr || return 1
    attrs="$(lsattr -d -- /etc/resolv.conf 2>/dev/null)" || return 1
    attrs="${attrs%%[[:space:]]*}"
    [[ "$attrs" == *i* ]]
}

lock_state_raw() {
    if [[ ! -e /etc/resolv.conf ]]; then
        echo "missing"
    elif ! command_exists lsattr; then
        echo "unknown"
    elif is_locked; then
        echo "locked"
    else
        echo "unlocked"
    fi
}

resolv_mode_raw() {
    if [[ -L /etc/resolv.conf ]]; then
        local target
        target="$(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf 2>/dev/null || true)"
        if [[ "$target" == /run/systemd/resolve/* || "$target" == /usr/lib/systemd/* || "$target" == /lib/systemd/* ]]; then
            echo "resolved link"
        else
            echo "symlink"
        fi
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

color_lock() {
    local state
    state="$(lock_state_raw)"
    case "$state" in
        locked) printf "%s已锁定%s" "$C_WARN" "$C_RESET" ;;
        unlocked) printf "%s未锁定%s" "$C_OK" "$C_RESET" ;;
        missing) printf "%s无 resolv.conf%s" "$C_WARN" "$C_RESET" ;;
        *) printf "%s未知%s" "$C_WARN" "$C_RESET" ;;
    esac
}

print_header() {
    local dns_v4

    dns_v4="$(current_ipv4_dns_servers)"

    echo
    print_banner "Google vs Cloudflare · DNS 测速与配置"
    print_status_line "IPv4 DNS" "${dns_v4:-未配置}" "$C_VALUE"
    print_status_line "配置锁" "$(color_lock)"
    print_rule "$HEADER_WIDTH" "="
    echo
}

prompt_install_missing() {
    local -a input=("$@")
    local -a missing=()
    local -A seen=()
    local item

    for item in "${input[@]}"; do
        [[ -n "$item" ]] || continue
        if [[ -z "${seen["$item"]+present}" ]]; then
            seen["$item"]=1
            missing+=("$item")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi
    echo
    warn "缺少依赖：${missing[*]}"
    warn "临时脚本不自动安装依赖，请手动安装后再运行。"
    return 1
}

need_test_tools() {
    local -a missing=()

    command_exists dig || missing+=(dig)
    command_exists timeout || missing+=(timeout)
    command_exists awk || missing+=(awk)
    command_exists sort || missing+=(sort)

    prompt_install_missing "${missing[@]}"
}

need_dns_write_tools() {
    local -a missing=()

    command_exists mktemp || missing+=(mktemp)
    command_exists mv || missing+=(mv)
    command_exists chmod || missing+=(chmod)

    prompt_install_missing "${missing[@]}"
}

need_unlock_tool_if_locked() {
    if is_locked && ! command_exists chattr; then
        err "检测到 /etc/resolv.conf 已锁定，但系统没有 chattr，无法解锁。"
        return 1
    fi
    return 0
}

calc_stats() {
    if [[ $# -eq 0 ]]; then
        echo "N/A N/A N/A N/A N/A"
        return 0
    fi
    printf "%s\n" "$@" | sort -n | awk '
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
            printf "100.00%%"
            exit
        }
        printf "%.2f%%", (bad / total) * 100
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

fmt_summary_header() {
    printf "%b%-24s%b | %8s | %8s | %8s | %5s | %5s | %8s\n" \
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

    printf "%b%-24s%b | %8s | %8s | %8s | %5s | %5s | %8s\n" \
        "$color" "$label" "$C_RESET" "$avg" "$median" "$p90" "$bad" "$zero" "$score"
}

fmt_compare_header() {
    printf "%b%-20s%b | %b%-27s%b || %b%-27s%b\n" \
        "$C_TITLE" "Domain" "$C_RESET" \
        "$C_INFO" "Cloudflare" "$C_RESET" \
        "$C_INFO" "Google" "$C_RESET"
    printf "%-20s | %7s %7s %5s %5s || %7s %7s %5s %5s\n" \
        "" "Median" "P90" "Bad" "0ms" "Median" "P90" "Bad" "0ms"
}

fmt_compare_row() {
    local domain="$1"
    local cf_median="$2"
    local cf_p90="$3"
    local cf_bad="$4"
    local cf_zero="$5"
    local google_median="$6"
    local google_p90="$7"
    local google_bad="$8"
    local google_zero="$9"

    printf "%-20s | %7s %7s %5s %5s || %7s %7s %5s %5s\n" \
        "$domain" "$cf_median" "$cf_p90" "$cf_bad" "$cf_zero" "$google_median" "$google_p90" "$google_bad" "$google_zero"
}

test_ui_begin() {
    if [[ -t 1 ]]; then
        printf '\033[?25l'
    fi
}

test_ui_end() {
    if [[ -t 1 ]]; then
        printf '\033[0m\033[?25h'
    fi
}

run_dns_query() {
    local dns="$1"
    local domain="$2"
    local line="" pid fd raw_out_fd start_fd

    QUERY_OUTPUT=""
    QUERY_RC=1

    # The coprocess shell immediately execs timeout, so it does not remain as
    # a child Bash. ACTIVE_QUERY_PID is always waited for or killed by traps.
    if ! coproc DNS_QUERY {
        # Keep the coprocess alive until the parent has duplicated the output
        # descriptor. Without this handshake, an extremely fast child can
        # exit before Bash finishes exposing the second output line.
        if ! IFS= read -r _query_start || [[ "$_query_start" != "GO" ]]; then
            exit 125
        fi
        exec timeout --foreground -k 1s "${OUTER_TIMEOUT}s" \
            dig @"$dns" "$domain" "$QTYPE" \
            +tries=1 +time="$DIG_TIMEOUT" \
            +noquestion +noanswer +noauthority +noadditional \
            +comments +stats 2>/dev/null
    }; then
        QUERY_RC=125
        return 0
    fi

    pid="$!"
    ACTIVE_QUERY_PID="$pid"
    raw_out_fd="${DNS_QUERY[0]}"
    start_fd="${DNS_QUERY[1]}"
    if ! exec {fd}<&"$raw_out_fd"; then
        exec {raw_out_fd}<&- 2>/dev/null || true
        exec {start_fd}>&- 2>/dev/null || true
        stop_active_query
        unset DNS_QUERY DNS_QUERY_PID 2>/dev/null || true
        QUERY_RC=125
        return 0
    fi
    exec {raw_out_fd}<&- 2>/dev/null || true
    ACTIVE_QUERY_FD="$fd"
    if ! printf 'GO\n' >&"$start_fd"; then
        exec {start_fd}>&- 2>/dev/null || true
        stop_active_query
        unset DNS_QUERY DNS_QUERY_PID 2>/dev/null || true
        QUERY_RC=125
        return 0
    fi
    exec {start_fd}>&- 2>/dev/null || true

    while IFS= read -r line <&"$fd"; do
        QUERY_OUTPUT+="$line"$'\n'
    done

    ACTIVE_QUERY_FD=""
    exec {fd}<&- 2>/dev/null || true

    if wait "$pid"; then
        QUERY_RC=0
    else
        QUERY_RC=$?
    fi
    ACTIVE_QUERY_PID=""
    unset DNS_QUERY DNS_QUERY_PID 2>/dev/null || true
    return 0
}

draw_test_dashboard() {
    local current_label="$1"
    local current_domain="$2"
    local query_done="$3"
    local query_total="$4"
    local current_round="$5"
    local current_status="$6"
    local -n cf_live_ref="$7"
    local -n google_live_ref="$8"
    local i domain cf_live google_live

    [[ -t 1 ]] || return 0

    printf '\033[H\033[2J'
    echo
    print_banner "Google vs Cloudflare · DNS 实时测速"
    print_status_line "测试目标" "Cloudflare @1.1.1.1  |  Google @8.8.8.8" "$C_VALUE"
    print_status_line "测试模式" "IPv4 DNS 服务器 · A 记录查询"
    print_status_line "测试进度" "${query_done}/${query_total} · 第 ${current_round}/${ITERATIONS} 轮"
    print_status_line "当前查询" "${current_label} → ${current_domain}（${current_status}）"
    print_rule "$HEADER_WIDTH" "="
    echo
    printf "%b%-3s %-24s %-24s %-24s%b\n" "$C_TITLE" "#" "Domain" "Cloudflare" "Google" "$C_RESET"
    print_rule
    for ((i=0; i<${#DOMAINS[@]}; i++)); do
        domain="${DOMAINS[$i]}"
        cf_live="${cf_live_ref[$i]:-...}"
        google_live="${google_live_ref[$i]:-...}"
        printf "%b%02d%b  %-24.24s %-24s %-24s\n" "$C_DIM" "$((i + 1))" "$C_RESET" "$domain" "$cf_live" "$google_live"
    done
    echo
    printf '%s说明：12ms = 成功；0ms = 忽略；bad = 失败/超时；... = 等待\n' "$MENU_PAD"
    printf '%s方法：按域名轮询，每个域名测试 %s 轮；0 ms 不计入统计\n' "$MENU_PAD" "$ITERATIONS"
}

choose_profile() {
    local choice

    while true; do
        clear_screen
        print_header
        print_section_title "DNS 方案"
        print_profile_item "1" "Cloudflare" "1.1.1.1 / 1.0.0.1"
        print_profile_item "2" "Google"     "8.8.8.8 / 8.8.4.4"
        print_profile_item "3" "Cloudflare 优先" "1.1.1.1 / 8.8.8.8"
        print_profile_item "4" "Google 优先" "8.8.8.8 / 1.1.1.1"
        print_menu_item "0" "返回"
        echo
        print_rule
        echo
        if ! read_user choice "${MENU_PAD}请选择 [0-4]: "; then
            echo
            return 1
        fi
        case "$choice" in
            1)
                PROFILE_NAME="Cloudflare"
                DNS1="1.1.1.1"
                DNS2="1.0.0.1"
                return 0
                ;;
            2)
                PROFILE_NAME="Google"
                DNS1="8.8.8.8"
                DNS2="8.8.4.4"
                return 0
                ;;
            3)
                PROFILE_NAME="Cloudflare 优先"
                DNS1="1.1.1.1"
                DNS2="8.8.8.8"
                return 0
                ;;
            4)
                PROFILE_NAME="Google 优先"
                DNS1="8.8.8.8"
                DNS2="1.1.1.1"
                return 0
                ;;
            0)
                return 1
                ;;
            *)
                warn "无效选择，请输入 0-4。"
                pause "按 Enter 重新选择..."
                ;;
        esac
    done
}

legacy_dns_exists() {
    [[ -f "$LEGACY_DOH_SERVICE" || -d "$LEGACY_DOH_DIR" ]] && return 0
    command_exists systemctl \
        && systemctl cat google-vs-cf-doh.service >/dev/null 2>&1
}

cleanup_legacy_doh() {
    local unit_known=0

    if [[ -f "$LEGACY_DOH_SERVICE" ]]; then
        unit_known=1
    elif command_exists systemctl \
        && systemctl cat google-vs-cf-doh.service >/dev/null 2>&1; then
        unit_known=1
    fi

    if (( unit_known == 1 )); then
        if ! command_exists systemctl; then
            err "检测到旧 DoH 服务，但缺少 systemctl，无法确认其进程已停止。"
            return 1
        fi
        systemctl stop google-vs-cf-doh.service 2>/dev/null || true
        if ! service_is_stopped_or_absent google-vs-cf-doh.service; then
            err "旧 DoH 服务未确认停止，未删除其文件。当前状态：$(service_state google-vs-cf-doh.service)"
            return 1
        fi
        systemctl disable google-vs-cf-doh.service 2>/dev/null || true
    fi

    if ! rm -f "$LEGACY_DOH_SERVICE"; then
        err "删除旧 DoH 服务文件失败。"
        return 1
    fi
    if ! rm -rf "$LEGACY_DOH_DIR"; then
        err "删除旧 DoH 目录失败。"
        return 1
    fi

    if command_exists systemctl; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed google-vs-cf-doh.service 2>/dev/null || true
    fi
}

cleanup_resolved_dropin() {
    local reload_active="${1:-no}"
    if ! rm -f "$RESOLVED_DROPIN_FILE"; then
        err "删除 resolved drop-in 失败：$RESOLVED_DROPIN_FILE"
        return 1
    fi
    # Remove the directory only when it became empty. A directory containing
    # configuration owned by the user or another tool is left untouched.
    rmdir "$RESOLVED_DROPIN_DIR" 2>/dev/null || true
    if [[ "$reload_active" == "yes" ]] && command_exists systemctl \
        && [[ "$(service_state systemd-resolved)" == "active" ]]; then
        systemctl restart systemd-resolved
    fi
}

prompt_cleanup_legacy() {
    local answer

    if ! legacy_dns_exists; then
        return 0
    fi

    echo
    warn "检测到旧版 google-vs-cf DoH 服务或目录。"
    if ! read_user answer "${MENU_PAD}是否删除这些旧配置？[y/N]: "; then
        echo
        return 0
    fi
    case "$answer" in
        y|Y)
            if cleanup_legacy_doh; then
                ok "旧版 DoH 配置已清理。"
            else
                err "旧版 DoH 配置未能完全清理。"
                return 1
            fi
            ;;
        *)
            warn "已保留旧版 DoH 配置；旧服务可能覆盖本次 DNS 设置。"
            ;;
    esac
}

prompt_unlock_old_resolv_lock() {
    local answer

    if ! is_locked; then
        return 0
    fi

    echo
    warn "检测到 /etc/resolv.conf 已被 chattr +i 锁定。"
    if ! read_user answer "${MENU_PAD}是否先移除旧锁？[y/N]: "; then
        echo
        return 1
    fi
    case "$answer" in
        y|Y)
            need_unlock_tool_if_locked || return 1
            chattr -i /etc/resolv.conf 2>/dev/null || true
            if is_locked; then
                err "解锁失败。"
                return 1
            fi
            ok "已解锁。"
            ;;
        *)
            warn "已取消写入。"
            return 1
            ;;
    esac
}

write_resolv_file() {
    local tmp_file

    if ! RUNTIME_TEMP_FILE="$(mktemp /etc/.google_vs_cf.resolv.conf.XXXXXX)"; then
        RUNTIME_TEMP_FILE=""
        err "无法在 /etc 中创建临时 DNS 文件。"
        return 1
    fi
    tmp_file="$RUNTIME_TEMP_FILE"

    if ! {
        printf 'nameserver %s\n' "$DNS1"
        printf 'nameserver %s\n' "$DNS2"
        printf 'options timeout:2 attempts:2\n'
    } > "$tmp_file"; then
        err "写入临时 DNS 文件失败。"
        rm -f -- "$tmp_file" 2>/dev/null || true
        RUNTIME_TEMP_FILE=""
        return 1
    fi
    if ! chmod 0644 "$tmp_file"; then
        err "设置临时 DNS 文件权限失败。"
        rm -f -- "$tmp_file" 2>/dev/null || true
        RUNTIME_TEMP_FILE=""
        return 1
    fi
    if ! mv -fT -- "$tmp_file" /etc/resolv.conf; then
        err "原子替换 /etc/resolv.conf 失败；原文件保持不变。"
        rm -f -- "$tmp_file" 2>/dev/null || true
        RUNTIME_TEMP_FILE=""
        return 1
    fi
    RUNTIME_TEMP_FILE=""
}

prompt_lock_resolv() {
    local answer

    echo
    if ! read_user answer "${MENU_PAD}是否锁定 /etc/resolv.conf？[y/N]: "; then
        echo
        return 0
    fi
    case "$answer" in
        y|Y)
            if ! command_exists chattr; then
                warn "缺少 chattr，无法上锁；DNS 已写入但未锁定。"
                return 0
            fi
            chattr +i /etc/resolv.conf 2>/dev/null || true
            if is_locked; then
                ok "DNS 已写入并锁定。"
            else
                warn "DNS 已写入，但锁定失败。"
            fi
            ;;
        *)
            ok "DNS 已写入，未上锁。"
            ;;
    esac
}

write_direct_resolv() {
    prompt_unlock_old_resolv_lock || return 1
    cleanup_resolved_dropin || return 1
    write_resolv_file || return 1
    prompt_lock_resolv
}

prepare_resolved_purge_plan() {
    local output action package package_base found_target=0
    local -A seen=()
    local -a removals=() unsafe_removals=() installations=()

    RESOLVED_PURGE_PLAN=""
    RESOLVED_PURGE_FINGERPRINT=""

    if ! output="$(
        LC_ALL=C DEBIAN_FRONTEND=noninteractive \
            apt-get -o APT::Get::AutomaticRemove=false \
            --simulate purge systemd-resolved 2>&1
    )"; then
        err "APT 无法生成 systemd-resolved 卸载预演，未修改 DNS。"
        return 1
    fi

    while read -r action package _; do
        [[ -n "${package:-}" ]] || continue
        case "$action" in
            Remv)
                if [[ -z "${seen["remove:$package"]+present}" ]]; then
                    seen["remove:$package"]=1
                    removals+=("$package")
                    package_base="${package%%:*}"
                    case "$package_base" in
                        systemd-resolved) found_target=1 ;;
                        libnss-resolve) ;;
                        *) unsafe_removals+=("$package") ;;
                    esac
                fi
                ;;
            Inst)
                if [[ -z "${seen["install:$package"]+present}" ]]; then
                    seen["install:$package"]=1
                    installations+=("$package")
                fi
                ;;
        esac
    done <<< "$output"

    if (( found_target == 0 )); then
        err "APT 预演没有包含 systemd-resolved，已拒绝继续。"
        return 1
    fi
    if [[ ${#installations[@]} -gt 0 ]]; then
        err "安全检查未通过：APT 还计划安装：${installations[*]}"
        warn "请先手动处理软件包依赖，本脚本不会自动继续。"
        return 1
    fi
    if [[ ${#unsafe_removals[@]} -gt 0 ]]; then
        err "安全检查未通过：APT 还计划移除：${unsafe_removals[*]}"
        warn "为避免影响网络或系统组件，本脚本已拒绝卸载。"
        return 1
    fi

    RESOLVED_PURGE_PLAN="${removals[*]}"
    RESOLVED_PURGE_FINGERPRINT="${removals[*]}"
}

confirm_purge_resolved() {
    local answer package_installed=0

    RESOLVED_PURGE_PLAN=""
    RESOLVED_PURGE_FINGERPRINT=""

    if ! command_exists systemctl; then
        err "未找到 systemctl，无法安全管理 systemd-resolved。"
        return 1
    fi
    if pkg_installed systemd-resolved; then
        package_installed=1
        if ! command_exists apt-get; then
            err "未找到 apt-get，无法自动卸载 systemd-resolved。"
            return 1
        fi
        prepare_resolved_purge_plan || return 1
    fi

    clear_screen
    print_header
    print_section_title "检测到 systemd-resolved"
    print_selected_profile
    echo
    if (( package_installed == 1 )); then
        print_detail_line "处理方式" "卸载 systemd-resolved"
        print_detail_line "APT 计划" "$RESOLVED_PURGE_PLAN"
    else
        print_detail_line "处理方式" "停止并屏蔽 systemd-resolved"
    fi
    print_detail_line "DNS 模式" "改为普通 /etc/resolv.conf（仅 IPv4）"
    echo
    warn "${MENU_PAD}注意：这可能影响 NetworkManager、netplan 或系统默认 DNS 行为。"
    echo
    print_rule
    echo
    if ! read_user answer "${MENU_PAD}确认卸载/停用并继续，请输入 yes: "; then
        echo
        return 1
    fi
    answer="${answer,,}"
    if [[ "$answer" != "yes" ]]; then
        warn "已取消，DNS 配置未修改。"
        return 1
    fi
}

purge_resolved() {
    local package_installed=0 approved_fingerprint

    if pkg_installed systemd-resolved; then
        package_installed=1
    fi
    if (( package_installed == 1 )) && ! command_exists apt-get; then
        err "未找到 apt-get，无法自动卸载 systemd-resolved。"
        return 1
    fi
    if (( package_installed == 1 )); then
        approved_fingerprint="$RESOLVED_PURGE_FINGERPRINT"
        if [[ -z "$approved_fingerprint" ]]; then
            err "缺少已经确认的 APT 卸载计划，已拒绝继续。"
            return 1
        fi
        prepare_resolved_purge_plan || return 1
        if [[ "$RESOLVED_PURGE_FINGERPRINT" != "$approved_fingerprint" ]]; then
            err "APT 卸载计划已发生变化，已停止操作，请重新进入配置流程。"
            return 1
        fi
    fi

    # Only replace the resolver link after the package plan has passed its
    # second safety check. The plain file keeps DNS working while the service
    # is stopped and its package maintainer scripts run.
    write_resolv_file || return 1

    systemctl stop systemd-resolved 2>/dev/null || true
    if ! service_is_stopped_or_absent systemd-resolved; then
        err "systemd-resolved 未确认停止，已取消卸载。当前状态：$(service_state systemd-resolved)"
        return 1
    fi
    if ! systemctl disable systemd-resolved 2>/dev/null; then
        warn "systemd-resolved 无法禁用或属于静态单元；继续执行卸载。"
    fi
    cleanup_resolved_dropin || return 1

    if (( package_installed == 1 )); then
        if ! DEBIAN_FRONTEND=noninteractive \
            apt-get -o APT::Get::AutomaticRemove=false \
            purge -y systemd-resolved; then
            err "systemd-resolved 卸载失败；当前已使用普通 /etc/resolv.conf，请检查 apt/dpkg 状态。"
            return 1
        fi
        ok "systemd-resolved 已卸载。"
    else
        # Some distributions ship the unit inside the systemd package, where
        # it cannot be purged independently. Mask it so it cannot be activated
        # again behind the plain resolv.conf configuration.
        if ! systemctl mask systemd-resolved 2>/dev/null; then
            err "systemd-resolved 没有独立软件包，且无法屏蔽该服务。"
            return 1
        fi
        ok "systemd-resolved 没有独立软件包；已停止并屏蔽该服务。"
    fi
}

resolved_related_detected() {
    [[ "$(resolv_mode_raw)" == "resolved link" ]] && return 0
    pkg_installed systemd-resolved && return 0

    # An inactive bundled or previously masked unit does not participate in
    # DNS resolution and should not cause the removal prompt on every run.
    case "$(service_state systemd-resolved)" in
        active|activating|reloading|deactivating)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

print_selected_profile() {
    print_status_line "所选方案" "$PROFILE_NAME" "$C_INFO"
    print_status_line "IPv4 DNS" "$DNS1 / $DNS2" "$C_VALUE"
}

replace_resolved_with_plain_dns() {
    confirm_purge_resolved || return 1
    prompt_unlock_old_resolv_lock || return 1

    # purge_resolved writes working DNS after its final APT safety check. Write
    # it once more afterwards in case package scripts recreate the old link.
    purge_resolved || return 1
    write_resolv_file || return 1
    prompt_lock_resolv
}

apply_dns_profile() {
    local answer

    need_dns_write_tools || return 1

    clear_screen
    print_header
    print_section_title "应用 DNS 配置"
    print_selected_profile
    echo
    print_rule
    echo
    read_user answer "${MENU_PAD}继续？[y/N]: " || { echo; warn "已取消。"; return 1; }
    case "$answer" in
        y|Y) ;;
        *) warn "已取消。"; return 1 ;;
    esac

    prompt_cleanup_legacy || return 1

    if resolved_related_detected; then
        replace_resolved_with_plain_dns
    else
        write_direct_resolv
    fi
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
    print_report_title "推荐结果"

    if [[ "$cf_score" == "N/A" && "$google_score" == "N/A" ]]; then
        print_detail_line "结论" "没有有效结果" "$C_WARN"
        return 0
    fi

    if [[ "$cf_score" == "N/A" ]]; then
        print_detail_line "结论" "建议使用 Google；Cloudflare 没有有效评分" "$C_OK"
        return 0
    fi

    if [[ "$google_score" == "N/A" ]]; then
        print_detail_line "结论" "建议使用 Cloudflare；Google 没有有效评分" "$C_OK"
        return 0
    fi

    if [[ "$cf_bad" == "$google_bad" \
        && "$cf_median" == "$google_median" \
        && "$cf_p90" == "$google_p90" \
        && "$cf_avg" == "$google_avg" \
        && "$cf_score" == "$google_score" ]]; then
        print_detail_line "结论" "Cloudflare 与 Google 表现相当" "$C_INFO"
        print_detail_line "共同指标" "失败 $cf_bad/$total_rounds · Median $cf_median ms · P90 $cf_p90 ms · Average $cf_avg ms"
        if (( cf_zero > 0 || google_zero > 0 )); then
            print_detail_line "样本处理" "0 ms 样本已忽略（Cloudflare $cf_zero · Google $google_zero）"
        fi
        print_detail_line "测试方法" "按域名轮询，每个域名测试 $ITERATIONS 轮"
        return 0
    fi

    local winner loser winner_score loser_score winner_avg winner_median winner_p90 winner_bad
    local loser_avg loser_median loser_p90 loser_bad

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
        loser_avg="$google_avg"
        loser_median="$google_median"
        loser_p90="$google_p90"
        loser_bad="$google_bad"
    else
        winner="Google"
        loser="Cloudflare"
        winner_score="$google_score"
        loser_score="$cf_score"
        winner_avg="$google_avg"
        winner_median="$google_median"
        winner_p90="$google_p90"
        winner_bad="$google_bad"
        loser_avg="$cf_avg"
        loser_median="$cf_median"
        loser_p90="$cf_p90"
        loser_bad="$cf_bad"
    fi

    local diff level winner_ratio loser_ratio
    diff=$(awk -v a="$winner_score" -v b="$loser_score" 'BEGIN { d=b-a; if (d < 0) d=-d; printf "%.2f", d }')
    winner_ratio=$(calc_bad_ratio "$winner_bad" "$total_rounds")
    loser_ratio=$(calc_bad_ratio "$loser_bad" "$total_rounds")

    if awk -v d="$diff" 'BEGIN { exit !(d < 0.80) }'; then
        level="轻微优势"
    elif awk -v d="$diff" 'BEGIN { exit !(d < 2.20) }'; then
        level="推荐"
    else
        level="强烈推荐"
    fi

    print_detail_line "结论" "${level}：${winner}" "$C_OK"
    print_detail_line "比较原则" "失败率 → Median → P90 → Average"
    print_detail_line "综合得分" "$winner $winner_score  vs  $loser $loser_score"
    print_detail_line "推荐方" "$winner · 失败 $winner_bad/$total_rounds（$winner_ratio）"
    print_detail_line "推荐指标" "Median $winner_median ms · P90 $winner_p90 ms · Average $winner_avg ms"
    print_detail_line "对照方" "$loser · 失败 $loser_bad/$total_rounds（$loser_ratio）"
    print_detail_line "对照指标" "Median $loser_median ms · P90 $loser_p90 ms · Average $loser_avg ms"

    if (( cf_zero > 0 || google_zero > 0 )); then
        print_detail_line "样本处理" "0 ms 样本已忽略，不参与统计和推荐"
    fi

    print_detail_line "评分模型" "Score = Median + 0.35×尾延迟 + 0.10×偏斜 + 25×失败率"
    print_detail_line "测试方法" "按域名轮询，每个域名测试 $ITERATIONS 轮"
}

test_dns() {
    local dns label domain output rc qtime status min max avg median p90 score idx round step domain_count
    local start_offset query_done total_bad total_zero total_queries domain_idx current_status live_value total_rounds
    local bad_count zero_count
    local -a all_times=() times=() summary_rows=() cf_live_status=() google_live_status=()
    local -A domain_time_map=() domain_bad_map=() domain_zero_map=()
    local -A cf_avg_map=() cf_median_map=() cf_p90_map=() cf_bad_map=() cf_zero_map=()
    local -A google_avg_map=() google_median_map=() google_p90_map=() google_bad_map=() google_zero_map=()
    local cf_score="N/A" google_score="N/A"
    local cf_avg="N/A" google_avg="N/A"
    local cf_median="N/A" google_median="N/A"
    local cf_p90="N/A" google_p90="N/A"
    local cf_bad=0 google_bad=0
    local cf_zero=0 google_zero=0

    if ! need_test_tools; then
        warn "测速已取消。"
        return 1
    fi

    domain_count=${#DOMAINS[@]}
    total_rounds=$(( domain_count * ITERATIONS ))
    total_queries=$(( total_rounds * ${#TEST_DNS[@]} ))
    query_done=0

    for ((idx=0; idx<domain_count; idx++)); do
        cf_live_status[idx]="..."
        google_live_status[idx]="..."
    done

    test_ui_begin
    draw_test_dashboard "准备中" "等待任务" "$query_done" "$total_queries" 0 "待开始" cf_live_status google_live_status

    for idx in 0 1; do
        dns="${TEST_DNS[$idx]}"
        label="${TEST_LABELS[$idx]}"

        all_times=()
        total_bad=0
        total_zero=0

        for domain in "${DOMAINS[@]}"; do
            domain_time_map["$domain"]=""
            domain_bad_map["$domain"]=0
            domain_zero_map["$domain"]=0
        done

        for ((round=1; round<=ITERATIONS; round++)); do
            start_offset=$(( (round - 1) % domain_count ))
            for ((step=0; step<domain_count; step++)); do
                domain_idx=$(((start_offset + step) % domain_count))
                domain="${DOMAINS[$domain_idx]}"
                output=""
                rc=0
                live_value="bad"

                run_dns_query "$dns" "$domain"
                output="$QUERY_OUTPUT"
                rc="$QUERY_RC"

                case "$rc" in
                    0)
                        qtime=$(awk '/Query time:/ {print $4; exit}' <<< "$output")
                        status=$(awk '/^;; ->>HEADER<<-/ { s=$0; sub(/.*status: /, "", s); sub(/,.*/, "", s); print s; exit }' <<< "$output")
                        if [[ "$status" == "NOERROR" && "$qtime" =~ ^[0-9]+$ ]]; then
                            if (( qtime > 0 )); then
                                domain_time_map["$domain"]+="${qtime} "
                                all_times+=("$qtime")
                                live_value="r$(printf '%02d' "$round") ${qtime}ms"
                            else
                                domain_zero_map["$domain"]=$(( ${domain_zero_map["$domain"]} + 1 ))
                                total_zero=$(( total_zero + 1 ))
                                live_value="r$(printf '%02d' "$round") 0ms"
                            fi
                        else
                            domain_bad_map["$domain"]=$(( ${domain_bad_map["$domain"]} + 1 ))
                            total_bad=$(( total_bad + 1 ))
                            live_value="r$(printf '%02d' "$round") bad"
                        fi
                        ;;
                    *)
                        domain_bad_map["$domain"]=$(( ${domain_bad_map["$domain"]} + 1 ))
                        total_bad=$(( total_bad + 1 ))
                        live_value="r$(printf '%02d' "$round") bad"
                        ;;
                esac

                if [[ "$label" == "Cloudflare" ]]; then
                    cf_live_status[$domain_idx]="$live_value"
                else
                    google_live_status[$domain_idx]="$live_value"
                fi

                query_done=$((query_done + 1))
                current_status="$live_value"
                draw_test_dashboard "$label" "$domain" "$query_done" "$total_queries" "$round" "$current_status" cf_live_status google_live_status
            done
        done

        for domain in "${DOMAINS[@]}"; do
            times=()
            bad_count="${domain_bad_map["$domain"]}"
            zero_count="${domain_zero_map["$domain"]}"

            if [[ -n "${domain_time_map["$domain"]// /}" ]]; then
                read -r -a times <<< "${domain_time_map["$domain"]}"
            fi

            if [[ ${#times[@]} -gt 0 ]]; then
                read -r min max avg median p90 <<< "$(calc_stats "${times[@]}")"
            else
                avg="N/A"
                median="N/A"
                p90="N/A"
            fi

            if [[ "$label" == "Cloudflare" ]]; then
                cf_avg_map["$domain"]="$avg"
                cf_median_map["$domain"]="$median"
                cf_p90_map["$domain"]="$p90"
                cf_bad_map["$domain"]="$bad_count"
                cf_zero_map["$domain"]="$zero_count"
            else
                google_avg_map["$domain"]="$avg"
                google_median_map["$domain"]="$median"
                google_p90_map["$domain"]="$p90"
                google_bad_map["$domain"]="$bad_count"
                google_zero_map["$domain"]="$zero_count"
            fi
        done

        if [[ ${#all_times[@]} -gt 0 ]]; then
            read -r min max avg median p90 <<< "$(calc_stats "${all_times[@]}")"
            score=$(calc_score "$avg" "$median" "$p90" "$total_bad" "$total_rounds")
            summary_rows+=("$score|$score|$label|$dns|$avg|$median|$p90|$total_bad|$total_zero")
        else
            avg="N/A"
            median="N/A"
            p90="N/A"
            score="N/A"
            summary_rows+=("999999|N/A|$label|$dns|N/A|N/A|N/A|$total_bad|$total_zero")
        fi

        if [[ "$label" == "Cloudflare" ]]; then
            cf_score="$score"; cf_avg="$avg"; cf_median="$median"; cf_p90="$p90"; cf_bad="$total_bad"; cf_zero="$total_zero"
        else
            google_score="$score"; google_avg="$avg"; google_median="$median"; google_p90="$p90"; google_bad="$total_bad"; google_zero="$total_zero"
        fi
    done

    test_ui_end
    if [[ -t 1 ]]; then
        printf '\033[H\033[2J'
    fi

    print_report_title "域名对比" "$COMPARE_WIDTH"
    fmt_compare_header
    print_rule "$COMPARE_WIDTH"
    for domain in "${DOMAINS[@]}"; do
        fmt_compare_row \
            "$domain" \
            "${cf_median_map["$domain"]:-N/A}" \
            "${cf_p90_map["$domain"]:-N/A}" \
            "${cf_bad_map["$domain"]:-0}" \
            "${cf_zero_map["$domain"]:-0}" \
            "${google_median_map["$domain"]:-N/A}" \
            "${google_p90_map["$domain"]:-N/A}" \
            "${google_bad_map["$domain"]:-0}" \
            "${google_zero_map["$domain"]:-0}"
    done

    echo
    print_report_title "总体汇总"
    fmt_summary_header
    print_rule "$REPORT_WIDTH"
    printf "%s\n" "${summary_rows[@]}" | sort -t'|' -k1,1g | while IFS='|' read -r sort_key score_display label dns avg median p90 bad zero; do
        fmt_summary_row "${label} @${dns}" "$avg" "$median" "$p90" "$bad" "$zero" "$score_display"
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

cleanup_script_configs() {
    local answer

    clear_screen
    print_header
    print_section_title "清理旧版配置"
    print_detail_line "清理范围" "resolved drop-in、旧 DoH 服务及目录"
    print_detail_line "可选操作" "移除 /etc/resolv.conf 文件锁"
    echo
    print_rule
    echo
    if ! read_user answer "${MENU_PAD}继续？[y/N]: "; then
        echo
        return 1
    fi
    case "$answer" in
        y|Y) ;;
        *) warn "已取消。"; return 1 ;;
    esac

    if ! cleanup_resolved_dropin yes; then
        err "resolved drop-in 已删除，但重启 systemd-resolved 失败。"
        return 1
    fi
    cleanup_legacy_doh || return 1

    if is_locked; then
        if read_user answer "${MENU_PAD}检测到 DNS 文件锁，是否移除？[y/N]: "; then
            case "$answer" in
                y|Y)
                    need_unlock_tool_if_locked || return 1
                    chattr -i /etc/resolv.conf 2>/dev/null || true
                    if is_locked; then
                        err "DNS 文件锁移除失败。"
                        return 1
                    fi
                    ;;
            esac
        fi
    fi

    ok "清理完成。"
}

main_menu() {
    local action

    while true; do
        clear_screen
        print_header
        print_menu_item "1" "DNS 性能测试"
        echo
        print_menu_item "2" "应用 DNS 配置"
        echo
        print_menu_item "3" "清理旧版配置"
        echo
        print_menu_item "0" "退出脚本"
        echo
        print_rule
        echo
        if ! read_user action "${MENU_PAD}请选择 [0-3]: "; then
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
                    apply_dns_profile || true
                    pause
                fi
                ;;
            3)
                cleanup_script_configs || true
                pause
                ;;
            0)
                clear_screen
                return 0
                ;;
            *)
                warn "无效选择，请输入 0-3。"
                pause "按 Enter 重新选择..."
                ;;
        esac
    done
}

trap 'on_exit $?' EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
trap 'on_signal 131' QUIT

capture_self_path
validate_runtime_settings
if ! setup_input; then
    err "未检测到可交互终端，无法显示菜单或读取选择。"
    exit 1
fi
need_root
main_menu
exit 0
