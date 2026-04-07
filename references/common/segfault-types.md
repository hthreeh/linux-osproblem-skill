# 段错误类型详细说明

本文档详细介绍用户态程序段错误的各种类型及其诊断方法。

---

## 1. 段错误概述

段错误（Segmentation Fault）是用户态程序访问非法内存地址时产生的错误，是用户态最常见的一类崩溃。

### 触发条件

- 访问未映射的内存地址
- 访问无权限的内存地址
- 写入只读内存区域
- 访问已释放的内存

---

## 2. 段错误类型分类

### 2.1 NULL指针解引用

**特征**：
```
Program received signal SIGSEGV, Segmentation fault.
0x0000000000401234 in function_name () at file.c:123
123         *ptr = value;
```

**GDB诊断**：
```gdb
(gdb) p ptr
$1 = (int *) 0x0
```

**常见原因**：
- 指针未初始化
- 函数返回NULL但未检查
- 初始化失败但继续使用
- 结构体成员指针未设置

**示例代码**：
```c
// 错误示例
void func() {
    char *ptr = NULL;
    *ptr = 'a';  // 崩溃
}

// 正确做法
void func() {
    char *ptr = malloc(1);
    if (!ptr) {
        // 处理错误
        return;
    }
    *ptr = 'a';
    free(ptr);
}
```

### 2.2 Use-After-Free

**特征**：
- 崩溃位置不固定
- 数据损坏但可能不立即崩溃
- 依赖内存分配器行为

**GDB诊断**：
```gdb
(gdb) p *ptr
$1 = 0x0  # 或垃圾值

# 检查内存内容
(gdb) x/20x ptr
0x55555556c2a0:	0x00000000	0x00000000	0x00021d31	0x00000000
                        ^^^^^^^^ 可能是freed标记
```

**检测工具**：
```bash
# Valgrind检测
valgrind --leak-check=full --show-leak-kinds=all ./program

# AddressSanitizer（编译时启用）
gcc -fsanitize=address -g program.c
./a.out
```

**示例代码**：
```c
// 错误示例
void func() {
    char *ptr = malloc(100);
    free(ptr);
    strcpy(ptr, "hello");  // Use-After-Free
}

// 正确做法
void func() {
    char *ptr = malloc(100);
    free(ptr);
    ptr = NULL;  // 避免悬空指针
}
```

### 2.3 栈溢出

**特征**：
```
Program received signal SIGSEGV, Segmentation fault.
0x00007ffff7a81234 in __libc_write () from /lib/libc.so.6
```
- 崩溃位置可能在libc函数中
- 无明确函数调用栈

**GDB诊断**：
```gdb
(gdb) info frame
Stack level 0, frame at 0x7fffffffde00:
 rip = 0x401234 in func; saved rip 0x401256
 called by frame at 0x7fffffffde10
 Arglist at 0x7fffffffdde8, args: 
 Locals at 0x7fffffffddf0, Previous frame's sp is 0x7fffffffde00

# 检查栈指针是否合理
(gdb) p/x $sp
$1 = 0x7fff0000  # 如果接近栈边界则可能是溢出
```

**常见原因**：
- 无限递归
- 局部数组过大
- 深度嵌套调用

**示例代码**：
```c
// 错误示例1：无限递归
void recursive() {
    recursive();  // 无终止条件
}

// 错误示例2：大数组
void func() {
    char buffer[10 * 1024 * 1024];  // 10MB栈分配
}

// 正确做法
void func() {
    char *buffer = malloc(10 * 1024 * 1024);
    // 使用buffer
    free(buffer);
}
```

### 2.4 数组越界

**特征**：
- 可能不立即崩溃
- 损坏相邻内存
- 症状随机

**GDB诊断**：
```gdb
(gdb) p array[10]
$1 = 0  # 看起来正常，但array只有5个元素

# 检查内存布局
(gdb) x/20x array
```

**检测工具**：
```bash
# AddressSanitizer
gcc -fsanitize=address -g program.c

# BoundsSanitizer（较新的GCC）
gcc -fsanitize=bounds -g program.c
```

**示例代码**：
```c
// 错误示例
void func() {
    int arr[5];
    for (int i = 0; i <= 5; i++) {  // 应该是 i < 5
        arr[i] = i;
    }
}

// 正确做法
void func() {
    int arr[5];
    for (int i = 0; i < 5; i++) {
        arr[i] = i;
    }
}
```

### 2.5 未初始化指针

**特征**：
- 指向随机地址
- 崩溃位置和值随机

**GDB诊断**：
```gdb
(gdb) p ptr
$1 = (int *) 0x7fff12345678  # 随机值

(gdb) p *ptr
Cannot access memory at address 0x7fff12345678
```

**示例代码**：
```c
// 错误示例
void func() {
    char *ptr;  // 未初始化
    strcpy(ptr, "hello");  // 崩溃
}

// 正确做法
void func() {
    char *ptr = malloc(6);
    if (ptr) {
        strcpy(ptr, "hello");
        free(ptr);
    }
}
```

### 2.6 对齐问题

**特征**：
- 在ARM、SPARC等平台常见
- x86/x64通常允许非对齐访问

**特征信息**：
```
Program received signal SIGBUS, Bus error.
```

