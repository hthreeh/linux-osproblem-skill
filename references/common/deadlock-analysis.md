# 死锁分析详细指南

本文档详细介绍死锁问题的分析方法，包括内核态和用户态死锁。

---

## 1. 死锁概述

### 定义

死锁是指两个或多个执行单元互相等待对方释放资源，导致所有执行单元都无法继续执行的状态。

### 死锁必要条件（Coffman条件）

1. **互斥条件**：资源不能共享
2. **持有并等待**：持有资源同时等待其他资源
3. **不可抢占**：资源不能被强制抢占
4. **循环等待**：存在资源的循环等待链

---

## 2. 内核态死锁

### 2.1 死锁类型

#### 自旋锁死锁

**特征**：
```
BUG: soft lockup - CPU#0 stuck for 23s!
```

**原因**：
- 自旋锁被长时间持有
- 在持有自旋锁时调用了可能睡眠的函数
- 自旋锁嵌套

**检测命令**：
```bash
# vmcore中
bt -a                  # 所有CPU调用栈
struct spinlock <addr> # 检查锁状态
```

#### 互斥锁死锁

**特征**：
- 进程处于UNINTERRUPTIBLE状态
- 多个进程互相等待

**检测命令**：
```bash
# vmcore中
ps | grep UN           # UN状态进程
foreach bt             # 所有进程栈
struct mutex <addr>    # 检查锁状态
```

**mutex结构分析**：
```bash
crash> struct mutex ffff880012345678
struct mutex {
  count = {
    counter = 0        # 0表示锁定，负数表示有等待者
  },
  wait_lock = {
    raw_lock = {
      val = {
        counter = 1    # 1表示未锁定
      }
    }
  },
  wait_list = {
    next = 0xffff880012345700,
    prev = 0xffff880012345800
  },
  owner = 0xffff880011111111  # 锁持有者的task_struct
}
```

#### 读写锁死锁

**场景**：
- 写者等待读者释放锁
- 新的读者不断到来
- 写者永远无法获取锁（写者饥饿）

#### RCU死锁

**特征**：
```
INFO: rcu_sched self-detected stall on CPU
```

**原因**：
- 在RCU读临界区长时间阻塞
- CPU长时间禁止抢占

### 2.2 vmcore分析流程

```
1. 确定死锁存在
   ├── ps | grep UN        # 找UN状态进程
   ├── bt -a              # 所有CPU调用栈
   └── foreach bt         # 所有进程栈

2. 找到等待链
   ├── 分析每个UN进程在等什么锁
   ├── struct mutex <addr> # 找锁的owner
   └── 追踪owner在等什么

3. 构建依赖图
   ├── 进程A -> 持有L1 -> 等待L2
   ├── 进程B -> 持有L2 -> 等待L1
   └── 发现循环依赖

4. 定位根因
   ├── 找到循环等待链
   ├── 分析为什么会出现这个顺序
   └── 确定修复方案
```

### 2.3 常见死锁场景

#### ABBA死锁

```
进程A                    进程B
lock(lock1)             lock(lock2)
lock(lock2)             lock(lock1)  <- 死锁
```

**分析**：
```bash
# 进程A
bt
# 显示：lock1 -> lock2（等待中）

# 进程B
bt
# 显示：lock2 -> lock1（等待中）

# 结论：ABBA死锁
```

#### 自死锁

```c
// 错误示例
void func() {
    lock(&my_lock);
    // ... 某些代码
    other_func();  // 内部又调用了lock(&my_lock)
    unlock(&my_lock);
}
```

#### 递归死锁

```c
// 错误示例
void recursive() {
    lock(&lock1);
    if (condition) {
        recursive();  // 再次尝试获取lock1
    }
    unlock(&lock1);
}
```

---

## 3. 用户态死锁

### 3.1 pthread互斥锁死锁

**检测方法**：
```bash
# attach到进程
gdb -p <PID>

# 查看所有线程
(gdb) info threads

# 查看各线程栈
(gdb) thread apply all bt

# 找到阻塞在pthread_mutex_lock的线程
(gdb) frame N
(gdb) p mutex
(gdb) p *mutex
```

**mutex状态分析**：
```gdb
(gdb) p *mutex
$1 = {
  __data = {
    __lock = 2,        # 0: 未锁定, 1: 锁定(无等待者), 2: 锁定(有等待者)
    __count = 1,       # 递归锁的计数
    __owner = 12345,   # 锁持有者的TID
    __nusers = 1,
    __kind = 0,
    __spins = 0,
    __elision = 0,
    __list = {__prev = 0x0, __next = 0x0}
  }
}
```

### 3.2 进程间死锁

**场景**：
- 文件锁竞争
- 共享内存中的锁
- IPC资源竞争

**检测方法**：
```bash
# 查看进程状态
ps -eo pid,ppid,stat,cmd | grep D

# 查看进程等待的内核函数
cat /proc/<PID>/wchan

# 查看打开的文件
lsof -p <PID>

# 查看IPC资源
ipcs -a
```

---

## 4. 死锁检测工具

### 4.1 内核lockdep

**启用lockdep**：
```bash
# 内核启动参数
lockdep

# 运行时检查
cat /proc/lockdep
cat /proc/lockdep_chains
cat /proc/lockdep_stats
```

