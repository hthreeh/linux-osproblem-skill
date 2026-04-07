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

- `scripts/vmcore/evidence_chain.sh`
- `scripts/vmcore/rca_wizard.sh`
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
