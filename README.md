# linux-osproblem-skill

`os-troubleshooter` 是一个面向 Linux OS 故障定位与根因分析的 Skill 仓库，覆盖以下场景：

- 内核崩溃：`panic`、`BUG`、`Oops`、`vmcore`、`crash`、`kdump`
- 用户态崩溃：`coredump`、`segfault`
- 系统挂起：`hang`、`hung task`、死锁、阻塞
- 性能问题：CPU、内存、IO、网络异常
- 通用系统问题：启动失败、容器、网络、存储、安全事件

仓库主体是 Skill 说明、参考资料和一组辅助脚本，适合被 Codex / ChatGPT 类技能系统加载，也可以单独拿脚本做现场辅助分析。

## 目录结构

- `SKILL.md`: Skill 主说明，定义适用范围、分流逻辑和分析方法
- `agents/openai.yaml`: agent 配置
- `assets/`: 报告模板
- `evals/`: 评测样例
- `references/`: 按主题整理的排障参考资料
- `scripts/`: 通用入口脚本
- `scripts/vmcore/`: `vmcore + crash` 深度分析脚本

## 主要脚本

- `scripts/diagnose.sh`: 总入口，支持 `auto/kernel/userspace/perf/hang/network/storage`
- `scripts/collect_info.sh`: 收集基础系统信息
- `scripts/quick_diagnosis.sh`: 快速自动分类（按 P1/P2 严重度排序检测）
- `scripts/vmcore/check_environment.sh`: 检查 `crash / vmlinux / vmcore` 环境
- `scripts/vmcore/crash_config.sh`: 保存和测试 `crash` 分析配置
- `scripts/vmcore/quick_report.sh`: 生成初步 crash 报告
- `scripts/vmcore/evidence_chain.sh`: 生成证据链（支持 `--batch` 批处理模式）
- `scripts/vmcore/rca_wizard.sh`: 交互式 RCA 向导（支持 `--batch` 批处理模式）
- `scripts/vmcore/analyze_struct.py`: 解析 crash 导出的结构体信息

`scripts/` 根目录中的部分脚本是 wrapper，会转发到 `scripts/vmcore/`。当前实现已经兼容“从 Windows 拷到 Linux 后脚本没有执行位”的常见场景。

## 快速使用

### 1. 通用分诊

```bash
bash scripts/diagnose.sh auto /tmp/os-diagnose
```

输出会落到目标目录，并生成 `SUMMARY.txt` 与归档包。

### 2. vmcore / crash 环境检查

```bash
bash scripts/vmcore/check_environment.sh \
  --crash-cmd crash \
  --vmlinux /path/to/vmlinux \
  --vmcore /path/to/vmcore
```

### 3. 保存 crash 配置

```bash
bash scripts/vmcore/crash_config.sh set \
  --vmlinux /path/to/vmlinux \
  --vmcore /path/to/vmcore

bash scripts/vmcore/crash_config.sh test
```

### 4. 交互式 RCA / 证据链

```bash
bash scripts/vmcore/evidence_chain.sh
bash scripts/vmcore/rca_wizard.sh
```

## 工件要求

### 完整 vmcore 分析

优先提供：

- `vmcore`
- 匹配内核版本的 `vmlinux`
- `crash` 工具

最小基线命令通常是：

```text
crash> sys
crash> log
crash> bt
```

### 只有 /var/crash/*.crash 时

如果现场没有完整 `vmcore`，只有 Ubuntu `apport` 生成的 `/var/crash/*.crash`，仍然可以从其中内嵌的 `VmCoreDmesg` 提取 panic / BUG / Oops 关键信息，但不能替代完整 `crash + vmcore` 交互分析。

## 当前验证状态

这套 Skill 已做过一轮真实 Linux 验证：

- Ubuntu 24.04 虚机上验证了 `diagnose.sh auto`
- 验证了 `scripts/vmcore/*.sh` 在无执行位权限下仍可通过 wrapper 正常运行
- 验证了 `crash_config.sh` 能正确处理带空格路径
- 验证了 `analyze_struct.py` 对 `task_struct.state` 的解析
- 验证了 `evidence_chain.sh` 和 `rca_wizard.sh` 的交互输出不会污染最终报告
- 验证了真实 `/var/crash/*.crash` 工件可提取出有效内核崩溃结论

## 已知边界

- 没有 `vmcore + vmlinux` 时，不能做完整 `crash` 深挖
- 仓库中的部分中文文档在某些 Windows 终端可能显示乱码，但文件本身为 UTF-8，可在 Linux / 正常 UTF-8 环境中使用
- `scripts/vmcore/` 适合做辅助分析，不替代现场工程师对 `crash` 输出的最终判断

## 适合的仓库定位

这个仓库更适合被当作：

- Codex / ChatGPT Skill 仓库
- Linux OS 问题排障知识库
- 现场辅助分析脚本集合

如果你准备继续维护，建议下一步补：

- `README` 中的更多样例输入/输出
- 基于真实样本的回归测试数据（`evals/` 目录）
