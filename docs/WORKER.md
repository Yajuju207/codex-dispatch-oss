# Codex Worker Engine v0.1

`Invoke-CodexWorker.ps1` 是 Codex Dispatch 的本地、可写工程执行层。它接收已经完成 routing 的 GitHub repository identity，重新从当前 `Project Index v1` 授权本地 Git 工作树，然后在该工作树内启动一次可恢复的 Codex CLI session。

Worker 不是 Router、GitHub control plane、Resume handler、workflow 或发布器。Phase 6A 不创建或修改 GitHub Issue，不做 Fast→Slow orchestration，不保存 Codex Dispatch runtime state，也不实现 resume。

## Core security invariant

```text
ROUTER SELECTION != WORKER AUTHORIZATION
```

Router 的选择只是一条 identity recommendation，不能直接授予文件系统写权限。Worker 不接受任意 `ProjectPath` 参数；它只接受 `ProjectRepository=owner/repository`，并从当前 Index 精确重取 `localPath`。

Worker 要求 repository 在 Index 中 Ordinal exact match exactly one dispatchable entry。`githubRepository=null` 是合法 local-only Index entry，但不能成为 Worker target。不存在或重复匹配均为 preflight error。

Worker 安全合同分为三层：

1. **Identity authorization**：Project Index exact repository identity 重新解析为 exactly one project root；
2. **Runtime sandbox authority**：只有 selected project workspace 可写，extra writable roots 强制为空，shell network 强制关闭，web search disabled，`.git` metadata 保持 protected read-only；
3. **Model operating protocol**：普通可逆工程工作可自主进行，mass delete 与其他高风险行为仍受 prompt protocol 限制。

Worker v0.1 是 unattended execution boundary。用户 Codex customization 不进入本次运行；下述单次 CLI isolation 与 sandbox 限制优先于普通用户配置。这是 deliberate tradeoff：保留 repository engineering context，但拒绝用户或项目配置扩展 Worker capability。

## CLI

```powershell
.\scripts\Invoke-CodexWorker.ps1 `
    -Task '修复解析器并运行测试' `
    -ProjectRepository 'owner/repository' `
    -ConfigPath .\config.local.json `
    -IndexPath .\project-index.json
```

参数：

- `Task`：必需的非空用户工程任务；
- `ProjectRepository`：必需的合法 `owner/repository` identity；
- `ConfigPath`：可选，沿用 Config Loader 的 `config.local.json` 行为；
- `IndexPath`：可选，默认当前目录的 `project-index.json`。

Worker 不运行 Discovery 或 Project Index Builder。

## Configuration

Worker 复用 `Load-CodexDispatchConfig.ps1`，并严格要求：

- `codex.command`：可解析的非空 `.exe`、`.com`、`.cmd` 或 `.bat` command；
- `codex.workerSandbox`：exactly `workspace-write`；
- `codex.approvalPolicy`：exactly `never`；
- `safety.restrictToWorkspaceRoot`：JSON `true`；
- `safety.requireExplicitAuthorizationFor`：非空字符串数组，且至少包含 `push`、`merge`、`publish`、`deploy`、`create-pr`、`remote-permission-change`、`mass-delete`、`real-money-spend`。

配置可以增加更多 protected actions，但不能删除 baseline protection。Phase 6A 不使用 `runtime.stateDirectory`。

## Project and filesystem authorization

Worker 只消费有效的 `Project Index v1`。Index 必须存在、是普通非 reparse 文件、使用有效 UTF-8 JSON，并包含整数 `version=1` 与 `projects` 数组。

所有 project entries 都要通过基本结构检查：非空字符串 `name`、非空字符串 `localPath`，以及存在的 `githubRepository` 字段。Repository 可以为 `null`；非 null 时必须是合法 `owner/repository`。

只对 exact selected entry 执行 runtime authorization：

- `localPath` 必须是绝对路径并经过 `GetFullPath`；
- 必须严格位于 `workspace.root` 之下，root 自身不合法；
- 相邻字符串前缀不能绕过边界；
- 当前必须存在且是目录；
- workspace root 到项目目录的完整路径链不能包含 reparse point；
- nested repository 合法；
- `git -C <path> rev-parse --show-toplevel` 必须成功，且规范化结果必须精确等于授权路径。

