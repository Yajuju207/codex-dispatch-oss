# Private Control-Plane Workflow v0.1

This document defines the public OSS contract for operating Codex Dispatch from
a separate, per-user private GitHub control repository. The active workflow,
runner registration, local configuration, Project Index, Runtime State, and
credentials do not belong in this public repository.

The inactive reference template is:

```text
examples/private-control/dispatch.yml.example
```

It must be reviewed and copied deliberately into the private control repository.
The public OSS repository does not install or activate it.

## Trust boundary

Runtime State is the dispatch lifecycle source of truth. A private GitHub Issue
is a projection and notification surface, not a lifecycle database.

```text
mobile workflow_dispatch (Task data only)
    -> private control repository default-branch workflow
    -> dedicated self-hosted Windows runner
    -> reviewed, full-SHA-pinned public OSS engine
    -> runner-local Project Index and authorized workspaces
    -> durable runner-local Runtime State
    -> private control-repository Issue projection
```

The private control repository is privileged. Write access to it is equivalent
to trust to execute code on the self-hosted runner. The job-level default-branch
gate prevents an operator from accidentally selecting a branch or tag in the
manual-run UI, but it is not an independent security boundary against a
malicious repository writer: such a writer can change the default-branch
workflow itself.

Protect the private repository's default branch and workflow file. If an
organization or enterprise runner group is used later, restrict that runner
group to the private repository and, where the platform supports it, to the
exact workflow path pinned to `refs/heads/main` or a reviewed full commit SHA.
The public OSS repository, its pull requests, forks, and arbitrary workflows
must never be allowed to target the privileged runner.

## Repository responsibilities

The public OSS repository owns:

- the dispatch engine and its component contracts;
- tests that use fake transports and fake Codex processes;
- this deployment contract;
- an inactive private-control workflow example.

The private control repository owns:

- the active `workflow_dispatch` workflow on its protected default branch;
- the reviewed full OSS engine commit SHA;
- the dedicated runner selection and concurrency policy;
- the private Issues produced by dispatch projection;
- operational documentation for its runner.

Runner-local storage owns:

- `config.local.json`;
- `project-index.json`;
- the sensitive Runtime State directory;
- authorized project workspaces;
- Codex authentication managed outside GitHub workflow inputs and files.

Never commit or upload local configuration, Project Index, Runtime State, task
text, Codex authentication, runner registration credentials, tokens, or local
workspace inventory as workflow artifacts.

## Runner topology

v0.1 requires a dedicated Windows self-hosted runner associated only with the
private control repository. The example selects all of these labels:

```text
self-hosted
Windows
X64
codex-dispatch-control
```

Labels are routing metadata, not authorization. Use a repository-level runner
for a personal private repository, or a runner group restricted to the selected
private repository. Run the service under a dedicated Windows account with ACL
access only to the required control root, Runtime State, and workspace roots.

Do not place the control root, Runtime State, workspace root, or Codex data under
the GitHub Actions runner installation or credential directories. Do not place
unrelated personal or infrastructure credentials in the runner account.

The self-hosted runner is persistent trusted infrastructure. A workflow cannot
make an already compromised runner trustworthy; suspected compromise requires
runner and host reprovisioning.

## Workflow dispatch input

The only v0.1 input is mandatory string `task`. The workflow rejects:

- a missing or zero-length Task;
- a whitespace-only Task;
- a Task longer than 16,384 .NET string characters.

Validation does not trim, normalize, truncate, or otherwise rewrite an accepted
Task. The original string is passed through the step-scoped environment
variable `CODEX_DISPATCH_TASK`:

```powershell
-Task $env:CODEX_DISPATCH_TASK
```

`${{ inputs.task }}` must never be inserted into PowerShell source. It may only
populate the step-scoped Task environment variable.

The workflow must not accept project paths, repository overrides, dispatch or
thread IDs, Issue numbers, tokens, commands, script paths, engine refs, config
paths, Index paths, or authorization/routing bypasses.

## Engine acquisition

The v0.1 privileged template contains no `uses:` entries. It uses only
PowerShell and native Git; it does not use `actions/checkout` or any third-party
action.

Every run creates a fresh engine directory beneath `RUNNER_TEMP`, fetches the
public OSS repository without credentials, checks out detached HEAD, and
requires `git rev-parse HEAD` to exactly equal the workflow's constant
40-character SHA. A branch, floating tag, caller-supplied ref, or locally reused
engine is not accepted.

Engine fetch removes `CODEX_DISPATCH_GITHUB_TOKEN`, `GH_TOKEN`, and
`GITHUB_TOKEN` from the process environment, disables credential helpers and
interactive prompting, ignores system Git configuration, uses a fresh empty
global Git configuration, and forces `GIT_CONFIG_COUNT=0` so Git processes no
`GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` environment command-scope config
pairs. It then uses only the public repository URL. This is predictable native
Git acquisition isolation, not general protection from a compromised runner.
Failure or SHA mismatch stops before configuration preflight, Index rebuild,
Runtime State creation, or Issue credential injection.

Upgrading the engine means reviewing a new OSS commit and changing the pinned
full SHA through the private repository's protected change process.

## Stable local paths and configuration

The template uses this runner-local control root:

```text
C:\CodexDispatch\control
```

The private operator may replace that constant before activation, but it must
remain a workflow constant—not a dispatch input. The directory must already
exist and contain:

```text
config.local.json
project-index.json        # generated immediately before dispatch
```

The Orchestrator resolves `project-index.json` from its current working
directory, so the workflow changes location to the control root before invoking
`Invoke-CodexDispatch.ps1`. It passes the absolute local configuration path via
`-ConfigPath`.

