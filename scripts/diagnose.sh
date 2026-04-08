#!/bin/bash
# 主入口诊断脚本
# 用法: diagnose.sh [模式] [输出目录]
# 模式: kernel | userspace | perf | hang | network | storage | auto (默认auto)
#
# auto模式: 自动检测问题类型并收集对应数据
# 指定模式: 针对特定问题类型进行深度收集

set -euo pipefail

# =====================================================================
# 配置
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
CMD_TIMEOUT=30
MAX_LOG_LINES=2000
COLLECTED_FILES=0

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

# =====================================================================
# 帮助信息
# =====================================================================
usage() {
    cat <<EOF
用法: $(basename "$0") [选项] [模式] [输出目录]

模式:
  auto       自动检测问题类型并收集对应数据 (默认)
  kernel     深度内核崩溃数据收集
  userspace  深度用户态崩溃数据收集
  perf       深度性能数据收集
  hang       深度系统挂起数据收集
  network    深度网络数据收集
  storage    深度存储数据收集

选项:
  -h, --help    显示此帮助信息

示例:
  $(basename "$0")                    # auto模式，默认输出目录
  $(basename "$0") kernel             # 内核崩溃深度收集
  $(basename "$0") perf ./my-output   # 性能深度收集，指定输出目录
EOF
    exit 0
}

# =====================================================================
# 参数解析
# =====================================================================
MODE="auto"
OUTPUT_DIR=""
VALID_MODES="auto kernel userspace perf hang network storage"

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage ;;
        auto|kernel|userspace|perf|hang|network|storage) MODE="$arg" ;;
        *)
            if [ -z "$OUTPUT_DIR" ]; then
                OUTPUT_DIR="$arg"
            else
                log_error "未知参数: $arg"
                usage
            fi
            ;;
    esac
done

OUTPUT_DIR="${OUTPUT_DIR:-./diagnose-${MODE}-${TIMESTAMP}}"

# =====================================================================
# 工具函数
# =====================================================================
has_cmd() { command -v "$1" &>/dev/null; }
has_script() { [ -f "$1" ]; }

# 安全执行：检查命令存在 + 超时保护 + 错误捕获
safe_run() {
    local outfile="$1"; shift
    local cmd_name="$1"

    if ! has_cmd "$cmd_name"; then
        echo "[跳过] 命令不存在: $cmd_name" >> "$outfile"
        return 0
    fi

    if timeout "$CMD_TIMEOUT" "$@" >> "$outfile" 2>&1; then
        COLLECTED_FILES=$((COLLECTED_FILES + 1))
    else
        echo "[警告] 命令超时或失败: $*" >> "$outfile"
    fi
}

# 安全读取文件
safe_cat() {
    local src="$1" dst="$2" lines="${3:-$MAX_LOG_LINES}"
    if [ -r "$src" ]; then
        smart_extract "$src" "$dst" "$lines" && COLLECTED_FILES=$((COLLECTED_FILES + 1)) || echo "[无法读取] $src" > "$dst"
    else
        echo "[不存在或无权限] $src" > "$dst"
    fi
}

