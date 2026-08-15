# Routing Resume Orchestrator v0.1

`Invoke-CodexDispatchRoutingResume.ps1` is Phase 6C-2B's synchronous project
clarification layer. It is not Codex session resume and it does not implement
Worker-session clarification.

Its public parameters are exactly `DispatchId`, `Answer`, `IssueNumber`, and
optional `ConfigPath`. Runtime State is authoritative. Only durable
`routing/needs_input` may resume, and its immutable `task` remains the durable
execution request.

The Answer is transient routing evidence. Fast Router receives only Answer.
Slow Router receives a compact ordered JSON envelope containing original task,
prior routing question/context/options, and Answer. The Initial Worker receives
only original immutable task plus the selected repository identity; neither
Answer nor the envelope reaches Worker execution.

The command first writes and reads back `routing/running`, clearing routing
output fields. It then runs Fast Router and, under the normal fallback rule,
Slow Router. A selected repository is written and read back as `worker/running`
with a null thread ID before the Initial Worker runs. Router local paths are not
authority; Worker reauthorizes the repository using the current Project Index,
workspace, and Git-root protections.

Initial Worker `completed` and `needs_input` results persist their valid thread
ID. A structured failed result preserves a valid returned thread ID when
available; throws and malformed results leave it null. Later
`worker/needs_input` is handled by Phase 6C-2A's
[`Invoke-CodexDispatchResume.ps1`](RESUME_ORCHESTRATOR.md), which is the
Worker-session continuation layer.

State is written and read back before the supplied existing Issue is updated.
The Issue number is projection identity only: this command never creates,
searches, or reconstructs an Issue from Issue text. Publisher success is only
`updated` or `noop`; projection failure never changes State.

The command removes `CODEX_DISPATCH_GITHUB_TOKEN`, `GH_TOKEN`, and
`GITHUB_TOKEN` before State, routing, and Worker activity. Publishing
temporarily restores only the original dedicated CODEX token, then an outer
`finally` restores the caller environment exactly, including absent versus
present-empty values.

Answer is never persisted, returned as a public property, supplied to Publisher,
or used as repository/path/capability authority. Fixed orchestrator-owned
routing text prevents raw Router exceptions and arbitrary routing prose from
becoming durable output. Structured repository identities and options are never
rewritten merely because they equal Answer.

A crash after `routing/needs_input -> routing/running` can lose Answer while
leaving State at `routing/running`. v0.1 provides no automatic retry or
recovery. “Stop dispatch” is an operator choice to cease future calls, not a
cancellation State or transition.
