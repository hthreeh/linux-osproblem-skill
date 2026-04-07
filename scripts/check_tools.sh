#!/bin/bash

# OS问题定位工具检查脚本
# 检查必要分析工具是否安装

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 超时秒数（每个检查命令的最大等待时间）
CHECK_TIMEOUT=5

# 解析命令行参数
QUIET=0
for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET=1 ;;
    esac
done

# root权限检查
if [ "$(id -u)" -ne 0 ]; then
    if [ "$QUIET" -eq 0 ]; then
        echo -e "${YELLOW}[警告]${NC} 未以root运行，部分工具检查可能不准确"
        echo ""
    fi
fi

if [ "$QUIET" -eq 0 ]; then
    echo "========================================"
    echo "OS问题定位工具检查"
    echo "========================================"
    echo ""
fi

MISSING_TOOLS=()
INSTALLED_TOOLS=()

check_command() {
    local cmd=$1
    local pkg=$2
    local desc=$3

    if timeout "$CHECK_TIMEOUT" command -v "$cmd" > /dev/null 2>&1; then
        if [ "$QUIET" -eq 0 ]; then
            echo -e "${GREEN}[✓]${NC} $cmd - $desc"
        fi
        INSTALLED_TOOLS+=("$cmd")
    else
        if [ "$QUIET" -eq 0 ]; then
            echo -e "${RED}[✗]${NC} $cmd - $desc (缺失)"
        else
            echo "$cmd"
        fi
        MISSING_TOOLS+=("$pkg")
    fi
}

check_file() {
    local pattern=$1
    local desc=$2

    # 先检查 ls 命令是否存在
    if ! command -v ls > /dev/null 2>&1; then
        if [ "$QUIET" -eq 0 ]; then
            echo -e "${RED}[✗]${NC} $desc (ls命令不可用)"
        else
            echo "$desc"
        fi
        MISSING_TOOLS+=("$desc")
        return
    fi

    if timeout "$CHECK_TIMEOUT" sh -c "ls $pattern 2>/dev/null | head -1 | grep -q ."; then
        if [ "$QUIET" -eq 0 ]; then
            echo -e "${GREEN}[✓]${NC} $desc: $(ls $pattern 2>/dev/null | head -1)"
        fi
        INSTALLED_TOOLS+=("$desc")
    else
        if [ "$QUIET" -eq 0 ]; then
            echo -e "${YELLOW}[?]${NC} $desc (未找到)"
        else
            echo "$desc"
        fi
        MISSING_TOOLS+=("$desc")
    fi
}

if [ "$QUIET" -eq 0 ]; then echo "--- 内核分析工具 ---"; fi
check_command "crash" "crash" "vmcore分析工具"
check_file "/usr/lib/debug/lib/modules/*/vmlinux*" "vmlinux调试符号"
check_command "dmesg" "util-linux" "内核日志工具"

if [ "$QUIET" -eq 0 ]; then echo ""; echo "--- 用户态分析工具 ---"; fi
check_command "gdb" "gdb" "GNU调试器"
check_command "strace" "strace" "系统调用跟踪"
check_command "ltrace" "ltrace" "库调用跟踪"

if [ "$QUIET" -eq 0 ]; then echo ""; echo "--- 性能分析工具 ---"; fi
check_command "perf" "perf" "Linux性能分析"
check_command "sar" "sysstat" "系统活动报告"
check_command "iostat" "sysstat" "IO统计"
check_command "mpstat" "sysstat" "多处理器统计"
check_command "vmstat" "procps-ng" "虚拟内存统计"
check_command "pidstat" "sysstat" "进程统计"

if [ "$QUIET" -eq 0 ]; then echo ""; echo "--- 网络分析工具 ---"; fi
check_command "ss" "iproute" "socket统计"
check_command "netstat" "net-tools" "网络统计"
check_command "tcpdump" "tcpdump" "网络包捕获"
check_command "iperf3" "iperf3" "网络带宽测试"

if [ "$QUIET" -eq 0 ]; then
    echo ""
    echo "========================================"
    echo "检查结果汇总"
    echo "========================================"
    echo -e "已安装: ${GREEN}${#INSTALLED_TOOLS[@]}${NC} 个工具"
    echo -e "缺失:   ${RED}${#MISSING_TOOLS[@]}${NC} 个工具"
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    if [ "$QUIET" -eq 0 ]; then
        echo ""
        echo "--- 安装建议 ---"
        echo "openEuler/CentOS/RHEL:"
        echo "  yum install -y ${MISSING_TOOLS[*]}"
        echo ""
        echo "Debian/Ubuntu:"
        echo "  apt-get install -y ${MISSING_TOOLS[*]}"
    fi
    if [ "$QUIET" -eq 0 ]; then echo ""; fi
    exit 1
fi

if [ "$QUIET" -eq 0 ]; then echo ""; fi
exit 0
