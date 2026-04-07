# 网络故障诊断指南

本文档详细介绍Linux网络故障的诊断方法与排查流程，重点面向openEuler/CentOS/RHEL系统。

---

## 1. 网络故障概述

### 常见网络问题分类

| 类别 | 典型表现 | 影响范围 |
|------|----------|----------|
| 网络不通 | ping不通、连接拒绝、连接超时 | 业务完全中断 |
| 丢包 | 间歇性连接失败、传输慢 | 业务不稳定 |
| TCP连接异常 | 连接超时、连接重置、半连接堆积 | 特定服务受影响 |
| 网络延迟 | 响应慢、吞吐量低 | 业务性能下降 |
| 网卡/驱动问题 | 网卡不可用、错误计数增长 | 主机级故障 |
| 虚拟网络问题 | 容器/虚机网络不通 | 虚拟化环境故障 |
| 防火墙规则阻断 | 特定端口/IP不可达 | 特定流量受影响 |

### 诊断方法论（OSI分层法）

自下而上逐层排查，快速定位故障层级：

```
物理层 → 链路层 → 网络层 → 传输层 → 应用层
 网线     ARP      IP/路由    TCP/UDP    HTTP等
 光模块   VLAN     ICMP       端口       DNS
 网卡状态  MAC      防火墙     连接状态    应用配置
```

**原则**：先排除底层问题，再排查高层问题。底层故障会导致高层全部异常。

---

## 2. 网络故障分类

### 2.1 网络不通/连接失败

#### Ping不通的排查流程

| 层级 | 检查项 | 命令 | 正常结果 |
|------|--------|------|----------|
| 链路层 | 网卡状态 | `ip link show eth0` | state UP |
| 链路层 | 物理连接 | `ethtool eth0` | Link detected: yes |
| 链路层 | ARP解析 | `ip neigh show` | 目标IP有MAC映射 |
| 网络层 | IP地址 | `ip addr show eth0` | IP/掩码正确 |
| 网络层 | 路由表 | `ip route get <目标IP>` | 路由存在 |
| 传输层 | 端口监听 | `ss -tlnp \| grep <端口>` | LISTEN状态 |
| 传输层 | 防火墙 | `iptables -L -n -v` | 无阻断规则 |

```bash
# 链路层快速检查
ip link set eth0 up
ethtool eth0 | grep "Link detected"
arping -I eth0 <目标IP>

# 网络层检查
ip route get <目标IP>
ip rule show                          # 策略路由
traceroute -n <目标IP>

# 传输层检查
ss -tlnp | grep <端口>
nc -zv <目标IP> <端口>
```

#### 路由问题

| 问题 | 症状 | 诊断命令 |
|------|------|----------|
| 默认路由丢失 | 无法访问外网 | `ip route show default` |
| 路由黑洞 | 特定网段不通 | `ip route get <IP>` |
| 策略路由冲突 | 部分流量异常 | `ip rule show` |
| 非对称路由 | 去程通回程不通 | 两端`traceroute` |

#### DNS解析问题

```bash
cat /etc/resolv.conf
nslookup <域名>
dig <域名> +trace
dig @<DNS服务器> <域名>
grep hosts /etc/nsswitch.conf
```

---

### 2.2 丢包问题

#### 网卡级丢包

| 丢包类型 | 检查命令 | 关键指标 |
|----------|----------|----------|
| RX/TX丢包 | `ifconfig eth0` | dropped计数 |
| Ring Buffer溢出 | `ethtool -S eth0` | rx_missed_errors |
| CRC错误 | `ethtool -S eth0` | rx_crc_errors |

```bash
ethtool -S eth0 | grep -i "drop\|error\|miss\|crc"
ethtool -g eth0                       # 查看Ring Buffer大小
ethtool -G eth0 rx 4096 tx 4096       # 增大Ring Buffer
```

#### 内核网络栈丢包

| 丢包位置 | 检查方法 | 关键指标 |
|----------|----------|----------|
| IP层 | `/proc/net/snmp` | InDiscards, InHdrErrors |
| TCP层 | `/proc/net/snmp` | TCPAbortOnMemory |
| UDP层 | `/proc/net/snmp` | RcvbufErrors |
| 软中断 | `/proc/net/softnet_stat` | 第二列（time_squeeze） |
| conntrack | `conntrack -S` | drop计数 |

```bash
nstat -az | grep -i "drop\|error\|overflow"
cat /proc/net/softnet_stat            # 软中断丢包
dropwatch -l kas                      # 实时追踪内核丢包点
```

#### 应用级丢包

```bash
cat /proc/net/snmp | grep Udp         # 关注RcvbufErrors
sysctl net.core.rmem_max net.core.wmem_max
sysctl -w net.core.rmem_max=16777216  # 增大缓冲区
```

