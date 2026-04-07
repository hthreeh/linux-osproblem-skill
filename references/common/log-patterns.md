# 日志错误模式匹配库

本文档提供集中的日志模式 → 问题类型 → 分析入口映射表，用于快速识别系统日志中的异常并定位问题根因。所有模式均为正则表达式，可直接用于 `grep -E` 或脚本中的模式匹配。

---

## 1. 内核日志模式（Kernel Log Patterns）

内核日志来源：`dmesg`、`/var/log/kern.log`、`journalctl -k`

| 日志模式（正则） | 问题类型 | 严重级别 | 分析入口/下一步 |
|------------------|----------|----------|-----------------|
| `kernel BUG at (.+):(\d+)` | 内核BUG | 高 | 查看源码文件:行号，`bt` 分析调用栈 |
| `BUG: unable to handle kernel NULL pointer dereference at (.+)` | NULL指针解引用 | 高 | `bt` 查看崩溃栈，追踪指针来源和初始化路径 |
| `BUG: unable to handle kernel paging request at (.+)` | 无效页面访问 | 高 | 检查地址范围（用户态/内核态），`kmem` 分析 |
| `BUG: soft lockup - CPU#(\d+) stuck for (\d+)s` | 软锁（Soft Lockup） | 高 | 检查该CPU运行队列 `runq -c N`，`bt -c N` |
| `NMI watchdog: BUG: hard lockup - CPU#(\d+)` | 硬锁（Hard Lockup） | 高 | NMI中断无法触发调度，检查中断/自旋锁 |
| `Out of memory: Killed process (\d+) \((.+)\)` | OOM Kill | 高 | `dmesg \| grep -i oom`，分析内存分配和oom_score |
| `Call Trace:` | 内核异常调用栈 | 中 | 提取完整调用栈，定位触发函数 |
| `WARNING: CPU: (\d+) PID: (\d+) at (.+)` | 内核警告（WARN） | 中 | 非致命但需关注，定位源码位置 |
| `stack segment fault` | 栈段异常 | 高 | 可能栈溢出或栈损坏，检查递归和栈大小 |
| `invalid opcode: 0000` | 非法指令 | 高 | CPU特性不匹配或代码损坏，检查模块版本 |
| `possible circular locking dependency detected` | 死锁检测（Lockdep） | 高 | 分析锁依赖链，参考 `lockdep` 输出 |
| `INFO: rcu_sched self-detected stall on CPU` | RCU停滞 | 高 | RCU回调长时间未完成，检查长时间禁抢占路径 |
| `BUG: scheduling while atomic` | 原子上下文调度 | 高 | 在不可调度上下文中调用了可睡眠函数 |
| `blocked for more than (\d+) seconds` | IO挂起（Hung Task） | 中 | `echo w > /proc/sysrq-trigger` 打印阻塞栈 |
| `page allocation failure: order:(\d+)` | 内存分配失败 | 高 | 检查内存碎片化 `cat /proc/buddyinfo`，分析order |
| `Kernel panic - not syncing: (.+)` | 内核Panic | 高 | 加载vmcore用crash分析，`bt`+`log` |
| `general protection fault` | 通用保护异常 | 高 | 检查非法内存访问或对齐问题 |
| `divide error: 0000` | 除零错误 | 高 | 定位崩溃指令，检查除数来源 |
| `UBSAN: (.+)` | 未定义行为检测 | 中 | 内核UBSAN检测到的UB，按提示修复 |

---

## 2. 文件系统日志模式（Filesystem Log Patterns）

