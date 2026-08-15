# Architecture

Codex Dispatch OSS is a local Windows dispatch engine. A separate private control plane is optional and intentionally inactive in this public repository.

## Implemented flow

```text
Config Loader
    -> Discovery
    -> Project Index
    -> Fast Router
    -> Slow Router when deterministic routing is insufficient
    -> Orchestrator
    -> Worker
    -> Runtime State
    -> GitHub Issue projection (optional private control plane)
```

The Config Loader validates existing local roots and the control-plane identity. Discovery reads local Git metadata without reading source contents. The Project Index records routing evidence, not execution capability. Fast and Slow Router results are checked by the Orchestrator, and the Worker independently authorizes the selected repository before invoking Codex.

## State and projection

Runtime State is the source of truth for dispatch lifecycle and clarification state. The implementation persists State first and projects to GitHub second. A publication failure must not rewrite durable execution truth. Issue bodies and comments are transport/input data and are never a substitute for State.

The design persists identity, not capability: a repository identity is reauthorized against the current Project Index before Worker execution or resume. Local paths, credentials, and Runtime State remain local.

## Resume paths

```text
routing/needs_input -> Routing Resume Orchestrator
worker/needs_input   -> Worker Resume -> Codex thread resume
```

Routing resume treats the answer as transient routing evidence. Worker resume accepts only the resumable Worker state and the validated answer; neither path turns Issue text into workspace authority.

## Component documentation

- [Configuration](CONFIGURATION.md)
- [Discovery](PROJECT_DISCOVERY.md) and [Project Index](PROJECT_INDEX.md)
- [Fast Router](FAST_ROUTER.md) and [Slow Router](SLOW_ROUTER.md)
- [Orchestrator](ORCHESTRATOR.md)
- [Worker](WORKER.md)
- [Runtime State](RUNTIME_STATE.md)
- [GitHub Issue adapter](GITHUB_ISSUE_ADAPTER.md)
- [Resume Orchestrator](RESUME_ORCHESTRATOR.md), [Resume Worker](RESUME_WORKER.md), and [Routing Resume Orchestrator](ROUTING_RESUME_ORCHESTRATOR.md)
- [Private control-plane contract](PRIVATE_CONTROL_PLANE.md)
