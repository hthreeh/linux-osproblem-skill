---
name: os-troubleshooter
description: Linux 操作系统问题定位与根因分析技能。用于排查内核崩溃、vmcore/crash 分析、用户态 coredump、段错误、性能瓶颈、系统挂起、死锁、网络/存储异常，以及需要对服务器或 OS 故障做系统化诊断、证据链分析和 RCA 报告输出的场景。当用户提到 panic、BUG、Oops、OOM、vmcore、coredump、segfault、卡死、hung task、性能变慢、CPU/内存/IO 异常、死锁、系统无响应或要求帮助定位 Linux OS 问题时使用此技能。
---

# OS Troubleshooter

统一的 Linux OS 排障技能入口。覆盖通用故障分诊，并内置 `vmcore + crash` 深度分析分支。

## 使用边界

- 默认面向 Linux，优先兼容 openEuler/CentOS/RHEL；跨发行版差异参考 `references/common/command-reference.md`
- 优先使用用户提供的路径、命令和上下文；不要擅自改写用户给出的现场信息
- 没有证据不要下结论；没有根因调查，不进入修复建议
- 复杂问题使用迭代诊断，不要把第一次观察当最终结论

## 总体分流

先判定输入属于哪一类，再进入对应分支：

| 类型 | 典型输入 | 首要工具/工件 |
|------|----------|---------------|
| `vmcore` / 内核崩溃 | panic, BUG, Oops, vmcore, crash, kdump | `crash`, `vmlinux`, `vmcore` |
| 用户态崩溃 | coredump, segfault, core dumped | `gdb`, 可执行文件, coredump |
| 性能问题 | 慢, 抖动, CPU 高, IO 高, 延迟高 | `perf`, `sar`, `iostat`, `pidstat` |
| 系统挂起/死锁 | hang, 卡死, hung task, blocked | `/proc/*/stack`, `ps`, `sysrq`, `crash` |
| OOM / 内存溢出 | oom-killer, 进程被 kill, 内存不足, cgroup 限制 | `scripts/vmcore/collect_basic_info.sh`, 专项脚本 |
| 网络/存储/其他系统问题 | 网络不通, 丢包, 磁盘慢, 启动失败 | 日志, 系统状态, 定向收集脚本 |

如果分类不明确：

1. 先执行快速基线收集。
2. 根据日志与症状二次分类。
3. 仍不明确时，明确说明不确定性，并给出下一步最小必要数据。

## 通用预检查

### 用户输入优先级

1. 用户给了完整执行命令：按用户命令执行，可跳过默认环境检查。
2. 用户给了路径参数：必须优先使用这些路径。
3. 用户没给路径：才回退到标准路径或脚本默认值。

### 标准路径

| 数据 | 标准路径 | 备选 |
|------|----------|------|
| `vmcore` | `/var/crash/` | 用户指定 |
| `coredump` | `/var/core/` | `/tmp/`, 用户指定 |
| 内核日志 | `/var/log/messages` | `journalctl -k` |
| 系统日志 | `/var/log/messages`/`syslog` | `journalctl` |

### 通用脚本

- `scripts/check_tools.sh`: 检查分析工具
- `scripts/collect_info.sh`: 收集系统基础信息
- `scripts/quick_diagnosis.sh`: 快速自动分类
- `scripts/diagnose.sh`: 按 `auto/kernel/userspace/perf/hang/network/storage` 模式做定向收集

## 核心流程

### 1. 快速建立基线

至少完成以下三件事：

1. 明确故障现象、影响范围、是否可复现、是否人为触发。
2. 收集第一批证据：日志、工件路径、时间线。
3. 给出问题类型初判和下一步分析路径。

### 2. 证据优先

- 每个结论都要有日志、命令输出、栈、地址、结构体或源码位置支撑
- 区分“观察事实”“推论”“待验证假设”
- 对高风险结论说明证据强度和缺失项

### 3. 先给用户当前判断，再继续深挖

- P1 类故障：先提供规避建议，再继续根因分析
- P2/P3 类故障：按标准流完成根因和验证路径

## 分支 A：`vmcore` / 内核崩溃分析

这是本技能的重点分支。细节按需读取：

- 命令细节：`references/vmcore/crash_commands.md`
- 故障模式：`references/vmcore/analysis_patterns.md`
- 深度 RCA：`references/vmcore/root_cause_analysis.md`
- 结构体分析：`references/vmcore/struct_analysis.md`
- 源码目录识别：`references/vmcore/source_code_structure.md`
- 环境与符号问题：`references/vmcore/troubleshooting.md`

### A1. 先区分场景

必须先判断 `vmcore` 属于哪种来源：

- 场景 A，系统故障触发：系统自己崩溃、panic、重启
- 场景 B，人工触发快照：用户用 `sysrq-c`、`kdump`、NMI 主动抓现场