| 日志模式（正则） | 问题类型 | 严重级别 | 分析入口/下一步 |
|------------------|----------|----------|-----------------|
| `EXT4-fs error \(dev (\S+)\): (.+)` | EXT4错误 | 高 | `fsck.ext4 -n /dev/X` 检查，`dumpe2fs` 查看状态 |
| `EXT4-fs warning \(dev (\S+)\): (.+)` | EXT4警告 | 中 | 关注warning内容，可能是元数据异常前兆 |
| `EXT4-fs \(\S+\): remounting filesystem read-only` | EXT4只读重挂载 | 高 | 文件系统检测到严重错误，需离线fsck |
| `XFS \(\S+\): (.+error.+)` | XFS错误 | 高 | `xfs_repair -n /dev/X`，检查 `xfs_info` |
| `XFS \(\S+\): Metadata I/O error` | XFS元数据IO错误 | 高 | 底层存储可能有问题，检查磁盘健康 |
| `XFS \(\S+\): Corruption of in-memory data detected` | XFS内存数据损坏 | 高 | 紧急备份，`xfs_repair` 修复 |
| `BTRFS error \(device (\S+)\): (.+)` | BTRFS错误 | 高 | `btrfs scrub start`，`btrfs device stats` |
| `BTRFS warning \(device (\S+)\): (.+)` | BTRFS警告 | 中 | 检查设备统计 `btrfs device stats /mount` |
| `I/O error, dev (\S+), sector (\d+)` | 设备IO错误 | 高 | 定位设备和扇区，`smartctl` 检查磁盘健康 |
| `Buffer I/O error on dev (\S+), .+ sector (\d+)` | 缓冲IO错误 | 高 | 多次出现表明磁盘可能故障 |
| `Remounting filesystem read-only` | 文件系统只读 | 高 | 检查底层磁盘状态，`mount -o remount,rw` 尝试恢复 |
| `directory inode \d+ has an unallocated block` | inode块异常 | 中 | 需要fsck修复文件系统元数据 |
| `Inode \d+ has illegal block` | 非法块引用 | 高 | 文件系统元数据损坏，离线fsck |

---

## 3. 存储/磁盘日志模式（Storage Log Patterns）

| 日志模式（正则） | 问题类型 | 严重级别 | 分析入口/下一步 |
|------------------|----------|----------|-----------------|
| `ata\d+: COMRESET failed` | SATA复位失败 | 高 | 磁盘或SATA线缆可能故障，`smartctl -a` |
| `ata\d+\.\d+: failed command: (.+)` | ATA命令失败 | 高 | 记录失败命令类型，`smartctl -l error` |
| `ata\d+\.\d+: status: \{ DRDY ERR \}` | ATA设备错误 | 高 | 磁盘硬件级错误，检查SMART属性 |
| `sd \d+:\d+:\d+:\d+ .+ medium error` | SCSI介质错误 | 高 | 磁盘表面损坏，`badblocks` 检查坏道 |
| `sd \d+:\d+:\d+:\d+ .+ hardware error` | SCSI硬件错误 | 高 | 磁盘硬件故障，准备更换 |
| `blk_update_request: I/O error, dev (\S+), sector (\d+)` | 块设备IO错误 | 高 | `smartctl -a /dev/X`，检查重分配扇区 |
| `SMART .+ has been tripped` | SMART预警 | 高 | 磁盘即将故障，立即备份数据 |
| `Current Pending Sector Count (\d+)` | 待重分配扇区 | 中 | 值非零表明存在潜在坏扇区 |
| `Reallocated Sector Ct (\d+)` | 已重分配扇区 | 中 | 持续增长说明磁盘恶化 |
| `md/raid\d+:\S+: Disk failure on (\S+)` | RAID磁盘故障 | 高 | `mdadm --detail /dev/mdN`，更换故障盘 |
| `md: recovery of RAID array` | RAID重建中 | 中 | `cat /proc/mdstat` 监控重建进度 |
| `md: (\S+): raid array is not clean` | RAID阵列不洁 | 中 | 非正常关机后重建，关注重建状态 |
| `mpt\d+: IOC is in FAULT state` | RAID控制器故障 | 高 | 硬件RAID控制器异常，检查电池和固件 |
| `device-mapper: multipath: Failing path (\S+)` | 多路径故障 | 中 | `multipath -ll` 检查路径状态 |

---

## 4. 网络日志模式（Network Log Patterns）