#### 丢包诊断决策

```
ifconfig/ethtool -S 有错误增长？ → 网卡级丢包
/proc/net/snmp 有丢包增长？     → 内核栈丢包
ss -s 显示溢出？                → 应用级丢包
tcpdump两端对比？               → 中间设备丢包
```

---

### 2.3 TCP连接异常

#### 连接超时（SYN_SENT堆积）

```bash
ss -tn state syn-sent                              # 查看堆积的SYN
tcpdump -i eth0 "tcp[tcpflags] & tcp-syn != 0" -nn # 确认SYN已发出
sysctl net.ipv4.tcp_syn_retries                     # 默认6次≈127秒超时
```

#### 连接重置（RST分析）

| RST场景 | 特征 | 排查方向 |
|----------|------|----------|
| 端口未监听 | 收到SYN后立即RST | 检查服务是否运行 |
| 防火墙REJECT | 有规律的RST | 检查iptables REJECT规则 |
| 应用close | FIN之后RST | 检查应用日志 |
| 资源限制 | accept队列满后RST | 检查somaxconn |

```bash
tcpdump -i eth0 "tcp[tcpflags] & tcp-rst != 0" -nn -c 100
nstat -az | grep -i rst
```

#### 半连接与全连接队列

```bash
sysctl net.ipv4.tcp_max_syn_backlog     # SYN队列（半连接）
nstat -az TcpExtListenOverflows TcpExtListenDrops
sysctl net.ipv4.tcp_syncookies          # SYN Cookie防御（1=启用）
ss -tlnp                               # Recv-Q=积压, Send-Q=上限
```

#### TIME_WAIT过多

```bash
ss -tan state time-wait | wc -l
ss -tan state time-wait | awk '{print $4}' | sort | uniq -c | sort -rn | head
sysctl -w net.ipv4.tcp_tw_reuse=1           # 允许复用
sysctl -w net.ipv4.tcp_max_tw_buckets=50000 # 最大数量
```

---

### 2.4 网络延迟

#### 延迟测量

| 工具 | 用途 | 命令示例 |
|------|------|----------|
| ping | 基本延迟 | `ping -c 100 -i 0.1 <IP>` |
| mtr | 逐跳分析 | `mtr -rn -c 100 <IP>` |
| hping3 | TCP延迟 | `hping3 -S -p 80 <IP>` |
| tcpdump | 精确分析 | 抓包后Wireshark分析 |

#### 延迟定位

| 延迟位置 | 判断方法 | 常见原因 |
|----------|----------|----------|
| 网络延迟 | ping/mtr逐跳 | 链路质量、路由绕行、拥塞 |
| 内核延迟 | 软中断/调度延迟 | CPU饱和、中断不均衡 |
| 应用延迟 | strace/perf | 锁竞争、IO等待 |

#### TCP重传分析

```bash
nstat -az TcpRetransSegs TcpExtTCPSlowStartRetrans TcpExtTCPFastRetrans
ss -ti dst <目标IP>                   # 关注retrans:和rto:字段
watch -d "nstat -az | grep -i retrans"
```

---

### 2.5 网卡/驱动问题

#### 网卡错误诊断

| 错误类型 | ethtool指标 | 可能原因 |
|----------|-------------|----------|
| CRC错误 | rx_crc_errors | 线缆/电磁干扰 |
| 帧错误 | rx_frame_errors | 双工不匹配 |
| FIFO溢出 | rx_fifo_errors | Ring Buffer太小 |
| 载波错误 | tx_carrier_errors | 物理链路问题 |

```bash
ethtool eth0                          # Speed, Duplex, Link
ethtool -i eth0                       # 驱动信息
ethtool -t eth0 online                # 网卡自检
ethtool -k eth0                       # 特性列表
```

#### 中断问题

```bash
grep eth0 /proc/interrupts            # 中断分布
cat /proc/net/softnet_stat            # 第2列=time_squeeze
cat /sys/class/net/eth0/queues/rx-*/rps_cpus  # RPS配置
echo <cpu_mask> > /proc/irq/<irq>/smp_affinity # 设置亲和性
```

#### 驱动问题

```bash
ethtool -i eth0                       # driver, version
dmesg | grep -i -E "eth0|<驱动名>"
modprobe -r <驱动> && modprobe <驱动>  # 重加载
dmesg | grep -i firmware              # 固件问题
```

---

### 2.6 虚拟网络问题

#### Linux Bridge

```bash
brctl show                            # Bridge信息
bridge fdb show br br0                # FDB表
brctl showstp br0                     # STP状态
sysctl net.bridge.bridge-nf-call-iptables  # 1则流量经过iptables
```

