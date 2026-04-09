#!/bin/bash
# ============================================================
# 路径A：系统级 OOM 专项诊断脚本
#
# 用法:
#   bash system_oom.sh -S <开始时间> [-E <结束时间>]
#
# 示例:
#   bash system_oom.sh -S "2024-01-15 14:00:00" -E "2024-01-15 15:00:00"
#
# 输出结构：
#   [SUMMARY]  自动摘要（模型优先阅读）
#   [DETAIL]   原始详细数据（摘要存疑时补充查阅）
# ============================================================

START_TIME=""; END_TIME=""

while getopts ":S:E:h" opt; do
    case $opt in
        S) START_TIME="$OPTARG" ;; E) END_TIME="$OPTARG" ;;
        h) sed -n '3,10p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
        :) echo "错误: -$OPTARG 需要参数值"; exit 1 ;;
    esac
done

if [ -n "$START_TIME" ] && [ -z "$END_TIME" ]; then
    START_TS=$(date -d "$START_TIME" +%s 2>/dev/null)
    END_TIME=$(date -d "@$((START_TS+3600))" '+%Y-%m-%d %H:%M:%S')
fi

OUTPUT_DIR="/tmp/oom_sys_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"
exec > >(tee "$OUTPUT_DIR/system_oom.log") 2>&1

HAS_JOURNAL=$(which journalctl 2>/dev/null)
LOG_FILES=""
for f in /var/log/messages /var/log/kern.log /var/log/syslog; do [ -f "$f" ] && LOG_FILES="$LOG_FILES $f"; done

section() { echo ""; echo "###############################################"; echo "# $1"; echo "###############################################"; }
banner()  { echo ""; echo "╔══════════════════════════════════════════════╗"; printf "║  %-44s║\n" "$1"; echo "╚══════════════════════════════════════════════╝"; }
cmd_info() {
    echo ""
    echo "  ▶ 命令 : $1"
    echo "  ▶ 用途 : $2"
    echo "  ▶ 输出 : $3"
    echo ""
}

# ================================================================
# ████████  [SUMMARY] 自动摘要 — 模型优先阅读此节  ████████████████
# ================================================================
banner "[SUMMARY] 路径A 系统级OOM 自动摘要 — 模型优先阅读此节"
echo "分析时段: ${START_TIME:-全量} ~ ${END_TIME:-全量}"
echo ""

# ── S1: 结构化解析所有 OOM kill 事件 ─────────────────────────
echo "━━━ S1. OOM Kill 事件列表 ━━━"
cmd_info \
    "dmesg -T | grep -n 'Killed process|Out of memory: Kill'" \
    "定位 dmesg 中每次 OOM kill 事件的行号，然后提取该行关键字段（时间/进程/score/内存）" \
    "结构化表格：每行一次 OOM 事件，包含时间戳、被杀进程名+PID、OOM score、anon-rss、total-vm"
echo ""
DMESG_TMP="$OUTPUT_DIR/dmesg_tmp.txt"

# 优先使用 dmesg -T（带时间戳），失败时兜底到文件日志
if dmesg -T 2>/dev/null > "$DMESG_TMP" && [ -s "$DMESG_TMP" ]; then
    : # dmesg 成功
elif [ -n "$LOG_FILES" ]; then
    echo "  ⚠️  dmesg -T 失败（可能受 kernel.dmesg_restrict=1 限制），回退到文件日志" >&2
    cat $LOG_FILES 2>/dev/null > "$DMESG_TMP"
else
    echo "  ⚠️  dmesg -T 失败，且无可用日志文件（/var/log/messages/kern.log/syslog 均不存在）" >&2
    : > "$DMESG_TMP"
fi

OOM_COUNT=$(grep -c "Out of memory\|Killed process" "$DMESG_TMP" 2>/dev/null || echo 0)
echo "  时间段内 OOM kill 事件总数: $OOM_COUNT"
echo ""
grep -n "Killed process\|Kill process\|Out of memory: Kill" "$DMESG_TMP" \
    | head -20 \
    | while IFS=: read lineno rest; do
        ts=$(echo "$rest" | grep -oE '\[[A-Za-z]+ [A-Za-z]+ +[0-9]+ [0-9:]+ [0-9]+\]' | head -1)
        proc=$(echo "$rest" | grep -oE 'process [0-9]+ \([^)]+\)' | head -1)
        score=$(echo "$rest" | grep -oE 'score [0-9]+' | awk '{print $2}')
        mem_line=$(sed -n "$((lineno)),$((lineno+2))p" "$DMESG_TMP" 2>/dev/null)
        anon_rss=$(echo "$mem_line" | grep -oE 'anon-rss:[0-9]+kB' | grep -oE '[0-9]+')
        total_vm=$(echo "$mem_line" | grep -oE 'total-vm:[0-9]+kB' | grep -oE '[0-9]+')
        [ -n "$proc" ] && printf "  时间=%-26s %-35s score=%-5s anon-rss=%-8skB total-vm=%skB\n" \
            "$ts" "$proc" "${score:-?}" "${anon_rss:-?}" "${total_vm:-?}"
    done