判断依据：

1. 用户描述是否明确说“我手动触发了 panic/抓包”
2. `crash> sys` 里的 panic 原因

### A2. 环境检查

先判断现场是不是自包含 `crash` 分析包。

#### A2.1 自包含 crash bundle 优先

如果用户提供的是故障目录，并且目录内存在类似结构：

```text
incident/
├── crash
├── vmlinux
├── vmcore
└── src/        # 可选
```

则优先把这个目录当作一等输入源：

1. 使用目录内自带的 `crash`、`vmlinux` 和 `vmcore`
2. 从该目录启动：`./crash ./vmlinux vmcore`
3. 如果存在 `src/`，后续源码联动只使用该目录中的源码
4. 不要回退到系统默认 `crash`、`/usr/lib/debug/.../vmlinux` 或 `/var/crash/vmcore`

#### A2.2 标准环境检查

只有在用户没有提供自包含 bundle，且也没有给完整执行命令时，才优先运行：

`scripts/vmcore/check_environment.sh`

规则：

- 返回非 0 时立即停止深入分析，先反馈环境/符号/文件不匹配问题
- 用户给了路径参数时，必须传给脚本
- 如果需要反复切换多个 `vmcore` 路径，可使用 `scripts/vmcore/crash_config.sh` 保存配置

### A3. 最小基线命令

所有 `vmcore` 分析先跑：

```text
crash> sys
crash> log
crash> bt
```

然后根据场景分流：

- 场景 A：从 panic 症状倒推根因
- 场景 B：忽略人为触发动作，聚焦用户真正想排查的卡死、性能、泄漏、网络等问题

### A4. 五类深挖方向

在 `sys/log/bt` 之后，用上下文命令定向分流：

```text
crash> ps
crash> bt -a
crash> foreach bt
```

根据迹象继续：

- 内存相关：`kmem -i`, `kmem -s`, `vm`
- 锁/死锁：`ps | grep UN`, `bt <pid>`, `struct mutex <addr>`
- 中断/定时器：`irq`, `timer`, `bt -a`
- 文件系统/IO：`files`, `mount`, `dev`
- 驱动/硬件：`mod`, `dev`, `sym <addr>`

### A5. 硬件 bit-flip 前置规则

如果是未知越界地址导致的页故障、非法访问、`unable to handle kernel paging request` 等异常，且地址不是显然的 `NULL`：

1. 先提取实际故障地址和故障指令位置。
2. 反汇编并计算“预期应访问的地址”。
3. 对实际地址与预期地址做异或比对。
4. 若明显符合单 bit 翻转特征，优先给出硬件故障结论，暂停软件根因追踪。

不要在这一关跳过硬件嫌疑，直接钻业务代码。

### A6. 源码联动

当用户提供 `src/` 内核源码时：

- 源码用于验证 crash 证据，不是替代 crash 证据
- 如果 crash 现场与源码推断冲突，以现场为准
- 根因必须尽量落到具体文件、函数、路径分支和行号

### A7. 证据链与 RCA

`vmcore` 复杂问题必须输出：

- 现象
- 直接原因
- 机制
- 潜在原因
- 根本原因
- 每一级对应的命令证据

可使用：

- `scripts/vmcore/evidence_chain.sh`（交互模式，也支持 `--batch <input_file>` 批处理）
- `scripts/vmcore/rca_wizard.sh`（交互模式，也支持 `--batch <input_file>` 批处理）
- `scripts/vmcore/quick_report.sh`
- `scripts/vmcore/crash_wrapper.sh`
- `scripts/vmcore/analyze_struct.py`

复杂 `vmcore` 报告模板见 `assets/vmcore-rca-template.md`。

## 分支 B：用户态 `coredump` / 段错误

优先使用 `gdb <executable> <coredump>`，建立以下基线：

```text
info threads
info registers
bt
bt full
frame N
info locals
info args
```

重点识别：

- `NULL` 指针
- 越界访问
- Use-After-Free
- 未初始化指针
- 栈溢出
- 对齐问题

需要更多细节时读取：

- `references/common/segfault-types.md`
- `references/common/command-reference.md`

## 分支 C：性能问题

遵循 USE 方法和红灯信号法：

1. CPU
2. 内存
3. IO
4. 网络

优先工具：

- `perf`
- `sar`
- `iostat`
- `vmstat`
- `pidstat`

详细方法参考：

- `references/common/perf-methodology.md`
- `references/common/log-patterns.md`

## 分支 D：系统挂起 / 死锁 / Hung Task

优先确认：

- 是否有 `D`/`UN` 状态进程
- 等待点在锁、IO、内存还是驱动
- 是否已有 `vmcore` 快照可转入分支 A

详细方法参考：

- `references/common/deadlock-analysis.md`
- `references/vmcore/analysis_patterns.md`

