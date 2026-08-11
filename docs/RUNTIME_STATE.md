# Local Runtime State Store v0.1

Phase 6B-1 引入本地 dispatch state persistence，但不调用 GitHub API、不创建 GitHub Issue、不运行 Router/Worker，也不实现 Resume。

## Source of truth

```text
GITHUB ISSUE != SOURCE OF TRUTH
```

`runtime.stateDirectory` 下的 state JSON 是 dispatch lifecycle 的权威状态。未来 GitHub Issue 只应保存 `dispatchId` 与 privacy-safe user-facing projection；Issue body 不应成为 original task、repository identity 或 Codex thread ID 的唯一数据库。

## Directory separation

`runtime.stateDirectory` 必须预先存在，并应位于普通用户私有本机目录。Config Loader 只读，不创建它。Runtime State layer 只可在其中创建直接子目录 `dispatches`。

规范化后的 state directory 不能位于任何 Git working tree 内。Loader 从 state directory 自身沿 ancestors 检查到 filesystem root；任何 `.git` directory 或 file marker 都会触发拒绝。它不扫描 descendants，因此 state directory 的 sibling 或 descendant 中存在 unrelated Git repository 不影响配置。相对路径仍受支持，包括从 Git checkout 内的 config directory 解析到 checkout 外的私有目录。

推荐布局：

```text
<private-state-directory>\dispatches\<canonical-dispatch-id>.json
```

State directory 与 `workspace.root` 必须位于彼此分离的目录树：不能相等、不能互为 descendant。它不应被提交、同步到 public repository，或放入 GitHub runner credential/install directory。

Config Loader 与 Runtime State API 都检查完整现有目录链，拒绝 reparse point。`dispatches` 如果不存在可由 Runtime State layer 创建；如果已存在，则必须是 non-reparse directory。

## Identity, not capability

```text
PERSIST IDENTITY
NOT CAPABILITY
```

State 可以保存 `projectRepository`，但 schema 中不存在 `localPath`。未来 Resume 必须执行：

```text
projectRepository
-> current Project Index
-> current authorization
-> local path
```

State Store 不访问 Project Index，也不持久化 filesystem capability。

## State schema v1

每个 JSON 严格包含以下字段并保持此顺序：

```text
version
dispatchId
revision
createdAtUtc
updatedAtUtc
phase
status
task
projectRepository
threadId
report
question
context
options
diagnostic
```

未知或缺失字段、错误类型、非 canonical UUID、非 UTC round-trip timestamp 和 impossible semantic combinations 都会被拒绝。JSON 使用 strict UTF-8 no BOM。

`dispatchId` 是 Runtime State layer 生成的 lowercase GUID v4 canonical `D`。所有 read/update API 先用 `Guid.TryParseExact(..., "D")` 解析，再 canonicalize；文件路径只能从解析后的 ID 派生，不能从 caller text 直接拼接。

## Lifecycle

合法转换只有：

```text
routing/pending     -> routing/running | routing/needs_input
routing/running     -> routing/needs_input | worker/running
routing/needs_input -> routing/running
worker/running      -> worker/completed | worker/needs_input | worker/failed
worker/needs_input  -> worker/running
```

`worker/completed` 与 `worker/failed` 是 terminal states，不可再更新。Schema validator 同时检查每个 phase/status 的 repository、thread、report、question、context、options 与 diagnostic 组合。

## Revision and concurrent writers

Create 从 `revision=1` 开始。Update 要求 caller 提供 `ExpectedRevision`；只有它与当前 revision exact 相等时才允许写入，新 revision 固定为旧值加一。冲突返回 `revision 冲突`，不会静默覆盖。

每个 dispatch update 使用由 canonical ID 派生的 exclusive coordination lock。两个基于 revision N 的 concurrent writers 不能都成功；获得锁的后继 writer 会重新读取当前 state 并看到 revision conflict。

## Atomic writes

Create/update 都先在同一个 `dispatches` directory 写入随机 GUID 命名的 temporary file：

1. UTF-8 no BOM 完整序列化；
2. flush data to disk；
3. Create 使用 same-directory atomic move，目标存在时拒绝覆盖；
4. Update 使用 `File.Replace` 原子替换，随机 backup 立即清理；
5. `finally` 清理 temporary、backup 与 coordination artifacts。

Readers 只会看到替换前或替换后的完整 JSON，而不是直接覆盖产生的 partial target。

## Local privacy

允许持久化：

- original task；
- repository identity；
- Codex thread/session ID；
- worker report、question、context、options 与 diagnostic。

State schema 没有以下专用字段：

- `localPath`；
- credential、GitHub/OpenAI token 或 Codex auth material；
- environment；
- raw Codex event stream；
- runner credentials。

Runtime State layer 不主动采集 GitHub token、OpenAI token、environment、Codex auth material 或 raw events。但是 `task`、`report`、`context`、`question` 与 `diagnostic` 是任意文本；如果上游传入敏感信息，这些字段可能包含敏感内容。为保持 Task exact round-trip，State Store 不自动改写或 redact Task。

因此整个 `runtime.stateDirectory` 必须视为 `SENSITIVE LOCAL DATA`，并依赖本机 filesystem/account ACL 保护。它不能位于 Git working tree，不应同步到 public service，也不应放入 GitHub runner credential/install directory。

## Known limitations

v0.1 使用完整目录链 reparse validation、non-reparse target checks、same-directory atomic replace 与 exclusive coordination，显著缩小 replacement race。WinPS 5.1/.NET Framework 没有为本实现提供一个可携带、可完全证明的“按 handle 原子校验并替换 pathname”接口，因此对不遵守本地目录权限、可在检查与打开/替换之间主动重写目录项的同机攻击者，仍存在 OS-level TOCTOU limitation。本文不声称消除了该平台边界。

v0.1 不提供 at-rest encryption，也不对任意文本字段执行自动 secret detection 或 redaction。部署者必须通过本机账户与 filesystem ACL 保护 state directory，并约束上游传入的文本内容。
