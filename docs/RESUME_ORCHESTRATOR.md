# Resume Orchestrator v0.1

`Invoke-CodexDispatchResume.ps1` is Phase 6C-2A's synchronous Worker-session
continuation layer. It is not an Issue-comment workflow and does not implement
routing clarification.

Project clarification for durable `routing/needs_input` is separately handled
by Phase 6C-2B's [`Invoke-CodexDispatchRoutingResume.ps1`](ROUTING_RESUME_ORCHESTRATOR.md).
That command selects a project for immutable State task; this command only
continues an already-created Worker session in `worker/needs_input`.

Its public parameters are exactly `DispatchId`, `Answer`, `IssueNumber`, and
optional `ConfigPath`. The local Runtime State is authoritative: it supplies
the repository identity and thread ID; neither is accepted from the caller or
recovered from Issue text. The supplied Issue number is projection identity
only.

Only durable `worker/needs_input` may resume. The command first writes and
reads back `worker/running`, explicitly preserving State repository/thread ID
and clearing prior user-facing output, then invokes the Resume Worker with the
freshly resolved current-CWD `project-index.json`. The Worker independently
reauthorizes the repository through the current index.

After the Worker returns, the command durably writes and reads back
`worker/completed`, `worker/needs_input`, or `worker/failed` before it updates
the supplied existing Issue. Existing-Issue publication accepts `updated` and
`noop`; a projection failure never changes execution State and never creates or
searches an Issue.

The process captures and removes `CODEX_DISPATCH_GITHUB_TOKEN`, `GH_TOKEN`,
and `GITHUB_TOKEN` before State and Worker work. Publication temporarily
restores only the captured dedicated CODEX token; a `finally` restores the
caller environment exactly, including absent versus empty values.

`Answer` is transient and is never persisted. Consequently, a crash after the
`worker/needs_input` to `worker/running` transition can lose the Answer while
leaving a non-resumable running State. Likewise, the command never reruns a
Worker after a final State-write failure. Both cases require operator
intervention in v0.1.
