# 常用命令速查

本文档提供OS问题定位的常用命令速查表。

---

## 1. 系统信息

| 用途 | 命令 | 说明 |
|------|------|------|
| 内核版本 | `uname -r` | 查看内核版本 |
| 系统信息 | `uname -a` | 查看完整系统信息 |
| 发行版信息 | `cat /etc/os-release` | 查看发行版版本 |
| 运行时间 | `uptime` | 系统运行时间和负载 |
| 主机名 | `hostname` | 查看主机名 |
| CPU信息 | `lscpu` | CPU架构信息 |
| 内存信息 | `free -h` | 内存使用概况 |

---

## 2. 内核崩溃分析（vmcore）

### crash工具常用命令

| 命令 | 用途 | 示例 |
|------|------|------|
| `sys` | 系统基本信息 | `sys` |
| `bt` | 崩溃调用栈 | `bt`, `bt -a`, `bt <pid>` |
| `log` | 内核日志 | `log`, `log | tail` |
| `ps` | 进程列表 | `ps`, `ps \| grep UN` |
| `foreach` | 遍历所有进程 | `foreach bt`, `foreach task` |
| `kmem` | 内存分析 | `kmem -i`, `kmem -s`, `kmem <addr>` |
| `struct` | 查看数据结构 | `struct task_struct <addr>` |
| `p` | 打印表达式 | `p jiffies`, `p *<addr>` |
| `dev` | 设备信息 | `dev -d` |
| `mount` | 挂载信息 | `mount` |
| `vm` | 虚拟内存 | `vm` |
| `runq` | 运行队列 | `runq`, `runq -c <cpu>` |

### crash加载vmcore

```bash
# 基本加载
crash /usr/lib/debug/lib/modules/$(uname -r)/vmlinux /var/crash/vmcore

# 指定架构
crash vmlinux vmcore --arch x86_64

# 加载模块调试信息
crash vmlinux vmcore -d <module-debuginfo>
```

---

## 3. 用户态崩溃分析（coredump）

### gdb常用命令

| 命令 | 用途 | 示例 |
|------|------|------|
| `bt` | 调用栈 | `bt`, `bt full` |
| `info threads` | 所有线程 | `info threads` |
| `thread N` | 切换线程 | `thread 1` |
| `frame N` | 切换栈帧 | `frame 0` |
| `info locals` | 局部变量 | `info locals` |
| `info args` | 函数参数 | `info args` |
| `p` | 打印值 | `p var`, `p *ptr` |
| `x` | 查看内存 | `x/20x $sp`, `x/s str` |
| `info registers` | 寄存器 | `info registers` |
| `disassemble` | 反汇编 | `disassemble` |
| `list` | 源码 | `list`, `list func` |

### gdb分析coredump

```bash
# 加载
gdb ./program core

# 基本分析流程
(gdb) bt
(gdb) bt full
(gdb) info threads
(gdb) thread apply all bt

# 查看变量
(gdb) frame 0
(gdb) info locals
(gdb) p variable_name
(gdb) x/20x $sp
```

---

## 4. 性能分析

### CPU性能

| 用途 | 命令 | 说明 |
|------|------|------|
| 实时CPU | `top -H` | 各线程CPU使用 |
| 各核CPU | `mpstat -P ALL 1` | 每个核心使用率 |
| 进程CPU | `pidstat -t 1` | 进程/线程CPU |
| 热点分析 | `perf top` | 实时函数热点 |
| 采样分析 | `perf record -g -- sleep 30` | 采样60秒 |
| 查看报告 | `perf report --stdio` | 查看分析报告 |
| 统计事件 | `perf stat -e cycles,instructions ./prog` | 事件统计 |

### 内存性能

| 用途 | 命令 | 说明 |
|------|------|------|
| 内存概况 | `free -h` | 内存使用概况 |
| 详细内存 | `cat /proc/meminfo` | 内存详细信息 |
| 内存统计 | `vmstat 1` | 实时内存统计 |
| 页面统计 | `sar -B 1` | 页面错误统计 |
| 进程内存 | `pmap -x <pid>` | 进程内存映射 |
| 内存排名 | `ps aux --sort=-%mem` | 按内存排序 |
| Slab信息 | `slabtop` | 内核slab分配 |
| NUMA统计 | `numastat` | NUMA内存统计 |

### IO性能

| 用途 | 命令 | 说明 |
|------|------|------|
| IO统计 | `iostat -x 1` | 详细IO统计 |
| 进程IO | `iotop` | 进程IO排名 |
| 磁盘使用 | `df -h` | 磁盘空间使用 |
| 块层跟踪 | `blktrace -d /dev/sda -o - \| blkparse -i -` | 块IO跟踪 |
| IO事件 | `perf record -e block:* -- sleep 30` | 块层事件采样 |

