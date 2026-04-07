# 容器与虚拟化故障诊断指南

本文档详细介绍容器和虚拟化环境（Docker/Podman、Kubernetes、KVM/QEMU）的常见故障及诊断方法，适用于 Linux（特别是 openEuler）环境。

---

## 1. 概述

### 1.1 容器 vs 虚拟机架构对比

| 对比维度 | 容器 | 虚拟机 |
|----------|------|--------|
| 隔离级别 | 进程级（namespace + cgroup） | 硬件级（Hypervisor） |
| 内核 | 共享宿主机内核 | 独立内核 |
| 启动速度 | 秒级 | 分钟级 |
| 资源开销 | 极小 | 较大（需完整OS） |
| 安全性 | 依赖内核隔离机制 | 硬件辅助隔离，更强 |
| 典型技术 | Docker、Podman、containerd | KVM/QEMU、libvirt |

### 1.2 常见问题分类

| 问题分类 | 容器 | 虚拟机 |
|----------|------|--------|
| 启动失败 | OCI运行时错误、镜像拉取失败 | 硬件虚拟化未启用、磁盘镜像损坏 |
| 性能问题 | cgroup限制命中、CPU throttle | 缺少KVM加速、virtio驱动缺失 |
| 网络故障 | CNI插件故障、iptables规则异常 | 虚拟网桥配置错误 |
| 存储问题 | overlay文件系统异常、inode耗尽 | 磁盘镜像格式/扩容问题 |

---

## 2. 容器故障诊断

### 2.1 容器启动失败

#### OCI运行时错误

**特征**：
```
Error response from daemon: OCI runtime create failed: container_linux.go:380:
starting container process caused: exec: "/app": permission denied
```

**分析步骤**：
1. 查看容器状态和退出码：`docker inspect <container> --format='{{.State.ExitCode}}'`
2. 查看详细日志：`docker logs <container>` 或 `journalctl -u docker`
3. 检查容器配置：`docker inspect <container>`
4. 尝试以交互模式启动排查：`docker run -it --entrypoint /bin/sh <image>`

**常见退出码**：

| 退出码 | 含义 | 排查方向 |
|--------|------|----------|
| 0 | 正常退出 | 检查entrypoint/cmd是否为一次性命令 |
| 1 | 应用错误 | 查看应用日志 |
| 125 | Docker daemon错误 | 检查daemon日志 |
| 126 | 命令不可执行 | 检查文件权限 |
| 127 | 命令未找到 | 检查entrypoint/cmd路径 |
| 137 | 被SIGKILL杀死 | 检查OOM或手动kill |
| 139 | 段错误（SIGSEGV） | 应用程序bug |

#### 镜像拉取失败

**常见原因及排查**：
```bash
# 检查DNS解析
nslookup registry-1.docker.io

# 检查网络连通性
curl -v https://registry-1.docker.io/v2/

# 检查代理配置
cat /etc/systemd/system/docker.service.d/http-proxy.conf

# 检查镜像仓库认证
cat ~/.docker/config.json
```

#### 存储驱动问题

| 存储驱动 | 常见问题 | 排查命令 |
|----------|----------|----------|
| overlay2 | inode耗尽、层数限制 | `df -i`、`docker system df` |
| devicemapper | thin pool空间不足 | `lvs`、`dmsetup status` |
| btrfs | 子卷损坏 | `btrfs filesystem show` |

```bash
# 查看当前存储驱动
docker info | grep "Storage Driver"

# overlay2目录分析
du -sh /var/lib/docker/overlay2/*
ls /var/lib/docker/overlay2/ | wc -l
```

#### 权限问题（rootless容器）

**排查**：
```bash
# 检查用户命名空间映射
cat /etc/subuid
cat /etc/subgid

# 检查内核参数
sysctl user.max_user_namespaces

# Podman rootless容器信息
podman info | grep -A5 store
podman unshare cat /proc/self/uid_map
```

---

