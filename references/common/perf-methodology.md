# USE方法详细指南

USE方法（Utilization, Saturation, Errors）是一种系统性的性能分析方法论，由Brendan Gregg提出。

---

## 1. USE方法概述

### 定义

对于每个资源，检查三个指标：

| 指标 | 含义 | 判断标准 |
|------|------|----------|
| **Utilization（利用率）** | 资源使用百分比 | 高利用率（>70-80%）可能影响性能 |
| **Saturation（饱和度）** | 队列长度、等待时间 | 非零饱和度表示资源不足 |
| **Errors（错误）** | 错误计数 | 任何非零错误都需要关注 |

### 适用范围

- 所有系统资源
- 硬件资源（CPU、内存、磁盘、网络）
- 软件资源（锁、线程池、连接池）

---

## 2. 资源检查清单

### 2.1 CPU

| 指标 | 工具 | 命令 |
|------|------|------|
| 利用率 | mpstat, top | `mpstat -P ALL 1` |
| 饱和度 | uptime, vmstat | `uptime`（load average） |
| 错误 | dmesg | `dmesg \| grep -i cpu` |

**利用率解读**：
```
%user  %nice %system %iowait %steal %idle
30.0    0.0    5.0     10.0    0.0   55.0

- user: 用户态CPU时间
- system: 内核态CPU时间
- iowait: 等待IO的CPU时间
- steal: 虚拟化环境被其他实例占用
- idle: 空闲时间
```

**饱和度解读**：
```
load average: 4.50, 4.20, 4.10
# CPU核数 = 4
# load/CPU = 1.125，存在排队
```

### 2.2 内存

| 指标 | 工具 | 命令 |
|------|------|------|
| 利用率 | free, vmstat | `free -h` |
| 饱和度 | vmstat, sar | `vmstat 1`（si/so） |
| 错误 | dmesg | `dmesg \| grep -i oom` |

**利用率解读**：
```
              total        used        free      shared  buff/cache   available
Mem:           31Gi       25Gi       500Mi       1.0Gi       5.0Gi       4.0Gi
Swap:         8.0Gi       7.5Gi       0.5Gi

关键指标：
- available: 真正可用的内存（考虑了可回收的缓存）
- used + buff/cache: 总占用
- Swap used: 使用了多少交换空间
```

**饱和度解读**：
```
vmstat 1
----- procs -----  ---- memory ----  -swap- ----- io----
 r  b   swpd   free   buff  cache   si   so    bi    bo
 2  0 102400  50000  10000 500000   10   20    50    30

- si (swap in): 从交换空间换入
- so (swap out): 换出到交换空间
- 非零值表示内存压力
```

### 2.3 磁盘IO

| 指标 | 工具 | 命令 |
|------|------|------|
| 利用率 | iostat | `iostat -x 1` |
| 饱和度 | iostat | `iostat -x 1`（await） |
| 错误 | dmesg, smartctl | `dmesg \| grep -i sda` |

**利用率解读**：
```
iostat -x 1
Device  rrqm/s  wrqm/s   r/s   w/s  rMB/s  wMB/s  avgrq-sz  avgqu-sz   await  r_await  w_await  %util
sda       0.0     5.0  10.0  20.0   0.5    1.0     50.0      1.5     50.0    40.0     55.0    30.0

关键指标：
- %util: 设备利用率（注意：多磁盘设备可达100%*N）
- avgqu-sz: 平均队列长度（饱和度）
- await: 平均等待时间（ms）
- r_await/w_await: 读写分别等待时间
```

**饱和度判断**：
- avgqu-sz > 1：存在排队
- await > 10ms：响应时间较长

### 2.4 网络

| 指标 | 工具 | 命令 |
|------|------|------|
| 利用率 | sar, ip | `sar -n DEV 1` |
| 饱和度 | netstat, ss | `ss -s` |
| 错误 | netstat, ethtool | `netstat -i` |

**利用率解读**：
```
sar -n DEV 1
IFACE rxpck/s txpck/s rxkB/s txkB/s rxcmp/s txcmp/s rxmcst/s %ifutil
eth0     1000     800    500    400       0       0        0     5.0

%ifutil = 实际吞吐量 / 接口带宽
- >70%: 高利用率
```

**错误检查**：
```
netstat -i
Iface  MTU  RX-OK RX-ERR RX-DRP RX-OVR  TX-OK TX-ERR TX-DRP TX-OVR
eth0  1500 100000    10     5      0  90000      0      0      0

- RX-ERR/TX-ERR: 接收/发送错误
- RX-DRP/TX-DRP: 丢包
```

### 2.5 软件资源

#### 进程/线程

| 指标 | 工具 | 命令 |
|------|------|------|
| 利用率 | pidstat | `pidstat -t 1` |
| 饱和度 | ps, top | `ps -eo pid,stat,cmd`（D状态） |
| 错误 | strace | `strace -e trace=all` |

#### 文件描述符

| 指标 | 工具 | 命令 |
|------|------|------|
| 利用率 | lsof | `lsof -p PID \| wc -l` |
| 饱和度 | /proc | `cat /proc/sys/fs/file-nr` |
| 错误 | strace | `strace -e trace=open` |

---

## 3. 红灯信号法（60秒检查）

