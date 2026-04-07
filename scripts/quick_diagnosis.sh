#!/bin/bash
# 智能问题诊断脚本
# 自动检测问题类型并收集对应数据
# 只读操作，不修改系统状态
# 用法: quick_diagnosis.sh [output_dir]

set -euo pipefail

# --- 配置 ---
OUTPUT_DIR="${1:-./diagnosis-$(date +%Y%m%d_%H%M%S)}"
TIMEOUT_SEC=30
MAX_LOG_LINES=2000
DETECTED_PROBLEMS=()

# --- 颜色输出 ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

# --- 工具函数 ---

has_cmd() { command -v "$1" &>/dev/null; }

# 安全执行：检查命令存在 + 超时保护 + 错误捕获
safe_run() {
    local outfile="$1"; shift
    local cmd="$1"; shift

    if ! has_cmd "$cmd"; then
        echo "[跳过] 命令不存在: $cmd" >> "$outfile"
        return 0
    fi

    if ! timeout "$TIMEOUT_SEC" "$cmd" "$@" >> "$outfile" 2>&1; then
        echo "[警告] 命令超时或失败: $cmd $*" >> "$outfile"
    fi
}

# 安全读取文件（限制行数）
safe_cat() {
    local src="$1" dst="$2" lines="${3:-$MAX_LOG_LINES}"
    if [ -r "$src" ]; then
        tail -n "$lines" "$src" > "$dst" 2>/dev/null || echo "[无法读取] $src" > "$dst"
    else
        echo "[不存在或无权限] $src" > "$dst"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "未以root运行，部分信息可能无法收集"
        log_warn "建议: sudo $0 $*"
        echo "non-root" > "$OUTPUT_DIR/.permissions"
    else
        log_info "root权限确认"
        echo "root" > "$OUTPUT_DIR/.permissions"
    fi
}

# =====================================================================
# 问题检测函数 — 返回0表示检测到问题
# =====================================================================

detect_kernel_crash() {
    # 检查 dmesg 中的 panic/BUG/oops 以及 /var/crash 中的 vmcore
    if dmesg 2>/dev/null | grep -qiE 'panic|BUG:|Oops:|Call Trace:|RIP:'; then
        return 0
    fi
    if [ -d /var/crash ] && find /var/crash -name 'vmcore*' -maxdepth 2 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

detect_userspace_crash() {
    # 检查常见 coredump 路径
    local core_dirs=(/var/core /var/lib/systemd/coredump /var/crash)
    for d in "${core_dirs[@]}"; do
        if [ -d "$d" ] && find "$d" -name 'core*' -mtime -7 -maxdepth 2 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    if dmesg 2>/dev/null | grep -qiE 'segfault|traps:|general protection'; then
        return 0
    fi
    return 1
}

detect_performance() {
    # 负载 > CPU核数*2 或 内存可用<10%
    local cpus load_int
    cpus=$(nproc 2>/dev/null || echo 1)
    load_int=$(awk '{printf "%d", $1}' /proc/loadavg 2>/dev/null || echo 0)
    if [ "$load_int" -ge $((cpus * 2)) ]; then
        return 0
    fi
    local mem_total mem_avail
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 1)
    mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 1)
    if [ "$mem_total" -gt 0 ] && [ $((mem_avail * 100 / mem_total)) -lt 10 ]; then
        return 0
    fi
    return 1
}

detect_hang() {
    # D 状态进程 或 dmesg 中 soft lockup
    if ps -eo state= 2>/dev/null | grep -q '^D'; then
        return 0
    fi
    if dmesg 2>/dev/null | grep -qiE 'soft lockup|hard LOCKUP|RCU.*stall|hung_task'; then
        return 0
    fi
    return 1
}

detect_network() {
    # 网卡错误、链路断开、conntrack 满
    if has_cmd ip && ip -s link 2>/dev/null | grep -qE 'errors [1-9]'; then
        return 0
    fi
    if dmesg 2>/dev/null | grep -qiE 'link is down|nf_conntrack.*table full|carrier lost'; then
        return 0
    fi
    return 1
}