### 2.2 容器运行时问题

#### 容器内进程崩溃

**诊断流程**：
```bash
# 1. 查看容器日志
docker logs --tail 100 <container>

# 2. 检查容器最后退出状态
docker inspect <container> | grep -A 10 '"State"'

# 3. 进入容器调试（运行中容器）
docker exec -it <container> /bin/sh

# 4. 检查coredump（需要宿主机配合）
cat /proc/sys/kernel/core_pattern
# 如果是 |/usr/lib/systemd/systemd-coredump 形式
coredumpctl list
```

#### 容器内OOM（cgroup级别）

**区分系统级OOM与cgroup级OOM**：

| 类型 | 日志特征 | 触发条件 |
|------|----------|----------|
| 系统级OOM | `Out of memory: Kill process` | 系统总内存耗尽 |
| cgroup级OOM | `Memory cgroup out of memory` | 容器超出内存限制 |

**cgroup v1 内存分析**：
```bash
# 查找容器的cgroup路径
CGPATH=$(docker inspect <container> --format='{{.HostConfig.CgroupParent}}')

# 内存使用情况
cat /sys/fs/cgroup/memory/$CGPATH/memory.usage_in_bytes
cat /sys/fs/cgroup/memory/$CGPATH/memory.limit_in_bytes

# OOM次数统计
cat /sys/fs/cgroup/memory/$CGPATH/memory.oom_control

# 内存详细统计
cat /sys/fs/cgroup/memory/$CGPATH/memory.stat
```

**cgroup v2 内存分析**：
```bash
# 内存使用情况
cat /sys/fs/cgroup/<slice>/memory.current
cat /sys/fs/cgroup/<slice>/memory.max

# OOM事件统计
cat /sys/fs/cgroup/<slice>/memory.events
# 关注 oom 和 oom_kill 字段
```

**监控工具对比**：

| 工具 | 用途 | 命令 |
|------|------|------|
| docker stats | 实时资源使用 | `docker stats --no-stream` |
| cadvisor | 历史监控与导出 | 运行cadvisor容器 |
| cgroup文件系统 | 底层精确数据 | 直接读取cgroup文件 |

#### 容器资源限制命中

**CPU Throttling分析**：
```bash
# cgroup v1
cat /sys/fs/cgroup/cpu/$CGPATH/cpu.stat
# nr_periods: 调度周期总数
# nr_throttled: 被限制的周期数
# throttled_time: 被限制的总时间（纳秒）

# 限制比例计算
# throttle_ratio = nr_throttled / nr_periods
# 若 > 20%，说明CPU限制过紧

# cgroup v2
cat /sys/fs/cgroup/<slice>/cpu.stat
```

**PID限制**：
```bash
# 查看PID限制
cat /sys/fs/cgroup/pids/$CGPATH/pids.max
cat /sys/fs/cgroup/pids/$CGPATH/pids.current
```

---

### 2.3 容器网络故障

#### DNS解析失败

**诊断步骤**：
```bash
# 1. 检查容器DNS配置
docker exec <container> cat /etc/resolv.conf

# 2. 从容器内测试DNS
docker exec <container> nslookup google.com

# 3. 检查Docker内置DNS
iptables -t nat -L -n | grep 127.0.0.11

# 4. 检查docker0网桥DNS转发
cat /etc/docker/daemon.json | grep dns
```

#### 端口映射问题

**排查**：
```bash
# 查看端口映射
docker port <container>

# 检查iptables NAT规则
iptables -t nat -L DOCKER -n -v

# 检查宿主机端口占用
ss -tlnp | grep <port>

# 检查docker-proxy进程
ps aux | grep docker-proxy
```

#### CNI插件故障

**排查**：
```bash
# 检查CNI配置
ls /etc/cni/net.d/
cat /etc/cni/net.d/*.conflist

# 检查CNI二进制
ls /opt/cni/bin/

# 检查网络接口
ip link show type bridge
ip link show type veth
```

