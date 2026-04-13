#!/usr/bin/env bash

set -euo pipefail

SCRIPT_VERSION="v1.1-github"
ITERATIONS_DEFAULT=8
DIG_TIMEOUT_DEFAULT=2
QTYPE="A"
DOMAINS=("google.com" "youtube.com" "instagram.com" "telegram.org" "x.com" "netflix.com")

C_NAME=20
C_S=6
C_M=7
C_BAD=4
SEP="$(printf '%0.s-' {1..65})"
BANNER="$(printf '%0.s=' {1..65})"
RUNTIME_DIR="/run/dns-lock-bench"
BACKUP_META="$RUNTIME_DIR/resolv.meta"
BACKUP_DATA="$RUNTIME_DIR/resolv.data"

PRIMARY_DNS=""
SECONDARY_DNS=""
PROFILE_KEY=""
PROFILE_NAME=""
SELECTED_DNS_SERVERS=()
ITERATIONS="$ITERATIONS_DEFAULT"
DIG_TIMEOUT="$DIG_TIMEOUT_DEFAULT"
OUTER_TIMEOUT=$((DIG_TIMEOUT + 1))

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "❌ 请使用 root 运行：sudo bash ..."
        exit 1
    fi
}

have_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

service_exists() {
    have_systemctl && systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

pkg_install() {
    local pkgs=("$@")
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "❌ 缺少依赖：${pkgs[*]}，且当前系统不是 apt 环境，请手动安装后重试。"
        exit 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
}

ensure_dependencies() {
    local -a missing_pkgs=()
    command -v dig >/dev/null 2>&1 || missing_pkgs+=(dnsutils)
    command -v timeout >/dev/null 2>&1 || missing_pkgs+=(coreutils)
    command -v awk >/dev/null 2>&1 || missing_pkgs+=(gawk)
    command -v sort >/dev/null 2>&1 || missing_pkgs+=(coreutils)
    command -v chattr >/dev/null 2>&1 || missing_pkgs+=(e2fsprogs)
    command -v lsattr >/dev/null 2>&1 || missing_pkgs+=(e2fsprogs)

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | awk '!seen[$0]++')
        echo "ℹ️  正在安装依赖：${missing_pkgs[*]}"
        pkg_install "${missing_pkgs[@]}"
    fi
}

fmt_header() {
    printf "%-${C_NAME}s | %-${C_S}s | %-${C_S}s | %-${C_M}s | %-${C_M}s | %-${C_BAD}s\n" \
        "$1" "Min" "Max" "Avg" "Median" "Bad"
}

fmt_row() {
    printf "%-${C_NAME}s | %-${C_S}s | %-${C_S}s | %-${C_M}s | %-${C_M}s | %-${C_BAD}s\n" \
        "$1" "$2" "$3" "$4" "$5" "$6"
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

is_resolv_locked() {
    [[ -e /etc/resolv.conf ]] || return 1
    lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

show_current_dns_state() {
    echo "$BANNER"
    echo "当前 DNS 状态"
    echo "$BANNER"

    if [[ -L /etc/resolv.conf ]]; then
        echo "[resolv.conf] 符号链接 -> $(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf 2>/dev/null || true)"
    elif [[ -e /etc/resolv.conf ]]; then
        echo "[resolv.conf] 普通文件"
    else
        echo "[resolv.conf] 不存在"
    fi

    if [[ -e /etc/resolv.conf ]]; then
        echo ""
        echo "[ls -l /etc/resolv.conf]"
        ls -l /etc/resolv.conf || true
        echo ""
        echo "[lsattr /etc/resolv.conf]"
        lsattr /etc/resolv.conf 2>/dev/null || true
        echo ""
        echo "[内容]"
        cat /etc/resolv.conf 2>/dev/null || true
    fi

    echo ""
    echo "[systemd-resolved]"
    if have_systemctl && service_exists systemd-resolved.service; then
        echo -n "enabled: "
        systemctl is-enabled systemd-resolved 2>/dev/null || true
        echo -n "active : "
        systemctl is-active systemd-resolved 2>/dev/null || true
    else
        echo "未检测到 systemd-resolved.service"
    fi

    if command -v resolvectl >/dev/null 2>&1; then
        echo ""
        echo "[resolvectl dns]"
        resolvectl dns 2>/dev/null || true
    fi

    echo ""
    if is_resolv_locked; then
        echo "锁定状态: 已加 immutable 锁"
    else
        echo "锁定状态: 未加 immutable 锁"
    fi
    echo ""
}

backup_current_resolv() {
    mkdir -p "$RUNTIME_DIR"

    if [[ -L /etc/resolv.conf ]]; then
        printf 'type=symlink\ntarget=%s\n' "$(readlink /etc/resolv.conf)" > "$BACKUP_META"
        : > "$BACKUP_DATA"
    elif [[ -e /etc/resolv.conf ]]; then
        printf 'type=file\n' > "$BACKUP_META"
        cat /etc/resolv.conf > "$BACKUP_DATA"
    else
        printf 'type=missing\n' > "$BACKUP_META"
        : > "$BACKUP_DATA"
    fi
}

restore_backup_resolv() {
    [[ -f "$BACKUP_META" ]] || return 1

    unlock_resolv_conf_only quiet || true
    rm -f /etc/resolv.conf

    local type target
    type=$(awk -F= '/^type=/{print $2; exit}' "$BACKUP_META")
    target=$(awk -F= '/^target=/{print $2; exit}' "$BACKUP_META")

    case "$type" in
        symlink)
            ln -s "$target" /etc/resolv.conf
            ;;
        file)
            cat "$BACKUP_DATA" > /etc/resolv.conf
            ;;
        missing)
            :
            ;;
        *)
            return 1
            ;;
    esac
}