### 网络性能

| 用途 | 命令 | 说明 |
|------|------|------|
| 接口统计 | `sar -n DEV 1` | 网络接口统计 |
| socket统计 | `ss -s` | socket汇总 |
| 连接状态 | `ss -tuln` | 监听端口 |
| 连接详情 | `ss -tan` | 所有TCP连接 |
| 网络错误 | `netstat -i` | 接口错误统计 |
| 协议统计 | `netstat -s` | 协议统计 |
| 抓包 | `tcpdump -i eth0 -w capture.pcap` | 网络抓包 |
| 带宽测试 | `iperf3 -c <host>` | 网络带宽测试 |

---

## 5. 进程分析

| 用途 | 命令 | 说明 |
|------|------|------|
| 进程列表 | `ps auxf` | 进程树 |
| 实时监控 | `top` 或 `htop` | 实时进程监控 |
| 进程状态 | `cat /proc/<pid>/status` | 进程状态详情 |
| 进程栈 | `cat /proc/<pid>/stack` | 内核栈 |
| 等待函数 | `cat /proc/<pid>/wchan` | 等待的内核函数 |
| 打开文件 | `lsof -p <pid>` | 进程打开的文件 |
| 文件描述符 | `ls -l /proc/<pid>/fd` | 文件描述符列表 |
| 系统调用 | `strace -p <pid>` | 跟踪系统调用 |
| 库调用 | `ltrace -p <pid>` | 跟踪库调用 |

---

## 6. 日志查看

| 用途 | 命令 | 说明 |
|------|------|------|
| 内核日志 | `dmesg` 或 `dmesg \| tail` | 内核环形缓冲区 |
| 系统日志 | `journalctl` | systemd日志 |
| 内核日志 | `journalctl -k` | 仅内核日志 |
| 实时日志 | `journalctl -f` | 实时跟踪 |
| 按时间 | `journalctl --since "2024-01-01 10:00"` | 指定时间范围 |
| 按服务 | `journalctl -u nginx` | 指定服务日志 |
| messages | `tail -f /var/log/messages` | 系统消息日志 |

---

## 7. 网络诊断

| 用途 | 命令 | 说明 |
|------|------|------|
| 接口信息 | `ip addr` | 网络接口信息 |
| 路由表 | `ip route` | 路由表 |
| 连接跟踪 | `conntrack -L` | 连接跟踪表 |
| ARP表 | `ip neigh` | ARP表 |
| 连通性 | `ping <host>` | 网络连通性 |
| 路由追踪 | `traceroute <host>` | 路由追踪 |
| DNS查询 | `dig <domain>` 或 `nslookup <domain>` | DNS查询 |
| 端口扫描 | `nc -zv <host> <port>` | 端口连通性 |

---

## 8. 存储诊断

| 用途 | 命令 | 说明 |
|------|------|------|
| 磁盘分区 | `fdisk -l` | 磁盘分区信息 |
| 挂载信息 | `mount` | 当前挂载 |
| 磁盘SMART | `smartctl -a /dev/sda` | SMART信息 |
| 文件系统检查 | `fsck -y /dev/sda1` | 文件系统检查（需卸载） |
| LVM信息 | `pvdisplay`, `vgdisplay`, `lvdisplay` | LVM信息 |
| RAID状态 | `cat /proc/mdstat` | 软RAID状态 |

---

## 9. 快速诊断脚本

### 60秒检查

```bash
#!/bin/bash
echo "=== 系统负载 ===" && uptime
echo "=== 内核错误 ===" && dmesg | tail -10
echo "=== 内存状态 ===" && free -h
echo "=== CPU使用 ===" && mpstat -P ALL 1 1
echo "=== IO状态 ===" && iostat -x 1 1
echo "=== 网络状态 ===" && sar -n DEV 1 1
```

### 查找问题进程

```bash
# CPU消耗最高的进程
ps aux --sort=-%cpu | head -10

# 内存消耗最高的进程
ps aux --sort=-%mem | head -10

# D状态进程
ps -eo pid,stat,cmd | grep " D"

# 僵尸进程
ps aux | awk '$8 ~ /Z/ {print}'
```

---

## 10. 工具安装

### openEuler/CentOS/RHEL

```bash
# 内核分析
yum install -y crash kernel-debuginfo

# 性能分析
yum install -y perf sysstat

# 调试工具
yum install -y gdb strace ltrace

# 网络工具
yum install -y tcpdump iperf3
```

### Debian/Ubuntu

```bash
# 内核分析（需要手动下载vmlinux）
apt-get install -y linux-crashdump crash

# 性能分析
apt-get install -y linux-tools-common sysstat

# 调试工具
apt-get install -y gdb strace ltrace

# 网络工具
apt-get install -y tcpdump iperf3
```