#### 网络命名空间诊断

```bash
# 获取容器PID
PID=$(docker inspect <container> --format='{{.State.Pid}}')

# 进入容器网络命名空间
nsenter -t $PID -n ip addr
nsenter -t $PID -n ip route
nsenter -t $PID -n iptables -L -n
nsenter -t $PID -n ss -tlnp

# 列出所有网络命名空间
ip netns list
lsns -t net
```

#### iptables NAT规则

**关键规则链**：

| 链 | 用途 | 检查命令 |
|----|------|----------|
| DOCKER | 端口映射 DNAT | `iptables -t nat -L DOCKER -n` |
| DOCKER-ISOLATION | 网络隔离 | `iptables -L DOCKER-ISOLATION-STAGE-1 -n` |
| MASQUERADE | 容器出站 SNAT | `iptables -t nat -L POSTROUTING -n` |

---

### 2.4 容器存储问题

#### 数据卷挂载失败

**常见原因**：
```bash
# 1. 路径不存在
ls -la <host_path>

# 2. 权限不足
# SELinux上下文问题（openEuler默认启用SELinux）
ls -Z <host_path>
# 使用 :z 或 :Z 选项
docker run -v /data:/data:z <image>

# 3. 挂载传播问题
findmnt | grep <path>
mount --make-shared <path>
```

#### overlay文件系统问题

```bash
# 检查overlay挂载状态
mount | grep overlay

# 检查overlay层数（某些旧内核限制128层）
docker inspect <image> | grep -c '"sha256:'

# 检查overlay元数据
ls /var/lib/docker/overlay2/
cat /var/lib/docker/image/overlay2/layerdb/sha256/*/diff
```

#### 磁盘空间清理

```bash
# Docker磁盘使用概览
docker system df
docker system df -v

# 清理策略
docker system prune              # 清理悬空资源
docker system prune -a           # 清理全部未使用资源
docker image prune -a            # 清理未使用镜像
docker volume prune              # 清理未使用卷
docker builder prune             # 清理构建缓存

# 检查各目录大小
du -sh /var/lib/docker/overlay2/
du -sh /var/lib/docker/volumes/
du -sh /var/lib/docker/containers/
```

---

### 2.5 containerd/docker daemon问题

#### daemon无法启动

**排查流程**：
```bash
# 1. 查看服务状态
systemctl status docker
systemctl status containerd

# 2. 查看详细日志
journalctl -xeu docker --no-pager | tail -50
journalctl -xeu containerd --no-pager | tail -50

# 3. 检查配置文件语法
dockerd --validate
cat /etc/docker/daemon.json | python3 -m json.tool

# 4. 检查存储目录权限
ls -la /var/lib/docker/
ls -la /run/docker.sock
```

**常见错误**：

| 错误 | 原因 | 修复 |
|------|------|------|
| `failed to start daemon: pid file found` | daemon异常退出未清理 | 删除 `/var/run/docker.pid` |
| `failed to mount overlay: invalid argument` | 内核不支持overlay2 | 检查内核版本，切换存储驱动 |
| `error initializing network controller` | 网络冲突 | 检查docker0网桥，清理iptables |

#### daemon性能问题

```bash
# 检查daemon事件流
docker events --since 10m

# 检查容器数量
docker ps -a | wc -l

# 检查daemon内存使用
ps aux | grep dockerd
cat /proc/$(pidof dockerd)/status | grep VmRSS

# 检查containerd shim进程数
ps aux | grep containerd-shim | wc -l
```

---

## 3. Kubernetes问题定位（基础）

### 3.1 Pod问题

#### 常见Pod状态及排查

