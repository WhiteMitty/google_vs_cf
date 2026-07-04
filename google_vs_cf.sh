#!/usr/bin/env bash

set -euo pipefail

APP_NAME="google_vs_cf"

TEST_DNS=("1.1.1.1" "8.8.8.8")
TEST_LABELS=("Cloudflare" "Google")
DOMAINS=(
    "x.com"          "bbc.com"        "twitch.tv"        "intel.com"
    "apple.com"      "amazon.com"     "fastly.com"       "akamai.com"
    "google.com"     "tiktok.com"     "github.com"       "youtube.com"
    "netflix.com"    "telegram.org"   "wikipedia.org"    "microsoft.com"
    "instagram.com"  "aws.amazon.com" "disneyplus.com"   "steampowered.com"
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
MENU_PAD="  "

say()  { echo "$*"; }
ok()   { echo "${C_OK}$*${C_RESET}"; }
warn() { echo "${C_WARN}$*${C_RESET}"; }
err()  { echo "${C_ERR}$*${C_RESET}"; }
info() { echo "${C_INFO}$*${C_RESET}"; }

print_menu_item() {
    local key="$1"
    local title="$2"
    printf "%s%b%s%b) %s
" "$MENU_PAD" "$C_INFO" "$key" "$C_RESET" "$title"
}

print_profile_item() {
    local key="$1"
    local title="$2"
    local dns="$3"
    printf "%s%b%s%b) %-12s %s
" "$MENU_PAD" "$C_INFO" "$key" "$C_RESET" "$title" "$dns"
}

center_text() {
    local text="$1"
    local color="${2:-}"
    local width=${#LINE}
    local len=${#text}
    local pad=0
    if (( width > len )); then
        pad=$(( (width - len) / 2 ))
    fi
    printf "%*s%b%s%b
" "$pad" "" "$color" "$text" "$C_RESET"
}

current_dns_servers() {
    local out=""
    if command_exists resolvectl && [[ "$(service_state systemd-resolved)" == "active" ]]; then
        out="$(resolvectl dns 2>/dev/null | awk '
            {
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ || $i ~ /^[0-9A-Fa-f:]+$/) {
                        if (!seen[$i]++) {
                            if (out) out = out " / " $i; else out = $i
                        }
                    }
                }
            }
            END { print out }
        ')"
    fi
    if [[ -z "$out" && -e /etc/resolv.conf ]]; then
        out="$(awk '$1 == "nameserver" { if (out) out = out " / " $2; else out = $2 } END { print out }' /etc/resolv.conf 2>/dev/null || true)"
    fi
    if [[ -n "$out" ]]; then
        echo "$out"
    elif [[ -e /etc/resolv.conf ]]; then
        echo "未发现 nameserver"
    else
        echo "无"
    fi
}

print_domain_grid() {
    local cols=3
    local width=22
    local i j idx
    for ((i=0; i<${#DOMAINS[@]}; i+=cols)); do
        for ((j=0; j<cols; j++)); do
            idx=$((i + j))
            if (( idx < ${#DOMAINS[@]} )); then
                printf "  %b%02d%b) %b%-*s%b" \
                    "$C_DIM" "$((idx + 1))" "$C_RESET" \
                    "$C_INFO" "$width" "${DOMAINS[$idx]}" "$C_RESET"
            fi
        done
        printf "\n"
    done
}

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "请使用 root 权限运行此脚本。"
        exit 1
    fi
}

pause() {
    echo
    if ! read -r -p "${MENU_PAD}按 Enter 返回..." _dummy; then
        echo
    fi
}

clear_screen() {
    clear 2>/dev/null || true
}

pkg_installed() {
    command -v dpkg-query >/dev/null 2>&1 || return 1
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

mode_cn() {
    case "$1" in
        "resolved link") echo "resolved 接管" ;;
        "symlink") echo "符号链接" ;;
        "locked file") echo "普通文件（旧锁定）" ;;
        "plain file") echo "普通文件" ;;
        "missing") echo "缺失" ;;
        *) echo "$1" ;;
    esac
}

color_mode() {
    local mode text
    mode="$(resolv_mode_raw)"
    text="$(mode_cn "$mode")"
    case "$mode" in
        "plain file") printf "%s%s%s" "$C_OK" "$text" "$C_RESET" ;;
        "resolved link") printf "%s%s%s" "$C_INFO" "$text" "$C_RESET" ;;
        "locked file") printf "%s%s%s" "$C_WARN" "$text" "$C_RESET" ;;
        *) printf "%s%s%s" "$C_WARN" "$text" "$C_RESET" ;;
    esac
}