### 检查顺序

```bash
#!/bin/bash
# 60秒性能检查脚本

echo "=== 1. 系统负载 (uptime) ==="
uptime

echo -e "\n=== 2. 内核错误 (dmesg) ==="
dmesg | tail -20

echo -e "\n=== 3. 内存和交换 (vmstat) ==="
vmstat 1 3

echo -e "\n=== 4. CPU使用率 (mpstat) ==="
mpstat -P ALL 1 1

echo -e "\n=== 5. IO统计 (iostat) ==="
iostat -x 1 1

echo -e "\n=== 6. 网络统计 (sar) ==="
sar -n DEV 1 1

echo -e "\n=== 检查完成 ==="
```

### 红灯信号解读

| 信号 | 含义 | 可能问题 |
|------|------|----------|
| load average很高 | CPU或IO饱和 | CPU瓶颈或磁盘瓶颈 |
| swap in/out非零 | 内存不足 | 内存泄漏或配置不当 |
| iowait很高 | IO等待 | 磁盘瓶颈 |
| CPU%很高 | CPU繁忙 | 计算密集型任务 |
| dmesg有错误 | 内核问题 | 硬件故障或驱动问题 |

---

## 4. 瓶颈定位流程

### 4.1 自顶向下分析

```
系统整体
    │
    ├── 检查负载
    │       └── uptime: load average
    │
    ├── 检查CPU
    │       ├── mpstat: 各核利用率
    │       └── perf top: 热点函数
    │
    ├── 检查内存
    │       ├── free: 内存使用
    │       └── vmstat: 页面交换
    │
    ├── 检查IO
    │       ├── iostat: 设备利用率
    │       └── iotop: 进程IO排名
    │
    └── 检查网络
            ├── sar -n DEV: 接口流量
            └── ss: 连接状态
```

### 4.2 自底向上分析

```
应用进程
    │
    ├── 进程状态
    │       ├── ps: 进程状态
    │       ├── top/htop: CPU/内存使用
    │       └── strace: 系统调用
    │
    ├── 线程分析
    │       ├── pidstat -t: 线程CPU
    │       └── gdb: 线程栈
    │
    ├── 内存分析
    │       ├── pmap: 内存映射
    │       └── valgrind: 内存泄漏
    │
    └── 锁分析
            ├── gdb: 查看锁状态
            └── perf lock: 锁性能
```

---

## 5. 性能分析工具详解

### 5.1 perf工具

```bash
# 实时热点
perf top

# 采样分析
perf record -g -- sleep 60
perf report --stdio

# 特定进程
perf record -g -p <PID> -- sleep 30

# 调用图分析
perf record -g --call-graph dwarf -- sleep 30
perf report -g graph,0.5,caller

# 事件统计
perf stat -e cycles,instructions,cache-misses ./program

# 火焰图生成
perf record -g -- sleep 30
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

### 5.2 sar工具

```bash
# CPU统计
sar -u 1 10

# 内存统计
sar -r 1 10

# IO统计
sar -b 1 10

# 网络统计
sar -n DEV 1 10

# 历史数据
sar -f /var/log/sa/saXX
```

### 5.3 vmstat工具

```bash
# 基本监控
vmstat 1

# 详细内存信息
vmstat -s

# slab信息
vmstat -m

# 关键指标
# r: 运行队列长度
# b: 不可中断睡眠进程数
# swpd: 交换空间使用
# free: 空闲内存
# si/so: 交换换入/换出
# bi/bo: 块设备读/写
# us/sy/id/wa/st: CPU时间分布
```

---

## 6. 场景化诊断

### 6.1 系统整体慢

```
检查步骤：
1. uptime - 查看负载
2. vmstat - 查看CPU和内存状态
3. iostat - 查看IO状态
4. sar -n DEV - 查看网络状态

常见原因：
- CPU过载：load > CPU核数
- 内存不足：频繁swap
- 磁盘慢：高iowait
- 网络拥塞：高错误率
```

### 6.2 进程响应慢

```
检查步骤：
1. ps - 查看进程状态
2. pidstat - 查看CPU使用
3. strace - 跟踪系统调用
4. lsof - 查看资源占用

常见原因：
- CPU消耗大
- IO等待
- 锁竞争
- 资源不足（文件描述符、连接数）
```

### 6.3 内存问题

```
检查步骤：
1. free - 查看内存概况
2. ps aux --sort=-%mem - 查看内存大户
3. pmap -x <PID> - 查看进程内存映射
4. valgrind - 检测内存泄漏

常见原因：
- 内存泄漏
- 缓存过大
- 配置不当（JVM堆大小等）
```

---

## 7. 性能优化建议

### 7.1 CPU优化

- 减少不必要的计算
- 使用更高效的算法
- 利用多核并行处理
- CPU亲和性绑定

### 7.2 内存优化

- 避免内存泄漏
- 合理设置缓存大小
- 使用内存池
- 大页内存（HugePages）

### 7.3 IO优化

- 使用更快的存储设备
- 减少不必要的IO
- 批量读写
- 使用异步IO
- 调整IO调度器

### 7.4 网络优化

- 调整TCP参数
- 使用连接池
- 启用压缩
- 使用更高效的协议
