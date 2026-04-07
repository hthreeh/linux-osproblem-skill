# 启动故障诊断指南

本文档详细介绍Linux系统（尤其是openEuler）的启动故障诊断方法，涵盖从固件到用户空间的完整启动链。

---

## 1. Linux启动流程概述

```
BIOS/UEFI ──▶ GRUB2 ──▶ Kernel ──▶ initramfs ──▶ systemd ──▶ multi-user
 (固件层)     (引导层)   (内核层)    (初始根FS)    (初始化)    (用户空间)
```

| 阶段 | 主要任务 | 常见故障 |
|------|----------|----------|
| **BIOS/UEFI** | 硬件自检（POST）、加载引导程序 | 硬件故障、引导顺序错误、安全启动阻止 |
| **GRUB2** | 加载内核和initramfs | MBR/GPT损坏、配置丢失、文件缺失 |
| **Kernel** | 初始化硬件驱动、建立基本运行环境 | 内核镜像损坏、参数错误、驱动缺失 |
| **initramfs** | 挂载根文件系统、激活LVM/RAID | initramfs损坏、UUID不匹配、LVM故障 |
| **systemd** | 启动系统服务、挂载文件系统 | 服务失败、依赖问题、fstab错误 |
| **multi-user** | 完成用户空间初始化 | 登录服务故障、网络配置错误 |

---

## 2. GRUB引导故障

### 2.1 GRUB无法加载

**典型表现**：
```
error: no such partition.
Entering rescue mode...
grub rescue>
```

**常见原因**：

| 原因 | 说明 | 检查方法 |
|------|------|----------|
| MBR损坏 | 前446字节引导代码被破坏 | Live CD启动，`dd if=/dev/sda bs=512 count=1` |
| GPT表损坏 | 分区表头或备份表损坏 | `gdisk -l /dev/sda` |
| GRUB文件缺失 | `/boot/grub2/` 下文件丢失 | 检查 `i386-pc/` 或 `x86_64-efi/` |
| EFI分区丢失 | UEFI模式下EFI分区不可用 | `efibootmgr -v` |

**修复方法**：
```bash
# BIOS（MBR）模式
grub2-install /dev/sda
grub2-mkconfig -o /boot/grub2/grub.cfg

# UEFI模式（openEuler）
yum reinstall grub2-efi shim
grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg
efibootmgr -c -d /dev/sda -p 1 -l '\EFI\openEuler\shimx64.efi' -L "openEuler"
```

### 2.2 GRUB rescue模式

**进入原因**：GRUB模块不可访问、分区结构变化、文件系统损坏。

**rescue模式命令**：

| 命令 | 功能 | 示例 |
|------|------|------|
| `set` | 查看/设置环境变量 | `set prefix=(hd0,msdos1)/boot/grub2` |
| `ls` | 列出分区和文件 | `ls (hd0,msdos1)/boot/` |
| `insmod` | 加载模块 | `insmod normal` |
| `boot` | 启动系统 | 加载内核后执行 |

**恢复步骤**：
```bash
grub rescue> ls                                       # 查找含grub的分区
grub rescue> set prefix=(hd0,msdos1)/boot/grub2       # 设置prefix
grub rescue> set root=(hd0,msdos1)                    # 设置root
grub rescue> insmod normal                            # 加载normal模块
grub rescue> normal                                   # 进入正常模式

# 进入系统后永久修复
grub2-install /dev/sda
grub2-mkconfig -o /boot/grub2/grub.cfg
```

### 2.3 GRUB配置错误

```bash
# 验证配置文件语法
grub2-script-check /boot/grub2/grub.cfg

# 重新生成配置
grub2-mkconfig -o /boot/grub2/grub.cfg

# 查看/设置默认启动项
grub2-editenv list
grub2-set-default 0                     # 使用序号
grub2-set-default "openEuler (5.10.0)"  # 使用菜单标题

# 临时修改内核参数：GRUB菜单按 'e' 编辑，Ctrl+X 启动
```

---

## 3. 内核加载故障

### 3.1 内核镜像问题

**典型表现**：
```
error: file '/vmlinuz-5.10.0-136.12.0.86.oe2203sp1.x86_64' not found.
```

**排查步骤**：
```bash
ls -la /boot/vmlinuz-*                        # 检查内核文件
file /boot/vmlinuz-$(uname -r)                # 验证完整性
rpm -qa | grep kernel | sort                  # 已安装内核列表
grep vmlinuz /boot/grub2/grub.cfg             # grub引用的版本
yum reinstall kernel-$(uname -r)              # 重新安装内核
```

### 3.2 内核参数问题

