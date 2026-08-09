# Codex Dispatch OSS

> Turn your own PC into a remotely dispatchable Codex workstation.

Codex Dispatch OSS is a Windows-first project for sending natural-language tasks from a phone, tablet, or other lightweight client to Codex running on your own computer.

The intended control loop is:

```text
phone / tablet
      ↓
GitHub control plane
      ↓
self-hosted Windows runner
      ↓
project discovery + routing
      ↓
Codex CLI in the selected local workspace
      ↓
result / NEEDS_INPUT
      ↓
GitHub Issue → phone
```

## Status

🚧 **Pre-release extraction stage.**

This repository is currently private while the working personal implementation is being separated from machine-specific paths, usernames, repositories, and other private configuration.

The existing production installation is intentionally kept separate. This repository must not be treated as the source of truth for any production deployment until the extraction audit is complete.

## Design goals

- Keep real projects and development environments on the user's own PC.
- Use GitHub as a control plane rather than exposing the PC directly to the internet.
- Accept natural-language tasks without requiring the user to choose a repository first.
- Discover local Git projects automatically.
- Route clear tasks quickly and fall back to a slower semantic router when needed.
- Let Codex stop with `NEEDS_INPUT`, ask the user on mobile, and continue the original thread after a reply.
- Default to reversible local engineering work and block obvious external side effects unless explicitly authorized.

## Planned repository layout

```text
codex-dispatch-oss/
├─ scripts/              # local discovery/router/runtime scripts
├─ .github/workflows/    # GitHub control plane (added after extraction audit)
├─ examples/             # frontend examples: Drafts, Shortcuts, etc.
├─ docs/                 # architecture and deployment docs
├─ config.example.json   # machine-independent configuration example
├─ SECURITY.md
└─ OPEN_SOURCE_AUDIT.md
```

## Safety note

Do **not** copy secrets, personal access tokens, Codex auth data, private repository contents, or machine-specific credentials into this repository.

The first milestone is not feature development. It is a clean-room style extraction of the already-working implementation into a configurable and reviewable open-source codebase.

## License

License selection is intentionally pending until the extraction audit is complete.
