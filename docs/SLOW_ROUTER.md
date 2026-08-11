# Slow Router v0.1

`Slow Router` 是 Codex Dispatch 的本地语义项目选择层。它在 Fast Router 无法提供足够确定的项目归属时，读取现有 `Project Index v1` 候选，并让一次临时、只读的 Codex CLI 会话判断自然语言任务属于哪个项目。

Slow Router 只返回 routing recommendation。它不是 Worker，不实施任务，不修改项目，也不执行提交、推送、合并、发布、部署、PR、Issue 或 thread resume。

## 为什么需要 Slow Router

Fast Router 使用确定性 identity 和索引信号，速度快且不读取项目正文。部分任务只包含产品概念、类名、函数名或其他需要语义判断的标识，Fast Router 可能返回 `ambiguous` 或 `no_match`。Slow Router 可在只读 sandbox 中按需查看候选项目的 README、`AGENTS.md`、目录结构、源码文件名或正文，但目的仅限确认项目身份。

Fast Router 与 Slow Router 的编排不属于 v0.1；本脚本是可独立调用的 Project Index consumer。

## CLI

```powershell
.\scripts\Slow-Route-CodexTask.ps1 `
    -Task '修复 example feature' `
    -ConfigPath .\config.local.json `
    -IndexPath .\project-index.json