#### veth pair

```bash
ethtool -S <veth名称>                  # peer_ifindex→对端index
ip link show | grep "^<index>:"       # 根据index找对端
ip netns exec <ns> ip link show       # 命名空间中查找
```

#### VXLAN/GRE隧道

```bash
ip -d link show type vxlan
bridge fdb show dev vxlan0
ip tunnel show
# MTU注意：VXLAN开销50B，GRE开销24-28B
tcpdump -i eth0 "udp port 4789" -nn   # 抓VXLAN
tcpdump -i eth0 "proto gre" -nn       # 抓GRE
```

#### OVS / 容器网络

```bash
# OVS
ovs-vsctl show
ovs-ofctl dump-flows br-int
ovs-appctl ofproto/trace br-int <匹配>

# 容器网络
nsenter -t <PID> -n ip addr show
nsenter -t <PID> -n ip route show
iptables -t nat -L -n -v              # NAT规则
```

---

### 2.7 防火墙规则分析

#### iptables

```bash
iptables -L -n -v --line-numbers
iptables -t nat -L -n -v --line-numbers
iptables-save > iptables_backup.txt

# TRACE调试
iptables -t raw -A PREROUTING -s <源IP> -j TRACE
dmesg | grep TRACE
```

**规则匹配流程**：
```
入站: PREROUTING(raw→mangle→nat) → 路由 → INPUT(mangle→filter)
转发: PREROUTING → 路由 → FORWARD(mangle→filter) → POSTROUTING(mangle→nat)
出站: OUTPUT(raw→mangle→nat→filter) → 路由 → POSTROUTING(mangle→nat)
```

#### nftables / firewalld

```bash
nft list ruleset                      # 所有规则
nft list ruleset -a                   # 含handle编号

firewall-cmd --state
firewall-cmd --list-all
firewall-cmd --add-port=<端口>/tcp    # 临时开放
```

#### conntrack表满

| 指标 | 命令 | 说明 |
|------|------|------|
| 当前连接数 | `conntrack -C` | 已跟踪连接 |
| 最大值 | `sysctl net.netfilter.nf_conntrack_max` | 表容量上限 |
| 丢弃统计 | `conntrack -S` | 关注drop计数 |

```bash
sysctl -w net.netfilter.nf_conntrack_max=1048576
echo 262144 > /sys/module/nf_conntrack/parameters/hashsize
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
```

---

## 3. 诊断工具详解

| 工具 | 用途 | 常用命令 |
|------|------|----------|
| ip | 网络配置 | `ip addr`, `ip route`, `ip link`, `ip neigh` |
| ss | Socket统计 | `ss -tlnp`, `ss -tanp`, `ss -ti`, `ss -s` |
| tcpdump | 抓包分析 | `tcpdump -i eth0 -nn -w capture.pcap` |
| ethtool | 网卡诊断 | `ethtool eth0`, `ethtool -S eth0`, `ethtool -i eth0` |
| iperf3 | 带宽测试 | `iperf3 -s` / `iperf3 -c <IP>` |
| mtr | 路径延迟 | `mtr -rn -c 100 <IP>` |
| nstat | 协议统计 | `nstat -az` |
| conntrack | 连接跟踪 | `conntrack -L`, `conntrack -C`, `conntrack -S` |
| dropwatch | 丢包追踪 | `dropwatch -l kas` |

### tcpdump常用过滤器

```bash
tcpdump -i eth0 host 10.0.0.1 -nn                         # 按主机
tcpdump -i eth0 port 80 -nn                                # 按端口
tcpdump -i eth0 "tcp[tcpflags] & tcp-syn != 0" -nn        # SYN包
tcpdump -i eth0 "tcp[tcpflags] & tcp-rst != 0" -nn        # RST包
tcpdump -i eth0 "greater 1400" -nn                         # 大包
tcpdump -i eth0 -w capture.pcap -c 10000                   # 保存
```

### ss命令详解

```bash
ss -tanp                              # 所有TCP连接
ss -tn state established              # 按状态过滤
ss -tn dst 10.0.0.1                   # 按目标过滤
ss -ti                                # TCP内部信息（RTT/窗口/拥塞）
ss -s                                 # 统计摘要
```

---

## 4. 诊断流程（分层法）

