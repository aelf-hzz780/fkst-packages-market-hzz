# Repository instructions

This repository is a workspace for business-owned FKST Market packages. It is not the official generic FKST package repository.

## Scope

- Keep host/runtime behavior in `fkst-hosted`.
- Keep reusable official packages in the official package source.
- Keep only business-owned Market packages here:
  - `packages/x-publisher`
  - `packages/github-auto-twitter-marketing`
  - `packages/marketing-radar`
  - `packages/telegram-governance`
- Do not copy official generic packages such as `github-proxy` into this repository.
- Do not modify FKST engine Rust code here. Engine changes belong in `fkst-substrate`.

## Language

- Source code comments, logs, errors, test names, docs, PR titles, PR bodies, and commit messages in this repository are English.
- User-facing chat may follow the user's language.

## Security

- Never commit raw credentials, tokens, private keys, local machine paths, or personal account-specific examples.
- User-owned service credentials must be supplied through FKST Environment Profiles / NyxID.
- X and Telegram writes must stay gated by explicit runtime configuration and service preflight.
- Telegram destructive writes require a separate NyxID service, two independent GitHub actors, and both write switches.
- Local `.fkst/env` and runtime state are ignored and must not be committed.

## Architecture rules

- Keep package boundaries explicit.
- Cross-package behavior must use FKST event queues and declared `[event_deps]`.
- Shared Lua code must live in declared workspace libraries.
- Do not add compatibility shims, legacy paths, deprecated copies, or dual-mode behavior.
- Fail closed on unknown input or missing required runtime authority.
- Keep public queue seams explicit through `published_seam` where a package exposes an entry queue.

## Testing

- Use `scripts/run.sh test` before PRs.
- Use `scripts/run.sh test-composed` to verify official `github-proxy` plus this business package set.
- Tests must mock external commands through FKST test facilities; do not create fake CLI binaries.
- Source files under `packages/`, `libraries/`, and `scripts/` should remain below 1000 lines.

## Git workflow

- Do not push directly to `main`, `master`, or `dev`.
- Use feature branches and PRs.
- Commit author must remain the configured GitHub noreply identity for this workspace.
- PR descriptions should include motivation, change summary, and test evidence.

⟦AI:FKST⟧