| Pod状态 | 含义 | 排查命令 |
|---------|------|----------|
| CrashLoopBackOff | 容器反复崩溃 | `kubectl logs <pod> --previous` |
| ImagePullBackOff | 镜像拉取失败 | `kubectl describe pod <pod>` |
| Pending | 未调度 | `kubectl describe pod <pod>`（查看Events） |
| OOMKilled | 内存超限 | `kubectl describe pod <pod>`（查看lastState） |
| ContainerCreating | 容器创建中 | `kubectl describe pod <pod>`（查看卷挂载/网络） |
| Init:Error | Init容器失败 | `kubectl logs <pod> -c <init-container>` |

#### CrashLoopBackOff 诊断

```bash
# 1. 查看Pod事件
kubectl describe pod <pod> -n <namespace>

# 2. 查看当前容器日志
kubectl logs <pod> -n <namespace>

# 3. 查看上一次崩溃日志
kubectl logs <pod> -n <namespace> --previous

# 4. 检查退出码
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'

# 5. 检查资源限制
kubectl get pod <pod> -o jsonpath='{.spec.containers[0].resources}'
```

#### OOMKilled 诊断

```bash
# 确认OOMKilled
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'

# 查看内存限制
kubectl get pod <pod> -o yaml | grep -A 5 resources

# 查看节点级OOM事件
dmesg | grep -i "oom\|killed"
journalctl -k | grep -i oom
```

---

### 3.2 节点问题

#### NotReady状态

**排查流程**：
```bash
# 1. 查看节点状态
kubectl get nodes
kubectl describe node <node>

# 2. 检查节点条件
kubectl get node <node> -o jsonpath='{.status.conditions[*]}' | python3 -m json.tool

# 3. 检查kubelet状态
systemctl status kubelet
journalctl -xeu kubelet --no-pager | tail -50

# 4. 检查容器运行时
crictl info
crictl ps -a
```

#### 资源压力

| 条件 | 含义 | 排查 |
|------|------|------|
| DiskPressure | 磁盘空间不足 | `df -h`、清理镜像和日志 |
| MemoryPressure | 内存不足 | `free -h`、检查Pod内存使用 |
| PIDPressure | PID数不足 | `ls /proc \| wc -l`、检查PID限制 |

```bash
# 查看节点资源分配情况
kubectl describe node <node> | grep -A 10 "Allocated resources"

# 查看节点上Pod资源请求
kubectl get pods --field-selector spec.nodeName=<node> \
  -o custom-columns="NAME:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory"
```

---

## 4. KVM/QEMU虚拟化故障

### 4.1 虚拟机无法启动

#### 硬件虚拟化检查

```bash
# 检查CPU是否支持虚拟化
grep -Ec '(vmx|svm)' /proc/cpuinfo

# 检查KVM模块是否加载
lsmod | grep kvm

# 手动加载KVM模块
modprobe kvm
modprobe kvm_intel  # Intel
modprobe kvm_amd    # AMD

# 检查/dev/kvm权限
ls -la /dev/kvm
```

**常见错误**：

| 错误 | 原因 | 修复 |
|------|------|------|
| `KVM not available` | BIOS未启用VT-x/AMD-V | 进BIOS启用虚拟化 |
| `/dev/kvm: Permission denied` | 用户无权限 | 将用户加入kvm组 |
| `kvm_intel: nested not supported` | 嵌套虚拟化未启用 | `echo 1 > /sys/module/kvm_intel/parameters/nested` |

#### QEMU参数错误

```bash
# 检查QEMU版本
qemu-system-x86_64 --version

# 验证磁盘镜像完整性
qemu-img check <image.qcow2>
qemu-img info <image.qcow2>

# 常见启动参数验证
# -m 指定内存需在宿主机可用范围内
# -smp 指定CPU数需在合理范围
# -drive 磁盘文件路径需正确
```

#### 磁盘镜像问题

```bash
# 检查镜像信息
qemu-img info <image.qcow2>

# 检查镜像完整性
qemu-img check <image.qcow2>

# 修复镜像（谨慎使用）
qemu-img check -r all <image.qcow2>

# 转换镜像格式
qemu-img convert -f raw -O qcow2 disk.raw disk.qcow2
```