## 分支 E：网络 / 存储 / 启动 / 容器 / 安全

按需读取场景文档：

- 网络：`references/scenarios/network-troubleshooting.md`
- 启动：`references/scenarios/boot-troubleshooting.md`
- 容器与虚拟化：`references/scenarios/container-troubleshooting.md`
- 安全事件：`references/scenarios/security-incident.md`

## 分支 F：OOM / 内存溢出专项分析

当用户提到 OOM、oom-killer、进程被 kill、内存不足、cgroup 内存限制、slab 异常等关键词时进入此分支。

### F1. 自动识别分析场景

根据用户描述中的关键词，直接路由到对应路径，无需询问：

| 用户描述关键词 | 判断场景 | 分析路径 |
|--------------|----------|----------|
| 系统变慢/无响应/整机OOM/大量进程被杀/服务全部挂掉 | 系统级 OOM | → 路径 A |
| 某进程名/PID/进程被kill/exit 137/进程崩溃/内存持续增长 | 进程级 OOM | → 路径 B |
| 容器/Docker/K8s/cgroup/Pod OOM/memory limit | cgroup OOM | → 路径 C |
| slab异常/dentry/inode/tmpfs/内核内存/模块泄漏/crashkernel | 内核态 OOM | → 路径 D |

如果同时命中多个场景，优先以更具体的场景为主（如"容器内某进程OOM"→ 进程级 + 参考 cgroup）。

### F2. 信息收集（基础信息 + 日志一体化）

优先使用 `scripts/vmcore/collect_basic_info.sh`，该脚本一次性完成：
- 系统内存快照与诊断指标（/proc/meminfo 异常判断）
- CPU & 内存压力指标
- OOM 内核参数（panic_on_oom / overcommit 等）
- 时间段内 OOM 日志（journalctl + /var/log/messages）
- OOM kill 事件完整上下文
- 进程内存排名 Top 30 + OOM score 排名
- Slab 详情（dentry/inode/sock 重点对象）
- cgroup 内存使用与 failcnt 告警
- 内核模块列表
- NUMA 拓扑 & 内存碎片

```bash
# 系统级 OOM
bash scripts/vmcore/collect_basic_info.sh -S "2024-01-15 14:00:00" -E "2024-01-15 15:00:00"

# 精确 PID（-E 可选，默认 +1h）
bash scripts/vmcore/collect_basic_info.sh -S "2024-01-15 14:00:00" -p 12345

# 模糊进程名
bash scripts/vmcore/collect_basic_info.sh -S "2024-01-15 14:00:00" -n java

# systemd 服务
bash scripts/vmcore/collect_basic_info.sh -S "2024-01-15 14:00:00" -s nginx
```

### F3. 分场景深度分析

根据 F1 自动判断的场景，执行对应专项脚本：

#### 路径 A：系统级 OOM

```bash
bash scripts/vmcore/system_oom.sh -S "2024-01-15 14:00:00" -E "2024-01-15 15:00:00"
```

脚本输出包含 **[SUMMARY]** 节（优先阅读）：
- `S1` OOM kill 事件表：时间/被杀进程/score/anon-rss
- `S2` 内存归因分类：用户态(anon/cache/shmem) vs 内核态(slab/pt/vmalloc)
- `S3` 内存压力指标：oom_kill次数/allocstall/kswapd回收量/swap换入换出
- `S4` OOM 关键内核参数快照
- `S5` 超额提交评估（CommitLimit vs Committed_AS）

详细方法论：`references/oom/system-oom-analysis.md`

#### 路径 B：进程级 OOM

```bash
bash scripts/vmcore/process_oom.sh -S "2024-01-15 14:00:00" -p 12345
# 或 -n java / -s nginx
```

脚本输出包含 **[SUMMARY]** 节：
- `S1` 进程退出方式确认（OOM kill / exit code 137 / 当前状态）
- `S2` 进程内存分布（heap/stack/anonymous_mmap/shared_lib）
- `S3` 历史内存趋势
- `S4` 同类进程对比

详细方法论：`references/oom/process-oom-analysis.md`

#### 路径 C：cgroup OOM

```bash
bash scripts/vmcore/cgroup_oom.sh -S "2024-01-15 14:00:00" -E "2024-01-15 15:00:00"
# 可选: -g "容器ID或cgroup路径"
```

脚本输出包含 **[SUMMARY]** 节：
- `S1` 存在 OOM 事件的 cgroup 汇总表
- `S2` 所有有限制的 cgroup 视图
- `S3` 目标 cgroup 内进程内存分布
- `S4` 容器运行时元数据
- `S5` cgroup OOM 内核日志

详细方法论：`references/oom/cgroup-oom-analysis.md`

#### 路径 D：内核态 OOM

```bash
bash scripts/vmcore/kernel_oom.sh -S "2024-01-15 14:00:00" -E "2024-01-15 15:00:00"
```

