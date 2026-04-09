#!/bin/bash
# ============================================================
# 性能核心诊断分析器 (OS-Troubleshooter - Branch C)
#
# 整合了 CPU 调度瓶颈、内存限制检查、IPC以及软硬中断分析。
# 设计面向 AI 快速吞吐，分离 SUMMARY 和 DETAIL。
#
# 用法:
#   system_perf.sh [输出目录]
# ============================================================

set -euo pipefail

OUTPUT_DIR="${1:-/tmp/perf_sys_$(date +%Y%m%d_%H%M%S)_$$}"
mkdir -p "$OUTPUT_DIR"
exec > >(tee "$OUTPUT_DIR/system_perf.log") 2>&1

section() { echo ""; echo "###############################################"; echo "# $1"; echo "###############################################"; }
banner()  { echo ""; echo "╔══════════════════════════════════════════════════════════════╗"; printf "║  %-58s║\n" "$1"; echo "╚══════════════════════════════════════════════════════════════╝"; }
cmd_info() { echo -e "\n  ▶ 执行: $1\n  ▶ $2\n"; }

banner "[SUMMARY] 路径C：系统性能与调度分析 — 模型优先阅读此节"
echo "采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "采集节点: $(hostname)"
echo ""

# ── S1: 负载大盘与过载预报 ────────────────────────────────
echo "━━━ S1. 负载大盘评估 ━━━"
cmd_info "/proc/loadavg 与 mpstat" "计算排队负载比例，直击过载心脏"

CORES=$(nproc 2>/dev/null || echo 1)
awk -v cores="$CORES" '{
    ratio1=$1/cores; ratio5=$2/cores; ratio15=$3/cores
    printf "  逻辑多核: %d\n", cores
    printf "  负载快照: %-5s (1m) | %-5s (5m) | %-5s (15m)\n", $1, $2, $3
    printf "  负载比例: %-5.2f (1m) | %-5.2f (5m) | %-5.2f (15m)\n", ratio1, ratio5, ratio15
    printf "\n  # 自动诊断结论:\n"
    printf "  1 分钟水位: %s\n", (ratio1>4)?"⚠️  严重过载 (超核4倍)":(ratio1>2)?"⚠️  存在过载排队":"✅ 健康"
    printf "  15分钟水位: %s\n", (ratio15>4)?"⚠️  属于持续性严重瓶颈":(ratio15>2)?"⚠️  属于持续性压力":"✅ 中长期健康"
}' /proc/loadavg

echo ""
echo "  # 当下综合 CPU 极速采样 (取1秒):"
if command -v top &>/dev/null; then
    timeout 5 top -bn2 2>/dev/null | grep '^%Cpu' | tail -1 | awk -F',' '{
        us="0.0"; sy="0.0"; wa="0.0"; si="0.0"; id="0.0";
        for(i=1;i<=NF;i++) {
            if($i~/ us/) { gsub(/[^0-9.]/,"",$i); us=$i }
            else if($i~/ sy/) { gsub(/[^0-9.]/,"",$i); sy=$i }
            else if($i~/ wa/) { gsub(/[^0-9.]/,"",$i); wa=$i }
            else if($i~/ si/) { gsub(/[^0-9.]/,"",$i); si=$i }
            else if($i~/ id/) { gsub(/[^0-9.]/,"",$i); id=$i }
        }
        printf "  用户态(usr) %4s | 内核态(sys) %4s | IO等待(wa) %4s | 软硬中断(si) %4s | 空闲(id) %4s\n", us, sy, wa, si, id
    }' || echo "  [获取 CPU 快照失败]"
else
    echo "  [缺少 top 工具]"
fi

# ── S2: 调度堵点挖掘 ────────────────────────────────
echo ""
echo "━━━ S2. 进程状态与调度堵点 ━━━"
cmd_info "ps 状态树扫描" "过滤出被内核锁死(D)与僵尸(Z)的过程"

