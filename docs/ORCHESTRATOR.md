# Dispatch Orchestrator Core v0.1

`scripts/Invoke-CodexDispatch.ps1` composes one initial dispatch from durable
Runtime State, the current Project Index, the Fast and Slow Routers, the Worker,
and the GitHub Issue projection adapter.

Runtime State is the lifecycle source of truth. A GitHub Issue is a projection
of a user-visible durable state, not a database and not an authority source.

## Public command

```powershell
./scripts/Invoke-CodexDispatch.ps1 [-Task] <string> [-ConfigPath <string>]
```

`Task` is mandatory and positional. A whitespace-only value is rejected before
state creation. `ConfigPath` is optional and retains the Config Loader's normal
resolution behavior.

Initial dispatch does not accept a dispatch ID, Issue number, project path,
repository override, token, transport, thread ID, force switch, authorization
bypass, routing bypass, or Index path. `New-CodexDispatchState.ps1` generates a
new dispatch ID for every invocation, including invocations with identical task
text.

## Project Index policy

At invocation start, the Orchestrator resolves `project-index.json` in the
current working directory to one absolute file path. That exact path is passed
to the Fast Router, Slow Router when needed, and Worker.

The Orchestrator does not run Project Discovery and does not build or refresh
the Project Index. Index freshness belongs to a future workflow layer.

## Lifecycle

The durable lifecycle begins with:

1. create `routing/pending` at revision 1;
2. update to `routing/running`;
3. invoke routing only after that update succeeds.

Fast Router results are handled without adding Router statuses:

| Fast status | Orchestrator action |
| --- | --- |
| `strong` with a usable `githubRepository` | Accept repository identity and continue to Worker. |
| `strong` with `githubRepository = null` | Invoke Slow Router. Router `localPath` is ignored as authority. |
| `ambiguous` | Invoke Slow Router. |
| `no_match` | Invoke Slow Router. |
| `disabled` | Invoke Slow Router. |
| exception or malformed contract | Persist deterministic technical `routing/needs_input`; do not invoke Slow Router. |

Slow Router results are handled as follows:

| Slow status | Orchestrator action |
| --- | --- |
| `routed` | Accept `selectedProject.githubRepository` as identity. |
| `needs_input` | Persist `routing/needs_input` with Router question and options and deterministic report/context. |
| `no_match` | Persist deterministic `routing/needs_input` with two distinct operator options. |
| `disabled` | Persist deterministic `routing/needs_input` intervention fields. |
| exception or malformed contract | Persist deterministic technical `routing/needs_input`. |

Runtime State v1 has no `routing/failed`, so Router exceptions and invalid
contracts are operational interventions represented as `routing/needs_input`.

After a repository identity is selected, the Orchestrator durably updates to
`worker/running` with `projectRepository` before calling the Worker. It passes
only `Task`, `ProjectRepository`, `ConfigPath`, and the resolved `IndexPath`.
The Worker remains responsible for current-index identity authorization,
workspace and Git-root authorization, reparse validation, and Codex sandbox and
security controls. Router selection is not Worker authorization.

Worker results map to durable `worker/completed`, `worker/needs_input`, or
`worker/failed`. A Worker invocation or preflight exception is sanitized and
persisted as `worker/failed`. A structured Worker `failed` result is returned as
a normal failed dispatch, not thrown.

## State-first projection

Only these user-visible durable states are projected:

- `routing/needs_input`
- `worker/needs_input`
- `worker/completed`
- `worker/failed`

The Orchestrator does not project pending or running states. For every projected
path, the ordering is:

```text
Runtime State durable update
Runtime State readback
GitHub Issue publication
structured Orchestrator return
```

An initial dispatch calls `Publish-CodexDispatchIssue.ps1` without an Issue
number and makes at most one create attempt. The Issue adapter owns open/closed
desired-state reconciliation. The Orchestrator does not issue GitHub POST or
PATCH requests and does not retry a partial-create failure, because retrying
without an Issue number could create a duplicate.

Private-repository preflight, create, reconciliation, or other projection
failures do not modify execution State. They return `issuePublication = failed`
and a bounded `projectionDiagnostic`. In v0.1 the Orchestrator does not parse an
Issue number or URL from partial-create exception text.

## Credential isolation

At entry the Orchestrator captures both existence and value for these process
environment variables:

- `CODEX_DISPATCH_GITHUB_TOKEN`
- `GH_TOKEN`
- `GITHUB_TOKEN`

It then removes all three before routing and Worker execution. Consequently,
Slow Router, Worker, and their child processes cannot inherit those control-plane
GitHub credentials.

For Issue publication only, the captured `CODEX_DISPATCH_GITHUB_TOKEN` state is
temporarily restored. `GH_TOKEN` and `GITHUB_TOKEN` remain absent. The CODEX
token is removed immediately after the Publisher returns or throws. An outer
`finally` restores the caller's exact original existence and value for all three
variables, including the distinction between absent and present with an empty
string.

This design mutates the process environment, which is process-global. v0.1
therefore supports synchronous, single-runspace invocation only. Parallel
Orchestrator invocations in the same PowerShell process are unsupported.
Separate PowerShell processes may invoke independently.

Technical diagnostics are bounded and scrub non-empty values captured for only
the three control-plane credential variables above. This is not general secret
redaction.

## Output

Normal return uses this fixed field order:

1. `version` (`int`, exactly `1`)
2. `dispatchId` (lowercase canonical UUID `D`)
3. `revision` (`int64`, at least `1`)
4. `phase` (`routing` or `worker`)
5. `status` (`needs_input`, `completed`, or `failed`)
6. `projectRepository` (`string` or `null`)
7. `report` (`string`)
8. `question` (`string`)
9. `context` (`string`)
10. `options` (`string[]`)
11. `diagnostic` (`string`)
12. `issuePublication` (`created` or `failed`)
13. `issueNumber` (`int64` or `null`)
14. `issueUrl` (`string` or `null`)
15. `projectionDiagnostic` (`string`)

Execution fields through `diagnostic` come from final durable Runtime State
readback. Issue fields are process-local projection metadata. Initial dispatch
accepts only Publisher action `created`; `updated`, `noop`, or an invalid result
is a projection contract failure and cannot rewrite execution truth.

The public output does not include task text, thread ID, local path, raw Router
or Worker objects, or tokens.

## Failure semantics and limitations

Any Runtime State create or update failure throws and stops. The Orchestrator
does not invoke components that depend on an unconfirmed state and does not
project it. It never assumes a failed update advanced the revision.

The Runtime State component uses `File.Replace` for commit. In an extreme
post-replace failure, the commit outcome can be ambiguous. v0.1 does not change
the State component and does not implement recovery for that boundary.

This phase does not implement GitHub Actions workflows, workflow dispatch,
Issue comment handling, Resume, `codex exec resume`, webhooks, daemons,
schedulers, Issue search/discovery, Runtime State schema v2, multi-user
authorization, or general secret redaction.
