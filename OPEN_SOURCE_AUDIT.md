# Open Source Audit Record

Release candidate: v0.1.0

- The public OSS repository is separated from any private control repository and personal deployment.
- No active privileged workflow is present in this repository.
- Local configuration, Project Index, Runtime State, Codex authentication, runner credentials, and workspace inventories are excluded from the release tree.
- The private-control example is inactive and uses the reviewed public engine SHA; it contains no credentials or personal paths.
- The reviewed engine behavior preserves Runtime State authority, independent Worker authorization, credential isolation, and State-first projection.
- Development fake acceptance evidence used isolated private-control infrastructure and is not included as runtime data here.
- Release review found no credential or private-data blocker in the candidate tree.

Historical author metadata remains ordinary Git history and is not treated as a credential or deployment dependency.