---

### 4.2 虚拟机性能问题

#### CPU性能诊断

**确认KVM加速是否生效**：
```bash
# 检查QEMU进程是否使用KVM
ps aux | grep qemu
# 应包含 -enable-kvm 或 -accel kvm

# 检查虚拟机内部
# 若看到 "QEMU Virtual CPU" 说明未使用KVM透传
cat /proc/cpuinfo | grep "model name"
# KVM透传应显示宿主机CPU型号
```

**CPU型号与特性**：

| CPU模式 | 含义 | 性能影响 |
|---------|------|----------|
| `-cpu host` | 透传宿主机CPU | 最佳性能 |
| `-cpu qemu64` | QEMU模拟CPU | 性能较差，缺少高级指令 |
| `-cpu SandyBridge` | 指定CPU型号 | 适用于迁移兼容性 |

#### IO性能诊断

**virtio vs 模拟设备对比**：

| 设备类型 | 磁盘 | 网络 | 性能差异 |
|----------|------|------|----------|
| virtio | virtio-blk/scsi | virtio-net | 接近原生性能 |
| 模拟设备 | IDE/SATA | e1000/rtl8139 | 性能差数倍 |

```bash
# 确认是否使用virtio
virsh dumpxml <vm> | grep -i virtio

# 磁盘IO测试（虚拟机内部）
fio --name=randwrite --ioengine=libaio --bs=4k --numjobs=4 \
    --size=1G --runtime=60 --rw=randwrite --direct=1

# IO调度器优化（宿主机）
cat /sys/block/sda/queue/scheduler
echo none > /sys/block/sda/queue/scheduler  # SSD推荐
```

#### 内存分配与balloon驱动

```bash
# 检查balloon驱动状态
virsh dommemstat <vm>

# 调整balloon内存
virsh setmem <vm> 4G --live

# 检查大页内存
cat /proc/meminfo | grep HugePages
# 为虚拟机启用大页内存可提升性能
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
```

#### NUMA配置优化

```bash
# 查看宿主机NUMA拓扑
numactl --hardware
lscpu | grep NUMA

# 查看虚拟机NUMA绑定
virsh numatune <vm>
virsh vcpupin <vm>

# 检查NUMA内存分配策略
numastat -c qemu-system
```

---

### 4.3 virtio驱动问题

#### 驱动检查

```bash
# 虚拟机内检查virtio模块
lsmod | grep virtio

# 常见virtio模块
# virtio_blk     - 块设备驱动
# virtio_net     - 网络驱动
# virtio_scsi    - SCSI控制器
# virtio_balloon - 内存气球驱动
# virtio_console - 控制台驱动

# 手动加载缺失驱动
modprobe virtio_blk
modprobe virtio_net
```

#### 设备热插拔故障

```bash
# 热插磁盘
virsh attach-disk <vm> /path/to/disk.qcow2 vdb --driver qemu --subdriver qcow2

# 热插网卡
virsh attach-interface <vm> --type bridge --source br0 --model virtio

# 检查热插拔是否生效（虚拟机内部）
dmesg | tail -20
lsblk
ip link show
```

---

### 4.4 libvirt管理问题

#### libvirtd故障

```bash
# 检查libvirtd状态
systemctl status libvirtd
journalctl -xeu libvirtd --no-pager | tail -30

# 检查连接
virsh -c qemu:///system list --all

# 常见问题：socket权限
ls -la /var/run/libvirt/libvirt-sock
# 确保用户在libvirt组中
groups $USER | grep libvirt
```

#### 虚拟机迁移失败

**常见迁移错误**：

| 错误 | 原因 | 修复 |
|------|------|------|
| `unable to connect to server` | 目标主机libvirtd未运行 | 启动目标主机libvirtd |
| `unsupported configuration: CPU model` | CPU型号不兼容 | 使用通用CPU型号或host-model |
| `missing shared storage` | 共享存储未配置 | 配置NFS/Ceph共享存储 |
| `migration timed out` | 内存脏页率过高 | 设置downtime，降低负载后迁移 |

