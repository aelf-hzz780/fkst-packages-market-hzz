# X 发布契约 / X Publishing Contract

本仓库中的 `x-publisher` 固定使用 X Publishing Contract `1.0.0`。版本、canonical source
SHA-256、generator 版本和生成文件摘要记录在
`contract-locks/x-publishing-contract.lock.json`。

The `x-publisher` package in this repository is pinned to X Publishing Contract `1.0.0`.
The version, canonical source SHA-256, generator version, and generated artifact digests are
recorded in `contract-locks/x-publishing-contract.lock.json`.

## 生成文件 / Generated Files

`libraries/contract/x_publishing_contract.lua` 与
`packages/x-publisher/tests/fixtures/x_publishing_conformance.lua` 是生成文件。文件头包含
contract version 与 source digest；这些文件不可手工编辑。

`libraries/contract/x_publishing_contract.lua` and
`packages/x-publisher/tests/fixtures/x_publishing_conformance.lua` are generated artifacts.
Their headers contain the contract version and source digest; do not edit these files manually.

契约更新必须先在 canonical source 项目中生成，再通过受限同步流程进入本仓库。同步后的
lock、Lua contract 和共同 fixtures 必须作为同一个 reviewable change 审核。

Contract updates must be generated in the canonical source project first and then delivered to
this repository through the restricted sync flow. Review the synced lock, Lua contract, and shared
fixtures as one change.

## 本地验证 / Local Verification

以下命令完全离线校验 market-side contract pin；它不读取 Environment Profile、GitHub
credential 或 NyxID credential。

The following command validates the market-side contract pin entirely offline. It does not read
an Environment Profile, GitHub credentials, or NyxID credentials.

```bash
python3 scripts/check_x_publishing_contract.py
```

以下命令运行 package 与 composed regression。测试使用 mocked provider boundary，不会发布
真实 X 内容。

The following commands run package and composed regressions. The tests use a mocked provider
boundary and do not publish real X content.

```bash
scripts/run.sh check
scripts/run.sh test x-publisher
scripts/run.sh test-composed
```

## 能力与兼容层 / Capabilities And Compatibility

Canonical operation 使用 `post`、`thread`、`reply`、`quote`；本 consumer 只声明
`post` 与 `quote`，Quote mode 为 `native` 或 `link`。未声明的 operation/mode 必须在任何
provider write 前返回 `unsupported_capability`。

Canonical operations are `post`, `thread`, `reply`, and `quote`; this consumer declares only
`post` and `quote`, with Quote mode `native` or `link`. An undeclared operation or mode must return
`unsupported_capability` before any provider write.

GitHub Issue adapter 继续接受已有 serialized keys：`operation`、`quote-mode` 与
`quote-url`。内部 contract 使用 `operation=quote` 加 mode，不创建 `quote-native` 或
`quote-link` operation。

The GitHub Issue adapter continues to accept the existing serialized keys: `operation`,
`quote-mode`, and `quote-url`. The internal contract uses `operation=quote` plus a mode and does not
create `quote-native` or `quote-link` operations.

例如，以下测试输入使用通用 owner/repository 与测试 post id，不绑定任何个人账号。

For example, the following test input uses a generic owner/repository and test post ID and is not
bound to a personal account.

```yaml
operation: quote
quote-mode: native
quote-url: https://x.com/example/status/1234567890123456789
tweet: Contract verification message
```

## NyxID 安全边界 / NyxID Security Boundary

Contract、fixtures 与 manifest 不保存 credential，通用测试数据不绑定生产账号。隔离
验收 Runbook 可以显式记录预期测试账号，但不得记录 raw token 或 credential。Live write
authority 只来自运行 FKST session 的用户 Environment Profile；`x-publisher` 继续通过
NyxID CLI broker 访问 X，并在 write gate、service 或 native capability 缺失时 fail closed。

The contract, fixtures, and manifest store no credentials, and generic fixtures are not bound to a
production account. An isolated acceptance runbook may name the expected test account, but it must
never contain a raw token or credential. Live write authority comes only from the Environment
Profile of the user running the FKST session; `x-publisher` continues to access X through the NyxID
CLI broker and fails closed when the write gate, service, or native capability is missing.

Native Quote provider failure 不会自动降级为 Link Quote。Blocked receipt 只包含稳定
error code、Trace ID 与安全 semantic metadata，不包含 raw command output。

A Native Quote provider failure never falls back automatically to a Link Quote. A blocked receipt
contains only a stable error code, Trace ID, and safe semantic metadata, never raw command output.

## 回滚 / Rollback

回滚时恢复上一个已审核的 contract lock、Lua contract 与 Lua fixtures，随后依次运行离线
checker、x-publisher tests 和 composed tests。不要单独回退其中一个生成文件。

To roll back, restore the previously reviewed contract lock, Lua contract, and Lua fixtures, then
run the offline checker, x-publisher tests, and composed tests in that order. Do not roll back only
one generated artifact.

回滚不修改用户 Environment Profile 或 NyxID authority，也不需要执行真实 X write。

A rollback does not modify the user's Environment Profile or NyxID authority and does not require
a real X write.

## 稳定发布 / Stable Release

Market PR 合入后，从合入后的 `main` commit 创建 `v0.3.0`。Manifest 与三个展开后的
business package descriptor 必须全部固定到该 tag；不要从 feature branch 创建 tag。

After the market PR merges, create `v0.3.0` from the merged `main` commit. The manifest and all
three expanded business package descriptors must be pinned to that tag. Never create the tag from
a feature branch.

从全新 checkout 验证 tag：

Verify the tag from a clean checkout:

```bash
git checkout v0.3.0
python3 scripts/check_x_publishing_contract.py
scripts/run.sh check
scripts/run.sh test x-publisher
scripts/run.sh test-composed
```

只有上述命令全部通过，才可声明 package release 完成。回滚时把 hosted manifest pin
恢复到上一个已验证 stable tag，不修改用户 Environment Profile 或 NyxID authority。

Declare the package release complete only after every command passes. To roll back, restore the
hosted manifest pin to the previous verified stable tag without changing the user's Environment
Profile or NyxID authority.