脚本输出包含 **[SUMMARY]** 节，自动诊断四个子场景：
- `D1` crashkernel 预留量是否过大
- `D2` 未归因内存分析 + vmalloc 消耗 + 非原生内核模块
- `D3` Shmem 占比 + tmpfs 挂载占用 + /dev/shm 大文件
- `D4` Slab 占比 + dentry/inode/proc_inode/sock 各对象

详细方法论：`references/oom/kernel-oom-analysis.md`

### F4. 根因分析框架

```
【时间链路确认】
- OOM 事件发生时间 T0
- 内存持续增长开始时间 T-N
- 触发阈值的时间 T-X
- 异常行为时间 T-Y

【因果链路确认】
- 直接原因（谁耗尽了内存）
- 根本原因（为什么会耗尽）
- 加速因素（什么让问题更快发生）
- 防护缺失（哪些机制没有拦住）
```

### F5. 源码级分析（可选）

当用户要求"源码分析"或"代码级定位"时执行。

详见 `references/oom/kernel-source-analysis.md`

常见源码入口：

| OOM 场景 | 源码入口 | 关键文件 |
|----------|----------|----------|
| OOM killer 触发 | `out_of_memory()` | mm/oom_kill.c |
| 页面分配失败 | `__alloc_pages_nodemask()` | mm/page_alloc.c |
| slab 分配失败 | `kmem_cache_alloc()` | mm/slub.c |
| cgroup OOM | `mem_cgroup_oom()` | mm/memcontrol.c |
| mmap 内存申请 | `do_mmap()` | mm/mmap.c |
| 内存回收 | `try_to_free_pages()` | mm/vmscan.c |

### F6. 常见 OOM 场景速查

| 场景 | 关键特征 | 快速定位命令 |
|------|----------|-------------|
| 用户态进程泄漏 | RES持续增长，OOM kill特定进程 | `ps aux --sort=-%mem` |
| cgroup OOM | memory.failcnt增加，特定容器OOM | `cat /sys/fs/cgroup/memory/*/memory.failcnt` |
| Slab膨胀 | Slab >> 正常值，dentry/inode异常 | `slabtop -o` |
| Shmem异常 | Shmem >> 正常值，tmpfs大文件 | `df -h /dev/shm; lsof +D /tmp` |
| kdump预留 | MemTotal远小于物理内存 | `dmesg \| grep -iE "reserved\|crashkernel"` |
| 内核模块泄漏 | total >> anon+file+slab之和 | `lsmod; cat /proc/vmallocinfo` |

## 迭代诊断

复杂问题按四轮推进：

1. 快速扫描：分类、严重度、初步风险
2. 定向收集：补最小必要数据
3. 深度分析：验证或推翻假设
4. 方案验证：根因修复、规避方案、验证闭环

退出条件：

- 根因和验证路径都明确
- 超过 3 轮仍无根因，则明确说明卡点和缺失数据
- 用户停止，则输出当前最可靠结论和后续建议

## 严重度

- P1：系统/核心服务不可用，或存在数据损坏风险
- P2：单服务或关键组件受影响，可恢复但需要尽快处理
- P3：影响有限、可计划性处理

P1 必须先给规避动作，再继续 RCA。

## 输出要求

### 简单问题

终端输出应包含：

- 问题类型
- 当前最可靠根因判断
- 严重度
- 解决方案或下一步动作
- 验证方法

### 复杂问题

生成 Markdown 报告。通用问题使用 `assets/report-template.md`；复杂 `vmcore` 问题使用 `assets/vmcore-rca-template.md`。

根因描述不要停留在“内核 bug”“内存泄漏”“死锁”这种笼统层级。尽量落到：

- 文件/模块
- 函数
- 错误路径或锁顺序
- 行号或关键代码位置
- 对应 crash/gdb 证据

## 资源索引

### 通用参考

- `references/common/command-reference.md`
- `references/common/log-patterns.md`
- `references/common/software-packages.md`

### `vmcore` 深度参考

- `references/vmcore/crash_commands.md`
- `references/vmcore/analysis_patterns.md`
- `references/vmcore/root_cause_analysis.md`
- `references/vmcore/source_code_structure.md`
- `references/vmcore/struct_analysis.md`
- `references/vmcore/troubleshooting.md`

### 场景参考

- `references/scenarios/network-troubleshooting.md`
- `references/scenarios/boot-troubleshooting.md`
- `references/scenarios/container-troubleshooting.md`
- `references/scenarios/security-incident.md`

### OOM 专项参考

- `references/oom/system-oom-analysis.md`
- `references/oom/process-oom-analysis.md`
- `references/oom/cgroup-oom-analysis.md`
- `references/oom/kernel-oom-analysis.md`
- `references/oom/kernel-source-analysis.md`
