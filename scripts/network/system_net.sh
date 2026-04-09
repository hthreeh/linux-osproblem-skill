#!/bin/bash
# ==============================================================================
# system_net.sh - AI 智能结构化网络连通性与瓶颈诊断引擎 (Branch E)
# ==============================================================================
set -euo pipefail

OUTPUT_DIR="${1:-/tmp/net_sys_$(date +%Y%m%d_%H%M%S)_$$}"
DEST_IP="${2:-}"
mkdir -p "$OUTPUT_DIR"
exec > >(tee "$OUTPUT_DIR/system_net.log") 2>&1

section() { echo -e "\n============================================\n$1\n============================================"; }
cmd_info() { echo -e "\n[$1] -> $2"; }

echo "开始采集系统网络全景数据..."

section "[SUMMARY] 核心网络瓶颈与风险扫描"

echo "━━━ S1. NAT/防火墙连接池 (Conntrack) 饱和度 ━━━"
max_count=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '0')
if [ "$max_count" -gt 0 ] 2>/dev/null; then
    current_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    usage_pct=$((current_count * 100 / max_count))
    printf "  Conntrack 条目: %s / %s (使用率: %s%%)\n" "$current_count" "$max_count" "$usage_pct"
    if [ "$usage_pct" -ge 90 ]; then
        echo "  ⚠️ 危险: Conntrack 表接近满载，新连接可能被丢弃 (drop)"
    elif [ "$usage_pct" -ge 70 ]; then
        echo "  ⚡ 警告: Conntrack 使用率较高，需关注"
    fi
else
    echo "  [未启用 Conntrack 或无法读取]"
fi

echo "━━━ S2. ARP 缓存溢出限制 (gc_thresh) ━━━"
thresh3=$(cat /proc/sys/net/ipv4/neigh/default/gc_thresh3 2>/dev/null || echo 0)
if [ "$thresh3" -gt 0 ] 2>/dev/null; then
    total_entries=$(timeout 5 ip neigh show 2>/dev/null | wc -l || echo 0)
    usage_pct=$((total_entries * 100 / thresh3))
    printf "  ARP 条目: %s / %s (硬上限) (使用率: %s%%)\n" "$total_entries" "$thresh3" "$usage_pct"
    if [ "$usage_pct" -ge 90 ]; then
        echo "  ⚠️ 危险: ARP 表接近满载，将导致底层寻址失败脱网"
    fi
else
    echo "  [无法读取 ARP 上限]"
fi

echo "━━━ S3. 本地 MAC 碰撞检测 ━━━"
timeout 5 ip -o link 2>/dev/null | awk '
match($0,/link\/ether [0-9a-fA-F:]{17}/){
  mac=substr($0,RSTART+11,17); mac=tolower(mac)
  iface=$2; gsub(/:$/, "", iface)
  cnt[mac]++; list[mac]=list[mac]" "iface
}
END {
  dup=0; 
  for(m in cnt) {
    if(cnt[m]>1) { print "  ⚠️ 暴露: MAC地址冲突 " m " -> " list[m]; dup=1 }
  }
  if(dup==0) print "  ✅ 无本地 MAC 址冲突"
}' || true

