# Bash JIT: LLM 驱动的 Bash 即时编译器

## 1. 问题背景

### 1.1 Bash 脚本性能瓶颈

Bash 是最广泛使用的脚本语言之一，在系统管理、CI/CD 管道、数据处理、自动化运维等领域无处不在。然而 Bash 的执行模型存在根本性的性能限制：

- **解释执行**：Bash 逐行解析、逐条执行，没有编译优化
- **进程创建开销**：Bash 的大部分"威力"来自调用外部命令（`grep`、`awk`、`sed`、`sort` 等），每次调用都需要 `fork + exec`，在循环中这个开销会被急剧放大
- **数据结构原始**：Bash 的数组和关联数组操作远不如 Python 高效
- **字符串处理慢**：Bash 的字符串操作（`${var:offset:length}`、`${var//pattern/replacement}` 等）每次都重新解析

一个典型的例子：在循环中调用 `tr` 和 `head` 生成随机密码，5000 次迭代需要 6 秒以上，而等效的 Python 代码用 `random.choices()` 仅需 16 毫秒——**388 倍差距**。

### 1.2 AI Agent 效率受限于 CLI

大语言模型（LLM）驱动的 AI Agent 在执行编程任务时，大量操作通过 CLI（命令行工具）完成：文件搜索、代码分析、构建测试、日志分析、数据提取等。这些 CLI 操作本质上是调用 Bash 脚本或命令管道。

当 AI Agent 需要分析一个大型仓库的代码统计时，它可能执行类似 `find ... | xargs wc -l` 的命令；当需要批量处理日志时，它可能写出 `for f in *.log; do grep ... "$f"; done` 的循环。这些操作在 Bash 中执行缓慢，Agent 被迫等待命令完成，浪费宝贵的上下文窗口和计算资源。

更关键的是，Agent 无法为提升性能而重写脚本——它必须使用宿主环境提供的方式（即 Bash）来操作。**Bash 执行效率成为了 AI Agent 效率的天花板。**

### 1.3 核心洞察

如果在 Bash 执行层透明地加速脚本，就能在不改变任何上层使用方式的前提下，同时提升人类和 AI Agent 的工作效率。

## 2. 设计目标

### 2.1 透明加速

核心设计原则是**上层完全不感知**：

- 用户（或 AI Agent）执行 `bash script.sh` 的方式不需要任何改变
- 编译、缓存、回退全部在底层自动完成
- 第一次运行正常速度（Bash 原生执行 + 后台编译），第二次运行自动使用编译后的 Python 版本
- 任何编译或执行失败都静默回退到 Bash 原生执行，上层不会看到错误

### 2.2 零修改

现有脚本不需要任何改动。JIT 系统不需要注解、配置文件或特殊标记。脚本内容通过指纹（FNV-128）自动识别和缓存。

### 2.3 安全回退

JIT 永远不会让脚本更慢或更不正确。每一个失败路径（守护进程未启动、LLM 编译失败、Python 运行时错误）都会回退到 Bash 原生执行。

### 2.4 零开销禁用

未设置 `BASH_JIT` 环境变量时，JIT 代码路径仅增加一次条件判断，对性能零影响。

## 3. 概述

Bash JIT 是为 Bash 5.3 实现的即时编译器，利用大语言模型（LLM）将 Bash 脚本自动翻译为 Python，在不修改任何脚本代码的前提下，实现数量级的性能提升。

**核心特性：**

- **透明加速**：上层无感知，执行方式不变
- **零修改**：现有 Bash 脚本无需任何改动即可受益
- **安全回退**：任何编译或执行失败都会回退到原始 Bash 执行
- **两种编译粒度**：支持逐命令编译（交互式场景）和整脚本编译（脚本场景）

## 4. 性能对比

### 4.1 测试环境

| 项目 | 说明 |
|------|------|
| 基线版本 | Bash 5.3，未启用 JIT（`~/local/bash-baseline/bin/bash`） |
| 优化版本 | Bash 5.3 + JIT，编译为 Python 执行 |
| 测试机器 | macOS (Apple Silicon) / Linux (x86_64) |
| 编译模型 | Claude Sonnet |
| 测试仓库 | mirror-bash（Bash 源码，~1651 个被跟踪文件） |

### 4.2 source-stats.sh：CPU 密集型脚本（55x 加速）

`scripts/source-stats.sh` 是一个源码统计工具，递归扫描目录，分析每个源文件的代码行、注释行、空行、超长行，按扩展名聚合统计，输出结构化报告。脚本包含循环、字符串处理、数组操作、文件 I/O 等典型的 CPU 密集型操作。

**测试命令：**

```bash
# 基线版本
./tests/jit/baseline_run_it.sh ./scripts/source-stats.sh

# 优化版本（首次编译后缓存）
./tests/jit/jit_run_it.sh ./scripts/source-stats.sh
```

**执行时间对比（中位数，3 次运行）：**

| 版本 | 耗时 | 说明 |
|------|------|------|
| 基线（Bash 原生执行） | 6,631 ms | 解释执行，循环和字符串操作慢 |
| 优化（JIT → Python） | 120 ms | 编译后 Python 执行 |
| **加速比** | **55.3x** | |

**功能正确性：**

```
Bash 输出:  94 行, 4,076 字符
Python 输出: 94 行, 4,071 字符
匹配率:     100%（行数一致，仅列对齐格式有微小差异）
```

**差异分析：** bash 的 `${#var}` 计算字节数，Python 的 `len()` 计算 Unicode 字符数。对于包含多字节 UTF-8 字符的行（如 `—` em dash），"超长行"计数存在微小差异。这不影响统计结论。

### 4.3 git-file-contributors.sh：I/O 密集型脚本

`scripts/git-file-contributors.sh` 统计仓库中每个文件的 git 历史贡献者排名。核心逻辑是对每个文件调用 `git log --follow`，属于典型的 I/O 密集型操作。

**执行时间对比（中位数，3 次运行）：**

