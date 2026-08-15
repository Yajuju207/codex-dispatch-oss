# Security Policy

## Scope

v0.1 covers the public PowerShell dispatch engine, its local configuration and Project Index boundaries, Runtime State persistence, Router/Orchestrator/Worker contracts, and the inactive private-control example. The public repository is not a hosted service and does not include a maintainer deployment.

## Security boundaries

- Never commit secrets, tokens, passwords, Codex authentication, local configuration, Runtime State, workspace inventories, or runner credentials.
- Task text, Issue bodies, and comments are untrusted data. They must not become filesystem paths, commands, or capabilities.
- Project authorization comes from local configuration and the current Project Index. The Worker independently re-authorizes the workspace.
- Runtime State is execution authority; GitHub Issues are transport/projection surfaces and are not authoritative lifecycle state.
- A self-hosted runner and its private control repository are a privileged execution boundary. Protect writers, workflow changes, runner scope, filesystem ACLs, and credentials before activation.

## Reporting a vulnerability

Please do not publish an unpatched vulnerability or an exploit in a public Issue. When available for this repository, use GitHub's private vulnerability reporting or Security Advisories. If that private channel is unavailable, contact the maintainer through a private GitHub channel and include a minimal description, affected commit or path, impact, and a safe reproduction that does not contain credentials or personal data. Allow reasonable time for coordination before public disclosure.

## Supported security expectations

Reports should distinguish defects in the public engine from deployment mistakes in a user's private control repository or self-hosted host. The v0.1 code does not provide at-rest encryption for Runtime State or automatic redaction of arbitrary task text; operators must protect the state directory with local account and filesystem controls.