```bash
# 实时迁移
virsh migrate --live <vm> qemu+ssh://target/system

# 检查迁移进度
virsh domjobinfo <vm>
```

#### 存储池问题

```bash
# 列出存储池
virsh pool-list --all

# 检查存储池状态
virsh pool-info <pool>

# 刷新存储池
virsh pool-refresh <pool>

# 重新定义损坏的存储池
virsh pool-destroy <pool>
virsh pool-start <pool>
```

---

## 5. 资源隔离问题

### 5.1 cgroup分析

#### cgroup v1 vs v2 对比

| 特性 | cgroup v1 | cgroup v2 |
|------|-----------|-----------|
| 层级结构 | 多层级（每个控制器独立） | 统一层级 |
| 根路径 | `/sys/fs/cgroup/<controller>/` | `/sys/fs/cgroup/` |
| 内存控制 | `memory.limit_in_bytes` | `memory.max` |
| CPU控制 | `cpu.cfs_quota_us` | `cpu.max` |
| IO控制 | `blkio.*` | `io.*` |
| 系统支持 | openEuler 20.03/22.03 | openEuler 22.03+（可选） |

**确认cgroup版本**：
```bash
# 检查cgroup版本
stat -fc %T /sys/fs/cgroup/
# tmpfs → cgroup v1
# cgroup2fs → cgroup v2

# 或检查挂载
mount | grep cgroup
```

#### 资源限制查看

```bash
# cgroup v1 - 查看容器内存限制
cat /sys/fs/cgroup/memory/docker/<container_id>/memory.limit_in_bytes
cat /sys/fs/cgroup/memory/docker/<container_id>/memory.usage_in_bytes
cat /sys/fs/cgroup/memory/docker/<container_id>/memory.max_usage_in_bytes

# cgroup v1 - 查看CPU限制
cat /sys/fs/cgroup/cpu/docker/<container_id>/cpu.cfs_quota_us
cat /sys/fs/cgroup/cpu/docker/<container_id>/cpu.cfs_period_us
# 实际CPU限制 = quota / period（以核为单位）

# cgroup v2 - 统一目录
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/memory.max
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.max
```

#### cgroup级OOM诊断

```bash
# 1. 确认OOM发生
dmesg | grep "memory cgroup out of memory"

# 2. 查看OOM统计
# cgroup v1
cat /sys/fs/cgroup/memory/<path>/memory.oom_control
# oom_kill_disable: 是否禁用OOM killer
# under_oom: 当前是否处于OOM状态

# cgroup v2
cat /sys/fs/cgroup/<path>/memory.events
# oom: OOM发生次数
# oom_kill: OOM killer杀死进程次数
# oom_group_kill: 整组OOM kill次数

# 3. 查看内存详细分布
cat /sys/fs/cgroup/memory/<path>/memory.stat
# 关注 rss, cache, swap 字段
```

---

### 5.2 namespace隔离

#### namespace类型

| namespace | 隔离内容 | 标志 | 查看命令 |
|-----------|----------|------|----------|
| PID | 进程ID | CLONE_NEWPID | `lsns -t pid` |
| NET | 网络栈 | CLONE_NEWNET | `lsns -t net` |
| MNT | 挂载点 | CLONE_NEWNS | `lsns -t mnt` |
| USER | 用户/组ID | CLONE_NEWUSER | `lsns -t user` |
| IPC | 进程间通信 | CLONE_NEWIPC | `lsns -t ipc` |
| UTS | 主机名/域名 | CLONE_NEWUTS | `lsns -t uts` |
| CGROUP | cgroup根目录 | CLONE_NEWCGROUP | `lsns -t cgroup` |

#### namespace泄漏检测

