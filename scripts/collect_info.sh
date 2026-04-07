#!/bin/bash

# 系统信息收集脚本
# 收集系统基本信息用于问题定位

# --- 默认参数 ---
CMD_TIMEOUT=30
OUTPUT_LIMIT="10M"
MAX_SIZE=""   # 输出目录最大字节数，空表示不限制

# --- 错误统计 ---
FAILED_CMDS=""
SKIPPED_CMDS=""
FAIL_COUNT=0
SKIP_COUNT=0

# --- 解析命令行参数 ---
POSITIONAL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --max-size)
            MAX_SIZE="$2"; shift 2 ;;
        --max-size=*)
            MAX_SIZE="${1#*=}"; shift ;;
        *)
            # 第一个位置参数作为输出目录
            if [ -z "$POSITIONAL" ]; then POSITIONAL="$1"; fi
            shift ;;
    esac
done

OUTPUT_DIR="${POSITIONAL:-./os-info-$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUTPUT_DIR"

# --- root权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "[警告] 未以root运行，部分命令可能因权限不足而失败"
    echo ""
fi

# --- 将 --max-size 的人类可读值转为字节数 ---
parse_size() {
    local val="$1"
    case "$val" in
        *G|*g) echo $(( ${val%[Gg]} * 1024 * 1024 * 1024 )) ;;
        *M|*m) echo $(( ${val%[Mm]} * 1024 * 1024 )) ;;
        *K|*k) echo $(( ${val%[Kk]} * 1024 )) ;;
        *)     echo "$val" ;;
    esac
}

# 检查输出目录是否超过 --max-size
check_dir_size() {
    if [ -z "$MAX_SIZE" ]; then return 0; fi
    local limit
    limit=$(parse_size "$MAX_SIZE")
    # du -sb 不一定所有平台都支持，兼容写法
    local current
    current=$(du -sk "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}')
    current=$(( current * 1024 ))
    if [ "$current" -ge "$limit" ]; then
        echo "[警告] 输出目录已达到大小限制 ($MAX_SIZE)，跳过后续收集"
        return 1
    fi
    return 0
}

# --- 核心函数: safe_run ---
# 用法: safe_run <描述> <输出文件> <命令...>
# - 检查命令是否存在
# - timeout 防止挂起
# - head -c 限制输出大小
# - 捕获错误不中断脚本
safe_run() {
    local desc="$1"
    local outfile="$2"
    shift 2
    local cmd_name
    cmd_name=$(echo "$1" | awk '{print $1}')

    # 如果是读文件 (cat) 则不检查目标文件命令
    if [ "$cmd_name" != "cat" ] && [ "$cmd_name" != "tail" ] && [ "$cmd_name" != "head" ]; then
        if ! command -v "$cmd_name" > /dev/null 2>&1; then
            SKIP_COUNT=$((SKIP_COUNT + 1))
            SKIPPED_CMDS="${SKIPPED_CMDS}  - ${desc} (${cmd_name} 未安装)\n"
            return 0
        fi
    fi

    # 检查目录大小限制
    if ! check_dir_size; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        SKIPPED_CMDS="${SKIPPED_CMDS}  - ${desc} (超过大小限制)\n"
        return 0
    fi

    if timeout "$CMD_TIMEOUT" sh -c "$*" 2>/dev/null | head -c "$OUTPUT_LIMIT" > "$OUTPUT_DIR/$outfile" 2>/dev/null; then
        return 0
    else
        local rc=$?
        # 124 = timeout 超时退出码
        if [ "$rc" -eq 124 ]; then
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_CMDS="${FAILED_CMDS}  - ${desc} (超时 ${CMD_TIMEOUT}s)\n"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_CMDS="${FAILED_CMDS}  - ${desc} (退出码 ${rc})\n"
        fi
        return 0
    fi
}

echo "收集系统信息到: $OUTPUT_DIR"
if [ -n "$MAX_SIZE" ]; then
    echo "输出目录大小限制: $MAX_SIZE"
fi
echo ""

echo "[1/10] 系统基本信息..."
safe_run "uname -a"         "uname.txt"        "uname -a"
safe_run "os-release"        "os-release.txt"   "cat /etc/os-release"
safe_run "hostname"          "hostname.txt"     "hostname"
safe_run "uptime"            "uptime.txt"       "uptime"

echo "[2/10] 内核信息..."
safe_run "kernel version"    "kernel-version.txt" "cat /proc/version"
safe_run "lsmod"             "modules.txt"       "lsmod"
safe_run "cmdline"           "cmdline.txt"       "cat /proc/cmdline"

echo "[3/10] CPU信息..."
safe_run "lscpu"             "cpu-info.txt"      "lscpu"
safe_run "cpuinfo"           "cpuinfo.txt"       "cat /proc/cpuinfo"

echo "[4/10] 内存信息..."
safe_run "free -h"           "memory-info.txt"   "free -h"
safe_run "meminfo"           "meminfo.txt"       "cat /proc/meminfo"
safe_run "vmstat"            "vmstat.txt"        "cat /proc/vmstat"

echo "[5/10] 磁盘信息..."
safe_run "df -h"             "disk-usage.txt"    "df -h"
safe_run "mount"             "mounts.txt"        "mount"
safe_run "partitions"        "partitions.txt"    "cat /proc/partitions"
safe_run "mdstat"            "mdstat.txt"        "cat /proc/mdstat"

echo "[6/10] 网络信息..."
safe_run "ip addr"           "network-interfaces.txt" "ip addr"
safe_run "ip route"          "routes.txt"        "ip route"
safe_run "resolv.conf"       "resolv.conf.txt"   "cat /etc/resolv.conf"
safe_run "ss -tuln"          "listening-ports.txt" "ss -tuln"

echo "[7/10] 进程信息..."
safe_run "ps auxf"           "processes.txt"     "ps auxf"
safe_run "top -b -n 1"       "top.txt"           "top -b -n 1"

echo "[8/10] 内核日志..."
safe_run "dmesg"             "dmesg.txt"         "dmesg"
safe_run "journalctl -k"     "kernel-journal.txt" "journalctl -k --no-pager"

echo "[9/10] 系统日志..."
if [ -f /var/log/messages ]; then
    safe_run "messages log"  "messages.txt"      "tail -1000 /var/log/messages"
fi
if [ -f /var/log/syslog ]; then
    safe_run "syslog"        "syslog.txt"        "tail -1000 /var/log/syslog"
fi

echo "[10/10] 系统配置..."
safe_run "sysctl -a"         "sysctl.txt"        "sysctl -a"
safe_run "ulimit -a"         "limits.txt"        "ulimit -a"

echo ""
echo "========================================"
echo "信息收集完成!"
echo "========================================"
echo "输出目录: $OUTPUT_DIR"
echo ""

# --- 错误汇总 ---
if [ "$FAIL_COUNT" -gt 0 ] || [ "$SKIP_COUNT" -gt 0 ]; then
    echo "--- 错误/跳过汇总 ---"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo "失败 ($FAIL_COUNT):"
        printf "$FAILED_CMDS"
    fi
    if [ "$SKIP_COUNT" -gt 0 ]; then
        echo "跳过 ($SKIP_COUNT):"
        printf "$SKIPPED_CMDS"
    fi
    echo ""
fi

echo "文件列表:"
ls -la "$OUTPUT_DIR"
echo ""
echo "打包命令:"
echo "  tar czf $OUTPUT_DIR.tar.gz -C $(dirname $OUTPUT_DIR) $(basename $OUTPUT_DIR)"