| 参数 | 问题 | 修复 |
|------|------|------|
| `root=UUID=xxx` | UUID不存在 | `blkid` 获取正确UUID |
| `rd.lvm.lv=vg/lv` | LVM卷名错误 | `lvs` 确认卷名 |
| `selinux=1` + 标签丢失 | SELinux阻止启动 | 临时添加 `selinux=0` |
| `crashkernel=auto` | 内存不足时分配失败 | 改为 `crashkernel=256M` |
| `quiet` | 隐藏错误信息 | 去掉以查看详细输出 |

```bash
# 查看当前启动参数
cat /proc/cmdline
# 临时修改：GRUB菜单按 'e'，修改 linux 行，Ctrl+X 启动
```

### 3.3 模块加载失败

**典型表现**：
```
modprobe: FATAL: Module xxx not found in directory /lib/modules/5.10.0-xxx
```

**排查步骤**：
```bash
find /lib/modules/$(uname -r) -name "*.ko*" | grep 模块名   # 模块是否存在
modinfo 模块名                                               # 模块信息
modprobe --show-depends 模块名                               # 依赖关系
dmesg | grep -i "module\|error\|fail"                       # 加载日志
depmod -a                                                    # 重建依赖
```

**常见场景**：内核升级后第三方驱动不兼容、最小化安装缺少驱动、DKMS模块未重建。

---

## 4. initramfs问题

### 4.1 initramfs损坏

**典型表现**：
```
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

```bash
# 检查内容
lsinitrd /boot/initramfs-$(uname -r).img
lsinitrd /boot/initramfs-$(uname -r).img | grep -E "xfs|ext4|nvme|ahci|lvm"
ls -lh /boot/initramfs-*.img                                # 异常小则已损坏

# 重建（openEuler/CentOS/RHEL）
dracut -f /boot/initramfs-$(uname -r).img $(uname -r)
dracut -f --add-drivers "nvme xfs" /boot/initramfs-$(uname -r).img $(uname -r)
```

### 4.2 根文件系统无法挂载

**UUID/LABEL不匹配**：
```bash
blkid                   # 查看所有设备UUID
cat /etc/fstab          # 对比fstab中的UUID
# 修正：将fstab中的旧UUID替换为blkid输出的正确UUID
```

**设备名变化**：

| 场景 | 原设备名 | 新设备名 | 原因 |
|------|----------|----------|------|
| 添加NVMe | `/dev/sda` | `/dev/nvme0n1` | NVMe控制器优先 |
| 磁盘顺序变化 | `/dev/sdb` | `/dev/sdc` | 设备枚举顺序变化 |
| 虚拟化迁移 | `/dev/vda` | `/dev/sda` | 驱动类型变化 |

**最佳实践**：始终使用UUID或LABEL代替设备名。

**fstab错误修复**：
```bash
mount -o remount,rw /                              # emergency模式下
vi /etc/fstab                                      # 编辑修正
# 常见错误：挂载点不存在、文件系统类型错误、已移除设备未删除
# 非关键分区使用 nofail 防止启动失败：
UUID=xxx  /data  xfs  defaults,nofail  0 0
```

### 4.3 LVM/RAID激活失败

```bash
# LVM未激活
pvscan                                 # 扫描物理卷
vgchange -ay                           # 激活所有卷组
lvs -a -o +devices                     # 检查逻辑卷状态
vgreduce --removemissing vg_name       # VG不完整时

# RAID阵列不完整
cat /proc/mdstat                       # 检查RAID状态
mdadm --detail /dev/md0                # 详细信息
mdadm --assemble --force /dev/md0      # 降级模式组装
```

---

## 5. systemd启动故障

### 5.1 emergency/rescue模式

| 模式 | 触发条件 | 等价目标 |
|------|----------|----------|
| **emergency** | 根文件系统挂载失败、fstab严重错误 | `emergency.target` |
| **rescue** | 基本系统加载成功但服务启动失败 | `rescue.target` |

```bash
systemctl list-units --failed           # 查看失败服务
journalctl -xb --no-pager | tail -100  # 当前启动日志
journalctl -b -1 --no-pager            # 上次启动日志
systemctl status 服务名 -l              # 特定服务状态
mount -o remount,rw /                   # 重新挂载为读写
```

### 5.2 服务启动失败

```bash
# 依赖分析
systemctl list-dependencies 服务名
systemctl list-dependencies --reverse 服务名
systemd-analyze verify 服务名.service

# 配置检查
systemctl cat 服务名
# 常见错误：ExecStart路径不存在、User/Group不存在、WorkingDirectory不存在