D_COUNT=$(ps -eo stat | awk 'NR>1 && /^D/ {count++} END {print count+0}')
Z_COUNT=$(ps -eo stat | awk 'NR>1 && /^Z/ {count++} END {print count+0}')
R_COUNT=$(ps -eo stat | awk 'NR>1 && /^R/ {count++} END {print count+0}')

printf "  不可中断睡眠 (D) 进程数: %-5d %s\n" "$D_COUNT" "$([ "$D_COUNT" -gt 5 ] && echo '⚠️  危险 (可能由于IO死锁打满)' || echo '')"
printf "  僵尸 (Z) 进程数         : %-5d %s\n" "$Z_COUNT" "$([ "$Z_COUNT" -gt 50 ] && echo '⚠️  偏多 (检查父进程回收bug)' || echo '')"
printf "  活动排队 (R) 进程数     : %-5d %s\n" "$R_COUNT" "$([ "$R_COUNT" -gt "$((CORES * 2))" ] && echo '⚠️  严重排队竞争' || echo '')"

if [ "$D_COUNT" -gt 0 ]; then
    echo "  [D 状态进程悬赏名单]:"
    ps -eo pid,stat,wchan:32,comm | awk 'NR==1 || $2~/^D/' | head -15 | sed 's/^/    /'
fi

# ── S3: 系统级限流墙与爆破点 ────────────────────────────────
echo ""
echo "━━━ S3. 资源限流阻滞 (Limits & Watchers) ━━━"
cmd_info "ulimit / inotify" "探查常见隐匿型报错如 fork failed 或 no space left"

MAX_PROC=$(ulimit -u)
STK_SIZE=$(ulimit -s)
NOW_PROC=$(ps -u "$(whoami)" -o pid | wc -l)
echo "  [系统 Limits] (身份: $(whoami))"
printf "    最大进程约束(ulimit -u): %-10s (当前使用: %d)\n" "$MAX_PROC" "$NOW_PROC"
printf "    堆栈约束    (ulimit -s): %-10s KB\n" "$STK_SIZE"

if [ "$MAX_PROC" != "unlimited" ] && [ "$MAX_PROC" -gt 0 ] 2>/dev/null; then
    USAGE_PCT=$(( NOW_PROC * 100 / MAX_PROC ))
    [ "$USAGE_PCT" -gt 85 ] && echo "    ⚠️  危险: 当前进程已占据配额的 $USAGE_PCT% ，易引发 fork() / clone() 报错！"
fi