# ── S2: 内存归因分类表 ────────────────────────────────────────
echo ""
echo "━━━ S2. 内存归因分类表 ━━━"
cmd_info \
    "awk 解析 /proc/meminfo，将内存分为用户态/内核态/未归因三大类" \
    "量化各类型内存占比；未归因=(total-free)-所有已知类型之和，>512MB 强烈暗示内核模块泄漏" \
    "每行一类内存：名称 / MB数值 / 占总内存比例 / 自动告警标记（⚠️/✅）"
awk '
/MemTotal/        {total=$2} /MemFree/         {free=$2}  /MemAvailable/    {avail=$2}
/^Buffers/        {buf=$2}   /^Cached/         {cache=$2} /^Slab:/          {slab=$2}
/SReclaimable/    {srec=$2}  /SUnreclaim/      {sunrec=$2}/^Shmem:/         {shmem=$2}
/AnonPages/       {anon=$2}  /PageTables/      {pt=$2}    /VmallocUsed/     {vmalloc=$2}
/KernelStack/     {kstack=$2}
END {
    used = total - free
    user_space   = anon + cache + buf + shmem
    kernel_space = slab + pt + kstack + vmalloc
    accounted    = user_space + kernel_space
    unaccounted  = used - accounted

    printf "  %-30s %8d MB  (%5.1f%%)\n","【用户态合计】:",user_space/1024,user_space*100/total
    printf "    %-28s %8d MB\n","AnonPages（进程堆/栈/匿名mmap）:",anon/1024
    printf "    %-28s %8d MB\n","PageCache（文件读写缓存）:",      cache/1024
    printf "    %-28s %8d MB\n","Shmem（tmpfs/共享内存）:",        shmem/1024
    printf "    %-28s %8d MB\n","Buffers（块设备缓冲）:",          buf/1024
    printf "\n"
    printf "  %-30s %8d MB  (%5.1f%%)\n","【内核态合计】:",kernel_space/1024,kernel_space*100/total
    printf "    %-28s %8d MB\n","Slab:",                           slab/1024
    printf "      %-26s %8d MB\n","  Reclaimable（可回收）:",      srec/1024
    printf "      %-26s %8d MB\n","  Unreclaimable（不可回收）:",  sunrec/1024
    printf "    %-28s %8d MB\n","PageTables:",                     pt/1024
    printf "    %-28s %8d MB\n","KernelStack:",                    kstack/1024
    printf "    %-28s %8d MB\n","VmallocUsed:",                    vmalloc/1024
    printf "\n"
    printf "  %-30s %8d MB  %s\n","【未归因内存】:",unaccounted/1024, \
        (unaccounted>512*1024)?"⚠️  >512MB，疑似内核模块泄漏":"✅ 正常"
    printf "  %-30s %8d MB\n","【空闲内存】:",free/1024
    printf "\n  === 主要消耗方向诊断 ===\n"
    if(anon>total*0.5)    printf "  ⚠️  AnonPages占比%.0f%%，用户态进程内存泄漏可能性高\n",anon*100/total
    if(slab>total*0.15)   printf "  ⚠️  Slab占比%.0f%%，内核Slab泄漏（dentry/inode/sock）可能性高\n",slab*100/total
    if(shmem>total*0.10)  printf "  ⚠️  Shmem占比%.0f%%，tmpfs/共享内存异常可能性高\n",shmem*100/total
    if(unaccounted>512*1024) printf "  ⚠️  未归因%dMB，内核模块内存泄漏可能性高\n",unaccounted/1024
}' /proc/meminfo

# ── S3: 内存压力与回收指标 ────────────────────────────────────
echo ""
echo "━━━ S3. 内存压力与回收指标 ━━━"
cmd_info \
    "awk 提取 /proc/vmstat 中 oom/allocstall/kswapd/pgsteal/swap 相关计数器" \
    "这些是内核内存子系统的累计事件计数，反映 OOM 前的回收行为强度" \
    "oom_kill=OOM触发总次数; allocstall_normal=直接回收次数(高=严重); kswapd_steal=后台回收页数; pswpin/pswpout=swap换入换出"
