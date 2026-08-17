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
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.1:manifests/auto-twitter-marketing.json
```

For reproducible production sessions, keep the SemVer pin. Do not use `main` or
a mutable feature branch.

The isolated shadow rollout uses `v0.3.0-rc.1`. After acceptance, replace every RC descriptor with
`v0.3.0`. Stop the RC Session before starting stable; the stable Session then takes over the same
account-specific work label sequentially. RC and stable must never be active on that label together.

隔离 Shadow 阶段使用 `v0.3.0-rc.1`；验收通过后再把所有 RC descriptor 替换为 `v0.3.0`。
启动 stable 前先停止 RC，再由 stable Session 顺序接管同一个账号专属 work label；二者不得在
该 label 上同时处于 active 状态。

生产 session 必须保留 SemVer pin，不要改用 `main` 或可变 feature branch。

The market manifest expands only to the business packages:

```text
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.1:packages/x-publisher
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.1:packages/github-auto-twitter-marketing
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.1:packages/marketing-radar
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
[`docs/hzz780-v0.3.0-rc.1-acceptance.md`](docs/hzz780-v0.3.0-rc.1-acceptance.md).

`hzz780` 账号的 RC 验收步骤见
[`docs/hzz780-v0.3.0-rc.1-acceptance.md`](docs/hzz780-v0.3.0-rc.1-acceptance.md)。

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

## Local development

Build or obtain `fkst-framework` from `fkst-substrate`, then configure the local ignored environment file:

```sh
cp .fkst/env.example .fkst/env
$EDITOR .fkst/env
```

Run the same entrypoint used by CI:

```sh
scripts/run.sh test
```

Useful commands:

```sh
scripts/run.sh check
scripts/run.sh test
scripts/run.sh test-composed
scripts/run.sh run x-publisher publish_x '{"payload":{}}'
```

`scripts/run.sh` exports the official `github-proxy` package and its official runtime libraries from the pinned `ChronoAIProject/fkst-hosted` package source into ignored `.fkst/official/` runtime state for local/composed tests. The official package source is not copied into this repository.

## Workflow contract

See `docs/auto-twitter-marketing-workflow.md` for the GitHub issue contracts and acceptance cases.

⟦AI:FKST⟧