INOTIFY_MAX=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
if [ -n "$INOTIFY_MAX" ] && [ "$INOTIFY_MAX" -eq "$INOTIFY_MAX" ] 2>/dev/null && [ "$INOTIFY_MAX" -gt 0 ]; then
    set +o pipefail
    INOTIFY_NOW=$(timeout 15 find /proc/*/fdinfo/ -type f 2>/dev/null | xargs grep -s 'inotify' 2>/dev/null | wc -l)
    set -o pipefail
    
    # 再次清洗以防出现脏数字
    INOTIFY_NOW=$(echo "$INOTIFY_NOW" | grep -oE '^[0-9]+$' | tail -1 || echo 0)
    
    echo "  [目录监控手表 Inotify]"
    printf "    最大 Watches: %-10s (当前使用: %s)\n" "$INOTIFY_MAX" "$INOTIFY_NOW"
    if [ "$INOTIFY_NOW" -gt 0 ]; then
        I_USAGE_PCT=$(( INOTIFY_NOW * 100 / INOTIFY_MAX ))
        [ "$I_USAGE_PCT" -gt 85 ] && echo "    ⚠️  危险: inotify 注册槽位即将耗尽，会引发 IDE崩溃 / tail -f / 文件同步 随机失败！"
    fi
fi

# ── S4: IPC 资源预警 ────────────────────────────────
echo ""
echo "━━━ S4. IPC 进程间通信核查 ━━━"
if command -v ipcs &>/dev/null; then
    MSG_MAX=$(cat /proc/sys/kernel/msgmni 2>/dev/null || echo 0)
    MSG_NOW=$(( $(timeout 5 ipcs -q 2>/dev/null | wc -l || echo 3) - 3 ))
    [ "$MSG_NOW" -lt 0 ] && MSG_NOW=0
    
    SHM_MAX=$(cat /proc/sys/kernel/shmmni 2>/dev/null || echo 0)
    SHM_NOW=$(( $(timeout 5 ipcs -m 2>/dev/null | wc -l || echo 3) - 3 ))
    [ "$SHM_NOW" -lt 0 ] && SHM_NOW=0
    
    printf "  消息队列列数 : %d / %d (配额)\n" "$MSG_NOW" "$MSG_MAX"
    printf "  共享内存段数 : %d / %d (配额)\n" "$SHM_NOW" "$SHM_MAX"
    
    if [ "$MSG_MAX" -gt 0 ]; then
        [ $((MSG_NOW * 100 / MSG_MAX)) -gt 85 ] && echo "  ⚠️  危险: 消息队列即将爆满！"
    fi
else
    echo "  [缺少 ipcs 工具]"
fi

# ── S5: 中断风暴检测 ────────────────────────────────
echo ""
echo "━━━ S5. 软硬中断异动速查 ━━━"
cmd_info "/proc/softirqs" "排除高发型的 NET_RX 与 RCU 风暴"
NET_RX=$(awk '/NET_RX:/{total=0; for(i=2;i<=NF;i++) total+=$i; print total}' /proc/softirqs 2>/dev/null || echo "")
TIMER=$(awk '/TIMER:/{total=0; for(i=2;i<=NF;i++) total+=$i; print total}' /proc/softirqs 2>/dev/null || echo "")
RCU=$(awk '/RCU:/{total=0; for(i=2;i<=NF;i++) total+=$i; print total}' /proc/softirqs 2>/dev/null || echo "")

echo "  累计历史触发 (用于观察系统热点偏向):"
printf "    NET_RX (网卡抓包): %s\n" "$NET_RX"
printf "    TIMER  (定时器)  : %s\n" "$TIMER"
printf "    RCU    (读写锁)  : %s\n" "$RCU"


echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[SUMMARY END] 以下为原始快照数据提取 (Top 消耗大户)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ================================================================
# [DETAIL] 原始快照数据
# ================================================================
section "[DETAIL-1] 现场 CPU 与内存掠夺大户 (TOP 20)"
ps -eo pid,user,stat,%cpu,%mem,nlwp,comm --sort=-%cpu | head -21

section "[DETAIL-2] 内核锁死与死等日志 (dmesg 抽检)"
cmd_info "dmesg" "检索 blocked / soft lockup / hung task"
timeout 10 dmesg -T 2>/dev/null | grep -iE "blocked for|hung_task|soft lockup|rcu.*stall|I/O error" | tail -30 || echo "无异常挂起日志。"

section "[DETAIL-3] VMSTAT 内存/IO联排快照"
if command -v vmstat &>/dev/null; then
    timeout 15 vmstat -w 1 5 2>/dev/null || timeout 15 vmstat 1 5 2>/dev/null || echo "vmstat 挂起或执行失败"
else
    echo "无 vmstat 命令"
fi

section "[DETAIL-4] 内核高危限制 (Modules/Crash Dump)"
echo "Core Pattern      : $(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo '<不可读>')"
echo "Softlockup Panic  : $(cat /proc/sys/kernel/softlockup_panic 2>/dev/null || echo '<不可读>')"
echo "Modules Disabled  : $(cat /proc/sys/kernel/modules_disabled 2>/dev/null || echo '<不可读>')"

section "采集完成"
echo "✅ 信息已归档至输出目录: $OUTPUT_DIR"