**lockdep输出解读**：
```
[ INFO: possible circular locking dependency detected ]
---------------------------------------------------------
process A/1234 is trying to acquire lock:
 (&lock2){+.+.}, at: func2+0x10/0x20

but task is already holding lock:
 (&lock1){+.+.}, at: func1+0x5/0x10

which lock already depends on the new lock.
```

### 4.2 运行时检测

```bash
# 软锁检测
cat /proc/sys/kernel/watchdog_thresh
echo 10 > /proc/sys/kernel/watchdog_thresh

# 硬锁检测（NMI watchdog）
cat /proc/sys/kernel/nmi_watchdog
```

### 4.3 用户态工具

```bash
# Valgrind helgrind
valgrind --tool=helgrind ./program

# Valgrind drd
valgrind --tool=drd ./program

# ThreadSanitizer（编译时）
gcc -fsanitize=thread -g program.c
```

---

## 5. 死锁分析案例

### 案例1：内核ABBA死锁

```
# 问题现象
BUG: soft lockup - CPU#0 stuck for 22s!

# 分析过程
crash> ps | grep UN
  PID: 1234  TASK: ffff880012345678  CPU: 0   COMMAND: "process_a"
  PID: 5678  TASK: ffff880012345abc  CPU: 1   COMMAND: "process_b"

crash> bt 1234
#11 [ffff880012345000] mutex_lock at ffffffff81234567
#12 [ffff880012345010] process_a_func at ffffffffa0123456
    -> 持有lock1，等待lock2

crash> bt 5678
#11 [ffff880012345000] mutex_lock at ffffffff81234567
#12 [ffff880012345010] process_b_func at ffffffffa0123789
    -> 持有lock2，等待lock1

# 结论：ABBA死锁
# 修复：统一锁获取顺序
```

### 案例2：用户态pthread死锁

```gdb
# 现象：程序无响应

# 分析
(gdb) info threads
  Id   Target Id         Frame 
* 1    Thread 0x7ffff7fb7740 "program" 0x00007ffff7bc712c in pthread_mutex_lock

(gdb) thread apply all bt

Thread 3:
#0  0x00007ffff7bc712c in pthread_mutex_lock
#1  0x0000000000401234 in thread2_func
    -> 持有mutex_a，等待mutex_b

Thread 2:
#0  0x00007ffff7bc712c in pthread_mutex_lock
#1  0x0000000000401567 in thread1_func
    -> 持有mutex_b，等待mutex_a

# 结论：两个线程互相等待
```

---

## 6. 死锁预防

### 6.1 锁顺序规则

```c
// 定义全局锁顺序
enum lock_order {
    LOCK_ORDER_A = 0,
    LOCK_ORDER_B = 1,
    LOCK_ORDER_C = 2,
};

// 按顺序获取锁
void func() {
    lock(LOCK_ORDER_A);  // 先获取低序号锁
    lock(LOCK_ORDER_B);  // 再获取高序号锁
    // ...
    unlock(LOCK_ORDER_B);
    unlock(LOCK_ORDER_A);
}
```

### 6.2 锁持有时间最小化

```c
// 错误：锁持有时间过长
void func() {
    lock(&lock);
    // 长时间操作
    file_operation();
    network_request();
    unlock(&lock);
}

// 正确：最小化锁持有时间
void func() {
    prepare_data();
    lock(&lock);
    update_shared_state();
    unlock(&lock);
    file_operation();
    network_request();
}
```

### 6.3 避免嵌套锁

```c
// 错误：嵌套锁
void func() {
    lock(&lock1);
    other_func();  // 可能获取其他锁
    unlock(&lock1);
}

// 正确：明确所有锁
void func() {
    lock(&lock1);
    lock(&lock2);
    // 操作
    unlock(&lock2);
    unlock(&lock1);
}
```

### 6.4 使用超时锁

```c
// 带超时的锁获取
void func() {
    if (pthread_mutex_timedlock(&mutex, &timeout) != 0) {
        // 超时处理
        return -1;
    }
    // 正常处理
    pthread_mutex_unlock(&mutex);
}
```

---

## 7. 死锁修复策略

### 7.1 统一锁顺序

最常见的修复方法：确保所有代码按相同顺序获取锁。

### 7.2 减少锁粒度

使用更细粒度的锁，减少竞争。

### 7.3 使用无锁算法

在适用场景使用原子操作或无锁数据结构。

### 7.4 使用RCU

读多写少场景使用RCU替代读写锁。

---

## 8. 调试技巧

### 8.1 内核调试选项

```bash
# 启用lockdep
CONFIG_LOCKDEP=y
CONFIG_LOCK_STAT=y

# 启用DEBUG_RWSEMS
CONFIG_DEBUG_RWSEMS=y

# 启用mutex调试
CONFIG_DEBUG_MUTEXES=y
```

### 8.2 用户态调试

```bash
# 使用调试版本的glibc
LD_LIBRARY_PATH=/path/to/debug/glibc ./program

# 设置mutex错误检查属性
pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_ERRORCHECK);
```

### 8.3 获取锁信息

```bash
# 内核锁统计
cat /proc/lock_stat

# 查看持有锁的进程
cat /proc/<PID>/stack
```
