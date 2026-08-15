# Codex Dispatch OSS v0.1.0

Codex Dispatch OSS is a Windows-first local dispatch engine for routing natural-language work to Codex in authorized Git projects.

It can discover local Git projects, build a Project Index, fast-route deterministic tasks, slow-route ambiguous tasks, invoke Codex in an independently authorized workspace, persist Runtime State, project results or `NEEDS_INPUT` to a private GitHub control plane, and resume routing or Worker/Codex clarification.

## What it is not

This public repository does not expose the maintainer's personal deployment. Secrets, Codex authentication, local configuration, Runtime State, and workspace inventories do not belong here. It contains no active privileged self-hosted GitHub workflow; the private control-plane example is intentionally inactive. Anyone activating a private control repository or self-hosted runner is responsible for protecting that boundary.

## Architecture

Runtime State is the source of truth. A GitHub Issue is an untrusted projection/input surface, not a lifecycle database. Router selection is not Worker authorization: the Worker independently re-authorizes the selected workspace from the current local configuration and Project Index.

```text
Config Loader -> Discovery -> Project Index -> Fast Router
                                      -> Slow Router when needed
                                      -> Orchestrator -> Worker -> Runtime State
                                                       -> private GitHub Issue projection

routing/needs_input -> Routing Resume Orchestrator
worker/needs_input   -> Worker Resume / Codex thread resume
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the [documentation map](#documentation).

## Requirements

- Windows PowerShell 5.1-compatible execution environment.
- Git available on `PATH` for discovery and Project Index construction.
- Codex CLI available on `PATH` only when running the Worker/Orchestrator locally.
- GitHub is optional for the local engine; it is required only when a user deliberately activates the separate private control-plane example.

The repository does not claim support for a specific Windows, Git, or Codex version beyond the contracts exercised by the scripts and tests.

## Local quick start

This path does not activate GitHub Actions or require a runner:

```powershell
git clone https://github.com/Yajuju207/codex-dispatch-oss.git
Set-Location .\codex-dispatch-oss
New-Item -ItemType Directory -Force .\local\workspace, .\local\state, .\local\control | Out-Null
Copy-Item .\config.example.json .\config.local.json
```

Edit `config.local.json` so `workspace.root` points to an existing local project root, `runtime.stateDirectory` points to an existing separate state directory, and the control-plane placeholders remain private values if remote projection will be used. Then run:

```powershell
$config = .\scripts\Load-CodexDispatchConfig.ps1 -Path .\config.local.json
.\scripts\Discover-CodexProjects.ps1 -ConfigPath .\config.local.json
.\scripts\Build-CodexProjectIndex.ps1 -ConfigPath .\config.local.json -OutputPath .\local\control\project-index.json
.\tests\Run-All.ps1
```

The loader and discovery scripts do not create the configured roots. Keep `config.local.json`, the generated index, Runtime State, and Codex credentials outside commits. For remote operation, read [docs/PRIVATE_CONTROL_PLANE.md](docs/PRIVATE_CONTROL_PLANE.md) and review the inactive example before any activation.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Configuration](docs/CONFIGURATION.md)
- [Project Discovery](docs/PROJECT_DISCOVERY.md)
- [Project Index](docs/PROJECT_INDEX.md)
- [Runtime State](docs/RUNTIME_STATE.md)
- [Fast Router](docs/FAST_ROUTER.md) and [Slow Router](docs/SLOW_ROUTER.md)
- [Orchestrator](docs/ORCHESTRATOR.md), [Worker](docs/WORKER.md), and resume contracts
- [Private control-plane contract](docs/PRIVATE_CONTROL_PLANE.md)

## Security model

Task and comment text is untrusted input. Local configuration and the current Project Index authorize workspaces; the Worker rechecks that authorization. Credentials are isolated from routing and Worker/Codex execution, and State is persisted before Issue projection. Read [SECURITY.md](SECURITY.md) before using a private control plane.

## License

MIT. See [LICENSE](LICENSE).