color_resolved() {
    if pkg_installed systemd-resolved; then
        printf "%s已安装%s" "$C_OK" "$C_RESET"
    else
        printf "%s未安装%s" "$C_DIM" "$C_RESET"
    fi
}

print_header() {
    echo "$LINE"
    center_text "$APP_NAME" "$C_TITLE"
    echo "$LINE"
    echo
    printf "%sresolved : %b
" "$MENU_PAD" "$(color_resolved)"
    printf "%sDNS      : %b%s%b
" "$MENU_PAD" "$C_INFO" "$(current_dns_servers)" "$C_RESET"
    echo
}

pkg_install() {
    local -a pkgs=("$@")
    if ! command_exists apt-get; then
        err "未找到 apt-get，当前脚本主要面向 Debian / Ubuntu。"
        return 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
}

prompt_install_missing() {
    local -a missing=("$@")
    mapfile -t missing < <(printf '%s
' "${missing[@]}" | awk 'NF && !seen[$0]++')
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
    printf "%b%-20s%b | %-5s | %-5s | %-7s | %-7s | %-7s | %-4s | %-4s\n" \
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

    printf "%b%-20s%b | %-5s | %-5s | %-7s | %-7s | %-7s | %-4s | %-4s\n" \
        "$color" "$label" "$C_RESET" "$min" "$max" "$avg" "$median" "$p90" "$bad" "$zero"
}

fmt_summary_header() {
    printf "%b%-22s%b | %-7s | %-7s | %-7s | %-4s | %-4s | %-6s\n" \
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

    printf "%b%-22s%b | %-7s | %-7s | %-7s | %-4s | %-4s | %-6s\n" \
        "$color" "$label" "$C_RESET" "$avg" "$median" "$p90" "$bad" "$zero" "$score"
}

fmt_compare_header() {
    printf "%b%-20s%b | %-6s | %-6s | %-4s | %-4s || %-6s | %-6s | %-4s | %-4s\n" \
        "$C_TITLE" "Domain" "$C_RESET" "CF Med" "CF P90" "Bad" "0ms" "GG Med" "GG P90" "Bad" "0ms"
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

    printf "%-20s | %-6s | %-6s | %-4s | %-4s || %-6s | %-6s | %-4s | %-4s\n" \
        "$domain" "$cf_median" "$cf_p90" "$cf_bad" "$cf_zero" "$google_median" "$google_p90" "$google_bad" "$google_zero"
}

test_ui_begin() {
    if [[ -t 1 ]]; then
        printf '\033[?25l'
    fi
}

test_ui_end() {
    if [[ -t 1 ]]; then
        printf '\033[?25h'
    fi
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
    echo "$LINE"
    center_text "${APP_NAME}  |  Live DNS test" "$C_TITLE"
    echo "$LINE"
    echo
    echo "Targets  : Cloudflare @1.1.1.1   |   Google @8.8.8.8"
    echo "Progress : ${query_done}/${query_total}   |   Round ${current_round}/${ITERATIONS}"
    echo "Current  : ${current_label}  ->  ${current_domain}  (${current_status})"
    echo
    printf "%b%-3s %-24s %-18s %-18s%b\n" "$C_TITLE" "#" "Domain" "Cloudflare" "Google" "$C_RESET"
    echo "$SUBLINE"
    for ((i=0; i<${#DOMAINS[@]}; i++)); do
        domain="${DOMAINS[$i]}"
        cf_live="${cf_live_ref[$i]:-...}"
        google_live="${google_live_ref[$i]:-...}"
        printf "%b%02d%b  %-24.24s %-18s %-18s\n" "$C_DIM" "$((i + 1))" "$C_RESET" "$domain" "$cf_live" "$google_live"
    done
    echo
    echo "Legend   : Nms = success, 0ms = ignored, bad = failed/timeout, ... = pending"
    echo "Method   : round-robin across domains, ${ITERATIONS} rounds per domain, 0 ms ignored"
}

choose_profile() {
    while true; do
        echo "DNS 方案"
        echo "$SUBLINE"
        print_profile_item "1" "Cloudflare" "1.1.1.1 / 1.0.0.1"
        print_profile_item "2" "Google"     "8.8.8.8 / 8.8.4.4"
        print_profile_item "3" "CF 优先"    "1.1.1.1 / 8.8.8.8"
        print_profile_item "4" "Google 优先" "8.8.8.8 / 1.1.1.1"
        print_profile_item "0" "返回"       ""
        echo
        if ! read -r -p "${MENU_PAD}请选择 [0-4]: " choice; then
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
                PROFILE_NAME="CF 优先"
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
                warn "无效选择。"
                ;;
        esac
        echo
    done
}

legacy_dns_exists() {
    [[ -f "$LEGACY_DOH_SERVICE" || -d "$LEGACY_DOH_DIR" ]]
}

cleanup_legacy_doh() {
    if [[ -f "$LEGACY_DOH_SERVICE" ]]; then
        systemctl stop google-vs-cf-doh.service 2>/dev/null || true
        systemctl disable google-vs-cf-doh.service 2>/dev/null || true
        rm -f "$LEGACY_DOH_SERVICE"
    fi
    rm -rf "$LEGACY_DOH_DIR"
    systemctl daemon-reload 2>/dev/null || true
}

cleanup_resolved_dropin() {
    rm -f "$RESOLVED_DROPIN_FILE"
    systemctl daemon-reload 2>/dev/null || true
}

prompt_cleanup_legacy() {
    if ! legacy_dns_exists; then
        return 0
    fi

    echo
    warn "检测到旧版 google-vs-cf DoH 服务或目录。"
    if ! read -r -p "是否删除这些旧配置？[y/N]: " answer; then
        echo
        return 0
    fi
    case "$answer" in
        y|Y)
            cleanup_legacy_doh
            ok "旧版 DoH 配置已清理。"
            ;;
        *)
            warn "已保留旧版 DoH 配置。"
            ;;
    esac
}

prompt_unlock_old_resolv_lock() {
    if ! is_locked; then
        return 0
    fi

    echo
    warn "检测到 /etc/resolv.conf 已被 chattr +i 锁定。"
    if ! read -r -p "${MENU_PAD}是否先移除旧锁？[y/N]: " answer; then
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
    rm -f /etc/resolv.conf
    {
        echo "nameserver $DNS1"
        echo "nameserver $DNS2"
        echo "options timeout:2 attempts:2"
    } > /etc/resolv.conf
    chmod 0644 /etc/resolv.conf 2>/dev/null || true
}

prompt_lock_resolv() {
    echo
    if ! read -r -p "${MENU_PAD}是否锁定 /etc/resolv.conf？[y/N]: " answer; then
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
    cleanup_resolved_dropin
    write_resolv_file
    prompt_lock_resolv
}

stop_disable_resolved() {
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    cleanup_resolved_dropin
}

purge_resolved() {
    if ! pkg_installed systemd-resolved; then
        return 0
    fi

    echo
    warn "卸载 systemd-resolved 可能影响 NetworkManager、netplan 或系统默认 DNS 行为。"
    if ! read -r -p "${MENU_PAD}确认卸载请输入 yes: " answer; then
        echo
        return 1
    fi
    answer="${answer,,}"
    if [[ "$answer" != "yes" ]]; then
        warn "已取消卸载。"
        return 1
    fi

    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    cleanup_resolved_dropin

    if command_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y systemd-resolved
        apt-get autoremove -y
        ok "systemd-resolved 已卸载。"
    else
        err "未找到 apt-get，无法自动卸载 systemd-resolved。"
        return 1
    fi
}

resolved_related_detected() {
    local mode raw package enabled active
    mode="$(resolv_mode_raw)"
    raw="$(resolved_summary_raw)"
    IFS='|' read -r package enabled active <<< "$raw"

    [[ "$mode" == "resolved link" ]] && return 0
    [[ "$package" == "installed" ]] && return 0
    return 1
}

apply_with_resolved_prompt() {
    while true; do
        echo "检测到 systemd-resolved"
        echo "$SUBLINE"
        print_menu_item "1" "停用 resolved 后写入"
        print_menu_item "2" "卸载 resolved 后写入"
        print_menu_item "0" "取消"
        echo
        if ! read -r -p "${MENU_PAD}请选择 [0-2]: " choice; then
            echo
            return 1
        fi
        echo
        case "$choice" in
            1)
                stop_disable_resolved
                write_direct_resolv
                return $?
                ;;
            2)
                prompt_unlock_old_resolv_lock || return 1
                write_resolv_file
                purge_resolved || return 1
                write_resolv_file
                prompt_lock_resolv
                return $?
                ;;
            0)
                warn "已取消。"
                return 1
                ;;
            *)
                warn "无效选择。"
                ;;
        esac
        echo
    done
}

