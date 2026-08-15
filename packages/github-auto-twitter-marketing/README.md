# GitHub Auto Twitter Marketing

`github-auto-twitter-marketing` is a hosted-facing composed package that maps
GitHub issue facts into the marketing seams already exposed by this repository.

It keeps reliable payloads pointer-only:

- strategy issues raise `strategy_imported`;
- weekly-content issues raise `weekly_content_imported`;
- schedule-publish issues raise `x-publisher.x_publish_request`;
- each handled issue raises a `github-proxy.github_issue_comment_request` status
  receipt.

The package recognizes the `auto-twitter-marketing` work label and accepts small
control fields either from a trusted `payload.controls` map or from simple
`key: value` lines in the issue body. Strategy text, weekly content, and final X
post content remain behind `source_ref`.

Live X writes are not authorized by this package. `mode: live` is only allowed
to become a live channel after the user's Environment Profile supplies an
explicit live write switch and a NyxID X service slug. The downstream
`x-publisher` package then performs the final live preflight: `NYXID_ACCESS_TOKEN`
must be present and `nyxid` must be available on `PATH`. Without those gates, the
workflow emits either a preview/shadow request or a blocked publish receipt.

## Issue formats

Strategy import:

```md
type: strategy
project: chronoai
account: main
```

Weekly content import:

````md
type: weekly-content
project: chronoai
week: 2026-W31
strategy-ref: #41

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
````

Native Quote weekly content / Native Quote 周内容：

````md
type: weekly-content
project: example-project
week: 2026-W32
operation: quote
quote-mode: native
quote-url: https://x.com/example/status/1234567890123456789

tweet-text:
```
Quote commentary text.
```
````

`quote-mode` may be `native` or `link`. Quote fields belong only to the weekly-content Issue; the
schedule Issue cannot override them. `native` also requires either `X_PUBLISH_NATIVE_QUOTE=1` in
the user Environment Profile or `FKST_X_PUBLISH_NATIVE_QUOTE=1` in the trigger's `### Package Env`
for `#### x-publisher`. `link` uses the ordinary Post authority.

`quote-mode` 可选 `native` 或 `link`。Quote 字段只属于 weekly-content Issue，schedule Issue
不能覆盖。`native` 还要求用户 Environment Profile 配置 `X_PUBLISH_NATIVE_QUOTE=1`，或在
trigger 的 `### Package Env` / `#### x-publisher` 下配置
`FKST_X_PUBLISH_NATIVE_QUOTE=1`；`link` 沿用普通 Post 权限。

Schedule publish:

```md
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #42
mode: live
scheduled-at: 2026-07-25T09:00:00Z
```

`calendar-ref` becomes the downstream `content_ref`. For `#42`, `x-publisher` resolves it relative
to the schedule issue repo and reads the weekly content issue through the GitHub adapter.

## One-shot completion lifecycle / 一次性任务完成生命周期

A live one-shot schedule remains open while it is pending, previewed, blocked, or publishing. After
`x-publisher` reports `published`, the package first asks `github-proxy` to persist the published
receipt comment. Only the resulting `github_comment_written` acknowledgement can trigger closure.
The terminalizer then force-refreshes the same schedule Issue and closes it only when it is still
open, still carries the `auto-twitter-marketing` label, still describes the same non-recurring
occurrence, still matches the published receipt dedup key, and the receipt contains a canonical X
post ID plus matching `https://x.com/i/web/status/<id>` URI. `FKST_GITHUB_WRITE=1` is required for
both the receipt write and the final Close. A restart can replay the existing receipt marker and
finish the Close without publishing to X again.

一次性 live schedule 在等待、preview、blocked 或发布过程中保持 Open。`x-publisher` 返回
`published` 后，package 会先通过 `github-proxy` 落盘发布回执评论；只有收到
`github_comment_written` 确认后才允许进入关闭流程。terminalizer 会强制重新读取同一个
schedule Issue，并且仅在 Issue 仍为 Open、仍带 `auto-twitter-marketing` label、仍是同一个
non-recurring occurrence、dedup key 与发布回执一致，且回执包含 canonical X post ID 与匹配的
`https://x.com/i/web/status/<id>` URI 时关闭。回执写入和最终 Close 都要求
`FKST_GITHUB_WRITE=1`。服务重启后可以通过已有回执 marker 重放并补关 Issue，不会再次发布到 X。