awk '
/^oom_kill/            {printf "  OOM kill 触发总次数:           %d\n",$2}
/^allocstall_normal/   {printf "  直接内存回收触发次数:          %d  (高值=进程被迫等待回收，严重压力)\n",$2}
/^kswapd_steal/        {printf "  kswapd 后台回收页数:           %d\n",$2}
/^pgsteal_kswapd/      {printf "  kswapd 页面回收总数:           %d\n",$2}
/^pgscan_kswapd/       {printf "  kswapd 页面扫描总数:           %d\n",$2}
/^pgmajfault/          {printf "  主缺页(swap换入):              %d  (高值=swap压力大)\n",$2}
/^pswpin/              {printf "  Swap 换入页数:                 %d\n",$2}
/^pswpout/             {printf "  Swap 换出页数:                 %d\n",$2}
/^compact_fail/        {printf "  内存规整失败次数:              %d  (高值=碎片化严重)\n",$2}
' /proc/vmstat

# ── S4: OOM 关键内核参数快照 ─────────────────────────────────
echo ""
echo "━━━ S4. OOM 关键内核参数 ━━━"
cmd_info \
    "sysctl -n vm.panic_on_oom / oom_kill_allocating_task / overcommit_memory 等" \
    "读取影响 OOM 行为的核心内核参数，判断系统 OOM 策略是否符合预期" \
    "每行：参数名 = 当前值 + 含义注释；panic_on_oom=1 时 OOM 不杀进程而是 panic"
for param in vm.panic_on_oom vm.oom_kill_allocating_task vm.oom_dump_tasks \
             vm.overcommit_memory vm.overcommit_ratio vm.min_free_kbytes vm.swappiness; do
    val=$(sysctl -n "$param" 2>/dev/null)
    case "$param" in
        vm.panic_on_oom)             hint="(0=OOM kill进程  1=kernel panic  2=always panic)" ;;
        vm.oom_kill_allocating_task) hint="(1=优先杀触发OOM的进程，而非内存最大的)" ;;
        vm.overcommit_memory)        hint="(0=启发式  1=总是允许  2=按比例限制)" ;;
        vm.min_free_kbytes)          hint="(最小空闲内存水位，低于此触发回收；MB=$(( ${val:-0}/1024 )))" ;;
        vm.swappiness)               hint="(0=尽量不用swap  60=默认  100=积极使用swap)" ;;
        *) hint="" ;;
    esac
    printf "  %-38s = %-6s %s\n" "$param" "${val:-未知}" "$hint"
done

# ── S5: 内存超额提交评估 ─────────────────────────────────────
echo ""
echo "━━━ S5. 内存超额提交评估 ━━━"
cmd_info \
    "awk 提取 /proc/meminfo 中 CommitLimit 和 Committed_AS" \
    "CommitLimit = 系统允许的最大虚拟内存承诺量；Committed_AS = 所有进程已申请（含未实际使用）的虚拟内存总量" \
    "Committed_AS > CommitLimit 表示已超额提交，此时新的内存申请可能直接失败触发 OOM"
awk '
/CommitLimit/   {limit=$2} /^Committed_AS/ {committed=$2}
/SwapTotal/     {swap=$2}  /MemTotal/      {total=$2}
END {
    printf "  CommitLimit（允许最大提交量）:  %8d MB\n",limit/1024
    printf "  Committed_AS（已承诺虚拟内存）: %8d MB\n",committed/1024
    printf "  超额率:                         %8.1f%%\n",committed*100/limit
    if(committed>limit)
        printf "  ⚠️  已超额提交！新内存申请可能直接返回 ENOMEM\n"
    else
        printf "  ✅ 未超额提交（余量 %d MB）\n",(limit-committed)/1024
}' /proc/meminfo

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[SUMMARY END] 以下为原始详细数据"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ================================================================
# [DETAIL] 原始详细数据
# ================================================================
section "[DETAIL-1] OOM Kill 事件完整上下文（含进程内存快照列表）"
cmd_info \
    "dmesg -T + 逆向查找锚点 ('Mem-Info' 或 'invoked oom-killer')" \
    "内核 OOM 输出顺序：[1]触发(invoked) → [2]Mem-Info(内存详细水位) → [3]Task List(各进程吃内存明细) → [4]Killed process(杀手判决)" \
    "从判决词([4])向前倒推抓取起手式([1]或[2])，绝不截断最有价值的内核内存统计现场。"