# 智能日志提取：优先保留错误上下文，而非简单尾部截断
# 策略：
#   1. 对日志类文件：提取错误/异常上下文 + 尾部基线
#   2. 对配置文件：完整输出（通常不大）
#   3. 对 proc 虚拟文件：按指定行数限制
smart_extract() {
    local src="$1" dst="$2" max_lines="${3:-2000}"

    # 前置检查：文件不存在或不可读时直接返回失败
    if [ ! -r "$src" ]; then
        return 1
    fi

    local total_lines
    total_lines=$(wc -l < "$src" 2>/dev/null || echo 0)

    # 文件行数不超过限制，直接完整输出
    if [ "$total_lines" -le "$max_lines" ] 2>/dev/null; then
        if cat "$src" > "$dst" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    # 判断是否为日志类文件（包含时间戳或内核日志特征）
    local is_log=0
    if head -5 "$src" 2>/dev/null | grep -qE '^[A-Z][a-z]{2} [ 0-9]{2} [0-9]{2}:' 2>/dev/null || \
       head -5 "$src" 2>/dev/null | grep -qE '^\[[ 0-9]+\.[0-9]+\]' 2>/dev/null || \
       head -5 "$src" 2>/dev/null | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' 2>/dev/null; then
        is_log=1
    fi

    if [ "$is_log" -eq 1 ]; then
        # 日志文件：提取错误上下文 + 尾部基线
        local context_lines=$((max_lines * 2 / 3))
        local tail_lines=$((max_lines - context_lines))

        {
            echo "=== 智能提取: 错误上下文 (最多 ${context_lines} 行) ==="
            # 提取包含 panic/BUG/Oops/error 等关键词的行及其上下文（不加 -n 保持格式一致）
            grep -iE -B 3 -A 10 'panic|BUG:|Oops:|error:|segfault|critical|fatal|unable to handle|general protection|call trace|kernel bug|warning.*failed|timeout|refused|reset|corrupt' "$src" 2>/dev/null \
                | head -n "$context_lines" || echo "[无匹配的错误行]"

            echo ""
            echo "=== 智能提取: 日志尾部基线 (后 ${tail_lines} 行) ==="
            tail -n "$tail_lines" "$src" 2>/dev/null
        } > "$dst"
    else
        # 非日志文件（如配置文件、proc 输出）：取尾部
        if tail -n "$max_lines" "$src" > "$dst" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    return 0
}

# =====================================================================
# 权限检查
# =====================================================================
check_permissions() {
    log_step "Step 1: 权限检查和环境准备"
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "未以root运行，部分数据可能无法收集"
        log_warn "建议: sudo $0 $*"
    else
        log_info "root权限确认"
    fi
    mkdir -p "$OUTPUT_DIR"
    log_info "输出目录: $OUTPUT_DIR"
}

# =====================================================================
# 深度收集函数
# =====================================================================