因此 parent Git repository 的普通子目录不能被提升为 Worker write workspace。Git preflight 只使用本地只读 `rev-parse`，不访问网络。

## Codex invocation

Worker 使用 Windows PowerShell 5.1 compatible process wrapper，异步收集 stdout/stderr，并以 UTF-8 no BOM stdin 发送 prompt。Windows `.cmd`/`.bat` 通过 `%ComSpec%` 安全启动。

核心 invocation 语义：

```text
-c sandbox_workspace_write.writable_roots=[]
-c sandbox_workspace_write.network_access=false
-c web_search="disabled"
-c shell_environment_policy.ignore_default_excludes=false
-c features.hooks=false
-c apps._default.enabled=false
-c projects."<exact-authorized-project-root>".trust_level="untrusted"
--disable plugins
--sandbox workspace-write
--ask-for-approval never
--cd <authorized-project-root>
exec
--ignore-user-config
--json
--color never
--output-last-message <temporary-final-result>
--output-schema <temporary-schema>
-
```

这些 `-c` override 对单次 exec 强制生效：用户 `config.toml` 不能增加第二项目、父目录或共享目录为 writable root，不能为 model-generated shell 打开 outbound network，也不能启用 live web search。Worker v0.1 不提供 web search 或 live internet research；未来若需要网络研究，必须作为显式能力另行设计。

`shell_environment_policy.ignore_default_excludes=false` 让 Codex 的默认 secret-name environment exclusion 生效，降低 `*_TOKEN`、`*_SECRET`、`*_KEY` 等明显敏感变量进入 model-generated shell 的风险。这是 defense in depth，不能替代未来 control plane 对进程环境的进一步清洗。

### Unattended extension isolation

`--ignore-user-config` 阻止本次 exec 加载 `$CODEX_HOME/config.toml`，因此用户自己的 MCP server config、App config、sandbox widening config、shell environment mutations 和其他 execution-affecting config 不进入 Worker。Authentication 仍使用 `CODEX_HOME`；Worker 不修改、迁移或删除用户配置。

Worker 根据已完成 authorization 的 exact `$authorizedPath` 逐字符生成 TOML basic quoted-key，并通过 `projects."<exact-authorized-project-root>".trust_level="untrusted"` 仅对本次 CLI invocation 标记该项目。反斜杠、双引号与 TOML control characters 都按 TOML basic-string 规则编码；Windows drive colon、空格和单引号保持为 key 内容，不能破坏 dotted-key/value 结构。Worker 不修改项目或用户的 persisted trust config。

`untrusted` project override 跳过该项目 `.codex/` capability layers，包括 `.codex/config.toml`、project-local hooks 与 project-local rules。Worker 不使用 `--ignore-rules`：普通 repository instruction discovery 保留，`AGENTS.md` 仍作为普通 project engineering context 加载。换言之，PROJECT ENGINEERING CONTEXT 为 YES，PROJECT SECURITY-CAPABILITY CONFIG 为 NO。

Lifecycle hooks 还由 `features.hooks=false` 显式 hard OFF；Worker 明确禁止 `--dangerously-bypass-hook-trust`。Apps/connectors 由 `apps._default.enabled=false` 默认关闭。当前受支持的 stable CLI feature `plugins` 通过单次 `--disable plugins` 关闭 installed plugin tool surface，不猜测或使用未验证的 feature 名称。

因此 `--ignore-user-config` 与 untrusted project override 共同阻止 user/project configured MCP servers 被加载；Worker 自身也不注册、登录或修改任何 MCP server。GitHub、Slack、Linear 等外部 control plane actions 不属于 Worker model tools；Phase 6B 的 GitHub API 由 external control plane 实现。

Worker 仍不使用 `--search`、`--add-dir`、`--dangerously-bypass-approvals-and-sandbox`、`--dangerously-bypass-hook-trust`、`--yolo`、`danger-full-access`、`--skip-git-repo-check` 或 `--ignore-rules`。这些 unattended isolation 限制优先于普通用户 Codex customization，是 Worker v0.1 的 deliberate tradeoff。

## Session persistence

Worker session 必须可供后续 Phase resume，因此明确不使用 `--ephemeral`。Worker 从 `codex exec --json` 的 JSONL stdout 捕获 `thread.started.thread_id`，要求 UUID 有效且整个 stream 中不能出现不同 thread IDs。

