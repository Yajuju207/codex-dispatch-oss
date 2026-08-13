# Worker Resume Primitive v0.1

`Invoke-CodexWorkerResume.ps1` 是 Phase 6C-1 的本地 Worker Resume primitive。它继续一个已经存在、此前返回 `needs_input` 的 Codex session，但它不是 mobile Issue workflow，也不处理 Issue comment、routing clarification、Runtime State transition 或 GitHub projection。

下一层 Resume Orchestrator 必须以 authoritative local Runtime State 作为 lifecycle source of truth，从该 State 取得已持久化的 `ProjectRepository` identity 与 `ThreadId`。本 primitive 不从 GitHub Issue、Markdown、旧 session 文本或任意本机路径重建 authority。

## Public command

```powershell
.\scripts\Invoke-CodexWorkerResume.ps1 `
    -Answer '继续方案 A，并保留现有修改' `
    -ProjectRepository 'owner/repository' `
    -ThreadId '11111111-1111-4111-8111-111111111111' `
    -ConfigPath .\config.local.json `
    -IndexPath .\project-index.json
```

固定参数为：

- `Answer`：必需字符串，长度为 1..16384 个 .NET string characters；whitespace-only 被拒绝。Worker 不 trim 或改写有效 Answer。
- `ProjectRepository`：必需的合法 `owner/repository` identity。
- `ThreadId`：必需的 lowercase canonical UUID D。
- `ConfigPath`、`IndexPath`：可选，沿用初始 Worker 的配置和 Index 解析语义。

不存在 `Task`、`ProjectPath`、Issue、dispatch、token、sandbox、approval、force、bypass、working-directory 或 `--last` 选择参数。Answer 是 v0.1 的 transient invocation input；本 primitive 不持久化 Answer。

## Authorization boundary

每次 Resume 都独立执行和初始 Worker 相同的当前授权链：

```text
ProjectRepository identity
→ current Project Index
→ Ordinal exact identity match exactly once
→ current localPath
→ workspace.root containment
→ complete reparse validation
→ exact Git toplevel
```

ThreadId 只选择 Codex session，永远不授予 filesystem capability。Worker 不持久化 `localPath`，也不从旧 session 恢复路径；它每次都从当前 Index 重新取得并验证路径。因此继续保持：

```text
ROUTER SELECTION != WORKER AUTHORIZATION
PERSIST IDENTITY, NOT CAPABILITY
```

## Exact Resume execution

Resume 复用 `CodexDispatchWorker.Common.ps1` 中与初始 Worker 相同的 application resolution、process execution、sandbox arguments、schema validation、diagnostic sanitation 和 temporary-artifact cleanup。

核心 CLI 形状为：

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
-c approval_policy="never"
--cd <freshly-authorized-project-root>
exec
--ignore-user-config
--json
--color never
--output-last-message <temporary-final-result>
--output-schema <temporary-schema>
resume <exact-ThreadId> -
```

Resume always uses the exact authoritative session ID and never `--last`. The continuation prompt is supplied through stdin, not the command line. Answer is represented as a JSON string in an explicit literal-data section; it cannot override Worker rules or enlarge runtime capability.

The prompt directs Codex to continue existing context, preserve completed work and current working-tree changes, remain within the freshly authorized repository, avoid `.git` mutation, network, push/merge/publish/deploy and secret disclosure, and ask again only for a genuine decision, critical missing context, protected action, irreversible operation or high-risk ambiguity.

## Structured result

The model final schema remains exactly:

```text
status   completed | needs_input
report   string
question string
context  string
options  array[string]
```

Public output remains exactly, in order:

```text
version
status
project
threadId
report
question
context
options
exitCode
diagnostic
```

After authorization, all structured outputs use the caller's canonical ThreadId. A Resume JSONL stream may omit `thread.started`. If it emits `thread.started`, every `thread_id` must itself be lowercase canonical UUID D and equal the requested ThreadId; a different ID is a protocol failure.

Malformed input, configuration, Index, identity, workspace, reparse, Git-root or command-resolution failures throw before Codex invocation. After authorization, process/transport/non-zero-exit/final-schema/protocol failures return `status=failed` with a bounded sanitized diagnostic and the requested ThreadId.

## Credential and GitHub boundary

This primitive has no GitHub credential, API or publication capability. It does not read Issues, publish Issues, inspect a control-plane repository or accept a token. The future Resume Orchestrator is responsible for removing `CODEX_DISPATCH_GITHUB_TOKEN`, `GH_TOKEN` and `GITHUB_TOKEN` before invocation; this primitive adds no fallback credential behavior.

## Deliberate limitations

- `routing/needs_input` clarification is intentionally not implemented; Phase 6C-1 only resumes an actual Worker session.
- Runtime State lookup/transitions, dispatchId lookup, mobile author validation, Issue comment handling and projection belong to the next layer.
- This primitive does not solve process crash/recovery. A caller must reconcile durable Runtime State and retry policy.
- Answer is transient and not persisted by this primitive.
- Session storage and protocol availability are responsibilities of the configured Codex CLI; this layer only requests the exact ThreadId.
- No GitHub Actions workflow, real network call, GitHub API call or real Codex invocation is part of the test contract.