```bash
# 列出所有namespace
lsns

# 检查namespace数量是否异常增长
lsns | wc -l

# 检查无进程引用的namespace（可能的泄漏）
# 对比 /proc/*/ns/ 与已知容器
find /proc/*/ns -maxdepth 0 2>/dev/null | wc -l

# 检查bind mount的namespace
findmnt -t nsfs
```

#### nsenter诊断

```bash
# 进入容器的所有namespace
PID=$(docker inspect <container> --format='{{.State.Pid}}')
nsenter -t $PID -m -u -i -n -p -- /bin/sh

# 只进入网络namespace
nsenter -t $PID -n -- ip addr
nsenter -t $PID -n -- ss -tlnp
nsenter -t $PID -n -- ping <target>

# 只进入PID namespace
nsenter -t $PID -p -- ps aux

# 只进入挂载namespace
nsenter -t $PID -m -- df -h
nsenter -t $PID -m -- cat /etc/resolv.conf
```

---

## 6. 诊断工具

### 6.1 容器诊断工具

| 工具 | 用途 | 常用命令 |
|------|------|----------|
| docker inspect | 查看容器详细配置 | `docker inspect <container>` |
| docker logs | 查看容器日志 | `docker logs --tail 100 -f <container>` |
| docker stats | 实时资源监控 | `docker stats --no-stream` |
| docker top | 查看容器内进程 | `docker top <container>` |
| docker diff | 查看文件系统变更 | `docker diff <container>` |
| docker events | daemon事件流 | `docker events --since 1h` |
| crictl | CRI运行时调试 | `crictl ps`、`crictl logs` |
| ctr | containerd低级调试 | `ctr containers list` |
| nerdctl | containerd兼容CLI | `nerdctl ps` |

### 6.2 虚拟化诊断工具

| 工具 | 用途 | 常用命令 |
|------|------|----------|
| virsh | libvirt虚拟机管理 | `virsh list --all`、`virsh dominfo <vm>` |
| virt-top | 虚拟机资源监控 | `virt-top` |
| qemu-img | 磁盘镜像管理 | `qemu-img info`、`qemu-img check` |
| qemu-monitor | QEMU交互调试 | Ctrl+Alt+2 或 `-monitor stdio` |
| virsh domblkstat | 块设备统计 | `virsh domblkstat <vm> vda` |
| virsh domifstat | 网络接口统计 | `virsh domifstat <vm> vnet0` |

---

## 7. 常见案例

### 案例1：cgroup内存限制导致OOMKilled

**现象**：容器频繁重启，`docker inspect` 显示 `OOMKilled: true`。

**分析过程**：
```bash
# 1. 确认OOM
docker inspect <container> | grep OOMKilled
# "OOMKilled": true

# 2. 查看容器内存限制
docker inspect <container> --format='{{.HostConfig.Memory}}'
# 536870912 (512MB)

# 3. 查看dmesg确认cgroup级OOM
dmesg | grep -A 5 "memory cgroup out of memory"
# Task in /docker/<id> killed as a result of limit of /docker/<id>

# 4. 查看内存使用峰值
cat /sys/fs/cgroup/memory/docker/<id>/memory.max_usage_in_bytes
```

**解决方案**：
- 增大容器内存限制：`docker update --memory 1g <container>`
- 优化应用内存使用
- 配置内存预留：`--memory-reservation`

---

### 案例2：iptables NAT规则丢失导致容器网络不通

**现象**：容器无法访问外部网络，宿主机网络正常。

**分析过程**：
```bash
# 1. 检查容器内网络
docker exec <container> ping 8.8.8.8
# ping: connect: Network is unreachable

# 2. 检查iptables NAT规则
iptables -t nat -L POSTROUTING -n
# 缺少 MASQUERADE 规则

# 3. 检查FORWARD链
iptables -L FORWARD -n
# 策略为DROP，缺少Docker FORWARD规则
```

**解决方案**：
```bash
# 重新生成Docker iptables规则
systemctl restart docker

# 或手动添加MASQUERADE
iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE

# 防止其他服务（如firewalld）清除Docker规则
# 在 /etc/docker/daemon.json 中设置
# { "iptables": true }
```