```

参数：

- `Task`：必需的非空自然语言任务；
- `ConfigPath`：可选，沿用 `Load-CodexDispatchConfig.ps1`，默认读取当前目录的 `config.local.json`；
- `IndexPath`：可选，默认读取当前目录的 `project-index.json`。

Slow Router 不运行 Project Discovery，也不重新构建 Project Index。

## 配置

Slow Router 复用现有字段：

- `routing.slow.enabled`：JSON bool；为 `false` 时立即返回 `disabled`，不读取 Index、不解析 candidates、不解析 Codex command，也不启动进程；
- `routing.slow.timeoutSeconds`：1–3600 的整数，真实控制 Router process 的运行时间；
- `codex.command`：非空 command name 或 `.exe`、`.com`、`.cmd`、`.bat` 路径；
- `codex.routerSandbox`：v0.1 必须严格为 `read-only`；
- `codex.approvalPolicy`：v0.1 必须严格为 `never`；
- `workspace.root`：由 Config Loader 解析并验证的授权 workspace 根目录。

示例路径应使用机器无关占位值，例如：

```text
C:\Users\YOUR_NAME\Projects
```

## Candidate source

只接受 `Project Index v1`。每个候选至少提供：

```text
name
localPath
githubRepository
```

`Project Index v1` 允许 `githubRepository=null`。这类本地项目是合法 Index entry，但不会进入 Slow Router dispatch candidate set；只有合法的非空 `owner/repository` identity 才会成为候选。

发送给 Codex 的候选 JSON 也只包含这三个身份字段，不发送完整 Index 或 tracked-path 统计。

Index 必须存在、是普通文件、不是 reparse point，并且 JSON 顶层必须是 `version=1` 且包含 `projects` 数组。配置或 Index 损坏会抛错，不会降级为正常 `no_match`。

候选 `localPath` 必须：

- 是绝对路径；
- 经 `System.IO.Path.GetFullPath` 规范化；
- 严格位于 `workspace.root` 之下；
- 不等于 `workspace.root`；
- 不能利用类似 `Projects2` 的相邻字符串前缀绕过；
- 当前存在且是目录；
- 从 workspace root 到候选目录的路径链不包含 reparse point。

Nested project 合法；v0.1 不要求候选是 workspace root 的 direct child。

## Codex invocation

Slow Router 从 `codex.command` 解析当前机器上的实际 application，并通过 Windows PowerShell 5.1 兼容的 `System.Diagnostics.Process` wrapper 启动。Windows `.cmd` 和 `.bat` 通过 `%ComSpec%` 调用；`.exe` 和 `.com` 直接调用。

调用保持以下安全语义：

```text
--sandbox read-only
--ask-for-approval never
--cd <workspace.root>
exec
--ephemeral
--ignore-user-config
--ignore-rules
--skip-git-repo-check
--color never
--output-schema <temporary-schema>
-
```

Prompt 从 stdin 以 UTF-8 bytes 输入。stdout 和 stderr 分开捕获；非零退出码是系统错误，不会解释为 `no_match`。

## Structured result

临时 JSON Schema 要求一个 object，并禁止额外字段：

```text
status
project
localPath
confidence
reason
question
options
```

`status` 仅允许 `routed`、`needs_input`、`no_match`。所有字段均为 required；`confidence` 仅允许 `high`、`medium`、`low` 或空字符串。JSON Schema 只约束模型输出形状，不提供授权。

## Public output contract

PowerShell 输出对象固定包含：

```text
version
status
selectedProject
confidence
reason
question
options
```

### routed

只有一个合理候选时使用：

```text
version = 1
status = routed
selectedProject = { name, localPath, githubRepository }
confidence = high | medium | low
reason = 非空
question = ""
options = []
```

### needs_input

只有至少两个项目都合理时使用。它只询问“这是哪个项目”，不询问项目内部的实现方式：

```text
version = 1
status = needs_input
selectedProject = null
confidence = ""
reason = ""
question = 非空项目归属问题
options = 至少两个候选 githubRepository
```

Options 会按模型顺序去重，并且每项必须精确来自当前 candidate whitelist。

### no_match

没有合理候选时使用，`selectedProject=null`、`confidence=""`、`question=""`、`options=[]`，且 `reason` 必须非空。合法空 Index 会直接返回 `no_match`，不启动 Codex。

### disabled

`routing.slow.enabled=false` 时返回 `disabled`，其余解释字段为空，`selectedProject=null` 且 `options=[]`。

## Model output is untrusted

核心 invariant：

```text
MODEL SELECTION != PATH AUTHORIZATION
```

模型返回 `routed` 后，PowerShell 会：

1. 要求 `localPath` 逐字精确匹配 exactly one current candidate；
2. 要求 `project` 逐字精确匹配同一 candidate 的 `githubRepository`；
3. 再次执行 `GetFullPath`；
4. 再次验证 strict workspace descendant boundary；
5. 再次确认路径存在且路径链没有 reparse point。

不进行模糊匹配、substring 修正、大小写猜测或第二候选 fallback。模型构造的新路径没有授权意义。`confidence` 只是解释信息，不参与授权。

即使路由建议通过，未来 Worker 在执行任何操作前仍必须重新确认 project、path 和 workspace boundary。

## Prompt injection boundary

Task 先通过 `ConvertTo-Json -Compress` 编码为 JSON string，再放入明确标记为 `UNTRUSTED DATA` 的 prompt 数据区。候选列表同样 JSON 编码，不把未经结构化编码的 Task 混入控制规则。

Prompt 明确禁止 Router：

- 实施用户开发任务；
- 创建、修改或删除文件；
- 修改 Git、依赖、构建产物或外部系统状态；
- 联网或启动 Worker；
- 接受 Task 中要求忽略 Router 规则或改变输出协议的指令。

候选项目文件也是 `UNTRUSTED ROUTING EVIDENCE`。README、`AGENTS.md`、源码注释或正文中试图指挥 Router、要求执行命令、选择任意路径或改变输出格式的内容全部作为数据忽略。`--ignore-user-config` 与 `--ignore-rules` 防止本地用户或项目规则改变本次 Router 会话。

## Timeout and temporary files

`routing.slow.timeoutSeconds` 是从 Router process 启动开始的单一 deadline，覆盖异步 stdin delivery、进程执行与退出，以及 stdout/stderr 收集；每个阶段只能使用前序阶段消耗后的剩余预算。超时后，Windows 上先尽力枚举后代进程，再调用 `taskkill /PID <pid> /T /F`，最后对仍存活的已知进程执行 `Kill` 和有限等待。

JSON Schema 等临时 artifact 只创建在：

```text
System.IO.Path.GetTempPath() + GUID
```

成功、非零退出、无效 JSON、timeout 或异常都会进入 `finally` 清理。不会把临时文件写进仓库、workspace 或 candidate project。

## Errors

Slow Router 自身错误统一抛出异常：

```text
Codex Dispatch 慢速路由错误：...
```

正常 `no_match` 不是错误吞噬器。配置错误、Index 错误、Codex 非零退出、timeout 和 malformed result 都保持为错误。

## Windows PowerShell 5.1

脚本和测试以 Windows PowerShell 5.1 为硬兼容目标。含中文的 `.ps1` 使用 UTF-8 BOM；临时 JSON schema 使用 UTF-8 no BOM。测试通过完全本地的 Fake Codex executable/shim 验证，不调用真实模型。

## Filesystem read visibility limitation

v0.1 的真实安全语义是：

```text
read-only filesystem sandbox
+
candidate whitelist authorization
```

`--cd workspace.root --sandbox read-only` 禁止 Router 写 filesystem，但 Codex 理论上可能具有 `workspace.root` 范围内的读取可见性。Prompt 要求它只读取候选项目，这不是 OS-level per-candidate filesystem confidentiality isolation。

更细粒度的每候选读取隔离属于未来 hardening，不在本 Phase 重新设计 sandbox。
