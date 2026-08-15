# fkst-packages-market-hzz

Business-owned FKST packages for the Auto Twitter marketing workflow.

This repository intentionally contains only the marketing capability layer. Generic FKST host/runtime behavior stays in `fkst-hosted`, and reusable official packages such as `github-proxy` are loaded from the official package source at runtime.

## Packages

- `packages/x-publisher`: text-only X Post and Quote publishing seam. Live writes are gated by user-owned Environment Profile / NyxID configuration.
- `packages/github-auto-twitter-marketing`: imports strategy issues, weekly content issues, and schedule-publish issues from GitHub events.
- `packages/marketing-radar`: imports radar configuration/signals and creates weekly-content or schedule-publish issue requests.

The repository also keeps a minimal local copy of the FKST Lua support libraries required by those packages:

- `libraries/contract`
- `libraries/workflow`
- `libraries/forge`
- `libraries/testkit`

These libraries are retained only until the official SDK libraries are available as publishable external libraries for business package repositories.

## Runtime composition

The intended hosted shape is official + user packages. Import the official
GitHub adapter separately, then import this repository's business-only
marketing manifest at the stable release tag:

Hosted 运行时由 official package 与用户 package 组合。请单独导入官方 GitHub adapter，
并使用稳定 release tag 导入本仓库的 business-only marketing manifest：

```text
ChronoAIProject/fkst-hosted@packages:packages/github-proxy
aelf-hzz780/fkst-packages-market-hzz@v0.2.2:manifests/auto-twitter-marketing.json
```

For reproducible production sessions, keep the SemVer pin. Do not use `main` or
a mutable feature branch.

生产 session 必须保留 SemVer pin，不要改用 `main` 或可变 feature branch。

The market manifest expands only to the business packages:

```text
aelf-hzz780/fkst-packages-market-hzz@v0.2.2:packages/x-publisher
aelf-hzz780/fkst-packages-market-hzz@v0.2.2:packages/github-auto-twitter-marketing
aelf-hzz780/fkst-packages-market-hzz@v0.2.2:packages/marketing-radar
```

Manifest 只展开上述三个 business package，不会隐式加载 host/runtime package。

`fkst-hosted` owns GitHub App login, session management, package fetching, and runtime execution. This repository does not require host changes for marketing business logic.

## Issue label

Marketing input issues must use this work label:

```text
auto-twitter-marketing
```

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