grep -n "Out of memory: Kill\|oom_kill_process\|Killed process" "$DMESG_TMP" 2>/dev/null \
    | head -10 \
    | while IFS=: read -r kill_lineno rest; do
        echo ""
        # 向前倒推最多 5000 行寻找事件的真正起手式
        start_search=$((kill_lineno > 5000 ? kill_lineno - 5000 : 1))
        
        # 在这个范围内寻找最早出现的 Mem-Info 或 invoked oom-killer
        anchor_offset=$(sed -n "${start_search},${kill_lineno}p" "$DMESG_TMP" | grep -n "invoked oom-killer:\|Mem-Info:" | head -1 | awk -F: '{print $1}')
        
        if [ -n "$anchor_offset" ]; then
            actual_start=$((start_search + anchor_offset - 1))
        else
            # 如果找不到起手式（可能由于环形缓冲区被大量日志吞没截断），打印被杀前最关键的 200 行
            actual_start=$((kill_lineno > 200 ? kill_lineno - 200 : 1))
        fi
        
        echo ">>> OOM 事件完整现场 (行 ${actual_start} ~ ${kill_lineno}) <<<"
        captured=$((kill_lineno - actual_start + 1))
        
        if [ "$captured" -gt 3500 ]; then
            # 进程列表和Mem-Info非常大，提取头尾，掐掉无关紧要的中间普通进程列表防止刷屏卡住AI
            echo "  [共 $captured 行 (可能运行了海量进程容器)，仅保留内存现场与可疑进程...]"
            sed -n "${actual_start},$((actual_start + 1000))p" "$DMESG_TMP"
            echo "  [... 中间省略 $((captured - 1500)) 行（无关普通进程） ...]"
            sed -n "$((kill_lineno - 499)),${kill_lineno}p" "$DMESG_TMP"
        else
            sed -n "${actual_start},${kill_lineno}p" "$DMESG_TMP"
        fi
    done

section "[DETAIL-2] 时间段内完整内核日志"
cmd_info \
    "journalctl --since/--until -k --no-pager" \
    "完整内核日志用于还原故障前后的事件时间线（包含 kswapd、内存分配、驱动等所有内核事件）" \
    "按时间顺序的内核消息流；OOM kill 前通常可见 kswapd 高负荷、page allocation failure 等前兆"
[ -n "$HAS_JOURNAL" ] && [ -n "$START_TIME" ] && \
    journalctl --since="$START_TIME" --until="$END_TIME" -k --no-pager 2>/dev/null | head -2000

section "[DETAIL-3] 进程内存排名 + OOM score（当前快照）"
cmd_info \
    "ps aux --sort=-%mem + 遍历 /proc/PID/oom_score" \
    "获取当前系统中内存占用最多的进程，以及各进程被 OOM killer 选中的概率" \
    "Top 20 进程 RSS 排名；OOM score 排名（score 最高的进程会被优先杀死）"
ps aux --sort=-%mem | head -21
echo ""
printf "%-8s %-10s %-8s %s\n" "PID" "OOM_SCORE" "OOM_ADJ" "COMM"
for pid in $(ls /proc | grep '^[0-9]*$'); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null)
    [ -z "$score" ] || [ "$score" -eq 0 ] 2>/dev/null && continue
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    printf "%-8s %-10s %-8s %s\n" "$pid" "$score" "$adj" "$comm"
done 2>/dev/null | sort -k2 -rn | head -20

section "[DETAIL-4] 历史监控：atop/sar 内存趋势"
cmd_info \
    "atop -r <历史文件> -PMEM 或 sar -r -f <sa文件>" \
    "从历史监控数据中回放故障时间段内系统内存的逐分钟变化趋势" \
    "可观察内存从正常到 OOM 的完整增长过程；是确认内存泄漏单调增长特征的关键证据"
if [ -n "$START_TIME" ]; then
    DATE_STR=$(date -d "$START_TIME" +%Y%m%d 2>/dev/null)
    ATOP_FILE="/var/log/atop/atop_$DATE_STR"
    [ -f "$ATOP_FILE" ] && \
        atop -r "$ATOP_FILE" \
            -b "$(date -d "$START_TIME" '+%H:%M' 2>/dev/null)" \
            -e "$(date -d "$END_TIME"   '+%H:%M' 2>/dev/null)" \
            -PMEM 2>/dev/null | head -150 || echo "atop 历史文件 $ATOP_FILE 不存在"
    SAR_FILE="/var/log/sa/sa$(date -d "$START_TIME" +%d 2>/dev/null)"
    sar -r -f "$SAR_FILE" \
        -s "$(date -d "$START_TIME" '+%H:%M:%S' 2>/dev/null)" \
        -e "$(date -d "$END_TIME"   '+%H:%M:%S' 2>/dev/null)" 2>/dev/null \
        | head -60 || echo "sar 历史不可用"
fi

section "收集完成"
tar czf "${OUTPUT_DIR}.tar.gz" -C /tmp "$(basename $OUTPUT_DIR)/" 2>/dev/null
echo "📦 打包文件: ${OUTPUT_DIR}.tar.gz"