# 权限排查
namei -l /path/to/executable            # 路径权限链
ls -Z /path/to/executable              # SELinux上下文
restorecon -Rv /path/to/executable     # 恢复上下文
```

### 5.3 启动挂起

```bash
# 定位启动瓶颈
systemd-analyze blame                   # 各服务启动耗时
systemd-analyze critical-chain          # 关键链分析
systemd-analyze time                    # 总启动时间
systemctl list-jobs                     # 等待中的任务

# 网络等待超时（卡在 "A start job is running for Network..."）
systemctl mask NetworkManager-wait-online.service    # 临时禁用

# 设备等待：fstab中引用已移除设备，添加 nofail 或移除条目
```

---

## 6. 文件系统检查失败

```bash
# fsck自动触发条件：fstab第六列非0、文件系统dirty、达到检查阈值
touch /forcefsck                        # 强制下次启动检查

# 手动修复（需先umount）
fsck.ext4 -y /dev/sda2                  # ext4自动修复
xfs_repair /dev/sda2                    # xfs修复
xfs_repair -L /dev/sda2                 # xfs清除损坏日志（可能丢数据）

# ext4 journal恢复
tune2fs -O ^has_journal /dev/sda2       # 移除日志
fsck.ext4 -y /dev/sda2                  # 修复
tune2fs -j /dev/sda2                    # 重建日志
```

---

## 7. 常见案例

### 案例1：fstab UUID错误导致emergency mode

**现象**：`[FAILED] Failed to mount /data.` → 进入emergency模式

**排查**：
```bash
systemctl list-units --failed            # 确认 data.mount 失败
grep /data /etc/fstab                    # fstab中UUID: aaaa-bbbb-cccc
blkid | grep data                        # 实际UUID: xxxx-yyyy-zzzz
mount -o remount,rw /
sed -i 's/aaaa-bbbb-cccc/xxxx-yyyy-zzzz/' /etc/fstab
systemctl reboot
```

**预防**：非关键分区添加 `nofail` 选项。

### 案例2：内核升级后initramfs未更新

**现象**：`Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)`

**排查**：
```bash
# 1. GRUB菜单选择旧内核启动
ls -la /boot/initramfs-新版本.img          # 文件不存在或大小异常
dracut -f /boot/initramfs-新版本.img 新版本  # 重建
lsinitrd /boot/initramfs-新版本.img | grep -E "xfs|lvm|dm"  # 验证
reboot
```

**根因**：内核升级过程中 `dracut` 执行失败或被中断。

### 案例3：SELinux relabel后启动慢

**现象**：启动时间从30秒延长至15-30分钟，显示 `*** Warning -- SELinux is relabelling this machine ***`

**排查**：
```bash
ls -la /.autorelabel                     # 确认relabel标记
ps aux | grep fixfiles                   # 查看进度
# relabel完成后系统自动重启
# 紧急跳过：GRUB中添加 selinux=0 参数
```

**预防**：使用 `restorecon` 对特定目录标记，避免全盘relabel。

---

## 8. 预防措施

### GRUB备份

```bash
dd if=/dev/sda of=/backup/mbr_backup.bin bs=512 count=1   # 备份MBR
cp -a /boot/grub2/ /backup/grub2_backup/                   # 备份GRUB配置
cp -a /boot/efi/ /backup/efi_backup/                       # UEFI备份
```

### 内核回退配置

```bash
# /etc/dnf/dnf.conf
installonly_limit=3             # 保留最近3个内核

# 内核管理
grubby --default-kernel         # 查看默认内核
grubby --info=ALL               # 所有内核信息
grubby --set-default=/boot/vmlinuz-稳定版本   # 设置默认
```

### 启动监控

```bash
systemd-analyze time >> /var/log/boot-times.log   # 记录启动时间
journalctl --list-boots                            # 启动历史

# /etc/systemd/system.conf 配置看门狗
RuntimeWatchdogSec=30
ShutdownWatchdogSec=10min
```

### 启动诊断速查表

| 故障现象 | 可能阶段 | 首选排查方法 |
|----------|----------|--------------|
| 无任何输出 | BIOS/UEFI | 检查硬件、引导顺序 |
| `grub rescue>` | GRUB | 重设prefix，加载normal模块 |
| `error: file not found` | GRUB→Kernel | 检查内核文件和grub.cfg |
| `Kernel panic: VFS` | initramfs | `dracut -f` 重建 |
| emergency mode | systemd | `journalctl -xb`、检查fstab |
| 启动极慢 | systemd | `systemd-analyze blame` |
| 登录界面不出现 | display-manager | 检查gdm/sddm服务状态 |
