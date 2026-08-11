# GitHub Issue Projection Adapter v0.1

## Security boundary

**GITHUB ISSUE != SOURCE OF TRUTH**

GitHub Issue 是 Local Runtime State 的 notification surface、human-readable projection，以及未来可能使用的 mobile interaction surface。权威方向始终是：

```text
LOCAL RUNTIME STATE
        |
        v
privacy-safe projection
        |
        v
GitHub Issue
```

Issue 包含 opaque `dispatchId`、projection revision 和受 privacy 配置约束的 human-readable projection。Issue 不是 task database、thread database、filesystem authorization source 或 lifecycle source of truth。

Issue 内容不授权：

- filesystem 或 local project path；
- project access；
- Codex session access；
- Runtime State transition；
- lifecycle 状态变更。

用户手动修改 Issue 的 title、body 或 open/closed state，不会修改本机 Runtime State。后续 publisher 可以用本机当前 state 恢复 canonical projection。

未来 Resume 必须遵循：

```text
Issue dispatchId
        |
        v
Local Runtime State
        |
        v
current project identity
        |
        v
fresh authorization
```

Issue 只能提供 opaque dispatch identity；Resume 不能从 Issue 恢复 task、thread ID、project、status 或 report，也不能把 Issue 中的 path 或文本当作 capability。

## Public commands

生成本地 projection（无网络）：

```powershell
.\scripts\New-CodexDispatchIssueProjection.ps1 `
    -DispatchId '00000000-0000-0000-0000-000000000001' `
    -ConfigPath '.\config.local.json'
```

输出字段固定为：

```text
version
dispatchId
revision
title
body
desiredState
```

发布新 Issue：

```powershell
.\scripts\Publish-CodexDispatchIssue.ps1 `
    -DispatchId '00000000-0000-0000-0000-000000000001' `
    -ConfigPath '.\config.local.json'
```

更新已知 Issue：

```powershell
.\scripts\Publish-CodexDispatchIssue.ps1 `
    -DispatchId '00000000-0000-0000-0000-000000000001' `
    -IssueNumber 42 `
    -ConfigPath '.\config.local.json'
```

Publisher 只操作 Loader 返回的 `config.controlPlane.repository`。公开命令不接受 repository、owner、token、API base URI 或 transport 参数。生产 endpoint 固定为 `https://api.github.com`。

每次 Publish 在任何 Issue POST、GET 或 PATCH 之前，都会先用相同 credential 和固定 headers 请求 `/repos/{configured-repository}`。只有 metadata `private` 是 JSON bool `true`，且 `full_name` 与配置的 repository identity case-insensitive exact 匹配时，才授权该 control-plane destination。Public repository、缺失或类型错误的 `private`、无效 `full_name`、rename/redirect 后的 identity mismatch 都会 fail closed。Repository metadata 仅用于 destination authorization，不写入 Runtime State，也不成为 dispatch lifecycle truth。

## Identity markers

每个 canonical body 的前三行是：

```text
<!-- CODEX_DISPATCH_ID: <lowercase-canonical-uuid> -->
<!-- CODEX_DISPATCH_REVISION: <positive-integer> -->

```

Marker 只表示 projection identity 和 projection revision，不是 source of truth。Update 只解析 body 开头的 exact marker prefix；正文中的相似 comment、task 文本或 report 文本不会参与 identity parsing。

Publisher 要求 existing Issue marker 的 dispatch ID 与 caller exact 匹配。Remote revision 高于 local Runtime State revision 时，publisher 拒绝 rollback；revision 相同且 title/body/state 完全一致时返回 `noop`；相同 revision 下的人工编辑和更低 remote revision 都会被 canonical local projection 覆盖。

## Projection format and lifecycle

Title 固定为：

```text
[CodexDispatch][<STATUS>][<TARGET>]
```

Title 不包含 task、thread ID、local path 或 diagnostic，并 deterministically 截断到不超过 120 characters。Routing target 为 `ROUTING`；worker target 为 `projectRepository` 的 repository-name 部分。

Desired Issue state：

| Runtime State | Issue state |
|---|---|
| `routing/pending` | open |
| `routing/running` | open |
| `routing/needs_input` | open |
| `worker/running` | open |
| `worker/needs_input` | open |
| `worker/completed` | closed |
| `worker/failed` | open |