unlock_resolv_conf_only() {
    local mode="${1:-normal}"
    if [[ ! -e /etc/resolv.conf ]]; then
        [[ "$mode" == "quiet" ]] || echo "⚠️  /etc/resolv.conf 不存在，无需解锁。"
        return 0
    fi

    if is_resolv_locked; then
        if chattr -i /etc/resolv.conf 2>/dev/null; then
            if is_resolv_locked; then
                [[ "$mode" == "quiet" ]] || echo "⚠️  已尝试解锁，但锁位仍存在，请手动检查文件系统是否支持 chattr。"
                return 1
            fi
            [[ "$mode" == "quiet" ]] || echo "✅ 已解除 /etc/resolv.conf 的 immutable 锁。"
        else
            [[ "$mode" == "quiet" ]] || echo "⚠️  解锁失败，可能是文件系统不支持 chattr。"
            return 1
        fi
    else
        [[ "$mode" == "quiet" ]] || echo "ℹ️  /etc/resolv.conf 当前未加锁。"
    fi
}

choose_profile_by_key() {
    case "$1" in
        cf)
            PROFILE_KEY="cf"
            PROFILE_NAME="CF 双 DNS"
            PRIMARY_DNS="1.1.1.1"
            SECONDARY_DNS="1.0.0.1"
            SELECTED_DNS_SERVERS=("1.1.1.1" "1.0.0.1")
            ;;
        google)
            PROFILE_KEY="google"
            PROFILE_NAME="Google 双 DNS"
            PRIMARY_DNS="8.8.8.8"
            SECONDARY_DNS="8.8.4.4"
            SELECTED_DNS_SERVERS=("8.8.8.8" "8.8.4.4")
            ;;
        cf-first)
            PROFILE_KEY="cf-first"
            PROFILE_NAME="CF 优先，Google 回落"
            PRIMARY_DNS="1.1.1.1"
            SECONDARY_DNS="8.8.8.8"
            SELECTED_DNS_SERVERS=("1.1.1.1" "8.8.8.8")
            ;;
        google-first)
            PROFILE_KEY="google-first"
            PROFILE_NAME="Google 优先，CF 回落"
            PRIMARY_DNS="8.8.8.8"
            SECONDARY_DNS="1.1.1.1"
            SELECTED_DNS_SERVERS=("8.8.8.8" "1.1.1.1")
            ;;
        *)
            return 1
            ;;
    esac
}

print_profile_menu() {
    echo "$BANNER"
    echo "DNS 方案选择"
    echo "$BANNER"
    echo "01) CF 双 DNS                1.1.1.1 -> 1.0.0.1"
    echo "02) Google 双 DNS            8.8.8.8 -> 8.8.4.4"
    echo "03) CF 优先，Google 回落     1.1.1.1 -> 8.8.8.8"
    echo "04) Google 优先，CF 回落     8.8.8.8 -> 1.1.1.1"
    echo "0)  返回上一级"
}