| 日志模式（正则） | 问题类型 | 严重级别 | 分析入口/下一步 |
|------------------|----------|----------|-----------------|
| `(\S+): link is not ready` | 网卡链路未就绪 | 高 | 检查网线、交换机端口和网卡驱动 |
| `(\S+): link up` | 网卡链路恢复 | 低 | 配合 link down 分析闪断频率 |
| `(\S+): link down` | 网卡链路断开 | 高 | `ethtool ethN` 检查链路状态和协商 |
| `nf_conntrack: table full, dropping packet` | 连接跟踪表满 | 高 | `sysctl net.netfilter.nf_conntrack_max` 调大 |
| `nf_conntrack: nf_conntrack: expectation table full` | 期望表满 | 中 | 调整 `nf_conntrack_expect_max` |
| `TCP: .+out of order .+ retransmits` | TCP重传 | 中 | `ss -ti` 查看连接重传计数 |
| `TCP: out of memory -- consider increasing` | TCP内存不足 | 高 | 调整 `net.ipv4.tcp_mem` 参数 |
| `Out of socket memory` | 套接字内存不足 | 高 | `ss -s` 查看套接字统计，调整内存参数 |
| `neighbour table overflow` | ARP/邻居表溢出 | 高 | 增大 `net.ipv4.neigh.default.gc_thresh3` |
| `NETDEV WATCHDOG: (\S+) .+: transmit queue \d+ timed out` | 网卡发送超时 | 高 | 网卡驱动或硬件问题，考虑重启网卡或升级驱动 |
| `RX (\S+) ring buffer overrun` | 网卡缓冲溢出 | 中 | `ethtool -g ethN` 检查并增大ring buffer |
| `bonding: (\S+): link status .+ for interface (\S+)` | 绑定口链路变化 | 中 | 检查bond成员口状态 `cat /proc/net/bonding/bondN` |
| `bridge: (\S+) port \d+\((\S+)\) entered (disabled\|forwarding)` | 网桥端口状态变化 | 低 | STP拓扑变更，关注频繁变化 |

---

## 5. 用户态崩溃模式（Userspace Crash Patterns）

日志来源：`/var/log/messages`、`journalctl`、应用日志、`coredumpctl`

| 日志模式（正则） | 问题类型 | 严重级别 | 分析入口/下一步 |
|------------------|----------|----------|-----------------|
| `Segmentation fault \(core dumped\)` | 段错误（有core） | 高 | `coredumpctl gdb`，`bt full` 分析 |
| `Segmentation fault$` | 段错误（无core） | 高 | 启用coredump：`ulimit -c unlimited` 后复现 |
| `segfault at (\S+) ip (\S+) sp (\S+) error (\d+)` | 内核报告的段错误 | 高 | 解析error code位：读/写/用户态/内核态 |
| `core dumped` | 程序崩溃产生core | 高 | 定位core文件，`gdb <prog> <core>` |
| `double free or corruption` | glibc双重释放 | 高 | 使用 `valgrind` 或 `ASAN` 检测 |
| `corrupted size vs\. prev_size` | 堆内存损坏 | 高 | 堆元数据被覆写，`ASAN`/`valgrind` 检测 |
| `malloc\(\): (corrupted top size\|invalid next size)` | malloc内部错误 | 高 | 堆溢出或越界写，`ASAN` 检测 |
| `free\(\): invalid (pointer\|next size\|size)` | free参数异常 | 高 | 非法指针传给free，检查内存管理逻辑 |
| `stack smashing detected` | 栈缓冲区溢出 | 高 | 栈保护触发，检查局部数组越界写入 |
| `buffer overflow detected` | 缓冲区溢出 | 高 | `_FORTIFY_SOURCE` 检测到溢出 |
| `\*\*\* .+ \*\*\*: terminated` | glibc安全终止 | 高 | FORTIFY检测，分析调用栈 |
| `==\d+==ERROR: AddressSanitizer: (.+)` | ASAN检测错误 | 高 | 根据ASAN报告类型定位：heap-use-after-free等 |
| `==\d+==ERROR: LeakSanitizer: (.+)` | LSAN内存泄漏 | 中 | 根据分配调用栈修复泄漏 |
| `==\d+==ERROR: ThreadSanitizer: (.+)` | TSAN线程错误 | 高 | 数据竞争或死锁，根据报告加锁 |
| `SIGABRT` | 程序主动终止 | 高 | 通常由 `assert` 或 `abort()` 触发 |
| `SIGBUS` | 总线错误 | 高 | 内存对齐问题或映射文件被截断 |
| `SIGFPE` | 浮点异常 | 中 | 除零或浮点溢出，检查算术逻辑 |

---

## 6. 服务/进程模式（Service/Process Patterns）

日志来源：`journalctl -u <service>`、`systemctl status <service>`