For every live occurrence with `scheduled_at`, if X accepted the Post but the Session stopped before
the GitHub receipt became durable, a later Session reconciles the authenticated account timeline
before attempting another write. A unique match for the same occurrence, normalized text/URLs, and
Quote target reconstructs the published receipt. A one-shot then continues the same
comment-then-Close lifecycle; a recurring schedule remains open. Zero matches permit the new Post;
ambiguous, damaged, failed, or incomplete timeline reads block the write.

对于每个带 `scheduled_at` 的 live occurrence，如果 X 已接受 Post，但 Session 在 GitHub 回执
落盘前停止，后续 Session 会在再次写入前对账当前认证账号的 timeline。只有同一 occurrence、
规范化正文/URL 与 Quote target 唯一匹配时，才会重建 published 回执；one-shot 继续“评论确认后
Close”的生命周期，recurring schedule 仍保持 Open。零匹配才允许新发，多匹配、证据损坏、查询
失败或分页未完成都会阻断写入。

This recovery path assumes one active Session owns a repository work scope at a time. It contains
sequential takeover and crash recovery, but it is not an atomic cross-Session lock; simultaneous
first attempts remain outside the package-only guarantee.

该恢复链路以“同一时刻只有一个活跃 Session 接管同一 repo 工作范围”为运行约束。它能处理顺序
接管与崩溃恢复，但不是跨 Session 原子锁；同时发生的首次尝试不属于 package-only 保证范围。

Recovery assumes the successful Post is visible on the X timeline before takeover and that nobody
manually publishes identical content in the same occurrence window. Visibility lag can look like a
zero match, while an identical manual Post can look like a unique recovery match.

恢复还假设接管前成功 Post 已在 X timeline 可见，并且同一 occurrence 时间窗内没有人工发布完全
相同的内容。可见性延迟可能表现为零匹配，人工同文 Post 则可能表现为唯一恢复匹配。

Recurring schedules are never closed by this flow because the Issue remains the durable definition
for future occurrences. Preview, blocked, skipped, malformed, mismatched, or schedule control/label
changes observed by the fresh read are also never closed.

Recurring schedule 的 Issue 是后续 occurrence 的持久定义，因此此流程永不关闭它。Preview、
blocked、skipped、格式错误、关联不一致，或 fresh read 已观察到控制字段/label 改动的 schedule
同样不会被关闭。

GitHub does not offer an atomic compare-and-close operation for Issues. The terminalizer therefore
serializes local acknowledgements and force-refreshes immediately before Close, but a user edit made
in the small interval between that read and the Close request can still race. Relevant changes
observed by the fresh read fail closed. Operators should avoid editing a schedule while its published
receipt is being finalized. Before reopening an Issue for review, remove the
`auto-twitter-marketing` label; otherwise receipt replay can close the unchanged schedule again.

GitHub 没有提供 Issue 的 atomic compare-and-close API。terminalizer 会串行处理本地 ACK，并在
Close 前立即强制刷新；但如果用户恰好在该次读取与 Close 请求之间修改 Issue，仍存在很小的竞态
窗口。刷新时已观察到的关联控制字段/label 改动会 fail closed；发布回执正在收尾时应避免编辑
schedule。若需要重新打开 Issue 复核，应先移除 `auto-twitter-marketing` label，否则未变化的
schedule 会因回执重放再次被关闭。

## Live Environment Profile contract

Live mode requires user-owned profile configuration, not host-owned X
credentials:

```sh
X_PUBLISH_WRITE=1
NYXID_URL=<nyxid-api-url>
NYXID_X_SERVICE_SLUG=<user-owned-x-service-slug>
X_PUBLISH_EXPECTED_USERNAME=<x-username>
X_PUBLISH_NATIVE_QUOTE=1 # native Quote only
NYXID_ACCESS_TOKEN=<secret-user-owned-nyxid-agent-key>
```

The profile must also install the `nyxid` CLI into a directory visible on `PATH`.
Hosted runtimes are not expected to bundle it globally.

The username preflight is a safety guard: if NyxID resolves to any account other than
`X_PUBLISH_EXPECTED_USERNAME`, the publish request is blocked and no tweet is created.
Raw X tokens must never appear in issues, manifests, package source, or logs.