choose_profile() {
    while true; do
        print_profile_menu
        read -r -p "请选择 DNS 方案 [0-4]: " choice
        case "$choice" in
            1|01) choose_profile_by_key cf; return 0 ;;
            2|02) choose_profile_by_key google; return 0 ;;
            3|03) choose_profile_by_key cf-first; return 0 ;;
            4|04) choose_profile_by_key google-first; return 0 ;;
            0) return 1 ;;
            *) echo "⚠️  请输入 0-4 之间的编号。" ;;
        esac
        echo ""
    done
}

apply_dns_lock() {
    echo "$BANNER"
    echo "即将应用并锁定 DNS"
    echo "$BANNER"
    echo "方案: $PROFILE_NAME"
    echo "顺序: $PRIMARY_DNS -> $SECONDARY_DNS"
    echo ""
    echo "说明：本脚本不会写入 rotate，因此这里的前后顺序有效。"
    echo ""
    read -r -p "确认继续？这会停止/禁用/mask systemd-resolved，并锁定 /etc/resolv.conf [y/N]: " answer
    case "$answer" in
        y|Y) ;;
        *)
            echo "已取消。"
            return 1
            ;;
    esac

    backup_current_resolv
    unlock_resolv_conf_only quiet || true

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

    if chattr +i /etc/resolv.conf 2>/dev/null; then
        if is_resolv_locked; then
            echo "✅ DNS 已写入并加锁。"
        else
            echo "⚠️  DNS 已写入，但未确认加锁成功。当前文件系统可能不支持 chattr。"
        fi
    else
        echo "⚠️  DNS 已写入，但加锁失败。当前文件系统可能不支持 chattr。"
    fi

    echo ""
    show_current_dns_state
    echo "以后如需修改，至少先执行："
    echo "chattr -i /etc/resolv.conf"
}

restore_systemd_resolved() {
    unlock_resolv_conf_only quiet || true

    if have_systemctl && service_exists systemd-resolved.service; then
        systemctl unmask systemd-resolved || true
        systemctl enable systemd-resolved || true
        systemctl start systemd-resolved || true
    fi

    if restore_backup_resolv; then
        echo "✅ 已恢复脚本运行前的 /etc/resolv.conf 状态。"
        return 0
    fi

    rm -f /etc/resolv.conf
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        echo "✅ 已恢复到 systemd-resolved 的 stub-resolv.conf。"
    elif [[ -e /run/systemd/resolve/resolv.conf ]]; then
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
        echo "✅ 已恢复到 systemd-resolved 的 resolv.conf。"
    else
        echo "⚠️  未找到标准恢复目标，请手动检查。"
    fi
}

