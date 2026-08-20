# fkst-packages-market-hzz

Business-owned FKST packages for the Auto Twitter marketing workflow.

This repository intentionally contains only the marketing capability layer. Generic FKST host/runtime behavior stays in `fkst-hosted`, and reusable official packages such as `github-proxy` are loaded from the official package source at runtime.

## Packages

- `packages/x-publisher`: text-only X Post and Quote publishing seam. Live writes are gated by user-owned Environment Profile / NyxID configuration.
- `packages/github-auto-twitter-marketing`: imports strategy issues, weekly content issues, and schedule-publish issues from GitHub events.
- `packages/marketing-radar`: aggregates radar signals into review proposals and materializes approved weekly content; it never creates schedules or publishes to X.

The repository also keeps a minimal local copy of the FKST Lua support libraries required by those packages:

- `libraries/contract`
- `libraries/workflow`
- `libraries/forge`
- `libraries/testkit`

These libraries are retained only until the official SDK libraries are available as publishable external libraries for business package repositories.

## Runtime composition

The intended hosted shape is official + user packages. Import the official
GitHub adapter separately, then import this repository's business-only
marketing manifest at the current immutable RC tag:

Hosted 运行时由 official package 与用户 package 组合。请单独导入官方 GitHub adapter，
并使用当前不可变 RC tag 导入本仓库的 business-only marketing manifest：

```text
ChronoAIProject/fkst-hosted@packages:packages/github-proxy
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.3:manifests/auto-twitter-marketing.json
```

The business manifest is immutable. The official adapter is a documented Hosted exception: the
current Host clone path accepts branch or tag refs but cannot start from a raw commit SHA, and the
official repository has no tag containing `packages/github-proxy`. Local and CI composition remains
pinned to the full SHA in `fkst.workspace.toml`; the Shadow runbook requires `@packages` to resolve
to that tested SHA before launch and after every restart. A ref change blocks acceptance and requires
a pin update plus a complete gate rerun.

Do not start a Stable Hosted Session while stable_hosted_release=blocked.

Business manifest 使用不可变 tag。Official adapter 是明确记录的 Hosted 例外：当前 Host clone
链路只支持 branch/tag，不能从 raw commit SHA 启动，且 official repo 尚无包含
`packages/github-proxy` 的 tag。本地与 CI composition 仍固定到 `fkst.workspace.toml` 的完整
SHA；Shadow 启动前及每次重启后，都必须确认 `@packages` 仍解析到该已测 SHA。Ref 一旦变化，
验收立即停止，更新 pin 并重跑完整门禁后才能继续。

For reproducible business packages, keep the SemVer pin. Do not use `main` or a mutable feature
branch.

The isolated shadow rollout uses `v0.3.0-rc.3`. After acceptance, freeze the evidence and stop the RC
Session. Do not create a stable descriptor or Session until the official dependency has an immutable
Hosted-supported ref, or a separately reviewed Host solution is approved. Only after that blocker is
resolved may the exact clean commit be tagged `v0.3.0`, verified again with `scripts/run.sh
formal-gate`, and considered for a sequential takeover of the account-specific work label.

隔离 Shadow 阶段使用 `v0.3.0-rc.3`；验收通过后只冻结证据并停止 RC Session。在 official
dependency 提供 Hosted 支持的 immutable ref，或单独评审批准 Host 方案前，不得创建 stable
descriptor 或 Session。Blocker 解除后，才可将精确的 clean commit 标记为 `v0.3.0`，重新执行
`scripts/run.sh formal-gate`，再评估顺序接管账号专属 work label。

生产 session 必须保留 SemVer pin，不要改用 `main` 或可变 feature branch。

The market manifest expands only to the business packages:

```text
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.3:packages/x-publisher
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.3:packages/github-auto-twitter-marketing
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.3:packages/marketing-radar
```

Manifest 只展开上述三个 business package，不会隐式加载 host/runtime package。

`fkst-hosted` owns GitHub App login, session management, package fetching, and runtime execution. This repository does not require host changes for marketing business logic.

## Session route

The manifest does not declare a shared work label. Each account Session must set one stable,
account-specific `### Work Label` in its Hosted trigger, for example `auto-x-hzz780`.
Every work Issue must carry the Session's effective label and have exactly one assignee equal to
the Session creator. The Issue `account` must also match `X_PUBLISH_EXPECTED_USERNAME`.

Manifest 不再声明共享 work label。每个账号的 Hosted Session 必须在 trigger 中显式设置稳定、
账号隔离的 `### Work Label`。每个工作 Issue 必须携带该 Session 的 effective label，且唯一
assignee 必须是 Session creator；Issue 的 `account` 还必须与
`X_PUBLISH_EXPECTED_USERNAME` 一致。

The RC acceptance procedure for the `hzz780` account is documented in
[`docs/hzz780-v0.3.0-rc.3-acceptance.md`](docs/hzz780-v0.3.0-rc.3-acceptance.md).

`hzz780` 账号的 RC 验收步骤见
[`docs/hzz780-v0.3.0-rc.3-acceptance.md`](docs/hzz780-v0.3.0-rc.3-acceptance.md)。

## Credential posture

No raw credentials belong in this repository, manifests, tests, or GitHub issue payloads.

X publishing is user-scoped. The user configures the FKST Environment Profile with:

```sh
X_PUBLISH_WRITE=1
NYXID_URL=<nyxid-api-url>
NYXID_X_SERVICE_SLUG=<user-owned-x-service-slug>
X_PUBLISH_EXPECTED_USERNAME=<expected-x-username>
# Required only for native Quote publishing.
X_PUBLISH_NATIVE_QUOTE=1
NYXID_ACCESS_TOKEN=<user-owned-nyxid-agent-key>
```

