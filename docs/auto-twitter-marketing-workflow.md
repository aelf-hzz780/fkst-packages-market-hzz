# Auto Twitter marketing workflow

This document defines the issue-driven contracts for the marketing package set. The host supplies GitHub events through the official `github-proxy` package; this repository supplies only the marketing business behavior.

## Runtime package set

Import the official GitHub adapter separately, then import this repository's
business-only marketing manifest at the stable release tag.

请单独导入官方 GitHub adapter，并通过稳定 release tag 导入本仓库的 business-only
marketing manifest。

```text
ChronoAIProject/fkst-hosted@packages:packages/github-proxy
aelf-hzz780/fkst-packages-market-hzz@v0.2.1:manifests/auto-twitter-marketing.json
```

The market manifest expands only to:

```text
aelf-hzz780/fkst-packages-market-hzz@v0.2.1:packages/x-publisher
aelf-hzz780/fkst-packages-market-hzz@v0.2.1:packages/github-auto-twitter-marketing
aelf-hzz780/fkst-packages-market-hzz@v0.2.1:packages/marketing-radar
```

The pinned manifest and all expanded package descriptors must use the same
stable SemVer tag. Mutable `main` and feature refs are rejected by the offline
checker.

Manifest 与展开后的 package descriptor 必须使用同一个稳定 SemVer tag。离线 checker
会拒绝可变的 `main` 或 feature ref。

## Shared issue label

Every workflow input issue must include:

```text
auto-twitter-marketing
```

## Strategy issue

Purpose: import the current marketing strategy.

Required fields:

```yaml
type: strategy
campaign: <campaign-id>
audience: <target audience>
positioning: <positioning statement>
voice: <voice guide>
constraints:
  - <constraint>
```

Expected result:

- `github-auto-twitter-marketing` imports the strategy issue.
- The package raises a strategy import receipt.
- No X write is attempted.

## Weekly content issue

Purpose: import scheduled content items.

Required fields:

```yaml
type: weekly-content
campaign: <campaign-id>
week: <YYYY-Www>
items:
  - id: <content-id>
    scheduled_at: <ISO-8601 timestamp>
    text: <tweet text or source-backed content instruction>
```

Expected result:

- `github-auto-twitter-marketing` imports the weekly content issue.
- The package raises content artifacts for downstream scheduling.
- No X write is attempted unless a schedule-publish issue requests it.

### Quote weekly content / Quote 周内容

Quote target 必须与正文一起保存在 weekly-content Issue。schedule-publish Issue 只能通过
`calendar-ref` 引用它，不能覆盖 mode 或 target。

The Quote target must live with the text in the weekly-content Issue. A schedule-publish Issue may
reference it through `calendar-ref`, but cannot override the mode or target.

```yaml
type: weekly-content
project: example-project
week: 2026-W32
operation: quote
quote-mode: native # native | link
quote-url: https://x.com/example/status/1234567890123456789
tweet: Quote commentary text
```

`native` sends the original commentary plus `quote_tweet_id` and requires
`X_PUBLISH_NATIVE_QUOTE=1` in the Environment Profile or `FKST_X_PUBLISH_NATIVE_QUOTE=1` under the
Hosted trigger's `### Package Env` / `#### x-publisher`. `link` appends
`\n\n<canonical-url>` and uses ordinary Post authority. Native failure never falls back to Link.

`native` 发送原始评论正文和 `quote_tweet_id`，并要求 Environment Profile 中的
`X_PUBLISH_NATIVE_QUOTE=1`，或 Hosted trigger 的 `### Package Env` / `#### x-publisher` 下的
`FKST_X_PUBLISH_NATIVE_QUOTE=1`；`link` 追加 `\n\n<canonical-url>`，沿用普通 Post 权限。
Native 失败不会自动降级为 Link。

## Schedule publish issue

Purpose: publish one content item or schedule a recurring publish request.

One-shot shape:

```yaml
type: schedule-publish
mode: live
platform: x
content-ref: <issue-or-artifact-ref>
scheduled-at: <ISO-8601 timestamp>
dedup-key: <stable dedup key>
```

Recurring interval shape:

```yaml
type: recurring-schedule-publish
mode: live
platform: x
content-ref: <issue-or-artifact-ref>
recurrence: every-minutes
interval-minutes: 10
dedup-key: <stable recurring dedup key>
```

Daily shape:

```yaml
type: recurring-schedule-publish
mode: live
platform: x
content-ref: <issue-or-artifact-ref>
recurrence: daily
time: "11:10"
timezone: Asia/Shanghai
dedup-key: <stable daily dedup key>
```

Expected result:

- The marketing package emits an `x-publisher.x_publish_request` event.
- `x-publisher` resolves the source-backed tweet text.
- Live X publishing only runs when user-owned NyxID configuration and `X_PUBLISH_WRITE=1` are present.
- The package emits `x-publisher.x_published` with `status = "published"`, `status = "preview"`, or `status = "blocked"`.
- Before any live occurrence POST with a valid `scheduled_at`, `x-publisher` scans the authenticated
  account timeline from that occurrence time. One matching Post is recovered, zero matches permit
  the POST, and ambiguity, query failure, malformed evidence, or incomplete pagination blocks it.