---

### 案例3：overlay2 inode耗尽

**现象**：`docker pull` 或 `docker build` 报错 `no space left on device`，但 `df -h` 显示空间充足。

**分析过程**：
```bash
# 1. 检查inode使用
df -i /var/lib/docker
# Inodes    IUsed    IFree  IUse%
# 1000000   999998   2      100%

# 2. 分析占用
find /var/lib/docker/overlay2 -maxdepth 2 -type d | wc -l

# 3. 查看Docker磁盘使用
docker system df
```

**解决方案**：
```bash
# 1. 清理未使用镜像和容器
docker system prune -a -f

# 2. 如问题持续，考虑独立分区或XFS文件系统
# XFS默认inode分配更灵活
mkfs.xfs /dev/sdX
```

---

### 案例4：KVM性能差因缺少virtio驱动

**现象**：虚拟机磁盘IO极慢，网络吞吐低。

**分析过程**：
```bash
# 1. 检查虚拟机磁盘接口类型
virsh dumpxml <vm> | grep "target dev"
# <target dev='hda' bus='ide'/>  ← IDE模拟，性能差

# 2. 检查网卡类型
virsh dumpxml <vm> | grep "model type"
# <model type='e1000'/>  ← 模拟网卡，性能差

# 3. 虚拟机内确认无virtio模块
lsmod | grep virtio
# （空输出）
```

**解决方案**：
```bash
# 1. 关闭虚拟机
virsh shutdown <vm>

# 2. 修改磁盘为virtio
virsh edit <vm>
# 将 bus='ide' 改为 bus='virtio'
# 将 dev='hda' 改为 dev='vda'

# 3. 修改网卡为virtio
# 将 model type='e1000' 改为 model type='virtio'

# 4. 确保虚拟机内有virtio驱动（启动后）
modprobe virtio_blk virtio_net virtio_scsi
```

---

## 8. 预防措施

### 8.1 容器环境

| 类别 | 预防措施 | 实施方式 |
|------|----------|----------|
| 资源限制 | 始终设置内存和CPU限制 | `--memory`、`--cpus` 参数 |
| 日志管理 | 限制容器日志大小 | daemon.json 中配置 `log-opts` |
| 磁盘清理 | 定期清理未使用资源 | cron + `docker system prune` |
| 镜像安全 | 使用可信镜像，定期扫描 | `trivy image <image>` |
| 监控告警 | 部署容器监控 | Prometheus + cAdvisor + Grafana |
| 健康检查 | 配置HEALTHCHECK | Dockerfile 或 compose 中配置 |

### 8.2 虚拟化环境

| 类别 | 预防措施 | 实施方式 |
|------|----------|----------|
| 性能优化 | 始终启用KVM加速和virtio驱动 | `-enable-kvm`、`bus='virtio'` |
| NUMA感知 | 正确配置NUMA亲和性 | `virsh numatune`、`virsh vcpupin` |
| 备份 | 定期快照和备份磁盘镜像 | `virsh snapshot-create`、`qemu-img` |
| 资源规划 | 避免过度分配CPU/内存 | 监控宿主机资源使用率 |
| 大页内存 | 高性能场景启用大页 | `hugepages` 配置 |
| 迁移兼容 | 使用通用CPU型号 | `-cpu host-model` 或指定通用型号 |

### 8.3 通用建议

```bash
# 定期检查脚本示例

# 1. 检查容器健康状态
docker ps --filter "status=exited" --format "{{.Names}}: {{.Status}}"

# 2. 检查磁盘空间
docker system df
df -h /var/lib/docker

# 3. 检查cgroup OOM事件
dmesg | grep -c "oom_kill"

# 4. 检查虚拟机状态
virsh list --all | grep -v running

# 5. 检查KVM模块状态
lsmod | grep kvm
```