| 日志模式（正则） | 问题类型 | 严重级别 | 分析入口/下一步 |
|------------------|----------|----------|-----------------|
| `Failed to start (.+)\.` | 服务启动失败 | 高 | `journalctl -u X -n 50`，检查配置和依赖 |
| `Main process exited, code=exited, status=(\d+)` | 服务异常退出 | 高 | 查看退出码含义，分析服务日志 |
| `Main process exited, code=killed, signal=(\d+)` | 服务被信号终止 | 高 | 信号9=OOM kill，信号11=段错误 |
| `Main process exited, code=dumped, signal=(\d+)` | 服务崩溃产生core | 高 | `coredumpctl list`，分析core |
| `oom-kill:constraint=(.+),.+task=(.+),pid=(\d+)` | OOM杀死进程 | 高 | 分析内存使用 `oom_score_adj`，增加内存/swap |
| `Out of memory: Kill process (\d+)` | OOM Kill事件 | 高 | `dmesg \| grep -A 20 "Out of memory"` 查看详情 |
| `Service (.+) has begun restarting too frequently` | 服务重启过频 | 中 | 检查 `RestartSec` 和 `StartLimitBurst` |
| `service start request repeated too quickly` | 服务启动过快 | 中 | 服务频繁崩溃重启，需修复根因 |
| `Dependency failed for (.+)` | 依赖服务失败 | 中 | `systemctl list-dependencies X` 查看依赖链 |
| `Timed out waiting for device (.+)` | 设备等待超时 | 中 | 检查设备是否存在，udev规则是否正确 |
| `A stop job is running for (.+)` | 服务停止超时 | 低 | 进程无法优雅退出，检查 `TimeoutStopSec` |
| `segfault at (\S+) ip (\S+) sp (\S+) error (\d+) in (.+)` | 进程段错误详情 | 高 | 定位崩溃模块，`addr2line` 解析地址 |

---

## 7. 安全相关模式（Security Patterns）

日志来源：`/var/log/secure`、`/var/log/auth.log`、`journalctl`、`ausearch`

| 日志模式（正则） | 问题类型 | 严重级别 | 分析入口/下一步 |
|------------------|----------|----------|-----------------|
| `avc:\s+denied\s+\{ (.+) \} for .+ scontext=(\S+) tcontext=(\S+)` | SELinux拒绝 | 中 | `audit2why`、`audit2allow` 分析策略 |
| `apparmor="DENIED" operation="(.+)" profile="(.+)"` | AppArmor拒绝 | 中 | 检查profile规则，`aa-logprof` 更新 |
| `Failed password for (\S+) from (\S+) port (\d+)` | 登录密码错误 | 中 | 多次出现可能为暴力破解，检查来源IP |
| `Failed password for invalid user (\S+) from (\S+)` | 非法用户登录 | 高 | 暴力破解尝试，考虑 `fail2ban` |
| `authentication failure; .+user=(\S+)` | PAM认证失败 | 中 | 检查用户是否存在，密码是否正确 |
| `Accepted (password\|publickey) for (\S+) from (\S+)` | 登录成功 | 低 | 审计合法登录，关注异常来源IP |
| `session opened for user (\S+) by` | 会话打开 | 低 | 正常审计事件 |
| `COMMAND=(.+)` | sudo命令执行 | 低 | `sudo` 操作审计，关注高权限命令 |
| `sudo: .+ authentication failure` | sudo认证失败 | 中 | 检查用户是否有sudo权限 |
| `pam_unix\(.+\): account expired` | 账户已过期 | 中 | `chage -l <user>` 查看过期时间 |
| `Possible SYN flooding on port (\d+)` | SYN洪泛攻击 | 高 | 启用 `syncookies`，配置防火墙限速 |
| `refused connect from (.+)` | 连接被拒绝 | 低 | 检查 TCP Wrappers 或防火墙规则 |

---

## 8. 模式匹配使用方法

### 8.1 使用 dmesg 搜索

```bash
# 搜索所有高严重级别内核问题
dmesg | grep -E 'BUG:|panic|OOM|lockup|Call Trace|segfault'

# 搜索特定模式（带时间戳）
dmesg -T | grep -E 'BUG: soft lockup - CPU#[0-9]+'

# 搜索内存相关问题
dmesg | grep -E 'Out of memory|page allocation failure|oom-kill'

# 搜索存储错误
dmesg | grep -E 'I/O error|medium error|COMRESET failed|blk_update_request'
```

### 8.2 使用 journalctl 搜索

```bash
# 搜索本次启动的内核错误
journalctl -k -p err -b 0

# 搜索特定服务的错误
journalctl -u nginx.service -p err --since "1 hour ago"

# 搜索段错误事件
journalctl | grep -E 'segfault at|Segmentation fault|core dumped'

# 搜索OOM事件
journalctl -k | grep -E 'Out of memory|oom-kill|Killed process'

# 搜索安全事件
journalctl | grep -E 'Failed password|authentication failure|avc:.*denied'
```