echo "━━━ S4. 局域网 IP 冲突主动试探 ━━━"
if command -v arping >/dev/null 2>&1; then
    # 获取本地 IP 列表
    ip_list=$(timeout 5 ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 || true)
    conflict_found=0
    for ip in $ip_list; do
        if [ -n "$ip" ]; then
            iface=$(ip -o -4 addr show 2>/dev/null | grep " ${ip}/" | awk '{print $2}' | head -1 || true)
            if [ -n "$iface" ]; then
                # 进行 2 次主动探测，设置 2 秒总超时，外部再套 timeout 5 防止由于底层卡死导致挂起
                arping_output=$(timeout 5 arping -D -c 2 -w 2 -I "$iface" "$ip" 2>&1 || true)
                response_mac=$(echo "$arping_output" | grep -oE '\[[0-9a-fA-F:]{17}\]' | head -1 | tr -d '[]' | tr '[:upper:]' '[:lower:]' || true)
                if [ -n "$response_mac" ]; then
                    # 检查响应的 MAC 是不是就是自己
                    my_mac=$(ip link show "$iface" 2>/dev/null | awk '/link\/ether/ {print $2}' || true)
                    if [ "$my_mac" != "$response_mac" ]; then
                        echo "  ⚠️ 危险: IP [${ip}] 检测到局域网冲突响应! 冲突设备MAC: ${response_mac^^}"
                        conflict_found=1
                    fi
                fi
            fi
        fi
    done
    if [ "$conflict_found" -eq 0 ]; then
        echo "  ✅ 无主动 IP 冲突响应"
    fi
else
    echo "  [缺少 arping 工具，跳过主动 IP 冲突检测]"
fi

echo "━━━ S5. 路由与 MTU 探针 ━━━"
if [ -n "$DEST_IP" ]; then
    out_iface=$(timeout 5 ip route get "$DEST_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}' || echo "")
    if [ -n "$out_iface" ]; then
        iface_mtu=$(ip link show "$out_iface" 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++){if($i=="mtu"){print $(i+1); exit}}}' || true)
        echo "  通往 [$DEST_IP] 出接口: $out_iface (接口设定 MTU: ${iface_mtu:-N/A})"
        
        if [ -n "$iface_mtu" ] && [ "$iface_mtu" -eq "$iface_mtu" ] 2>/dev/null && [ "$iface_mtu" -gt 28 ]; then
            for test_mtu in 1500 1400 1300 800; do
                if [ "$test_mtu" -le "$iface_mtu" ]; then
                    payload=$((test_mtu - 28))
                    if timeout 3 ping -M do -s "$payload" -c 1 -W 1 "$DEST_IP" >/dev/null 2>&1; then
                        echo "  → MTU $test_mtu (Payload: $payload) : ✅ 无碎分片通过"
                        break # Find max valid and stop
                    else
                        echo "  → MTU $test_mtu (Payload: $payload) : ❌ 需分片或被拦截"
                    fi
                fi
            done
        fi
    else
        echo "  ⚠️ 警告: 无法获取通往 $DEST_IP 的路由出口接口，网络可能不达。"
    fi
else
    echo "  [提示: 未提供测试目标IP (DEST_IP)，跳过路径 MTU 与 Route 深度探测]"
fi


section "[DETAIL-1] 当前网络寻址基准"
cmd_info "ip -br addr" "端口IP聚合"
timeout 5 ip -br addr show 2>/dev/null || timeout 5 ip addr 2>/dev/null || echo "无法获取地址"
echo ""
cmd_info "ip route" "路由快照"
timeout 5 ip route show table main 2>/dev/null || netstat -rn 2>/dev/null || echo "无法获取路由"

section "[DETAIL-2] 网络套接字宏观统计"
if command -v ss &>/dev/null; then
    timeout 5 ss -s 2>/dev/null | head -15 || echo "ss 执行异常"
else
    timeout 5 netstat -s 2>/dev/null | grep -iE 'tcp|udp|drop|error' | head -15 || echo "无 netstat"
fi

section "[DETAIL-3] 内核网络异常挂起排查 (dmesg 抽检)"
cmd_info "dmesg" "检索 drop, martian, out of memory, syn_flood, time wait bucket"
timeout 10 dmesg -T 2>/dev/null | grep -iE "NF_CONNTRACK.*full|ip_conntrack.*full|drop|martian|Possible SYN flooding|out of socket memory|TCP: time wait bucket table overflow" | tail -30 || echo "无异常网络底座告警日志。"

section "采集完成"
echo "✅ 网络诊断已归档至: $OUTPUT_DIR"