Failure 保持 open，便于人工查看和处理。Issue state 仍然只是 projection，不是 lifecycle truth。

Task、report、question、context、options 和 diagnostic 都是 arbitrary text。Adapter 对这些字段做 deterministic HTML encoding，并置于 literal `<pre>` rendering 中；正文中的 Markdown heading、fenced code、HTML comment、fake marker、mention 或 link syntax 不会成为 adapter machine metadata。

`worker/failed` 显示固定摘要 `Dispatch failed.`，并可显示 literal-safe diagnostic。Adapter 不声称能够自动 secret-redact arbitrary text，因此 control-plane repository 必须是 **PRIVATE**。

## Privacy behavior

Adapter 严格要求以下字段是 JSON bool，不接受字符串 `"false"`：

- `privacy.exposeLocalPathsInIssues`；
- `privacy.exposeThreadIdsInIssues`；
- `privacy.includeOriginalTaskInIssues`。

`exposeThreadIdsInIssues=false` 时 body 任何位置都不包含 state 的 thread ID：除隐藏显式 Thread ID section 外，adapter 还会在 task、report、question、context、options 和 diagnostic 等 arbitrary projected text 中，对 exact canonical thread ID 做 case-insensitive deterministic replacement：`[REDACTED_THREAD_ID]`。它不会泛化删除其他 UUID。为 `true` 时可以显示 canonical thread ID，包括显式 Thread ID section 和 arbitrary text 中的原值。

`includeOriginalTaskInIssues=false` 时 body 不包含 direct original Task section；为 `true` 时可以显示 literal-safe task。这个开关不尝试判断 report 或其他文本是否语义复述了 Task。

Runtime State v0.1 没有 `localPath`，Issue Adapter 不查询 Project Index、不做 path discovery，也不从其他输入重建 path。因此 `exposeLocalPathsInIssues` 在本 Phase 不授予任何新增 capability：无论 true 或 false，adapter 都不会主动解析或显示 local path。未来若其他 projection source 引入 path，才必须受该开关约束。

原则是：**PERSIST IDENTITY, NOT CAPABILITY.**

## Credential contract

Token 不能存入 config、Runtime State、Issue、diagnostic 或日志，也不能作为公开命令参数。v0.1 只从 process environment 读取：

```text
CODEX_DISPATCH_GITHUB_TOKEN
```

该变量必须 non-empty。没有 fallback 到 `GH_TOKEN` 或 `GITHUB_TOKEN`。

`CODEX_DISPATCH_GITHUB_TOKEN` 只属于 future control-plane layer。Worker/Codex process **MUST NOT inherit** `CODEX_DISPATCH_GITHUB_TOKEN`。本 Phase 不修改 Worker，也不实现 credential-isolating orchestrator；这个隔离必须在后续 control-plane integration 中完成。

HTTP 错误只报告 bounded status、GitHub message 和不含 query secret 的 endpoint path。Adapter 不记录 Authorization header 或完整 response body，并在错误文本中移除当前 configured token value。

Exact thread-ID replacement 不是 general secret redaction。Arbitrary text 仍可能包含其他未识别的 token、credential、path 或敏感内容；v0.1 不提供 public-repository escape hatch，control-plane repository 必须保持 private。

## Create and update

Private-repository preflight 成功后，Create 才会对 `/repos/{configured-repository}/issues` 发送 `title` 和 `body`。只有 `controlPlane.issueAssignee` 存在、trim 后非空且符合 conservative GitHub login syntax 时才发送单元素 `assignees`；否则省略该字段。

Update 先 GET configured repository 中的 Issue，并拒绝带 `pull_request` object 的响应。Body 必须存在且以合法 markers 开头。需要同步时，PATCH 只发送 canonical `title`、`body` 和 desired `state`。

Remote title、body、state 不会反向更新 Runtime State。Update 唯一用于决策的 remote data 是 exact dispatch marker 与 projection revision；它们只回答“这是哪个 projection”和“是否已经存在更新版本”。

## Scope

v0.1 是独立、可测试的 control-plane primitive。它不创建 GitHub Actions workflow，不实现 Resume，不处理 `issue_comment`，也不连接 Router、Worker 或 Runtime State transitions。所有 adapter tests 使用 fake transport；测试不会访问真实 GitHub。