detect_storage() {
    # IO 错误、文件系统错误
    if dmesg 2>/dev/null | grep -qiE 'I/O error|EXT[234]-fs error|XFS.*error|Buffer I/O|blk_update_request'; then
        return 0
    fi
    # 磁盘空间不足 (>95%)，忽略只读镜像和临时文件系统
    if df -PT 2>/dev/null | awk '
        NR > 1 {
            fs_type = $2
            gsub(/%/, "", $6)
            if (fs_type ~ /^(tmpfs|devtmpfs|iso9660|squashfs|overlay)$/) {
                next
            }
            if (($6 + 0) >= 95) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    '; then
        return 0
    fi
    return 1
}

detect_oom() {
    if dmesg 2>/dev/null | grep -qiE 'Out of memory|oom-kill|invoked oom-killer|Killed process'; then
        return 0
    fi
    return 1
}

# =====================================================================
# 数据收集函数
# =====================================================================

collect_base() {
    log_step "收集基础系统信息..."
    local d="$OUTPUT_DIR/base"
    mkdir -p "$d"

    safe_run "$d/uname.txt"      uname -a
    safe_run "$d/uptime.txt"     uptime
    safe_run "$d/free.txt"       free -h
    safe_run "$d/df.txt"         df -hT
    safe_run "$d/hostname.txt"   hostname
    safe_run "$d/ps_aux.txt"     ps auxf
    safe_run "$d/lscpu.txt"      lscpu
    safe_cat /proc/meminfo       "$d/meminfo.txt"
    safe_cat /proc/vmstat        "$d/vmstat_proc.txt"
    safe_cat /proc/loadavg       "$d/loadavg.txt"
    safe_cat /etc/os-release     "$d/os-release.txt"

    # dmesg 尾部
    if has_cmd dmesg; then
        dmesg 2>/dev/null | tail -n "$MAX_LOG_LINES" > "$d/dmesg_tail.txt" || true
    fi
}

collect_kernel_crash() {
    log_step "收集内核崩溃数据..."
    local d="$OUTPUT_DIR/kernel_crash"
    mkdir -p "$d"

    # 完整 dmesg
    if has_cmd dmesg; then
        dmesg --decode 2>/dev/null > "$d/dmesg_full.txt" || \
        dmesg 2>/dev/null > "$d/dmesg_full.txt" || true
    fi

    # 提取 panic/oops 上下文
    if has_cmd dmesg; then
        dmesg 2>/dev/null | grep -iE -A 30 'panic|BUG:|Oops:|Call Trace:' > "$d/crash_context.txt" 2>/dev/null || true
    fi

    safe_cat /var/log/messages   "$d/messages.txt"
    safe_cat /var/log/kern.log   "$d/kern.log.txt"
    safe_cat /proc/cmdline       "$d/cmdline.txt"

    # vmcore 位置
    if [ -d /var/crash ]; then
        find /var/crash -maxdepth 2 -name 'vmcore*' -ls > "$d/vmcore_files.txt" 2>/dev/null || true
    fi

    # crash 工具检查
    {
        echo "--- crash 工具 ---"
        has_cmd crash && echo "crash: $(which crash)" || echo "crash: 未安装"
        echo "--- debuginfo ---"
        ls /usr/lib/debug/lib/modules/*/vmlinux 2>/dev/null || echo "vmlinux debuginfo: 未找到"
    } > "$d/crash_tools.txt"

    safe_run "$d/modules.txt" lsmod
}

collect_userspace_crash() {
    log_step "收集用户态崩溃数据..."
    local d="$OUTPUT_DIR/userspace_crash"
    mkdir -p "$d"

    # coredump 文件列表
    {
        for p in /var/core /var/lib/systemd/coredump /var/crash; do
            [ -d "$p" ] && find "$p" -name 'core*' -mtime -7 -maxdepth 2 -ls 2>/dev/null
        done
    } > "$d/coredump_files.txt"

    # segfault 日志
    dmesg 2>/dev/null | grep -iE 'segfault|traps:|general protection' > "$d/segfault_dmesg.txt" 2>/dev/null || true

    # coredumpctl（如有）
    if has_cmd coredumpctl; then
        timeout "$TIMEOUT_SEC" coredumpctl list --no-pager 2>/dev/null | tail -50 > "$d/coredumpctl.txt" || true
    fi

    # gdb 检查
    {
        has_cmd gdb && echo "gdb: $(gdb --version 2>/dev/null | head -1)" || echo "gdb: 未安装"
    } > "$d/debug_tools.txt"
}

collect_performance() {
    log_step "收集性能数据..."
    local d="$OUTPUT_DIR/performance"
    mkdir -p "$d"

    # top 快照
    if has_cmd top; then
        timeout "$TIMEOUT_SEC" top -b -n 2 -d 1 > "$d/top.txt" 2>/dev/null || true
    fi

    safe_run "$d/vmstat.txt"   vmstat 1 5
    safe_run "$d/iostat.txt"   iostat -xz 1 3
    safe_run "$d/mpstat.txt"   mpstat -P ALL 1 3

    # sar（如有）
    if has_cmd sar; then
        timeout "$TIMEOUT_SEC" sar -u 1 3 > "$d/sar_cpu.txt" 2>/dev/null || true
        timeout "$TIMEOUT_SEC" sar -r 1 3 > "$d/sar_mem.txt" 2>/dev/null || true
    fi

    safe_cat /proc/pressure/cpu    "$d/psi_cpu.txt" 50
    safe_cat /proc/pressure/memory "$d/psi_memory.txt" 50
    safe_cat /proc/pressure/io     "$d/psi_io.txt" 50
}

collect_hang() {
    log_step "收集系统挂起数据..."
    local d="$OUTPUT_DIR/hang"
    mkdir -p "$d"

    # D 状态进程
    ps -eo pid,stat,wchan:32,comm | awk 'NR==1 || /^[[:space:]]*[0-9]+[[:space:]]+D/' > "$d/d_state_procs.txt" 2>/dev/null || true

    # D 状态进程的内核栈
    {
        for pid in $(ps -eo pid,stat | awk '$2 ~ /D/ {print $1}' 2>/dev/null); do
            echo "=== PID $pid: $(cat /proc/$pid/comm 2>/dev/null || echo '?') ==="
            cat "/proc/$pid/stack" 2>/dev/null || echo "[无法读取]"
            echo ""
        done
    } > "$d/d_state_stacks.txt"

    # lockup 相关 dmesg
    dmesg 2>/dev/null | grep -iE 'soft lockup|hard LOCKUP|RCU.*stall|hung_task|blocked for more than' \
        > "$d/lockup_dmesg.txt" 2>/dev/null || true

    safe_run "$d/ps_full.txt" ps -eLf
}

collect_network() {
    log_step "收集网络数据..."
    local d="$OUTPUT_DIR/network"
    mkdir -p "$d"

    safe_run "$d/ip_addr.txt"     ip -s addr
    safe_run "$d/ip_route.txt"    ip route show table all
    safe_run "$d/ss.txt"          ss -tunap
    safe_run "$d/iptables.txt"    iptables-save
    safe_run "$d/ip6tables.txt"   ip6tables-save

    # ethtool（逐接口）
    if has_cmd ethtool; then
        {
            for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo); do
                echo "=== $iface ==="
                timeout "$TIMEOUT_SEC" ethtool "$iface" 2>/dev/null || echo "[失败]"
                echo ""
            done
        } > "$d/ethtool.txt"
    fi

    # conntrack
    if has_cmd conntrack; then
        safe_run "$d/conntrack_stats.txt" conntrack -S
        safe_run "$d/conntrack_count.txt" conntrack -C
    fi

    safe_cat /etc/resolv.conf "$d/resolv.conf.txt"
}

collect_storage() {
    log_step "收集存储数据..."
    local d="$OUTPUT_DIR/storage"
    mkdir -p "$d"

    safe_run "$d/df.txt"     df -hT
    safe_run "$d/mount.txt"  mount
    safe_run "$d/lsblk.txt"  lsblk -f
    safe_run "$d/iostat.txt" iostat -xz

    safe_cat /proc/mdstat "$d/mdstat.txt"

    # IO 错误上下文
    dmesg 2>/dev/null | grep -iE -B 2 -A 5 'I/O error|EXT[234]-fs error|XFS.*error|blk_update_request' \
        > "$d/io_errors.txt" 2>/dev/null || true

    # smartctl（如有）
    if has_cmd smartctl; then
        {
            for dev in $(lsblk -dno NAME 2>/dev/null | sed 's/^/\/dev\//'); do
                echo "=== $dev ==="
                timeout "$TIMEOUT_SEC" smartctl -a "$dev" 2>/dev/null || echo "[失败或不支持]"
                echo ""
            done
        } > "$d/smartctl.txt"
    fi
}

collect_oom() {
    log_step "收集OOM数据..."
    local d="$OUTPUT_DIR/oom"
    mkdir -p "$d"

    dmesg 2>/dev/null | grep -iE -B 5 -A 20 'Out of memory|oom-kill|invoked oom-killer|Killed process' \
        > "$d/oom_dmesg.txt" 2>/dev/null || true

    safe_cat /proc/meminfo "$d/meminfo.txt"
    safe_cat /proc/buddyinfo "$d/buddyinfo.txt"
    safe_cat /proc/slabinfo "$d/slabinfo.txt" 500

    # 各进程内存占用 top20
    ps -eo pid,rss,vsz,comm --sort=-rss 2>/dev/null | head -21 > "$d/mem_top20.txt" || true
}

# 60秒快速观测（未检测到明确问题时）
collect_quick_check() {
    log_step "未检测到明确问题，执行60秒快速观测..."
    local d="$OUTPUT_DIR/quick_check"
    mkdir -p "$d"

    safe_run "$d/vmstat_60s.txt" vmstat 5 12
    if has_cmd iostat; then
        safe_run "$d/iostat_60s.txt" iostat -xz 5 12
    fi
}

# =====================================================================
# 生成摘要报告
# =====================================================================

generate_summary() {
    local report="$OUTPUT_DIR/SUMMARY.txt"
    {
        echo "============================================"
        echo "  智能诊断报告"
        echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  主机名:   $(hostname 2>/dev/null || echo '未知')"
        echo "  内核:     $(uname -r 2>/dev/null || echo '未知')"
        echo "============================================"
        echo ""

        if [ ${#DETECTED_PROBLEMS[@]} -eq 0 ]; then
            echo "检测结果: 未发现明显异常，已执行快速观测"
        else
            echo "检测到以下问题类型:"
            for p in "${DETECTED_PROBLEMS[@]}"; do
                echo "  ● $p"
            done
        fi

        echo ""
        echo "已收集数据:"
        find "$OUTPUT_DIR" -type f -name '*.txt' | sort | while read -r f; do
            local rel="${f#$OUTPUT_DIR/}"
            local size
            size=$(wc -c < "$f" 2>/dev/null || echo 0)
            printf "  %-45s %s\n" "$rel" "$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")"
        done

        echo ""
        echo "============================================"
        echo "打包命令:"
        echo "  tar czf $(basename "$OUTPUT_DIR").tar.gz -C $(dirname "$OUTPUT_DIR") $(basename "$OUTPUT_DIR")"
        echo "============================================"
    } > "$report"
}

# =====================================================================
# 主逻辑
# =====================================================================

main() {
    echo ""
    log_info "智能问题诊断 v1.0"
    log_info "输出目录: $OUTPUT_DIR"
    echo ""

    mkdir -p "$OUTPUT_DIR"
    check_root "$@"

    # 基础信息（始终收集）
    collect_base

    # 问题检测
    log_step "检测问题类型..."
    local detectors=(
        "detect_kernel_crash:内核崩溃(panic/BUG/oops):collect_kernel_crash"
        "detect_oom:内存耗尽(OOM):collect_oom"
        "detect_hang:系统挂起(D-state/lockup):collect_hang"
        "detect_performance:性能异常(高负载/内存不足):collect_performance"
        "detect_userspace_crash:用户态崩溃(coredump/segfault):collect_userspace_crash"
        "detect_network:网络异常(错误/链路断开):collect_network"
        "detect_storage:存储异常(IO错误/空间不足):collect_storage"
    )

    for entry in "${detectors[@]}"; do
        IFS=':' read -r func desc collector <<< "$entry"
        if $func 2>/dev/null; then
            log_warn "检测到: $desc"
            DETECTED_PROBLEMS+=("$desc")
            $collector
        fi
    done

    # 未检测到问题时执行快速观测
    if [ ${#DETECTED_PROBLEMS[@]} -eq 0 ]; then
        collect_quick_check
    fi

    # 生成报告
    generate_summary

    echo ""
    log_info "诊断完成！"
    log_info "摘要报告: $OUTPUT_DIR/SUMMARY.txt"
    if [ ${#DETECTED_PROBLEMS[@]} -gt 0 ]; then
        log_info "检测到 ${#DETECTED_PROBLEMS[@]} 类问题"
    fi
    echo ""
    log_info "打包命令:"
    echo "  tar czf $(basename "$OUTPUT_DIR").tar.gz -C $(dirname "$OUTPUT_DIR") $(basename "$OUTPUT_DIR")"
    echo ""
}

main "$@"