Worker 自己创建的 schema/final-result artifacts 位于系统 temp 的 GUID directory，并在 success、needs-input、failed 或 exception 后清理。Codex CLI 自己保存的 session/rollout 数据不属于 Worker temp artifacts，不会被删除。

## Task and operating policy

Task 是真正授权执行的工程任务，但不能覆盖 Worker safety protocol。Task 使用 JSON string 放入独立数据区，避免破坏 prompt delimiter。

Worker prompt 允许 Codex 自主执行普通可逆本地工作：inspect/read、edit、build、test、lint、format、本地 validation，以及只读 git status/diff/log。它同时要求：

- 尊重既有 working-tree changes，不 revert unrelated user work；
- `.git` metadata 在 workspace-write 下 protected read-only；不尝试 `git add`、commit、merge、rebase、tag、创建/切换 branch、reset 或 clean；
- 如果 Task 要求 commit，Worker 可以完成安全的 working-tree 修改和验证，但必须返回 `needs_input`，说明 commit 需由未来 privileged/control-plane step 或用户完成；
- 不越过授权项目；
- 不尝试 push、fetch、pull、publish、deploy、remote GitHub mutation、web search 或其他网络操作；
- 不泄露 secret、token、credential 或 auth material；
- 最终报告不主动输出绝对本机路径或 thread ID；
- Task 对 protected action 的明确授权是必要条件，但不是获得额外 sandbox capability 的充分条件；
- 显式授权不能打开网络、增加 writable root、解除 `.git` protection 或启用 bypass。超出 Phase 6A runtime capability 的动作必须停在 `needs_input` boundary。

`approvalPolicy=never` 表示 CLI 不弹交互批准提示；它不移除 Worker prompt 的 protected-action authorization boundary，也不允许 Task 扩大 runtime sandbox。

## Structured model result

`--output-schema` 要求 exactly five required fields，并设置 `additionalProperties=false`：

```text
status   completed | needs_input
report   string
question string
context  string
options  array[string]
```

`completed` 要求非空 `report`，并使用空 `question`、空 `context`、空 `options`。

`needs_input` 仅用于真实决策、关键缺失上下文、protected-action authorization 或不可逆/高风险歧义。它要求非空 `report`、`question`、`context`，以及至少两个 distinct non-empty options。普通实现选择或可自行检查的信息不能成为提问理由。

模型不能返回 `failed`。`failed` 是 Worker control-layer 状态。

## Public output

Worker 返回固定 PowerShell object：

```text
version
status
project { name, localPath, githubRepository }
threadId
report
question
context
options
exitCode
diagnostic
```

成功的 `completed`/`needs_input` 必须有 exit code `0`、有效 threadId 与空 diagnostic。Codex 启动后的 non-zero exit、缺失或 malformed final result、无效 semantic combination、缺失/无效 thread UUID 或 JSONL protocol failure 返回 `status=failed`。Diagnostic 会清洗常见 credential patterns 并截断到约 2000 字符，不返回原始 event dump 或环境变量。

配置、Index、identity、路径、Git root、command resolution 或 process start 等 preflight/authorization failure 统一抛出：

```text
Codex Dispatch Worker 错误：...
```

## Privacy and future phases

`project.localPath` 与 `threadId` 是本地 API/control-plane contract。是否向 GitHub Issue 暴露它们由后续 Phase 6B 根据 privacy configuration 决定；Phase 6A 不调用 GitHub API。

Worker v0.1 暂不定义独立 hard-coded execution deadline，因为公共配置尚无 `workerTimeoutSeconds`。未来 control-plane/runtime phase 将为整次 dispatch 建立 orchestration-level execution policy。Process stdin/stdout/stderr 仍使用并发 I/O，避免经典 pipe deadlock。

Prompt-level protected-action policy 不是通用 command interception engine；因此 extra writable roots、shell network 与 web search 由 CLI runtime override 强制关闭。环境 secret-name exclusion 仍只是 defense in depth。

Phase 6A 也不实现 resume；它只保留可恢复 session 并返回经过验证的 threadId。

## Platform

Worker 脚本支持 Windows PowerShell 5.1。含中文的 `.ps1` 使用 UTF-8 BOM；临时 JSON 使用 UTF-8 no BOM。文档示例只使用机器无关 identity，不包含真实用户名、私有路径或凭据。