`x-publisher` validates source-backed Post/Quote content, checks that the NyxID CLI is available,
verifies the configured X account through `/users/me`, and only then sends the text-only request
through NyxID. Native Quote additionally requires `X_PUBLISH_NATIVE_QUOTE=1`; Link Quote uses the
ordinary Post authority.

For a Hosted trigger, Native Quote can instead be enabled without editing the Environment Profile:

```md
### Package Env

#### x-publisher
FKST_X_PUBLISH_NATIVE_QUOTE=1
```

Hosted trigger 也可通过上述 `### Package Env` 显式开启 Native Quote，无需修改 Environment
Profile；该能力仍默认关闭，且不会绕过 live-write、account 或 NyxID 检查。

## Local development / 本地开发

Build `fkst-framework` from the exact full SHA in `.fkst/substrate-ref`, then configure the local
ignored environment file for ordinary development commands. Before every command, `scripts/run.sh`
verifies both the selected binary's source SHA and its `EVENT=code_provenance` engine version. A stale
`BIN`, `PATH`, sibling build, or binary compiled from a dirty checkout fails closed. Every run also
requires a matching clean source checkout; set `FKST_FRAMEWORK_SOURCE_ROOT` when using a custom target
directory.

请使用 `.fkst/substrate-ref` 中的完整 SHA 构建 `fkst-framework`，再为普通开发命令配置本地
ignored environment 文件。`scripts/run.sh` 会在每条命令执行前同时校验 binary 的 source SHA 与
`EVENT=code_provenance` engine version；如果 `BIN`、`PATH`、sibling build 已过期，或 binary
由 dirty checkout 编译，都会在测试开始前 fail closed。每次运行还必须对应 HEAD 一致且 clean
的源码 checkout；自定义 target directory 时需设置 `FKST_FRAMEWORK_SOURCE_ROOT`。

```sh
cp .fkst/env.example .fkst/env
$EDITOR .fkst/env
```

Run the same entrypoint used by CI:

```sh
scripts/run.sh formal-gate
```

`formal-gate` completely skips `.fkst/env`, rejects process-environment overrides for
`FKST_FRAMEWORK_EXPECTED_SHA`, `FKST_OFFICIAL_PACKAGE_SOURCE_URL`, and
`FKST_OFFICIAL_PACKAGE_SOURCE_REF`, and runs `verify-framework -> check -> test -> test-composed` in
that order. Its log records the tracked and effective official URL/ref, fetched commit SHA, and
locked tree digest. It also requires a clean business-repository HEAD before and after the suites and records release
provenance. Branch and PR CI attest that HEAD without requiring a future tag; a `v*` tag push reruns
the gate and requires the manifest ref, GitHub tag, peeled tag commit, event SHA, and tested HEAD to
agree. The checker also reports `hosted_ref_class=mutable-shadow-only` and
`stable_hosted_release=blocked`; a green gate authorizes the isolated RC Shadow, not Stable Hosted
release. Supply only the release binary location and its clean checkout location through `BIN` and,
when needed, `FKST_FRAMEWORK_SOURCE_ROOT`.

`formal-gate` 完全跳过 `.fkst/env`，并拒绝通过 process environment 覆盖
`FKST_FRAMEWORK_EXPECTED_SHA`、`FKST_OFFICIAL_PACKAGE_SOURCE_URL` 或
`FKST_OFFICIAL_PACKAGE_SOURCE_REF`；它固定按 `verify-framework -> check -> test -> test-composed`
顺序执行，并在日志中记录 tracked/effective official URL/ref、实际 fetch commit SHA 与 lock tree
digest。它还在测试前后要求 business repository HEAD 对应 clean worktree，并记录 release provenance；
Branch/PR CI 不要求未来 tag，`v*` tag push 则会重跑门禁，并强制 Manifest ref、GitHub tag、
peeled tag commit、event SHA 与 tested HEAD 完全一致。Checker 还会输出
`hosted_ref_class=mutable-shadow-only` 与
`stable_hosted_release=blocked`；门禁全绿只授权隔离 RC Shadow，不代表 Stable Hosted 可发布。
只通过 `BIN` 和必要时的 `FKST_FRAMEWORK_SOURCE_ROOT` 提供 release binary 与 clean checkout
位置。

Useful commands:

```sh
scripts/run.sh formal-gate
scripts/run.sh check
scripts/run.sh verify-framework
scripts/run.sh test
scripts/run.sh test-composed
scripts/run.sh run x-publisher publish_x '{"payload":{}}'
```

To intentionally evaluate another framework revision, use an ordinary diagnostic command and set
both `BIN` and the exact full SHA in `FKST_FRAMEWORK_EXPECTED_SHA`. Branch names and short SHAs are
rejected. This override changes only the expected diagnostic framework; it does not mutate the
tracked release pin and `formal-gate` never accepts it.

如需有意验证另一版 framework，请在普通 diagnostic command 中同时设置 `BIN` 和完整的
`FKST_FRAMEWORK_EXPECTED_SHA`。Branch name 与 short SHA 会被拒绝；该 override 只改变本次
diagnostic 期望的 framework，不会修改仓库内的 release pin，且 `formal-gate` 永不接受该
override。GitHub Actions 的正式 `ci / test` 永远只使用 tracked pin；alternate ref 只运行独立的
`framework diagnostic` job，不能作为发布门禁。

`scripts/run.sh` exports the official `github-proxy` package and its official runtime libraries from the pinned `ChronoAIProject/fkst-hosted` package source into ignored `.fkst/official/` runtime state for local/composed tests. The official package source is not copied into this repository.

## Workflow contract

See `docs/auto-twitter-marketing-workflow.md` for the GitHub issue contracts and acceptance cases.

⟦AI:FKST⟧