### 8.3 使用 awk 提取关键信息

```bash
# 提取OOM被杀进程名和PID
dmesg | awk '/Out of memory: Killed process/{
    match($0, /Killed process ([0-9]+) \(([^)]+)\)/, m);
    print "PID=" m[1], "进程=" m[2]
}'

# 统计段错误频率（按小时）
journalctl --since "24 hours ago" | \
    grep 'segfault' | \
    awk '{print $1, $2, substr($3,1,2)":00"}' | \
    sort | uniq -c | sort -rn

# 提取IO错误的设备和扇区
dmesg | awk '/I\/O error, dev/{
    match($0, /dev ([a-z]+), sector ([0-9]+)/, m);
    print "设备=" m[1], "扇区=" m[2]
}' | sort | uniq -c | sort -rn

# 统计登录失败来源IP
grep 'Failed password' /var/log/secure | \
    awk '{for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}' | \
    sort | uniq -c | sort -rn | head -20
```

### 8.4 综合快速扫描

```bash
# 一键扫描所有高危模式
dmesg -T | grep -E -c \
    'BUG:|panic|Out of memory|lockup|I/O error|medium error|segfault' && \
echo "--- 以上为匹配计数 ---"

# 按严重级别统计（需要 journalctl）
for level in emerg alert crit err; do
    count=$(journalctl -k -p $level -b 0 --no-pager 2>/dev/null | wc -l)
    echo "$level: $count 条"
done
```

---

## 9. 自动分类脚本片段

以下 Bash 函数接收一行日志文本，返回问题类型和严重级别。可集成到监控脚本或日志分析流水线中。

```bash
#!/bin/bash
# classify_log_line - 日志行自动分类函数
# 用法: classify_log_line "日志文本"
# 输出: 问题类型|严重级别

classify_log_line() {
    local line="$1"

    # --- 内核级（高优先级） ---
    if [[ "$line" =~ "Kernel panic" ]]; then
        echo "内核Panic|高"
    elif [[ "$line" =~ "BUG: unable to handle kernel NULL pointer" ]]; then
        echo "NULL指针解引用|高"
    elif [[ "$line" =~ "BUG: soft lockup" ]]; then
        echo "软锁|高"
    elif [[ "$line" =~ "hard lockup" ]]; then
        echo "硬锁|高"
    elif [[ "$line" =~ "Out of memory: Killed process" ]]; then
        echo "OOM Kill|高"
    elif [[ "$line" =~ "kernel BUG at" ]]; then
        echo "内核BUG|高"
    elif [[ "$line" =~ "page allocation failure" ]]; then
        echo "内存分配失败|高"
    elif [[ "$line" =~ "circular locking dependency" ]]; then
        echo "死锁检测|高"
    elif [[ "$line" =~ "rcu_sched self-detected stall" ]]; then
        echo "RCU停滞|高"
    elif [[ "$line" =~ "scheduling while atomic" ]]; then
        echo "原子上下文调度|高"
    elif [[ "$line" =~ "invalid opcode" ]]; then
        echo "非法指令|高"
    elif [[ "$line" =~ "general protection fault" ]]; then
        echo "通用保护异常|高"

    # --- 存储/文件系统 ---
    elif [[ "$line" =~ "I/O error, dev" ]]; then
        echo "设备IO错误|高"
    elif [[ "$line" =~ "EXT4-fs error" ]]; then
        echo "EXT4错误|高"
    elif [[ "$line" =~ "XFS".*"error" ]]; then
        echo "XFS错误|高"
    elif [[ "$line" =~ "BTRFS error" ]]; then
        echo "BTRFS错误|高"
    elif [[ "$line" =~ "medium error" ]]; then
        echo "SCSI介质错误|高"
    elif [[ "$line" =~ "COMRESET failed" ]]; then
        echo "SATA复位失败|高"
    elif [[ "$line" =~ "blk_update_request: I/O error" ]]; then
        echo "块设备IO错误|高"
    elif [[ "$line" =~ "Remounting filesystem read-only" ]]; then
        echo "文件系统只读|高"

    # --- 网络 ---
    elif [[ "$line" =~ "nf_conntrack: table full" ]]; then
        echo "连接跟踪表满|高"
    elif [[ "$line" =~ "Out of socket memory" ]]; then
        echo "套接字内存不足|高"
    elif [[ "$line" =~ "neighbour table overflow" ]]; then
        echo "邻居表溢出|高"
    elif [[ "$line" =~ "link down" ]] || [[ "$line" =~ "link is not ready" ]]; then
        echo "网卡链路异常|高"
    elif [[ "$line" =~ "transmit queue".*"timed out" ]]; then
        echo "网卡发送超时|高"

    # --- 用户态崩溃 ---
    elif [[ "$line" =~ "segfault at" ]] || [[ "$line" =~ "Segmentation fault" ]]; then
        echo "段错误|高"
    elif [[ "$line" =~ "double free or corruption" ]]; then
        echo "双重释放|高"
    elif [[ "$line" =~ "stack smashing detected" ]]; then
        echo "栈缓冲区溢出|高"
    elif [[ "$line" =~ "core dumped" ]]; then
        echo "程序崩溃|高"
    elif [[ "$line" =~ "AddressSanitizer" ]]; then
        echo "ASAN检测|高"

    # --- 服务 ---
    elif [[ "$line" =~ "Failed to start" ]]; then
        echo "服务启动失败|高"
    elif [[ "$line" =~ "Main process exited, code=killed" ]]; then
        echo "服务被终止|高"
    elif [[ "$line" =~ "Main process exited, code=exited" ]]; then
        echo "服务异常退出|高"
    elif [[ "$line" =~ "oom-kill:" ]]; then
        echo "OOM Kill|高"

    # --- 安全 ---
    elif [[ "$line" =~ 'avc:.*denied' ]]; then
        echo "SELinux拒绝|中"
    elif [[ "$line" =~ 'apparmor="DENIED"' ]]; then
        echo "AppArmor拒绝|中"
    elif [[ "$line" =~ "Failed password for invalid user" ]]; then
        echo "非法用户登录|高"
    elif [[ "$line" =~ "Failed password" ]]; then
        echo "登录密码错误|中"

    # --- 中等严重级别 ---
    elif [[ "$line" =~ "Call Trace:" ]]; then
        echo "内核异常调用栈|中"
    elif [[ "$line" =~ "WARNING: CPU:" ]]; then
        echo "内核警告|中"
    elif [[ "$line" =~ "blocked for more than" ]]; then
        echo "IO挂起|中"

    # --- 未匹配 ---
    else
        echo "未分类|低"
    fi
}

# 批量分析用法示例：
# dmesg | while IFS= read -r line; do
#     result=$(classify_log_line "$line")
#     if [[ "$result" != "未分类|低" ]]; then
#         echo "[$result] $line"
#     fi
# done
```