apply_dns_profile() {
    echo "应用 DNS"
    echo "$SUBLINE"
    echo
    printf "%s方案 : %s
" "$MENU_PAD" "$PROFILE_NAME"
    printf "%sDNS  : %s / %s
" "$MENU_PAD" "$DNS1" "$DNS2"
    echo
    read -r -p "${MENU_PAD}继续？[y/N]: " answer || { echo; warn "已取消。"; return 1; }
    case "$answer" in
        y|Y) ;;
        *) warn "已取消。"; return 1 ;;
    esac

    prompt_cleanup_legacy

    if resolved_related_detected; then
        apply_with_resolved_prompt
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
    echo "推荐结果"
    echo "$SUBLINE"
    echo

    if [[ "$cf_score" == "N/A" && "$google_score" == "N/A" ]]; then
        warn "没有有效结果。"
        return 0
    fi

    if [[ "$cf_score" == "N/A" ]]; then
        ok "建议使用 Google。Cloudflare 没有有效评分。"
        return 0
    fi

    if [[ "$google_score" == "N/A" ]]; then
        ok "建议使用 Cloudflare。Google 没有有效评分。"
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
        level="轻微优势"
    elif awk -v d="$diff" 'BEGIN { exit !(d < 2.20) }'; then
        level="推荐"
    else
        level="强烈推荐"
    fi

    ok "${level}：${winner}"
    echo "原因   : 优先比较失败率，其次比较 median、p90、average。"
    echo "Score  : $winner $winner_score  vs  $loser $loser_score"
    echo "Winner : bad $winner_bad/$total_rounds ($winner_ratio), median $winner_median ms, p90 $winner_p90 ms, avg $winner_avg ms"
    echo "Loser  : bad $loser_bad/$total_rounds ($loser_ratio), median $loser_median ms, p90 $loser_p90 ms, avg $loser_avg ms"

    if (( cf_zero > 0 || google_zero > 0 )); then
        echo "0ms    : 0 ms 已忽略，不参与统计和推荐。"
    fi

    echo "Model  : score = median + 0.35*(p90-median) + 0.10*(avg-median) + 25*bad_ratio"
    echo "Method : round-robin sampling across domains, $ITERATIONS rounds per domain."
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
    trap 'test_ui_end' RETURN
    draw_test_dashboard "Preparing" "waiting" "$query_done" "$total_queries" 0 "pending" cf_live_status google_live_status

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
                sleep 0.03
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

    if [[ -t 1 ]]; then
        printf '\e[H\e[2J'
    fi

    echo "Compare report"
    echo "$SUBLINE"
    echo
    fmt_compare_header
    echo "$SUBLINE"
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
    echo "Summary"
    echo "$SUBLINE"
    echo
    fmt_summary_header
    echo "$SUBLINE"
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
    echo "清理旧配置"
    echo "$SUBLINE"
    echo
    warn "只清理旧版 google_vs_cf 残留：resolved drop-in、旧 DoH 服务/目录，以及可选 DNS 文件锁。"
    if ! read -r -p "${MENU_PAD}继续？[y/N]: " answer; then
        echo
        return 1
    fi
    case "$answer" in
        y|Y) ;;
        *) warn "已取消。"; return 1 ;;
    esac

    cleanup_resolved_dropin
    cleanup_legacy_doh

    if is_locked; then
        if read -r -p "${MENU_PAD}检测到 DNS 文件锁，是否移除？[y/N]: " answer; then
            case "$answer" in
                y|Y)
                    if command_exists chattr; then
                        chattr -i /etc/resolv.conf 2>/dev/null || true
                    fi
                    ;;
            esac
        fi
    fi

    ok "清理完成。"
}

main_menu() {
    while true; do
        clear_screen
        print_header
        print_menu_item "1" "DNS 测试"
        print_menu_item "2" "应用 DNS"
        print_menu_item "3" "清理旧配置"
        print_menu_item "0" "退出"
        echo
        if ! read -r -p "${MENU_PAD}请选择 [0-3]: " action; then
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
                fi
                pause
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
                warn "无效选择。"
                pause
                ;;
        esac
    done
}

need_root
main_menu
exit 0