**GDB诊断**：
```gdb
(gdb) p/x &var
$1 = 0x4003  # 非对齐地址（应该是4的倍数）
```

**示例代码**：
```c
// 错误示例（在ARM上）
void func() {
    char buf[10];
    int *p = (int*)(buf + 1);  // 非对齐
    *p = 123;  // 可能触发SIGBUS
}

// 正确做法
void func() {
    char buf[10];
    int val;
    memcpy(&val, buf + 1, sizeof(int));  // 安全拷贝
}
```

---

## 3. 其他崩溃类型

### 3.1 Double Free

**特征**：
```
*** Error in `./program': double free or corruption (fasttop): 0x0000000000602010 ***
```

**检测**：
```bash
valgrind --leak-check=full ./program
```

### 3.2 堆损坏

**特征**：
```
*** Error in `./program': corrupted size vs. prev_size: 0x0000000000602010 ***
```

**常见原因**：
- 堆溢出
- Double free
- Use-after-free
- 无效释放地址

---

## 4. GDB调试技巧

### 4.1 基本调试流程

```gdb
# 1. 加载程序
gdb ./program core

# 2. 查看崩溃位置
(gdb) bt
(gdb) bt full

# 3. 查看线程信息
(gdb) info threads
(gdb) thread apply all bt

# 4. 查看寄存器
(gdb) info registers

# 5. 查看内存
(gdb) x/20x $sp
(gdb) x/s string_ptr

# 6. 查看局部变量
(gdb) frame 0
(gdb) info locals
(gdb) info args
```

### 4.2 高级调试技巧

```gdb
# 查看内存映射
(gdb) info proc mappings

# 查看共享库
(gdb) info sharedlibrary

# 反汇编
(gdb) disassemble

# 查看源码
(gdb) list

# 设置断点重试
(gdb) break main
(gdb) run
```

### 4.3 核心转储设置

```bash
# 启用coredump
ulimit -c unlimited

# 设置coredump位置
echo "/var/core/%e.%p.core" | sudo tee /proc/sys/kernel/core_pattern

# 永久设置
echo "* soft core unlimited" | sudo tee -a /etc/security/limits.conf
```

---

## 5. Valgrind使用

### 5.1 内存错误检测

```bash
# 基本检测
valgrind --leak-check=full ./program

# 详细检测
valgrind --leak-check=full \
         --show-leak-kinds=all \
         --track-origins=yes \
         --verbose \
         ./program

# 输出解释
# definitely lost: 确定泄漏
# indirectly lost: 间接泄漏
# possibly lost: 可能泄漏
# still reachable: 程序结束时仍可访问（可能正常）
```

### 5.2 常见错误类型

| 错误类型 | 含义 |
|----------|------|
| Invalid read | 读非法内存 |
| Invalid write | 写非法内存 |
| Invalid free | 无效释放 |
| Use of uninitialised value | 使用未初始化值 |
| Conditional jump depends on uninitialised value | 条件判断依赖未初始化值 |

---

## 6. AddressSanitizer使用

### 6.1 编译启用

```bash
# GCC/Clang编译
gcc -fsanitize=address -fno-omit-frame-pointer -g program.c -o program

# 运行时选项
ASAN_OPTIONS=halt_on_error=0:detect_leaks=1 ./program
```

### 6.2 错误类型

| 错误 | 含义 |
|------|------|
| heap-buffer-overflow | 堆缓冲区溢出 |
| stack-buffer-overflow | 栈缓冲区溢出 |
| global-buffer-overflow | 全局缓冲区溢出 |
| use-after-free | 释放后使用 |
| double-free | 重复释放 |
| use-after-return | 返回后使用（栈地址） |

---

## 7. 诊断流程总结

```
收到coredump
    │
    ├── 加载：gdb program core
    │
    ├── 定位：bt, bt full
    │
    ├── 分析崩溃点
    │       │
    │       ├── NULL指针？
    │       │       └── p ptr -> 确认是否为0
    │       │
    │       ├── 栈溢出？
    │       │       └── info frame, p $sp
    │       │
    │       ├── 数组越界？
    │       │       └── x/20x array
    │       │
    │       ├── 悬空指针？
    │       │       └── x/20x ptr（找freed标记）
    │       │
    │       └── 对齐问题？
    │               └── p/x &var
    │
    ├── 检查数据结构
    │       └── info locals, info args
    │
    ├── 追踪数据流
    │       └── 确定指针来源
    │
    └── 确定根因
            └── 提出修复方案
```

---

## 8. 预防措施

### 8.1 编码规范

- 初始化所有指针为NULL
- free后立即设为NULL
- 检查所有malloc返回值
- 使用sizeof而非硬编码大小
- 使用安全的字符串函数（strncpy, snprintf）

### 8.2 编译选项

```bash
# 调试版本
gcc -g -O0 -Wall -Wextra -Werror program.c

# 启用警告
gcc -Wall -Wextra -Wpedantic -Wformat=2

# 静态分析
gcc -fanalyzer program.c

# 运行时检查
gcc -fsanitize=address,undefined program.c
```

### 8.3 代码审查重点

- 所有指针使用前检查
- 内存分配/释放配对
- 数组边界检查
- 字符串操作安全性
- 递归深度限制