### 使用示例

```bash
# 单行分类
classify_log_line "BUG: soft lockup - CPU#3 stuck for 22s"
# 输出: 软锁|高

# 批量扫描dmesg并只输出异常
source classify_log.sh
dmesg -T | while IFS= read -r line; do
    result=$(classify_log_line "$line")
    type="${result%%|*}"
    level="${result##*|}"
    if [[ "$level" == "高" ]]; then
        echo "[${level}] [${type}] ${line}"
    fi
done

# 统计各类问题出现次数
dmesg | while IFS= read -r line; do
    classify_log_line "$line"
done | sort | uniq -c | sort -rn | grep -v "未分类"
```

---

## 附：段错误error code速查

内核报告的 `segfault at ADDR ip IP sp SP error N` 中，error code各位含义：

| 位 | 值 | 含义 |
|----|-----|------|
| bit 0 | 0/1 | 0=页不存在，1=权限违规 |
| bit 1 | 0/1 | 0=读操作，1=写操作 |
| bit 2 | 0/1 | 0=内核态，1=用户态 |
| bit 3 | 0/1 | 0=非保留位，1=使用了保留位 |
| bit 4 | 0/1 | 0=非指令获取，1=指令获取 |

**常见组合**：

| error值 | 含义 | 典型场景 |
|---------|------|----------|
| 4 | 用户态读不存在页 | NULL指针解引用读 |
| 6 | 用户态写不存在页 | NULL指针解引用写 |
| 5 | 用户态读权限违规 | 读已释放/受保护内存 |
| 7 | 用户态写权限违规 | 写只读内存（如代码段） |
| 14 | 用户态指令获取不存在页 | 跳转到无效地址 |
| 15 | 用户态指令获取权限违规 | NX位保护触发（DEP） |