deep_kernel() {
    log_step "深度内核崩溃数据收集..."
    local d="$OUTPUT_DIR/kernel_deep"
    mkdir -p "$d"

    # vmcore 定位
    {
        echo "=== vmcore 搜索 ==="
        for dir in /var/crash /var/spool/abrt; do
            if [ -d "$dir" ]; then
                find "$dir" -maxdepth 3 -name 'vmcore*' -ls 2>/dev/null || echo "  $dir: 无vmcore"
            else
                echo "  $dir: 目录不存在"
            fi
        done
    } > "$d/vmcore_locate.txt"

    # crash 工具检查
    {
        echo "=== crash 工具状态 ==="
        if has_cmd crash; then
            echo "crash 路径: $(which crash)"
            crash --version 2>/dev/null | head -3 || true
        else
            echo "crash: 未安装"
            echo "安装建议: yum install crash / apt install crash"
        fi
        echo ""
        echo "=== debuginfo 检查 ==="
        ls -la /usr/lib/debug/lib/modules/*/vmlinux 2>/dev/null || echo "vmlinux debuginfo: 未找到"
        echo ""
        echo "=== 当前内核 ==="
        uname -r 2>/dev/null || echo "未知"
    } > "$d/crash_tools_status.txt"

    # dmesg 完整导出
    if has_cmd dmesg; then
        dmesg --decode 2>/dev/null > "$d/dmesg_full.txt" || \
        dmesg 2>/dev/null > "$d/dmesg_full.txt" || true
        # 提取崩溃上下文
        dmesg 2>/dev/null | grep -iE -B 5 -A 30 'panic|BUG:|Oops:|Call Trace:|RIP:|Code:' \
            > "$d/crash_context.txt" 2>/dev/null || true
    fi

    # messages 日志
    safe_cat /var/log/messages  "$d/messages.txt"
    safe_cat /var/log/kern.log  "$d/kern.log.txt"
    safe_cat /proc/cmdline      "$d/cmdline.txt" 10

    # 内核模块
    safe_run "$d/lsmod.txt" lsmod
    safe_cat /proc/modules "$d/modules_proc.txt"

    # kdump 配置
    safe_cat /etc/kdump.conf "$d/kdump_conf.txt" 200
    if has_cmd kdumpctl; then
        safe_run "$d/kdump_status.txt" kdumpctl status
    elif has_cmd systemctl; then
        systemctl status kdump 2>/dev/null > "$d/kdump_status.txt" || true
    fi
}

deep_userspace() {
    log_step "深度用户态崩溃数据收集..."
    local d="$OUTPUT_DIR/userspace_deep"
    mkdir -p "$d"

    # coredump 查找
    {
        echo "=== 最近7天 coredump 文件 ==="
        for p in /var/core /var/lib/systemd/coredump /var/crash /cores; do
            if [ -d "$p" ]; then
                echo "--- $p ---"
                find "$p" -name 'core*' -mtime -7 -maxdepth 2 -ls 2>/dev/null || echo "  无"
            fi
        done
        echo ""
        echo "=== core_pattern 配置 ==="
        cat /proc/sys/kernel/core_pattern 2>/dev/null || echo "不可读"
    } > "$d/coredump_files.txt"

    # coredumpctl（systemd 环境）
    if has_cmd coredumpctl; then
        timeout "$CMD_TIMEOUT" coredumpctl list --no-pager 2>/dev/null | tail -50 > "$d/coredumpctl.txt" || true
    fi

    # gdb 检查
    {
        echo "=== 调试工具状态 ==="
        if has_cmd gdb; then
            echo "gdb: $(gdb --version 2>/dev/null | head -1)"
        else
            echo "gdb: 未安装"
        fi
        if has_cmd lldb; then
            echo "lldb: $(lldb --version 2>/dev/null | head -1)"
        else
            echo "lldb: 未安装"
        fi
    } > "$d/debug_tools.txt"

    # segfault 日志
    if has_cmd dmesg; then
        dmesg 2>/dev/null | grep -iE 'segfault|traps:|general protection|SIGABRT' \
            > "$d/segfault_dmesg.txt" 2>/dev/null || true
    fi

    # 应用日志（常见路径）
    {
        echo "=== 应用日志最近错误 ==="
        for logfile in /var/log/messages /var/log/syslog; do
            if [ -r "$logfile" ]; then
                echo "--- $logfile ---"
                grep -iE 'segfault|core dumped|signal 11|signal 6|SIGSEGV|SIGABRT' "$logfile" 2>/dev/null | tail -30 || echo "  无匹配"
            fi
        done
    } > "$d/app_crash_logs.txt"

    if has_cmd journalctl; then
        timeout "$CMD_TIMEOUT" journalctl --no-pager -p err -n 200 > "$d/journal_errors.txt" 2>/dev/null || true
    fi
}

deep_perf() {
    log_step "深度性能数据收集..."
    local d="$OUTPUT_DIR/perf_deep"
    mkdir -p "$d"

    # perf record（如有权限，短采样）
    if has_cmd perf; then
        log_info "perf stat 采样 5 秒..."
        timeout 10 perf stat -a sleep 5 > "$d/perf_stat.txt" 2>&1 || echo "[perf stat 失败]" > "$d/perf_stat.txt"
        log_info "提示: 如需火焰图数据，请手动运行:"
        echo "  perf record -F 99 -ag -- sleep 30" > "$d/flamegraph_hint.txt"
        echo "  perf script > perf.out" >> "$d/flamegraph_hint.txt"
    fi

    # sar 历史数据
    if has_cmd sar; then
        timeout "$CMD_TIMEOUT" sar -u  > "$d/sar_cpu_history.txt" 2>/dev/null || true
        timeout "$CMD_TIMEOUT" sar -r  > "$d/sar_mem_history.txt" 2>/dev/null || true
        timeout "$CMD_TIMEOUT" sar -b  > "$d/sar_io_history.txt"  2>/dev/null || true
        timeout "$CMD_TIMEOUT" sar -n DEV > "$d/sar_net_history.txt" 2>/dev/null || true
    fi

    # 60秒快照
    log_info "60秒系统快照 (vmstat/iostat/mpstat)..."
    if has_cmd vmstat; then
        timeout 65 vmstat 5 12 > "$d/vmstat_60s.txt" 2>/dev/null || true
    fi
    if has_cmd iostat; then
        timeout 65 iostat -xz 5 12 > "$d/iostat_60s.txt" 2>/dev/null || true
    fi
    if has_cmd mpstat; then
        timeout 65 mpstat -P ALL 5 12 > "$d/mpstat_60s.txt" 2>/dev/null || true
    fi
    if has_cmd pidstat; then
        timeout 65 pidstat 5 12 > "$d/pidstat_60s.txt" 2>/dev/null || true
    fi

    # PSI（压力信息）
    safe_cat /proc/pressure/cpu    "$d/psi_cpu.txt" 50
    safe_cat /proc/pressure/memory "$d/psi_memory.txt" 50
    safe_cat /proc/pressure/io     "$d/psi_io.txt" 50

    # top 快照
    if has_cmd top; then
        timeout "$CMD_TIMEOUT" top -b -n 2 -d 1 > "$d/top.txt" 2>/dev/null || true
    fi

    # 内存 top 进程
    ps -eo pid,rss,vsz,comm --sort=-rss 2>/dev/null | head -30 > "$d/mem_top30.txt" || true
    ps -eo pid,pcpu,comm --sort=-pcpu 2>/dev/null | head -30 > "$d/cpu_top30.txt" || true
}

deep_hang() {
    log_step "深度系统挂起数据收集..."
    local d="$OUTPUT_DIR/hang_deep"
    mkdir -p "$d"

    # 所有进程栈
    safe_run "$d/ps_full.txt" ps -eLf

    # D 状态进程
    ps -eo pid,stat,wchan:32,comm 2>/dev/null | awk 'NR==1 || /^[[:space:]]*[0-9]+[[:space:]]+D/' \
        > "$d/d_state_procs.txt" 2>/dev/null || true

    # D 状态进程的内核栈
    {
        for pid in $(ps -eo pid,stat 2>/dev/null | awk '$2 ~ /D/ {print $1}'); do
            echo "=== PID $pid: $(cat /proc/$pid/comm 2>/dev/null || echo '?') ==="
            cat "/proc/$pid/stack" 2>/dev/null || echo "[无法读取]"
            cat "/proc/$pid/wchan" 2>/dev/null && echo "" || true
            echo ""
        done
    } > "$d/d_state_stacks.txt"

    # 锁信息
    safe_cat /proc/locks "$d/proc_locks.txt"

    # lockup / hung_task 日志
    if has_cmd dmesg; then
        dmesg 2>/dev/null | grep -iE 'soft lockup|hard LOCKUP|RCU.*stall|hung_task|blocked for more than' \
            > "$d/lockup_dmesg.txt" 2>/dev/null || true
    fi

    # sysrq 触发全部进程栈（仅提示，不执行）
    {
        echo "如需查看所有内核线程栈，可手动执行:"
        echo "  echo t > /proc/sysrq-trigger"
        echo "  dmesg > all_stacks.txt"
    } > "$d/sysrq_hint.txt"

    # 负载和运行队列
    safe_cat /proc/loadavg "$d/loadavg.txt" 5
    if has_cmd vmstat; then
        timeout "$CMD_TIMEOUT" vmstat 1 5 > "$d/vmstat.txt" 2>/dev/null || true
    fi
}

deep_network() {
    log_step "深度网络数据收集..."
    local d="$OUTPUT_DIR/network_deep"
    mkdir -p "$d"

    # 接口统计
    safe_run "$d/ip_addr.txt"    ip -s addr
    safe_run "$d/ip_link.txt"    ip -s link

    # 路由
    safe_run "$d/ip_route.txt"   ip route show table all
    safe_run "$d/ip_rule.txt"    ip rule show

    # 防火墙规则
    safe_run "$d/iptables.txt"   iptables-save
    safe_run "$d/ip6tables.txt"  ip6tables-save
    if has_cmd nft; then
        safe_run "$d/nftables.txt" nft list ruleset
    fi

    # 连接状态
    safe_run "$d/ss_all.txt"     ss -tunap
    safe_run "$d/ss_summary.txt" ss -s
    if has_cmd netstat; then
        safe_run "$d/netstat.txt" netstat -s
    fi

    # conntrack
    if has_cmd conntrack; then
        safe_run "$d/conntrack_stats.txt" conntrack -S
        safe_run "$d/conntrack_count.txt" conntrack -C
    fi

    # ethtool 逐接口
    if has_cmd ethtool; then
        {
            for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo); do
                echo "=== $iface ==="
                timeout "$CMD_TIMEOUT" ethtool "$iface" 2>/dev/null || echo "[失败]"
                timeout "$CMD_TIMEOUT" ethtool -S "$iface" 2>/dev/null || true
                echo ""
            done
        } > "$d/ethtool.txt"
    fi

    # DNS
    safe_cat /etc/resolv.conf "$d/resolv.conf.txt"

    # 抓包准备提示
    {
        echo "如需抓包，可手动执行:"
        echo "  tcpdump -i <接口> -c 1000 -w capture.pcap"
        echo "  tcpdump -i any -nn -s0 port <端口> -w capture.pcap"
    } > "$d/tcpdump_hint.txt"

    # 网络相关 dmesg
    if has_cmd dmesg; then
        dmesg 2>/dev/null | grep -iE 'link is down|carrier lost|nf_conntrack|dropped|net_ratelimit' \
            > "$d/network_dmesg.txt" 2>/dev/null || true
    fi
}

deep_storage() {
    log_step "深度存储数据收集..."
    local d="$OUTPUT_DIR/storage_deep"
    mkdir -p "$d"

    # SMART 信息
    if has_cmd smartctl; then
        {
            for dev in $(lsblk -dno NAME 2>/dev/null | sed 's/^/\/dev\//'); do
                echo "=== $dev ==="
                timeout "$CMD_TIMEOUT" smartctl -a "$dev" 2>/dev/null || echo "[失败或不支持]"
                echo ""
            done
        } > "$d/smartctl.txt"
    else
        echo "smartctl 未安装，无法获取 SMART 信息" > "$d/smartctl.txt"
    fi

    # RAID 状态
    safe_cat /proc/mdstat "$d/mdstat.txt"
    if has_cmd mdadm; then
        safe_run "$d/mdadm_detail.txt" mdadm --detail --scan
    fi
    if has_cmd megacli; then
        safe_run "$d/megacli.txt" megacli -LDInfo -Lall -Aall
    fi

    # IO 统计
    if has_cmd iostat; then
        timeout 35 iostat -xz 5 6 > "$d/iostat_30s.txt" 2>/dev/null || true
    fi
    safe_run "$d/lsblk.txt" lsblk -f

    # 文件系统状态
    safe_run "$d/df.txt"    df -hT
    safe_run "$d/mount.txt" mount
    safe_cat /proc/mounts   "$d/proc_mounts.txt"

    # IO 错误日志
    if has_cmd dmesg; then
        dmesg 2>/dev/null | grep -iE -B 2 -A 5 'I/O error|EXT[234]-fs error|XFS.*error|blk_update_request|SCSI error' \
            > "$d/io_errors.txt" 2>/dev/null || true
    fi

    # 磁盘使用 top 目录
    if has_cmd du; then
        timeout "$CMD_TIMEOUT" du -hx --max-depth=1 / 2>/dev/null | sort -rh | head -20 > "$d/du_top20.txt" || true
    fi
}

# =====================================================================
# 打包和摘要
# =====================================================================

pack_output() {
    log_step "Step 5: 打包输出..."
    local tarfile="${OUTPUT_DIR}.tar.gz"
    tar czf "$tarfile" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")" 2>/dev/null
    log_info "打包完成: $tarfile"
}

generate_summary() {
    log_step "Step 6: 生成摘要报告"
    local report="$OUTPUT_DIR/SUMMARY.txt"
    local file_count
    file_count=$(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ')
    local total_size
    total_size=$(du -sh "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}')

    {
        echo "============================================"
        echo "  OS 诊断报告"
        echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  主机名:   $(hostname 2>/dev/null || echo '未知')"
        echo "  内核:     $(uname -r 2>/dev/null || echo '未知')"
        echo "  系统:     $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo '未知')"
        echo "============================================"
        echo ""
        echo "诊断模式: $MODE"
        echo ""
        if [ "$MODE" = "auto" ] && [ -f "$OUTPUT_DIR/auto_diagnosis/SUMMARY.txt" ]; then
            echo "(auto模式由 quick_diagnosis.sh 生成详细检测结果)"
        elif [ "$MODE" = "auto" ]; then
            echo "(auto模式未生成详细检测结果)"
        else
            echo "针对问题类型: $MODE"
        fi
        echo ""
        echo "收集文件数: $file_count"
        echo "总大小:     $total_size"
        echo ""
        echo "--- 文件清单 ---"
        find "$OUTPUT_DIR" -type f -name '*.txt' | sort | while read -r f; do
            local rel="${f#$OUTPUT_DIR/}"
            printf "  %s\n" "$rel"
        done
        echo ""
        echo "输出目录: $OUTPUT_DIR"
        echo "打包文件: ${OUTPUT_DIR}.tar.gz"
        echo "============================================"
    } > "$report"
}

print_final_summary() {
    local file_count
    file_count=$(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ')

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  诊断完成！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo "  诊断模式:   $MODE"
    echo "  收集文件:   $file_count 个"
    echo "  输出目录:   $OUTPUT_DIR"
    echo "  打包文件:   ${OUTPUT_DIR}.tar.gz"
    echo "  摘要报告:   $OUTPUT_DIR/SUMMARY.txt"
    echo -e "${GREEN}============================================${NC}"
    echo ""
}

# =====================================================================
# 主流程
# =====================================================================
main() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}  OS 问题诊断工具 v1.0${NC}"
    echo -e "${CYAN}  模式: $MODE${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""

    # Step 1: 权限检查和环境准备
    check_permissions "$@"
    echo ""

    # Step 2: 检查工具可用性
    log_step "Step 2: 检查分析工具..."
    if has_script "$SCRIPT_DIR/check_tools.sh"; then
        bash "$SCRIPT_DIR/check_tools.sh" --quiet || log_warn "部分工具缺失，诊断继续"
    else
        log_warn "check_tools.sh 不可用，跳过工具检查"
    fi
    echo ""

    # Step 3: 收集基础系统信息
    log_step "Step 3: 收集基础系统信息..."
    if has_script "$SCRIPT_DIR/collect_info.sh"; then
        bash "$SCRIPT_DIR/collect_info.sh" "$OUTPUT_DIR/base_info" || log_warn "基础信息收集部分失败"
    else
        log_warn "collect_info.sh 不可用，跳过基础信息收集"
    fi
    echo ""

    # Step 4: 根据模式选择诊断策略
    log_step "Step 4: 执行诊断 (模式: $MODE)..."
    case "$MODE" in
        auto)
            log_info "运行自动检测..."
            if has_script "$SCRIPT_DIR/quick_diagnosis.sh"; then
                bash "$SCRIPT_DIR/quick_diagnosis.sh" "$OUTPUT_DIR/auto_diagnosis" || log_warn "自动诊断部分失败"
            else
                log_error "quick_diagnosis.sh 不可用，无法执行自动诊断"
            fi
            ;;
        kernel)    deep_kernel    ;;
        userspace) deep_userspace ;;
        perf)      deep_perf      ;;
        hang)      deep_hang      ;;
        network)   deep_network   ;;
        storage)   deep_storage   ;;
    esac
    echo ""

    # Step 5: 打包输出
    generate_summary
    pack_output
    echo ""

    # Step 6: 最终摘要
    print_final_summary
}

main "$@"
