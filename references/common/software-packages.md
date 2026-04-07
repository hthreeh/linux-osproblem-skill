# 软件包责任领域表

本文档列出了基于openEuler的发行版中常用软件包的责任领域分类，用于快速定位问题责任方。

---

## 软件包分类表

### Q1级别 - 高优先级（核心组件）

| 软件包 | 责任领域 | 说明 |
|--------|----------|------|
| kernel | compute | 内核核心，包括调度、内存管理、文件系统、驱动等 |
| glibc | compute | GNU C库，用户态程序的基础运行库 |
| libvirt | virt | 虚拟化API和守护进程 |
| qemu | virt | 处理器模拟器和虚拟化 |
| docker | virt | 容器运行时 |
| runc | virt | OCI容器运行时 |
| openvswitch | virt | 虚拟交换机 |
| dpdk | virt | 数据平面开发套件 |
| kpatch | compute | 内核热补丁 |
| containerd | virt | 容器运行时 |

### Q2级别 - 中等优先级

#### 基础系统组件

| 软件包 | 责任领域 | 说明 |
|--------|----------|------|
| acl | base | 访问控制列表 |
| audit | base | 审计子系统 |
| bash | base | Bash shell |
| coreutils | base | 核心工具集 |
| dbus | base | D-Bus消息系统 |
| gnutls | base | GnuTLS加密库 |
| grub2 | base | GRUB2引导加载器 |
| libseccomp | base | seccomp库 |
| libselinux | base | SELinux库 |
| openldap | base | LDAP客户端库 |
| openssh | base | SSH客户端和服务端 |
| openssl | base | OpenSSL加密库 |
| python3 | base | Python解释器 |
| rsyslog | base | 系统日志守护进程 |
| secGear | base | 安全计算框架 |
| security-tool | base | 安全工具集 |

#### 计算相关组件

| 软件包 | 责任领域 | 说明 |
|--------|----------|------|
| bcache-tools | compute | Bcache工具 |
| dhcp | compute | DHCP客户端/服务端 |
| dracut | compute | initramfs生成工具 |
| e2fsprogs | compute | ext2/3/4文件系统工具 |
| edk2 | compute | UEFI固件 |
| fuse | compute | FUSE文件系统 |
| fuse3 | compute | FUSE3文件系统 |
| gcc | compute | GNU编译器集合 |
| kata-containers | compute | Kata容器 |
| libaio | compute | 异步IO库 |
| libbpf | compute | BPF库 |
| libhugetlbfs | compute | 大页文件系统库 |
| libsolv | compute | 包依赖解析 |
| lvm2 | compute | LVM2工具 |
| numactl | compute | NUMA控制工具 |

#### 虚拟化相关组件

| 软件包 | 责任领域 | 说明 |
|--------|----------|------|
| anaconda | tool | 安装程序 |
| ansible | tool | 自动化配置工具 |
| arptables | virt | ARP防火墙 |
| container-selinux | virt | 容器SELinux策略 |
| corosync | tool | 集群通信层 |
| corosync-qdevice | tool | 集群仲裁设备 |
| iproute | virt | 网络配置工具 |
| iptables | virt | 防火墙工具 |
| iputils | virt | 网络工具集 |
| irqbalance | virt | 中断负载均衡 |
| libvirt-glib | virt | libvirt GLib封装 |
| NetworkManager | virt | 网络管理服务 |
| numad | tool | NUMA守护进程 |

#### 工具类组件

| 软件包 | 责任领域 | 说明 |
|--------|----------|------|
| dnf | tool | 包管理器 |
| etmem | compute | 内存管理工具 |
| install-scripts | tool | 安装脚本 |
| intel-sgx-ssl | base | Intel SGX SSL |
| kmod | compute | 内核模块工具 |
| rpm-ostree | tool | 原子化更新 |

---

## 责任领域说明

### compute（计算领域）
- 内核核心功能
- CPU调度
- 内存管理
- 文件系统
- 进程管理
- 编译工具链

### virt（虚拟化领域）
- 虚拟机管理
- 容器运行时
- 网络虚拟化
- 存储虚拟化
- 虚拟化安全

### base（基础领域）
- 系统基础库
- 安全框架
- 认证授权
- 日志系统
- Shell和工具

### tool（工具领域）
- 系统管理工具
- 配置管理
- 包管理
- 集群管理

---

## 问题定位流程

当问题涉及特定软件包时：

```
1. 确定问题软件包
   ├── 从日志/调用栈识别
   └── 从功能推测

2. 查找责任领域
   └── 参考上表

3. 确定代码仓库
   ├── Q1级别：优先级高，需要快速响应
   └── Q2级别：标准处理流程

4. 定位相关代码
   ├── 软件包源码位置
   ├── 内核相关代码
   └── 测试用例

5. 分析和修复
   ├── 代码审查
   ├── 测试验证
   └── 发布补丁
```

---

## 常见问题软件包对照

| 问题现象 | 可能涉及的软件包 | 检查命令 |
|----------|------------------|----------|
| 系统崩溃 | kernel | dmesg, crash |
| 内存问题 | kernel, glibc | vmstat, pmap |
| 网络问题 | kernel, NetworkManager, iptables | ss, ip, iptables |
| 存储问题 | kernel, lvm2, e2fsprogs | iostat, df, mount |
| 容器问题 | docker, containerd, runc, libvirt | docker logs, journalctl |
| 安全问题 | selinux, audit, openssl | ausearch, getenforce |
| 启动问题 | grub2, dracut, systemd | journalctl, grub2-editenv |