- For a published one-shot schedule, the package waits for the durable GitHub receipt acknowledgement,
  requires canonical X post evidence, force-refreshes the schedule Issue, and closes it when the
  occurrence and dedup key still match.
- Recurring, preview, blocked, skipped, out-of-scope, or schedule control/label changes observed by
  the fresh read remain open.
- GitHub Close is not a conditional write, so an edit made between the fresh read and Close remains a
  documented race. Avoid editing while the published receipt is being finalized. If the Issue must be
  reopened for review, remove the `auto-twitter-marketing` label first; otherwise receipt replay can
  close the unchanged schedule again.

- 对于成功发布的一次性 schedule，package 会等待 GitHub 回执持久化确认，再强制刷新 schedule
  Issue；仅当 canonical X post 证据、occurrence 与 dedup key 均匹配时才关闭。
- 带有效 `scheduled_at` 的任意 live occurrence 会在 POST 前扫描当前认证账号从该 occurrence 开始的
  timeline：唯一命中则恢复已有 Post，零命中才发布，多匹配、查询失败、证据损坏或分页未完成
  都会阻断发布。
- Recurring、preview、blocked、skipped、已脱离 work-label 范围，或 fresh read 已观察到 schedule
  控制字段/label 改动的 Issue 保持 Open。
- GitHub Close 不是 conditional write，fresh read 与 Close 之间发生的编辑仍存在已知竞态；发布回执
  收尾期间应避免编辑。若必须重新打开复核，应先移除 `auto-twitter-marketing` label，否则未变化的
  schedule 会因回执重放再次被关闭。

One active Session must own a repository work scope at a time. Timeline reconciliation makes a later
Session converge after a crash or sequential takeover, but does not provide an atomic lease when two
first attempts start simultaneously.

同一 repo 的同一工作范围在同一时刻只能由一个活跃 Session 接管。Timeline 对账用于崩溃恢复和
顺序接管后的收敛，不提供两个首次尝试同时启动时的原子租约。

Takeover assumes the successful Post is already visible on the X timeline and that no operator posts
identical content in the same occurrence window. Visibility lag and an identical manual Post remain
documented residual risks because X provides no create idempotency key or package correlation field.

接管还假设成功 Post 已在 X timeline 可见，并且同一 occurrence 时间窗内没有人工发布完全相同的
内容。由于 X 不提供 create idempotency key 或 package 关联字段，可见性延迟与人工同文 Post 仍是
明确保留的风险。

## Radar issue

Purpose: turn configured signals into weekly content and schedule requests.

Configuration shape:

```yaml
type: radar-config
campaign: <campaign-id>
sources:
  - kind: github-issue
    repo: owner/repo
    label: market-signal
cadence:
  weekly-content: true
  schedule-publish: true
```

Signal shape:

```yaml
type: radar-signal
campaign: <campaign-id>
summary: <signal summary>
evidence:
  - <source URL or source ref>
```

Expected result:

- `marketing-radar` imports the radar configuration or signal.
- It creates source-backed weekly-content or schedule-publish issue requests through `github-proxy`.
- It does not publish to X directly.

## Acceptance cases

The minimum hosted validation set is:

1. Create a strategy issue and verify import receipt.
2. Create a weekly-content issue and verify imported content artifacts.
3. Create a one-shot schedule-publish issue and verify preview mode first.
4. Enable a user-owned NyxID/X Environment Profile, create a live schedule-publish issue, and verify
   one real X post, one persisted receipt comment, and automatic closure after the comment acknowledgement.
5. Create a recurring interval issue with two near-term fire times and verify exactly one post per due window.
6. Create a daily recurring issue with a future fire time and verify the next scheduled fire is calculated without publishing early.
7. Create a radar-config plus radar-signal pair and verify generated weekly-content or schedule-publish issue requests.
8. Remove or break required NyxID configuration and verify live X publishing fails closed with a blocked receipt.
9. Publish one Native Quote with the explicit capability gate and verify the receipt contains the
   new post URL, Quote mode, canonical target URL, and target post ID.
10. Run one Link Quote in the mocked adapter and verify its final text contains one canonical target
    URL and no `quote_tweet_id`.
11. Return a Native provider failure and verify exactly one provider call, one blocked receipt, and
    no Link fallback.
12. Simulate an X success with no durable GitHub receipt, start a later Session, and verify a unique
    timeline match restores the same post ID, persists the missing receipt, and closes the Issue
    without another POST.
13. Return an empty but complete timeline and verify exactly one provider POST.
14. Return duplicate matches, problem JSON, malformed URL/Quote evidence, or a non-terminal fifth
    page and verify a blocked receipt with no provider POST.
15. Omit `scheduled_at` and verify the legacy path is preserved without a recent-history guess.

最低验收还应覆盖：X 已发布但 GitHub 回执缺失时由后续 Session 唯一匹配并补齐评论/Close；完整
timeline 零命中时只发布一次；多匹配、problem JSON、URL/Quote 证据损坏或超过 5 页时阻断且不
POST；缺少 `scheduled_at` 时保持 legacy 行为，不按“最近 N 条”猜测。

⟦AI:FKST⟧