benchmark_dns_set() {
    local dns domain i output rc qtime status
    local -a summary_rows=()

    OUTER_TIMEOUT=$((DIG_TIMEOUT + 1))

    echo "$BANNER"
    echo "🚀 DNS Benchmark $SCRIPT_VERSION  (每个域名测试 $ITERATIONS 次)"
    echo "📌 当前方案: $PROFILE_NAME"
    echo "📌 顺序    : $PRIMARY_DNS -> $SECONDARY_DNS"
    echo "📌 测试域名: ${DOMAINS[*]}"
    echo "$BANNER"

    for dns in "${SELECTED_DNS_SERVERS[@]}"; do
        echo ""
        echo "🎯 当前 DNS: @$dns  （单位：ms）"
        fmt_header "Domain"
        echo "$SEP"

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

        if [[ ${#all_times[@]} -gt 0 ]]; then
            read -r min max avg median <<< "$(calc_stats "${all_times[@]}")"
            summary_rows+=("${median/./}|$dns|$min|$max|$avg|$median|$total_bad")
            echo "$SEP"
            fmt_row "TOTAL" "$min" "$max" "$avg" "$median" "$total_bad"
        else
            summary_rows+=("999999|$dns|N/A|N/A|N/A|N/A|$total_bad")
            echo "$SEP"
            fmt_row "TOTAL" "N/A" "N/A" "N/A" "N/A" "$total_bad"
        fi
    done

    echo ""
    echo "$BANNER"
    echo "📊 总体汇总（按 Median 升序，全超时排末尾）"
    echo "$BANNER"
    fmt_header "DNS"
    echo "$SEP"
    if [[ ${#summary_rows[@]} -gt 0 ]]; then
        printf "%s\n" "${summary_rows[@]}" | sort -t'|' -k1,1n | while IFS='|' read -r _k dns min max avg median bad; do
            fmt_row "$dns" "$min" "$max" "$avg" "$median" "$bad"
        done
    fi
}

prompt_apply_after_test() {
    echo ""
    read -r -p "是否将当前所选方案写入 /etc/resolv.conf 并加锁？[y/N]: " answer
    case "$answer" in
        y|Y) apply_dns_lock ;;
        *) echo "已跳过写入。" ;;
    esac
}

print_cli_help() {
    cat <<'EOFH'
用法：
  --menu                         进入交互菜单（默认）
  --test <cf|google|cf-first|google-first>
  --apply <cf|google|cf-first|google-first>
  --test-apply <cf|google|cf-first|google-first>
  --unlock
  --restore
  --status
  --iterations <N>
  --dig-timeout <N>
  --help
EOFH
}

parse_args() {
    [[ $# -eq 0 ]] && return 0

    local action=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --menu)
                action="menu"
                shift
                ;;
            --test)
                action="test"
                shift
                choose_profile_by_key "$1"
                shift
                ;;
            --apply)
                action="apply"
                shift
                choose_profile_by_key "$1"
                shift
                ;;
            --test-apply)
                action="test-apply"
                shift
                choose_profile_by_key "$1"
                shift
                ;;
            --unlock)
                action="unlock"
                shift
                ;;
            --restore)
                action="restore"
                shift
                ;;
            --status)
                action="status"
                shift
                ;;
            --iterations)
                shift
                ITERATIONS="$1"
                shift
                ;;
            --dig-timeout)
                shift
                DIG_TIMEOUT="$1"
                shift
                ;;
            --help|-h)
                print_cli_help
                exit 0
                ;;
            *)
                echo "❌ 未知参数：$1"
                print_cli_help
                exit 1
                ;;
        esac
    done

    case "$action" in
        "") return 0 ;;
        menu) return 0 ;;
        test)
            benchmark_dns_set
            exit 0
            ;;
        apply)
            apply_dns_lock
            exit 0
            ;;
        test-apply)
            benchmark_dns_set
            apply_dns_lock
            exit 0
            ;;
        unlock)
            unlock_resolv_conf_only
            exit 0
            ;;
        restore)
            restore_systemd_resolved
            exit 0
            ;;
        status)
            show_current_dns_state
            exit 0
            ;;
        *)
            echo "❌ 参数处理失败。"
            exit 1
            ;;
    esac
}

main_menu() {
    while true; do
        echo "$BANNER"
        echo "DNS 锁定 / 测试工具 $SCRIPT_VERSION"
        echo "$BANNER"
        echo "01) 选 DNS 方案 → 测试 → 写入并加锁"
        echo "02) 选 DNS 方案 → 直接写入并加锁（跳过测速）"
        echo "03) 选 DNS 方案 → 仅测试，不写入"
        echo "04) 仅解锁 /etc/resolv.conf"
        echo "05) 恢复脚本运行前的 DNS 状态"
        echo "06) 查看当前 DNS 状态"
        echo "0)  退出"
        read -r -p "请选择 [0-6]: " action
        echo ""

        case "$action" in
            1|01)
                if choose_profile; then
                    benchmark_dns_set
                    prompt_apply_after_test
                fi
                ;;
            2|02)
                if choose_profile; then
                    apply_dns_lock
                fi
                ;;
            3|03)
                if choose_profile; then
                    benchmark_dns_set
                fi
                ;;
            4|04)
                unlock_resolv_conf_only
                ;;
            5|05)
                restore_systemd_resolved
                ;;
            6|06)
                show_current_dns_state
                ;;
            0)
                break
                ;;
            *)
                echo "⚠️  请输入 0-6 之间的编号。"
                ;;
        esac

        echo ""
        read -r -p "按回车返回主菜单..." _dummy
        clear 2>/dev/null || true
    done
}

need_root
ensure_dependencies
parse_args "$@"
main_menu
