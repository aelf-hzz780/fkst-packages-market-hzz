# Contributing to fkst-packages-market-hzz

This repository contains business-owned FKST packages for the Auto Twitter marketing workflow. It is not the official generic FKST package repository.

## Development setup

1. Build `fkst-framework` from the exact full SHA recorded in `.fkst/substrate-ref`.
2. Copy `.fkst/env.example` to `.fkst/env`.
3. Set `BIN=/path/to/fkst-substrate/target/debug/fkst-framework`.
4. Run `scripts/run.sh verify-framework`, then `scripts/run.sh test` from the repository root.

The runner probes the binary's embedded source SHA and `EVENT=code_provenance` engine version. It
rejects a stale `BIN`, `PATH`, sibling build, or any binary compiled from a dirty checkout. Every run
also requires a source checkout with matching `HEAD` and a clean worktree; standard Cargo target
layouts are discovered automatically. For a custom target directory, set
`FKST_FRAMEWORK_SOURCE_ROOT` explicitly. To intentionally test another revision, set
`FKST_FRAMEWORK_EXPECTED_SHA` to that revision's full 40-character SHA; branch names and short SHAs
are not accepted. Formal CI never accepts this override; manual alternates run as a separate
`framework diagnostic` job.

Useful commands:

```sh
scripts/run.sh check
scripts/run.sh verify-framework
scripts/run.sh test
scripts/run.sh test x-publisher
scripts/run.sh test-composed
scripts/run.sh run x-publisher publish_x '{"payload":{}}'
```

`scripts/run.sh test-composed` loads the official `github-proxy` package from the pinned official source at runtime. The official package source is not committed into this repository.

## Branch and PR workflow

- Use `main` as the integration branch.
- Do not commit directly to `main`; open a PR into `main`.
- CI still accepts PRs targeting legacy `dev` branches for compatibility; new work must target `main`.
- Use branch names of the form `<type>/<kebab-topic>`, where `<type>` is one of `feat`, `fix`, `docs`, `chore`, `refactor`, or `test`.
- Keep each commit to one coherent logical change.
- Use English-only commit messages, PR titles, and PR bodies.
- PR bodies should include motivation, changes, and test evidence with commands and results.
- Merge with squash after CI is green.
- AI-generated PR bodies or change notes should end with `⟦AI:FKST⟧`.

## Package structure

Only these business packages belong here:

```text
packages/x-publisher
packages/github-auto-twitter-marketing
packages/marketing-radar
```

Only the minimal FKST Lua support libraries required by those packages belong here:

```text
libraries/contract
libraries/workflow
libraries/forge
libraries/testkit
```

Do not copy official generic packages such as `github-proxy` into this repository. Use runtime package composition instead.

## Source and documentation language

Source files such as `.lua`, `.sh`, `.py`, and `.rs` use English for comments, docstrings, log messages, error text, template strings, and identifiers.

Outward artifacts such as issues, PRs, comments, commit messages, and change notes are English-only
in this public repository. Approved repository documentation (including README files), operational
runbooks, and contract documents may be bilingual; keep the English section authoritative and
preserve the Chinese translation alongside it.

## Design rules

- Keep package behavior deterministic where possible and fail closed on unknown input.
- Treat GitHub and X/NyxID as external boundaries.
- Keep external side effects dry-run or blocked by default.
- Require explicit runtime authority before live X writes.
- Do not serialize raw credentials, large issue bodies, PR diffs, comments, code, or files into reliable delivery payloads.
- Do not store business state in the source tree or runtime scratch paths to survive crashes.
- Do not add deprecated shims, compatibility layers, `.old` files, `_legacy` paths, or dual-mode behavior for old contracts.

## File size and test discipline

Source files under `packages/`, `libraries/`, and `scripts/` should stay below 1000 lines for `.lua`, `.sh`, `.py`, and `.rs` files.

Tests belong in `packages/<pkg>/tests/` and should be named `*_test.lua`; shared test helpers should be named `*_helpers.lua`. External commands such as `gh` and `nyxid` must be mocked through FKST test facilities.

Run:

```sh
scripts/run.sh test
scripts/run.sh test-composed
```

## Security and side effects

Do not put secrets in tests, fixtures, docs, examples, or issue templates. Do not modify GitHub or X state as part of local development unless a task explicitly requires it and the required write posture is configured by the operator.

See `SECURITY.md` for vulnerability reporting.

⟦AI:FKST⟧