| 层级 | 检查项 | 命令 | 异常表现 |
|------|--------|------|----------|
| 物理层 | 链路状态 | `ethtool eth0` | Link detected: no |
| 物理层 | 速率双工 | `ethtool eth0` | Speed/Duplex不匹配 |
| 物理层 | 网卡识别 | `lspci \| grep -i net` | 网卡未识别 |
| 链路层 | 接口状态 | `ip link show` | state DOWN |
| 链路层 | ARP表 | `ip neigh show` | FAILED/INCOMPLETE |
| 链路层 | VLAN | `ip -d link show` | VLAN未配置/ID错误 |
| 网络层 | IP地址 | `ip addr show` | 无IP/IP冲突 |
| 网络层 | 路由 | `ip route show` | 缺少路由 |
| 网络层 | ICMP | `ping <目标>` | 超时/不可达 |
| 网络层 | 防火墙 | `iptables -L -n` | DROP/REJECT规则 |
| 传输层 | 端口监听 | `ss -tlnp` | 端口未监听 |
| 传输层 | 连接状态 | `ss -tanp` | 异常状态堆积 |
| 传输层 | 重传 | `nstat -az` | 重传计数增长 |
| 应用层 | 服务状态 | `systemctl status <服务>` | 未运行 |
| 应用层 | DNS | `dig <域名>` | 解析失败 |
| 应用层 | HTTP | `curl -v <URL>` | 非2xx响应 |

---

## 5. 常见案例

### 案例1: iptables DROP规则导致服务不可达

**现象**：外部无法访问80端口，本地curl正常。

```bash
ss -tlnp | grep :80                   # 服务在监听
curl http://127.0.0.1:80              # 本地正常
iptables -L INPUT -n -v --line-numbers
# 发现默认DROP规则阻断所有入站流量
iptables -I INPUT 2 -p tcp --dport 80 -j ACCEPT  # 修复
```

**根因**：默认DROP规则阻断所有入站流量，应在DROP前添加特定端口ACCEPT。

### 案例2: conntrack表满导致新连接失败

**现象**：间歇性无法建立新连接，已有连接不受影响。

```bash
dmesg | grep conntrack                # "table full, dropping packet"
conntrack -C                          # 65535（已满）
sysctl net.netfilter.nf_conntrack_max # 65536
# 修复
sysctl -w net.netfilter.nf_conntrack_max=262144
echo 65536 > /sys/module/nf_conntrack/parameters/hashsize
```

**根因**：高并发场景下conntrack默认值（65536）不足。

### 案例3: MTU不匹配导致大包丢失

**现象**：ping小包正常，大包或传文件时超时。

```bash
ping -c 5 -s 1472 -M do <目标IP>
# "Frag needed and DF set (mtu = 1400)"
tracepath <目标IP>                    # 显示路径MTU
ip link set eth0 mtu 1400            # 修复
sysctl net.ipv4.ip_no_pmtu_disc      # 确保=0（启用PMTUD）
```

**根因**：中间链路（VPN/隧道）MTU<1500，大包丢弃且ICMP报文被防火墙过滤。

### 案例4: ARP表溢出导致网络不通

**现象**：大二层网络中部分主机间歇性不通。

```bash
dmesg | grep "neighbour table overflow"
ip neigh show | wc -l                 # 条目过多
sysctl net.ipv4.neigh.default.gc_thresh3  # 默认1024
# 修复
sysctl -w net.ipv4.neigh.default.gc_thresh1=4096
sysctl -w net.ipv4.neigh.default.gc_thresh2=8192
sysctl -w net.ipv4.neigh.default.gc_thresh3=16384
```

**根因**：ARP条目超过gc_thresh3限制，新ARP请求被丢弃。

---

## 6. 预防与监控

### 关键监控指标

| 分类 | 监控指标 | 采集方式 | 告警阈值 |
|------|----------|----------|----------|
| 连通性 | 丢包率 | `ping` | > 1% |
| 连通性 | 延迟 | `ping` | 超过基线2倍 |
| 网卡 | 错误包数 | `ethtool -S` | 任何增长 |
| 网卡 | 丢包数 | `ip -s link` | 任何增长 |
| TCP | 重传率 | `/proc/net/snmp` | > 1% |
| TCP | TIME_WAIT数 | `ss -s` | > 20000 |
| conntrack | 表使用率 | `conntrack -C` | > 80% |
| DNS | 解析延迟 | `dig` | > 100ms |
| 带宽 | 利用率 | `sar -n DEV` | > 80% |

### 网络基线采集

| 基线项 | 采集命令 | 频率 |
|--------|----------|------|
| 延迟基线 | `ping -c 100 <关键节点>` | 每日 |
| 带宽基线 | `iperf3 -c <对端> -t 30` | 每周 |
| 连接数 | `ss -s` | 每小时 |
| 路由快照 | `ip route show` | 每日 |
| ARP表大小 | `ip neigh show \| wc -l` | 每小时 |
| conntrack | `conntrack -C` | 每分钟 |
| 网卡错误 | `ethtool -S <iface>` | 每5分钟 |
| 防火墙快照 | `iptables-save` | 每日 |