Relative `workspace.root` and `runtime.stateDirectory` values are resolved by
the Config Loader relative to `config.local.json`. Runtime State must remain in
an existing ACL-protected directory outside every Git working tree, outside the
workspace tree, and outside the runner installation/credential tree.

## Control-repository identity preflight

Before Index rebuild, Runtime State creation, and Issue-token injection, the
workflow loads runner-local `config.local.json` through the pinned engine's
Config Loader. It validates `GITHUB_REPOSITORY` as an `owner/repository`
identity using the same shape restrictions, then compares it with
`config.controlPlane.repository` using an ordinal, case-sensitive exact match.

A mismatch is a fail-stop `CONTROL_REPOSITORY_PREFLIGHT_FAILURE`. The workflow
must not rebuild the Index, invoke the Orchestrator, create Runtime State, or
inject `CODEX_DISPATCH_GITHUB_TOKEN` after that failure.

This exact-identity requirement keeps the built-in job token and Issue target
in the same private repository. Cross-repository publication is out of scope for
v0.1 and must not be enabled with a broader personal access token.

## Project Index freshness

The Orchestrator consumes an existing `project-index.json` and intentionally
does not schedule Discovery or Index refresh. Therefore the workflow layer must
rebuild the Index before every initial dispatch:

```text
control-repository identity preflight
    -> Build-CodexProjectIndex.ps1
    -> Invoke-CodexDispatch.ps1
```

`Build-CodexProjectIndex.ps1` already invokes Project Discovery internally. The
workflow must not call `Discover-CodexProjects.ps1` separately. Index failure
stops before Orchestrator invocation and therefore before Runtime State
creation. A stale cached Index is not a v0.1 fallback.

The rebuild runs without all three GitHub credential environment variables.

## Credentials and permissions

The workflow's complete token permission declaration is:

```yaml
permissions:
  issues: write
```

All unspecified permissions are `none`. In particular, v0.1 does not request
`contents: write`, `pull-requests: write`, `actions: write`, or
`id-token: write`. Public engine acquisition does not require repository-content
credentials.

The Issue-write credential comes from the private control repository's
job-scoped `${{ github.token }}`. It is mapped only on the Orchestrator step:

```text
github.token -> CODEX_DISPATCH_GITHUB_TOKEN
```

It is not mapped to `GH_TOKEN` or `GITHUB_TOKEN`, and it is not defined at
workflow or job scope. The workflow removes `GH_TOKEN` and `GITHUB_TOKEN` before
Orchestrator invocation. The Orchestrator then removes all three credentials
during Fast Router, Slow Router, Worker, and Codex execution and temporarily
restores only `CODEX_DISPATCH_GITHUB_TOKEN` inside Issue publication.

| Process | CODEX token | GH token | GITHUB token |
| --- | --- | --- | --- |
| Engine fetch | absent | absent | absent |
| Configuration preflight | absent | absent | absent |
| Index build/Discovery | absent | absent | absent |
| Orchestrator entry | present | absent | absent |
| Fast/Slow Router and Codex child | absent | absent | absent |
| Worker and Codex child | absent | absent | absent |
| Issue Publisher scope | present | absent | absent |

The runner service account must not define persistent values for these three
variables.

## Concurrency

The Orchestrator is synchronous and supports one runspace per invocation. v0.1
serializes the complete workflow—including engine acquisition, Index rebuild,
Worker execution, and projection—with one constant group:

```yaml
concurrency:
  group: codex-dispatch-control-plane-v0-1
  cancel-in-progress: false
  queue: max
```

The group contains no caller-controlled value. A new Task must not cancel an
in-progress or older pending Task. Any future workflow that refreshes the same
Index or operates on the same workspaces must share this serialization boundary.

## Failure classification

The template distinguishes:

- `CONTROL_PLANE_PROCESS_FAILURE`: engine, configuration, Index, invocation, or
  result-contract failure; the workflow fails;
- `DISPATCH_COMPLETED`: durable `worker/completed`; the workflow succeeds;
- `DISPATCH_NEEDS_INPUT`: durable routing/Worker `needs_input`; the workflow
  succeeds and waits for a future Phase 6C interaction design;
- `DISPATCH_EXECUTION_FAILED`: durable `worker/failed`; the lifecycle completed
  correctly and the workflow succeeds while reporting the failed dispatch;
- `PROJECTION_FAILURE`: durable execution State exists but Issue publication
  failed; the workflow fails for operator visibility without changing State.

Projection failure must never trigger an automatic retry. The Issue adapter may
have created an Issue before desired-state reconciliation failed; retrying an
initial publication without an Issue number could create a duplicate. Do not
search Issues or reconstruct lifecycle state from GitHub in v0.1.

Workflow summaries contain only dispatch ID, outcome classification, and Issue
publication status. They do not contain Task, report/context, diagnostic,
thread ID, local path, configuration, Index, Runtime State, or token values.

## Activation checklist

Before copying the example to the private repository:

1. protect the private default branch and workflow changes;
2. ensure only fully trusted writers can modify or dispatch the repository;
3. dedicate/restrict the Windows runner to that private repository;
4. review and update the full pinned engine SHA;
5. establish the fixed local control root and ACLs;
6. create and validate local `config.local.json`;
7. ensure `controlPlane.repository` exactly equals `GITHUB_REPOSITORY`;
8. ensure the Runtime State and workspace directories satisfy Config Loader
   boundaries;
9. ensure persistent GitHub token environment variables are absent;
10. run the private-repository workflow contract tests with fake components
    before enabling real dispatch.

## Explicit exclusions

This contract does not implement Runner registration, setup automation,
`issue_comment`, Resume, `codex exec resume`, webhooks, schedules, daemons,
cross-repository credentials, Index caching, artifact upload, or active public
workflows.