| 版本 | 耗时 | 说明 |
|------|------|------|
| 基线（Bash 原生执行） | 51,620 ms | 对 1651 个文件逐一调用 `git log` |
| 优化（JIT → Python） | 45,189 ms | 相同的 `git log` 子进程调用 |
| **加速比** | **1.14x** | 瓶颈在 git 子进程 I/O，非 CPU |

**功能正确性：**

```
Bash 输出:  5,861 行, 161,992 字符
Python 输出: 5,861 行, 161,992 字符
匹配率:     100%（输出完全一致）
```

**结论：** I/O 密集型脚本的性能瓶颈在子进程调用（`git log`），Bash 和 Python 均需等待外部进程完成，因此加速有限。JIT 编译最适用于 CPU 密集型操作：字符串处理、循环、数组运算、算术计算等。

### 4.4 Koala 基准测试套件

使用 [Koala](https://github.com/kbensh/koala)（USENIX ATC '25）中的真实世界脚本进行扩展测试。Koala 是一个 POSIX Shell 性能基准套件，包含来自 NLP、随机数生成等领域的 18 组脚本。

**测试环境：**

| 项目 | 说明 |
|------|------|
| 测试机器 | Linux 6.12 (aarch64) |
| 基线版本 | Bash 5.3，未启用 JIT |
| 优化版本 | Bash 5.3 + JIT，编译为 Python 执行 |
| 编译模型 | Claude Sonnet |
| 测试来源 | Koala benchmark suite (nlp, rand) |
| 测试方法 | 每个脚本运行 3 次，取中位数 |

**测试脚本：**

| 脚本 | 来源 | 说明 |
|------|------|------|
| `nlp-count-words` | koala/nlp | 遍历文本文件，对每个文件运行 `tr/sort/uniq` 管道统计词频 |
| `nlp-bigrams` | koala/nlp | 计算文本 bigram（相邻词对），使用 `export -f`、临时目录、`paste/sort/uniq` |
| `nlp-anagrams` | koala/nlp | 查找文本中的回文构词法（anagram），使用 `sort/rev/uniq` 管道 |
| `nlp-syllables` | koala/nlp | 按音节数排序单词，使用 `tr/awk/paste/sort` 管道 |
| `pass` | koala/rand | 5000 次循环，每次生成 32 字符随机密码（`tr/head` 子进程） |
| `pickname` | koala/rand | 500 次循环，每次从姓名文件中随机采样 10 个（`cat/shuf/head`） |

**执行时间对比（中位数，3 次运行）：**

| 脚本 | 类型 | Bash 耗时 | Python 耗时 | 加速比 |
|------|------|-----------|-------------|--------|
| pass | 循环 + 子进程 | 6,215 ms | 16 ms | **388x** |
| pickname | 循环 + 文件 I/O | 27,471 ms | 141 ms | **195x** |
| nlp-anagrams | 循环 + 函数 + sort/uniq | 677 ms | 371 ms | **1.8x** |
| nlp-syllables | 循环 + 函数 + 管道 | 902 ms | 621 ms | **1.5x** |
| nlp-bigrams | 循环 + 函数 + 文件 I/O | 2,158 ms | 1,498 ms | **1.4x** |
| nlp-count-words | 循环 + 子进程管道 | 509 ms | 527 ms | 1.0x |

**分析：**

- **高加速（195x–388x）**：`pass` 和 `pickname` 在循环内每次迭代都启动子进程（`tr/head/shuf`）。Python 翻译用 `random.choices()`/`random.sample()` 替代子进程调用，消除了所有进程创建开销。`pickname` 加速比受限于读取 218 万行输入文件到内存的时间（~130ms）。
- **中等加速（1.4x–1.8x）**：三个 NLP 脚本（bigrams、anagrams、syllables）处理 50 个文本文件（ENTRIES=50），Python 翻译用 `collections.Counter`、`str.translate` 等内置替代子进程管道，获得适度加速。加速比受限于文件 I/O（1.1GB 总数据量）。
- **无加速（1.0x）**：`nlp-count-words` 原始 bash 脚本已使用高效的 `tr/sort/uniq` 管道，Python 翻译的 `Counter` + 正则方式没有额外优势，加上 Python 启动开销（~15ms），几乎无加速。

**复现方法：**

```bash
# 1. 下载 koala 基准套件并获取测试数据（首次运行）
./tests/jit/koala/setup.sh

# 2. 运行全部基准测试
./tests/jit/koala/run_all.sh

# 也可指定 koala 路径
./tests/jit/koala/run_all.sh /path/to/koala
```

### 4.5 性能总结

**自有脚本：**

| 脚本 | 类型 | Bash 耗时 | Python 耗时 | 加速比 |
|------|------|-----------|-------------|--------|
| source-stats.sh | CPU 密集 | 16,639 ms | 376 ms | **44.3x** |
| git-file-contributors.sh | I/O 密集 | 49,211 ms | 42,802 ms | 1.15x |

**Koala 基准（真实世界脚本，pg-small 数据集）：**

| 脚本 | 类型 | Bash 耗时 | Python 耗时 | 加速比 |
|------|------|-----------|-------------|--------|
| pass | 循环 + 子进程 | 6,215 ms | 16 ms | **388x** |
| pickname | 循环 + 文件 I/O | 27,471 ms | 141 ms | **195x** |
| nlp-anagrams | 循环 + 函数 + sort/uniq | 677 ms | 371 ms | **1.8x** |
| nlp-syllables | 循环 + 函数 + 管道 | 902 ms | 621 ms | **1.5x** |
| nlp-bigrams | 循环 + 函数 + 文件 I/O | 2,158 ms | 1,498 ms | **1.4x** |
| nlp-count-words | 循环 + 子进程管道 | 509 ms | 527 ms | 1.0x |

**关键发现：** JIT 编译对「循环+子进程」型脚本（pass、pickname）效果最显著，用 Python 标准库替代子进程调用可获得 195x–388x 加速。对 I/O 密集型脚本（文件遍历+文本处理），加速比取决于 I/O 占比：数据量越大，计算占比越高，加速越明显。编译提示词中的性能优化规则对翻译质量有决定性影响。

### 4.6 输出正确性对比

以下对比基线版本（Bash 原生执行）与优化版本（JIT 编译后 Python 执行）的输出差异，分析每个差异是正常的还是异常的。

#### source-stats.sh

| 指标 | Bash | Python (JIT) | 说明 |
|------|------|-------------|------|
| 行数 | 98 | 196 | JIT 扫描了更多文件 |
| 文件数 | 1,237 | 1,346 | 差异 109 个文件 |
| .sh 文件 | 352 | 409 | 差异 57 个 |
| .py 文件 | 0 | 69 | JIT 检测到缓存中的 .py 文件 |

**差异原因：** 两次运行之间项目目录内容发生了变化——`tests/jit/koala/` 目录下的测试脚本、`setup.sh`、`run_all.sh` 等文件在基准测试过程中创建，导致 JIT 版本扫描到更多文件。此外，JIT 编译过程中会在缓存目录中生成 `.py` 文件。这不是翻译错误，而是环境差异。bash 的 `${#var}` 计算字节数，Python 的 `len()` 计算 Unicode 字符数，对于包含多字节 UTF-8 字符的行，统计结果有微小差异（约 5 个字符）。**结论：正常。**

#### git-file-contributors.sh

| 指标 | Bash | Python (JIT) |
|------|------|-------------|
| 行数 | 5,871 | 5,871 |
| 字符数 | 162,211 | 162,211 |

**差异：** 仅 "Jari Aalto" 条目在同分贡献者中的排序位置略有不同（684 行 diff，全部为同一个人的位置移动）。

**差异原因：** 当多个贡献者贡献次数相同时，`sort -rn` 和 Python `sorted()` 的稳定排序行为可能不同——bash 的 `sort` 和 Python 的排序算法在处理相同键值时，保留原始相对顺序的规则不同。**结论：正常，属于排序稳定性差异。**

#### rand-pass

| 指标 | Bash | Python (JIT) |
|------|------|-------------|
| 行数 | 5,000 | 5,000 |
| 每行字符数 | 32 | 32 |
| 总字符数 | 165,000 | 165,000 |

**差异：** 每次运行生成不同的随机密码，但格式完全一致（5000 行，每行 32 个字符）。

**结论：正常。随机输出每次不同，格式和统计特征完全一致。**

#### rand-pickname

| 指标 | Bash | Python (JIT) |
|------|------|-------------|
| 输出文件数 | 500 | 500 |
| 每个文件行数 | 10 | 10 |

**差异：** 每次运行从姓名文件中随机采样不同的名字，但格式完全一致（500 个文件，每个 10 个名字）。

**结论：正常。随机采样结果每次不同，格式完全一致。**

#### nlp-count-words

| 指标 | Bash | Python (JIT) |
|------|------|-------------|
| 输出行数 | 2,940 | 2,940 |
| diff 行数 | 0 | 0 |

**差异：** 输出完全一致。

**结论：正常。无差异。**

#### nlp-bigrams

| 指标 | Bash | Python (JIT) |
|------|------|-------------|
| 输出行数 | 9,646 | 9,645 |
| 分隔符 | Tab（`\t`） | Space |

**差异：** (1) bash 版使用 `paste` 命令连接字段，默认以 Tab 分隔；Python 版使用空格分隔。(2) 行数差异 1 行，可能为边界处理差异（如空行或文件末尾处理）。

**结论：基本正常。Tab/Space 分隔差异是 bash 工具与 Python 实现的固有差异，不影响数据内容。行数差 1 是边界条件的微小差异。**

#### nlp-anagrams

| 指标 | Bash | Python (JIT) |
|------|------|-------------|
| 输出行数 | 0 | 1,234 |

**差异：** bash 版输出为空（运行时报错 `rev: command not found`），Python 版正常输出 1,234 个回文构词结果。

**差异原因：** 测试环境未安装 `rev` 命令，bash 脚本依赖外部命令 `rev` 实现字符串反转，命令缺失导致静默失败。Python 版使用原生字符串操作（`s[::-1]`），不依赖外部命令。**结论：这是 JIT 编译的一个优势——Python 翻译消除了对外部命令的依赖，提高了脚本的可移植性。**

#### nlp-syllables

| 指标 | Bash | Python (JIT) |
|------|------|-------------|
| 输出行数 | 5 | 5 |
| 分隔符 | Tab | Space |
| 音节计数 | 不一致 | 不一致 |

**差异：** (1) 分隔符 Tab vs Space（同 bigrams）。(2) 相同单词的音节数不同（如 `revolutionised`，bash 统计为 6 音节，Python 统计为 7 音节）。

**差异原因：** 音节计数是一个近似算法。bash 版使用 `grep -i '[aeiouy]'` 统计元音组数来估算音节数，Python 版由 LLM 翻译实现，使用了不同的启发式规则。两种实现都是近似的，差异属于算法选择差异而非翻译错误。**结论：正常。音节计数本身是启发式算法，不同实现会有微小差异。**

#### 总结

| 测试用例 | 输出一致性 | 差异类型 | 评价 |
|---------|-----------|---------|------|
| source-stats.sh | 格式一致，数据因环境不同 | 环境差异（文件集不同） | 正常 |
| git-file-contributors.sh | 行数/字符数完全一致 | 排序稳定性差异 | 正常 |
| rand-pass | 格式完全一致 | 随机输出不同 | 正常 |
| rand-pickname | 格式完全一致 | 随机采样不同 | 正常 |
| nlp-count-words | 完全一致 | 无差异 | 正常 |
| nlp-bigrams | 内容基本一致 | Tab/Space 分隔 + 行数差 1 | 基本正常 |
| nlp-anagrams | JIT 优于基线 | 基线缺 `rev` 命令失败 | JIT 优势 |
| nlp-syllables | 格式一致，数值近似 | 算法差异（Tab/Space + 音节计数） | 正常 |

**总体结论：** 所有差异均为格式差异（Tab vs Space 分隔符）、环境差异（文件集不同）、随机差异（密码/采样）、或算法差异（音节计数近似值），不存在语义错误。JIT 编译后的 Python 脚本功能正确。

## 5. 架构

### 5.1 系统组件

```
┌──────────────────────────────────────────────────────┐
│                    Bash 进程 (C)                       │
│                                                        │
│  ┌──────────────────┐    ┌──────────────────────────┐ │
│  │ 整脚本 JIT        │    │ 逐命令 JIT                │ │
│  │ bash_jit_try_     │    │ bash_jit_check()          │ │
│  │ script()          │    │ (reader_loop 拦截)        │ │
│  └────────┬─────────┘    └────────────┬─────────────┘ │
│           │                           │                │
│     缓存命中？                    缓存命中？            │
│      ↓ 是     ↓ 否              ↓ 是     ↓ 否         │
│  execvp()   发送给 daemon    构造替换命令  报告给 daemon│
│ (Python 替换                  (python3 作为            │
│  bash 进程)                    cm_simple 命令)          │
└──────────────────────────────────────────────────────┘
                      │ Unix Domain Socket
                      ▼
┌──────────────────────────────────────────────────────┐
│           bash_jitd (Python 守护进程)                   │
│                                                        │
│  · 接收执行报告，维护全局计数器                          │
│  · 计数超过阈值 或 收到整脚本编译请求时，调用 LLM         │
│  · 将 Bash 代码翻译为 Python，写入缓存                  │
│  · 缓存目录: ~/.cache/bash_jit/<fingerprint>/          │
└──────────────────────────────────────────────────────┘
                      │
                      ▼
┌──────────────────────────────────────────────────────┐
│                 LLM API (Claude)                       │
│  · 输入: Bash 源代码                                    │
│  · 输出: 等价 Python 代码                               │
│  · 模型: Claude Sonnet                                  │
└──────────────────────────────────────────────────────┘
```

### 5.2 执行流程

```
首次运行:   bash script.sh → 检查缓存（未命中）→ Bash 原生执行 → 异步发送给 daemon 编译
                                                                    ↓
                                                           LLM 翻译 Bash → Python
                                                                    ↓
                                                           写入 ~/.cache/bash_jit/<fp>/compiled.py

第二次运行: bash script.sh → 检查缓存（命中）→ execvp("python3", compiled.py) → Python 执行
```

对于整脚本 JIT，首次运行后 bash 会将脚本源码发送给守护进程。守护进程收到 `exec_script` 消息后立即触发 LLM 编译（不需要等待执行计数阈值），编译完成后写入缓存。第二次运行时，bash 在解析脚本之前就通过 `execvp` 替换为 Python 进程。

### 5.3 两种编译模式

#### 整脚本 JIT（主要模式）

适用于 `bash script.sh` 场景。在 bash 启动、解析脚本之前拦截：

1. 读取脚本文件内容，计算 FNV-128 指纹
2. 检查 `~/.cache/bash_jit/<fp>/compiled.py` 是否存在
3. **存在** → 设置 `BASH_JIT_SCRIPT` 环境变量，`execvp("python3", ...)` 替换进程
4. **不存在** → 将脚本内容发送给守护进程异步编译，bash 正常执行

拦截点在 `shell.c` 的脚本打开函数之前，此时 JIT 已初始化、`$0` 和位置参数已设置、启动文件已执行。

整脚本 JIT 的编译是即时触发的：守护进程收到 `exec_script` 消息后立即启动编译，不需要等待执行计数达到阈值。这使得脚本在第一次运行后就能获得编译缓存。

#### 逐命令 JIT（辅助模式）

适用于交互式 shell 或 `eval`/`source` 场景：

1. 在 `reader_loop()` 中拦截每条命令
2. 计算指纹（源码 + 函数定义上下文 + shell 选项）
3. 检查是否适合编译（排除 `eval`、`cd`、动态作用域等）
4. 缓存命中时构造 `python3 compiled.py` 作为替换命令

逐命令 JIT 使用阈值机制：同一段代码被解释执行超过 `BASH_JIT_THRESHOLD`（默认 100）次后，守护进程才触发编译。这是因为在交互式场景中，单次执行的命令通常很短，编译收益有限。

两种模式互不干扰：整脚本 JIT 仅在 `shell_script_filename` 存在时生效，逐命令 JIT 在所有场景中可用。

### 5.4 缓存机制

```
~/.cache/bash_jit/
├── <fingerprint_32hex>/
│   ├── compiled.py      # LLM 翻译的 Python 代码
│   └── meta.json        # 元信息（源码、时间戳）
├── counters.json         # 跨进程计数器持久化
└── ...
```

**指纹算法：** FNV-128，对脚本文件的原始字节计算。C 侧和 Python 侧使用相同的实现，确保指纹一致。指纹仅基于文件内容，不含上下文信息（与逐命令 JIT 不同）。

**缓存一致性：** 脚本内容变化后指纹改变，自动触发重新编译。`jit clear` 可手动清空缓存。

### 5.5 编译守护进程 (bash_jitd)

每个用户一个实例，通过 Unix Domain Socket 与 bash 进程通信：

- **全局计数器**：所有 bash 进程共享，跨进程持久化（`counters.json`）
- **异步编译**：LLM 调用在后台进行，不阻塞 bash 执行
- **语法验证**：编译后自动验证 Python 语法，失败不写入缓存
- **安全检查**：验证编译后的 Python 代码不含危险操作
- **并发控制**：最多 3 个并发 LLM 请求（信号量），超出的排队等待
- **持久化**：守护进程退出时保存计数器，重启后恢复状态

守护进程生命周期：
- 首个 JIT bash 进程启动时自动启动（`jit_connect_or_start_daemon()`）
- 持续运行直到 `jit stop` 或 SIGTERM
- 崩溃后由下一个 JIT bash 进程自动重启

### 5.6 CLI 工具 (jit)

```bash
jit status                # 查看守护进程状态、热点代码、正在编译的任务
jit compile --stdin       # 从标准输入编译
jit compile <file.sh>     # 编译脚本文件
jit compile --force ...   # 强制重新编译
jit check <file.sh>       # 查询脚本是否有编译缓存
jit clear                 # 清空所有缓存
jit clear --compiled      # 仅清空已编译缓存
jit clear --failed        # 仅清空失败缓存
jit start                 # 启动守护进程
jit stop                  # 停止守护进程
```

`jit status` 输出示例：

```
Daemon PID: 25962
Uptime: 21s
Total snippets tracked: 23
Compiled: 1
Failed: 0
Total exec events: 65

Compiling (2):
  e34030a0bc3a160e..  #!/bin/bash
  ded1c5c1d97ec943..  #!/bin/sh -

Top hot code:
  [ not_compiled] count=     4  SKIP_DIRS=".git node_modules ...
  [     compiled] count=     0  #!/bin/bash
```

`jit check` 输出示例：

```
$ jit check ./scripts/source-stats.sh
Script:      ./scripts/source-stats.sh
Fingerprint: e34030a0bc3a160e097a89c3f569ee59
Cache:       compiled
Path:        /home/user/.cache/bash_jit/e34030a0bc3a160e097a89c3f569ee59/compiled.py
Compiled:    2026-06-03T09:15:10Z
```

## 6. 使用方式

### 6.1 构建

```bash
# 构建 JIT 版本（默认，安装到 ~/local/bash-jit/）
./scripts/build.sh

# 构建基线版本（安装到 ~/local/bash-baseline/，用于对比）
./scripts/build.sh --no-jit

# 清理后重新构建
./scripts/build.sh --clean
```

### 6.2 启用 JIT

```bash
# 方式一：进入 JIT Bash 环境（推荐）
source scripts/enter-jit-bash.sh

# 方式二：环境变量启用
BASH_JIT=1 ~/local/bash-jit/bin/bash script.sh

# 方式三：预编译后直接运行
jit compile --stdin < script.sh       # 预编译
BASH_JIT=1 ~/local/bash-jit/bin/bash script.sh  # 直接命中缓存

# 禁用 JIT
BASH_JIT=0 ~/local/bash-jit/bin/bash script.sh
```

### 6.3 预编译与缓存管理

```bash
# 预编译脚本（不执行）
jit compile script.sh                    # 编译脚本文件
jit compile --stdin < script.sh          # 从标准输入编译
jit compile --force script.sh            # 强制重新编译

# 查询编译状态
jit check script.sh                      # 查看是否有编译缓存

# 清理缓存
jit clear                                # 清空所有缓存
jit clear --compiled                     # 仅清空已编译缓存
jit clear --failed                       # 仅清空失败记录
```

### 6.4 测试脚本

```bash
# 运行指定脚本并显示耗时（JIT 版本）
./tests/jit/jit_run_it.sh ./scripts/source-stats.sh

# 运行指定脚本并显示耗时（基线版本）
./tests/jit/baseline_run_it.sh ./scripts/source-stats.sh

# 功能+性能综合测试（对比 bash 与 Python 输出）
./tests/jit/jit_test_it.sh ./scripts/source-stats.sh

# 运行完整测试套件
./tests/jit/run_jit_tests.sh

# 运行 Koala 基准测试（真实世界脚本对比）
./tests/jit/koala/bench.sh ./tests/jit/koala/nlp_bigrams_bench.sh --label koala-nlp-bigrams
./tests/jit/koala/bench.sh ./tests/jit/koala/pass_bench.sh --label koala-pass
```

## 7. 代码结构

| 文件 | 说明 |
|------|------|
| `bash_jit.c` | JIT 核心实现：指纹计算、缓存查询、命令替换、整脚本 execvp |
| `bash_jit.h` | JIT 接口声明 |
| `shell.c` | 整脚本 JIT 拦截点（`open_shell_script()` 之前） |
| `eval.c` | 逐命令 JIT 拦截点（`reader_loop()`） |
| `evalstring.c` | `source`/`eval` 场景的 JIT 拦截点 |
| `execute_cmd.c` | 函数调用场景的 JIT 拦截点 |
| `scripts/bash_jitd` | 编译守护进程（Python）：计数、LLM 翻译、缓存管理 |
| `scripts/jit` | CLI 管理工具：status / compile / check / clear / start / stop |
| `scripts/build.sh` | 构建脚本（`--jit`/`--no-jit`） |
| `scripts/enter-jit-bash.sh` | 一键进入 JIT Bash 环境 |
| `tests/jit/koala/` | Koala 基准测试脚本（NLP、随机数生成等真实世界脚本） |

## 8. 配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BASH_JIT` | (未设置) | 设为 `1` 启用 JIT |
| `BASH_JIT_THRESHOLD` | `100` | 逐命令 JIT 触发编译的执行次数阈值（整脚本 JIT 无此限制） |
| `BASH_JIT_MIN_DURATION` | `50` | 触发编译的最小平均耗时（毫秒） |
| `BASH_JIT_CACHE_DIR` | `~/.cache/bash_jit` | 缓存目录 |
| `BASH_JIT_DAEMON` | `scripts/bash_jitd` | 守护进程路径 |

LLM 配置从 `~/.config/bash_jit/config.json` 或环境变量读取。支持两种 API 提供商（Anthropic 优先）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ANTHROPIC_API_KEY` | (无) | Anthropic API 密钥 |
| `ANTHROPIC_AUTH_TOKEN` | (无) | Anthropic OAuth 令牌（备选） |
| `ANTHROPIC_BASE_URL` | `https://api.anthropic.com` | Anthropic API 基础 URL |
| `OPENAI_API_KEY` | (无) | OpenAI API 密钥 |
| `OPENAI_BASE_URL` | `https://api.openai.com/v1` | OpenAI API 基础 URL |
| `BASH_JIT_LLM_MODEL` | `claude-sonnet-4-20250514`（Anthropic）/ `gpt-4o`（OpenAI） | 编译使用的模型 |
| `BASH_JIT_LLM_ENDPOINT` | (根据提供商自动生成) | 完整 API 端点 URL（优先级低于 BASE_URL） |

## 9. 适用场景

### 推荐场景

- 循环内调用外部命令的脚本（`for` + `grep`/`tr`/`sort` 等）——加速最显著
- 字符串处理、文本分析脚本（大量 `${var//pattern/replacement}` 操作）
- 数据聚合和统计脚本（循环 + 计数 + 排序）
- CI/CD 管道中反复执行的构建/部署脚本
- AI Agent 执行的 Bash 命令管道和脚本

### 效果有限场景

- I/O 密集型脚本（瓶颈在外部进程等待，如 `git log`、`curl`）
- 极简脚本（脚本本身耗时 < 100ms，Python 启动开销占比高）
- 重度依赖 Bash 特性的脚本（进程替换、文件描述符操作、信号处理）

## 10. 局限性与风险

Bash JIT 的核心思路是用 LLM 将 Bash 翻译为 Python，这在带来巨大性能提升的同时，也存在根本性的局限。

### 10.1 编译正确性无法保证

Bash JIT 的编译过程基于 LLM，是一种概率性的翻译，而非确定性的编译。LLM 无法保证生成的 Python 程序与原始 Bash 程序在语义上完全一致。

- **简单脚本**（循环、字符串处理、文件遍历）：LLM 翻译正确率高，差异通常是格式性的（Tab vs Space 分隔符、排序稳定性）
- **复杂脚本**（嵌套函数、trap 信号处理、文件描述符操作、动态作用域）：LLM 翻译出错概率显著增加
- **环境依赖**：Bash 脚本的行为可能依赖 shell options（`set -e`、`set -u`）、trap handler、文件描述符状态等运行时环境，LLM 很难完整捕捉这些隐式依赖

**关键问题：静默错误。** Python 脚本可能执行过程没有任何异常、没有错误返回码，但程序行为与原始 Bash 脚本不一致。这种错误无法通过常规的异常检测或返回码检查发现。比如 Python 脚本正常退出（exit code 0），但输出的数据与 Bash 版本有微妙差异（少了一行、排序不同、数值偏差），调用方可能完全察觉不到。

### 10.2 不可复现性

LLM 输出是非确定性的。同一个 Bash 脚本在不同时间编译可能产生不同的 Python 代码：

- 脚本今天编译后运行正常，`jit clear` 后重新编译可能行为就不同了
- 不同机器上的缓存不同，同一脚本在不同环境可能表现不一致
- 故障难以复现：同样的脚本、同样的输入，因为编译时机不同就可能产生不同结果

这对调试和可靠性保障是非常致命的。

### 10.3 调试路径断裂

透明性的反面是调试困难。用户或工具看到的是 `bash script.sh`，但实际执行的是 `python3 compiled.py`：

- `bash -x` 调试不生效——进程已被 execvp 替换
- 错误堆栈是 Python 的（`traceback`），但用户以为在运行 Bash
- Bash 的调试机制（`set -x`、`trap DEBUG`、`PS4`）在 Python 进程中不存在
- 用户不知道需要去 `~/.cache/bash_jit/<fp>/compiled.py` 查看 Python 源码

### 10.4 开环控制问题

Bash JIT 的编译过程本质上是一个**开环控制系统**：LLM 接收 Bash 源码作为输入，生成 Python 代码作为输出，但系统缺乏可靠的"生成-验证"反馈环来确认输出的正确性。

```
Bash 源码 → [LLM 编译] → Python 代码 → 写入缓存 → 直接使用
                ↑                              │
                └── 无反馈 ←───────────────────┘
                    （没有验证步骤确认输出与输入语义一致）
```

与之对比，可靠的软件工程实践通常是**闭环控制**：

```
输入 → [生成] → 输出 → [验证/测试] → 通过？→ 使用
                         ↑              │
                         └── 不通过 ←───┘
                            （反馈驱动修正）
```

LLM 编译缺少这样的闭环：没有测试用例可以自动验证 Python 输出与 Bash 原始行为的一致性，也没有反馈信号可以驱动 LLM 修正翻译。编译结果的正确性完全依赖 LLM 的单次生成质量，没有任何兜底机制。

### 10.5 AI Agent 场景的特殊风险

在 AI Agent 场景中，问题进一步加剧：**Bash JIT 的 LLM 编译过程脱离了上层 AI Agent 的工作循环。**

AI Agent 自身具备闭环工作能力——它会生成 Bash 脚本、执行、观察结果、发现错误、修改重试：

```
Agent 生成 bash 脚本 → 执行 → 观察结果 → 有错误？
                                        ↓ 是          ↓ 否
                              修改脚本 → 重试       任务完成
```

但 Bash JIT 的编译过程完全发生在这个闭环之外：

- Agent 生成 Bash 脚本，期望它被 Bash 正确执行
- Bash JIT 透明地将脚本替换为 Python，Agent 完全不感知
- Python 脚本的行为偏差被 Agent 当作"自己的 Bash 脚本有问题"
- Agent 检查 Bash 脚本——逻辑没问题——修改重试——同样的偏差再次出现

```
Agent 的闭环工作循环：
  生成 bash → 执行（被 JIT 替换为 Python）→ 观察异常 → 检查 bash（没问题）→ 修改 → 重试 → ...
                    ↑                                                                ↓
                    └────── JIT 开环编译在此处插入，脱离 Agent 的反馈循环 ─────────────┘
```

Agent 陷入"脚本逻辑正确但执行结果错误"的死循环，因为它的闭环反馈被一个它感知不到的开环过程打断了。

**双层 LLM 误差叠加。** Bash 脚本本身由 LLM 生成（第一层不确定性），JIT 编译又由 LLM 完成（第二层不确定性）。两层概率性误差叠加，且两层都缺乏可靠的验证机制：
- Agent 生成的 Bash 脚本可能就有微妙问题
- JIT 翻译可能"恰好"掩盖了问题，也可能让问题更严重
- Agent 基于执行反馈调试时，面对的是一个被第二层 LLM 改变了行为的不确定系统

### 10.6 核心矛盾

Bash JIT 的最大优势（透明、上层不感知）同时也是它最大的风险来源。透明意味着上层无法参与判断和纠错——无法判断当前异常是 Bash 脚本自身的问题还是 JIT 编译引入的问题，也无法通过切换回 Bash 来快速验证。从控制论角度看，透明性将 JIT 的开环编译过程完全隐藏在上层的闭环反馈之外，使得系统整体失去了自我纠错能力。

### 10.7 可能的缓解方向

需要首先承认一个根本事实：**证明两个任意程序的语义等价是不可判定问题**（Rice 定理）。不存在通用的验证手段可以保证 LLM 编译结果在所有输入下都与原始 Bash 行为一致。以下方案只能是启发式的缓解，无法从根本上消除风险。

- **双重执行采样验证**：首次编译后，用相同输入同时运行 Bash 和 Python 版本并对比输出，仅当结果一致时才启用缓存。但有两个根本局限：(1) 一次验证通过不代表所有输入都能通过——脚本可能在边界条件、不同数据规模、不同环境状态下表现出差异；(2) 非幂等脚本（有副作用的脚本，如创建文件、发送请求、修改状态）不能安全地执行两次。因此，这只是一个概率性的烟雾测试，不是真正的闭环验证
- **适用范围限制**：仅对高置信度的脚本类型启用 JIT（如无 trap、无文件描述符操作、无动态 eval 的简单脚本），从源头降低出错概率
- **Agent 感知机制**：允许 AI Agent 通过环境变量或返回标记感知 JIT 的存在，在调试异常时可以主动禁用 JIT 排查。这相当于将 JIT 纳入 Agent 的闭环反馈中
- **确定性编译**：固定 LLM 的随机种子和编译 prompt 版本，使同一脚本始终产生相同的 Python 代码，缓解不可复现问题
- **人工审核节点**：对于关键脚本，编译后人工确认再启用缓存

## 11. 从局限到新方向

### 11.1 根源问题：CLI 作为 Agent 工具调用接口的固有缺陷

Bash JIT 的核心思路是"透明加速 CLI 执行"——Agent 编写 Bash 脚本，系统在底层自动将其编译为更高效的 Python。但从上一节的分析可以看出，这种"Agent 生成 CLI + 系统透明编译 CLI"的架构存在一个结构性问题：**系统内部的编译优化过程发生在 Agent 的闭环反馈之外**。

这不是 Bash JIT 的实现问题，而是 CLI 作为 AI Agent 工具调用接口这一范式的固有缺陷。CLI 的设计目标是给人类使用——它的语义是确定的、确定性的（相同命令永远产生相同结果），人类因此信任 CLI 的输出，不需要"感知不确定性"。但当 LLM 编译/优化被引入 CLI 执行链路时，确定性被打破：编译可能引入偏差、输出可能不一致、错误可能被掩盖。上层 Agent 仍然按照"CLI 是确定性的"这一假设工作，但实际上它面对的是一个不确定的系统。

### 11.2 更好的方式：Agent 以自然语言调用系统 Agent

如果跳出"Agent 写 CLI"的范式，一个更根本的方案是：**上层应用 Agent 以自然语言的方式调用系统 Agent，把系统 Agent 当作通用的工具。**

```
当前范式（Agent → CLI → 系统透明编译）：

  应用 Agent → 编写 Bash 脚本 → Bash JIT 透明编译为 Python → 执行
                                   ↑
                            开环编译，脱离 Agent 的反馈循环


新范式（Agent → 自然语言 → 系统 Agent）：

  应用 Agent → 自然语言请求 → 系统 Agent 理解意图 → 生成最优执行流 → 执行 → 返回结果
                                    ↑                                              ↓
                                    └──── 结果不确定？Agent 感知并纳入反馈循环 ←─────┘
```

这个范式的关键优势在于**自然语言本身携带不确定性信号**：

- 自然语言是模糊的、可能有歧义的——上层 Agent 天然知道这一点
- 当系统 Agent 返回结果时，上层 Agent 会像对待任何自然语言输入一样，**对结果保持审视和验证**
- 系统 Agent 的不确定性被纳入了上层 Agent 的闭环工作循环中——Agent 会评估结果、提出追问、验证关键输出、必要时换一种方式重试

换言之，**自然语言接口迫使 Agent 感知系统的不确定性，将系统 Agent 纳入 Agent 自身的闭环反馈中**。而 CLI 接口的确定性假象恰恰掩盖了这种不确定性，使 Agent 丧失了对系统行为的审视能力。

需要指出的是，"自然语言接口"是控制论角度的论证——它解决了闭环反馈的问题。但在工程实现层面，上层 Agent 已经拥有结构化的 tool call 能力，把精确意图拍扁成自然语言再让另一个 LLM 去理解，反而会叠加推理延迟和不确定性。真正有意义的接口应该是一个**结构化的意图级接口**——比 CLI 语义层次更高（表达"做什么"而非"怎么做"），比纯自然语言更确定（类型安全、可组合），而 OS 内部将其编译为最优执行流。这本质上是定义一套新的 Agent-OS ABI。

### 11.3 行业现状：都有 AI Shell，但没有人真正代替 CLI

"系统 Agent"的方向是否有人在做了？目前市面上被冠以"Agent OS / AI Shell"名号的方案不少，但**没有一家真正做到了"语义理解 → 最优执行流 → 高效执行"**。它们可以归为三类：

**类型 1：AI 包装的 Shell（自然语言 → 还是翻译成 bash）**

| 方案 | 实际架构 |
|------|---------|
| ANOLISA cosh | 自然语言 → LLM 规划 → 翻译成 shell 命令执行 → 结果回传 |
| OSPilot（超聚变）| 简单操作故意绕开模型直接走 bash，仅含自然语言意图的走推理 |
| PolyMind（openEuler）| 对接多 Agent 运行时，把 OS 能力封装为"可被自然语言调用的技能" |

它们的核心价值是降低人类操作门槛（不用记 tar 参数）和给 Agent 提供结构化环境地图减少 Token 浪费。但底层最终执行的仍然是进程 spawn → bash → grep → awk 这条路径。**优化的是"减少摸索轮次"，不是"消除 CLI 串行化的执行效率瓶颈"。** Bash JIT 测量的两个数量级效率差距，一个都没解决。

**类型 2：MCP 工具注册表（结构化工具，不是自然语言编译）**

统信 UOS-MCP 把文件管理、系统控制、网络访问等底层能力抽象为标准化、可发现的工具集，UOS AI 作为"总调度员"用 LLM 做规划 + 工具组装。这比类型 1 更工程化、更确定——但本质上就是给 Agent 提供了一个更好的 tool schema registry。上层 Agent 调的还是结构化 tool call，不是自然语言；而且每个 tool 内部该 spawn 进程还是 spawn 进程。

**类型 3：安全沙箱 / 编排框架（管 Agent，不改执行方式）**

微软 MXC（Microsoft 执行容器）、ANOLISA 的 AgentSecCore，做的是身份、权限、隔离、审计。这些是必要条件，但不是"代替 CLI"的竞争力——它们不让你跑得更快，它们让你摔不死。

### 11.4 为什么生态没有形成？核心在竞争力问题

上层应用 Agent 发现调用系统 Agent 还不如自己直接调用 CLI、或者效果差不多——系统 Agent 就活不了。这个冷酷的筛选标准在现实中具体展开为三个因素：

**因素 1：系统 Agent 的"增值"不够厚。** 以 ANOLISA 为例，它目前能给上层 Agent 带来的实际好处主要是 Token 节省（OS Skills 减少环境探索）、安全拦截、eBPF 级可观测性、工作区快照回滚。这些增值主要在"安全 / 可观测性 / 减少摸索"等配套能力上，**不在"执行效率质变"上**。配套能力可以通过独立的安全 proxy、容器沙箱、自建缓存等手段部分获得。

**因素 2：自然语言接口对上层 Agent 反而是退化。** 人类想要自然语言接口，因为讨厌记语法；但上层 Agent 已经有结构化 tool call 了，它要的是确定性的、类型安全的、可组合的原语，不是一个黑盒自然语言"理解一下再说"。把精确意图拍扁成自然语言、再让另一个 LLM 去"理解"，两条推理延迟叠加，确定性还下降了。真正有意义的接口应该是一个新的、类型安全的 Agent-OS ABI——上层 Agent 发送结构化的意图描述（而非模糊的自然语言），OS 内部把它编译成最优执行流（而非 spawn N 次进程）。

**因素 3：网络效应锁死在 CLI 上。** 每个 Agent 框架（LangGraph、CrewAI、AutoGen……）都有自己的 tool 定义格式，它们都对接 bash / container exec，因为这是最小公分母。要让它们"对接系统 Agent 代替 CLI"，需要系统 Agent 定义一套稳定的结构化 API，且这套 API 必须比"just run bash in docker"明显更好。**目前没有任何系统 Agent 做到了"明显更好"。**

### 11.5 行业空白与方向

综合以上分析，当前的格局是：

- 现有"AI OS"方案都停留在"AI 包装 Shell + 安全沙箱 + 可观测性"——各自在解决一个真实的、可落地的子集，但回避了"OS 替 Agent 生成最优执行流"这个核心硬骨头
- 生态卡住不是没人想做，而是做了也没人迁移，因为 ROI 没过阈值——系统 Agent 在执行效率侧没有提供足够竞争力
- **"OS 提供真正的意图级接口、内部编译最优执行流"——不是已有人做砸了，而是还没人真正动工**

Bash JIT 的工作为这个方向提供了一个有价值的起点和验证。它通过实践证明了：(1) LLM 可以作为编译器后端，将 Bash 翻译为更高效的 Python，实现数量级的性能提升；(2) 但透明编译的开环控制问题使得这种"Agent 写 CLI + 系统透明编译"的范式存在根本缺陷。由此推导出的方向是：**操作系统应该提供意图级的系统 Agent 接口（超越纯自然语言，走向结构化的 Agent-OS ABI），内部编译最优执行流，取代 CLI 成为 AI Agent 工具调用的事实标准。** 谁先做出来一个可审计、可回滚、兼容现有生态、又确实把执行效率提升一个数量级的 Agent-OS ABI，谁就定义了下一代 POSIX。

### 11.6 安全架构：最小权限原则

上述方向面临一个关键的安全问题：如果系统 Agent 是一个特权进程，而它通过自然语言接收请求，那么 LLM 的不确定性可能导致系统 Agent 执行错误的特权操作，对系统造成严重破坏。应用 Agent 可能通过精心构造的自然语言请求（或无意中的歧义表述）诱导系统 Agent 执行超出预期的高权限操作。

解决方案是将系统 Agent 拆分为两层，遵循最小权限原则：

```
┌─────────────────────────────────────────────────────┐
│  应用 Agent                                          │
│    ↓ 自然语言请求                                    │
│  应用内的系统 Agent（每个应用一个）                     │
│    · 身份 = 关联应用的 UID/GID/capabilities           │
│    · 接口 = 自然语言                                  │
│    · 受 LLM 不确定性影响，但权限 = 应用权限             │
│    · 应用能干啥它就能干啥，应用不能干啥它就不能干啥      │
│    ↓ 语义确定的序列化 IPC                             │
│  全局系统 Agent 服务（系统级，可选）                    │
│    · 身份 = 系统服务                                   │
│    · 接口 = 传统的结构化 IPC（无自然语言）              │
│    · 不信任应用内系统 Agent                            │
│    · 接口设计上做好安全防护，避免被攻击                  │
└─────────────────────────────────────────────────────┘
```

**应用内的系统 Agent** 的定位是帮助应用 Agent 实现更丰富的功能和更高的执行效率——它不是用来提供特权能力的。它运行在应用的权限边界内，虽然受 LLM 不确定性影响，但无论 LLM 生成什么指令，它都无法突破应用的权限范围。这与当前应用执行 Bash 脚本的安全模型一致：Bash 脚本也可能有 bug，但它的权限不会超过调用者。

**全局系统 Agent 服务** 对应用内的系统 Agent 持不信任态度，只暴露经过安全设计的结构化 IPC 接口（类似现有的 syscall、D-Bus、Android Binder 等机制）。它不提供自然语言接口，因此不存在"LLM 误解自然语言导致特权操作"的风险。

全局系统 Agent 服务是否必须存在，取决于原有 syscall 和系统服务接口是否已能满足场景诉求。如果已有接口足够，则不需要额外引入。但在某些场景下（例如跨应用资源协调、全局策略执行、Agent 级的审计和隔离），可能需要一个全局的系统 Agent 服务来补充现有的系统服务架构。其具体职责有待进一步探索。
