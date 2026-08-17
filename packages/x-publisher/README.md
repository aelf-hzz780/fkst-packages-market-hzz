# x-publisher

General X release package - **contract + shadow-first live implementation.** A reusable publish lane
for X that any host repo composes via `pkg.queue`: consume a safe publish request, validate that only
small control fields plus source pointers are present, and emit a receipt.

- **consumes** `x_publish_request` - `{ artifact_id, source_ref, account, work_label, content_ref,
  content_digest, schedule_digest, approval_id, platform, channel, dedup_key, trace_id,
  scheduled_at?, metadata? }`.
- **produces** `x_published` - preview receipts in shadow mode, blocked receipts when a requested
  live write is not authorized, and published receipts after NyxID returns an X tweet id.
- **payload boundary** body/content fields (`tweet`, `body`, `text`, `message`, `media_bytes`,
  provider raw responses) and sensitive fields (`token`, `bearer`, `oauth`, `secret`,
  `credential`, authorization-like names) are rejected fail-closed.
- **posture** shadow-first: live writes require all of `channel = "live"`,
  `X_PUBLISH_WRITE=1`, `NYXID_X_SERVICE_SLUG=<service-slug>`,
  `NYXID_ACCESS_TOKEN`, and a `nyxid` CLI available on `PATH`.
- **schedule authority** `schedule_digest` is the canonical SHA-256 of the complete v2 Schedule
  contract. The publisher force-refreshes the Schedule and blocks stale one-shot or recurring
  requests before any NyxID call when the digest no longer matches.

## Live X write contract

`x-publisher` uses NyxID as the only credential path. It never accepts or stores raw X tokens.

Required user Environment Profile for live mode:

- install the `nyxid` CLI into a directory visible on `PATH`, for example the
  profile's tool/bin directory;
- provide a user-owned NyxID agent key as the secret `NYXID_ACCESS_TOKEN`;
- provide the user's X service slug and optional expected account guard as env
  variables.

```sh
X_PUBLISH_WRITE=1
NYXID_URL=<nyxid-api-url>
NYXID_X_SERVICE_SLUG=<user-owned-x-service-slug>
X_PUBLISH_EXPECTED_USERNAME=<x-username>
# Required only for native Quote publishing.
X_PUBLISH_NATIVE_QUOTE=1
NYXID_ACCESS_TOKEN=<secret-user-owned-nyxid-agent-key>
```

Hosted trigger Issues expose the same Native Quote capability through the package-owned setting
`FKST_X_PUBLISH_NATIVE_QUOTE=1` under `### Package Env` / `#### x-publisher`.

Hosted trigger Issue 通过 `### Package Env` / `#### x-publisher` 下的 package 配置
`FKST_X_PUBLISH_NATIVE_QUOTE=1` 开启同一 Native Quote 能力。

`NYXID_ACCESS_TOKEN` is checked for presence only; the package does not read,
log, persist, or include the token in receipts. The `nyxid` CLI consumes it from
the environment when making proxy requests.

Legacy `FKST_X_PUBLISH_WRITE` / `FKST_NYXID_X_SERVICE_SLUG` /
`FKST_X_PUBLISH_EXPECTED_USERNAME` names are still accepted for older non-hosted runners. Hosted
Environment profiles reserve the `FKST_*` prefix, so hosted installs should use the non-reserved
names above.

If a live request is missing the access token or cannot execute `nyxid --version`, the package emits
an `x_published` receipt with `status = "blocked"` and does not call the X API.

Before any live provider request, `x-publisher` force-refreshes the schedule Issue referenced by
`source_ref`. A `published` receipt suppresses the provider POST only when its comment author is in
the bot-only allowlist (`FKST_GITHUB_BOT_LOGIN` plus `FKST_DEVLOOP_MANAGED_BOT_LOGINS`, excluding
general `FKST_GITHUB_AUTHORIZED_LOGINS`), its `dedup_key` exactly matches the current publish
request, and its X status URI and optional post-id fields agree. Publish keys are 1-512 bytes with
no leading/trailing whitespace or ASCII control characters. The package replays the original post
ID. A failed fresh read, damaged matching marker, or conflicting trusted marker fails closed;
forged comments, receipts for another key, unscoped damaged comments, and blocked-only receipts do
not suppress publishing. The runtime-local `once` marker remains a second same-runtime guard.

This receipt check is immediate cross-session containment, not provider-side atomic idempotency.
For an Auto Twitter occurrence with a valid `scheduled_at`, the timeline reconciliation below also
recovers a provider POST whose GitHub receipt was not persisted. These two checks make sequential
Session takeover converge on the same post.

该回执检查用于跨 Session 收敛，但并不等同于 provider 侧的原子幂等。对于带有效
`scheduled_at` 的 Auto Twitter occurrence，下面的 timeline 对账还可以恢复“X 已发布、GitHub
回执尚未落盘”的结果，使后启动的 Session 复用同一条 Post。

When `X_PUBLISH_EXPECTED_USERNAME` is set, the package first calls:

```text
nyxid proxy request <slug> /users/me?user.fields=id,name,username -m GET
```

The returned username must match before the package can post to:

```text
nyxid proxy request <slug> /tweets -m POST -d {"text":"..."}
```

The `/tweets` path is relative to the NyxID service base URL `https://api.x.com/2`; do not use
`/2/tweets`.

## Cross-session timeline reconciliation / 跨 Session Timeline 对账

Immediately before a live provider POST, a request with `scheduled_at` resolves the authenticated
account and reads that account's own timeline from the occurrence time. It excludes replies and
retweets, requests `created_at`, URL entities, and Quote references, reads at most five pages of 100
posts, and accepts an occurrence no older than 30 days. Matching uses the authenticated account,
time window, normalized text, expanded `t.co` URLs, and the expected Quote target.

带 `scheduled_at` 的 live 请求会在 provider POST 前解析当前认证账号，并从 occurrence 时间
开始读取该账号自己的 timeline。查询排除 replies 与 retweets，请求 `created_at`、URL entity
及 Quote reference，最多读取 5 页、每页 100 条，并且 occurrence 最长只允许回看 30 天。
匹配同时校验认证账号、时间窗、规范化正文、展开后的 `t.co` URL 与预期 Quote target。

- Exactly one match: recover its post ID and emit the normal `published` receipt. For a published
  one-shot, the receipt comment is persisted and the terminalizer closes the schedule Issue. For a
  recurring occurrence, the receipt/comment is restored and the schedule Issue remains open.
- Zero matches after a complete scan: perform exactly one provider POST.
- Multiple matches, query failure, problem JSON, malformed evidence, or an unfinished fifth page:
  emit `blocked` and never POST.
- Missing `scheduled_at`: preserve the legacy publisher behavior; the package does not guess from a
  recent-post interval.

- 唯一命中：恢复该 Post ID 并发出正常 `published` 回执。对已发布的 one-shot，持久化回执评论
  后由 terminalizer 关闭 schedule Issue；对 recurring occurrence，只恢复回执/评论，schedule
  Issue 继续保持 Open。
- 完整扫描后零命中：只执行一次 provider POST。
- 多条命中、查询失败、problem JSON、证据损坏或第 5 页仍未结束：返回 `blocked`，绝不 POST。
- 缺少 `scheduled_at`：保持原 publisher 行为，不用“最近 N 小时”进行猜测。

This is a recovery guard, not a distributed lease. Operators must not intentionally run two active
Sessions over the same repository and work scope. If two first attempts query the timeline at the
same instant, both can observe zero matches; X does not expose an idempotency key for Post creation.
A provider-side idempotency ledger or shared lease is required before concurrent first-attempt
exactly-once can be claimed.

这是一层恢复保护，不是 distributed lease。运行侧不应让两个活跃 Session 同时接管同一 repo
的同一工作范围。若两个首次尝试在同一时刻查询 timeline，仍可能同时看到零命中；X 的 Post
创建接口没有 idempotency key。只有在 provider 写入边界增加幂等账本或共享租约后，才能承诺
并发首次尝试的 exactly-once。

Recovery also assumes a successful Post is visible in the account timeline before takeover and that
no operator manually publishes identical content in the same occurrence window. A visibility lag can
produce a false zero match; an identical manual Post can produce a false unique match. Neither case
can be proven away without provider-side correlation metadata.

恢复还假设：后续 Session 接管前，成功 Post 已能在账号 timeline 中读取，且同一 occurrence
时间窗内没有人工发布完全相同的内容。Timeline 可见性延迟可能造成“假零匹配”，人工同文 Post
可能造成“假唯一匹配”；没有 provider 侧关联元数据时，package 无法彻底排除这两种情况。

## Quote contract / Quote 契约

Quote target 跟随 weekly-content Issue 中的正文保存，schedule-publish Issue 只保留
`calendar-ref` 和调度字段。`quote-url` 只接受 HTTPS `x.com` 或 `twitter.com` status URL；
package 会派生 post ID，并规范化为 canonical `x.com` URL。

The Quote target lives with the text in the weekly-content Issue. The schedule-publish Issue keeps
only `calendar-ref` and scheduling fields. `quote-url` accepts only an HTTPS `x.com` or
`twitter.com` status URL; the package derives the post ID and canonicalizes the URL.

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

- `native` keeps the commentary unchanged and sends `quote_tweet_id`. It requires
  `X_PUBLISH_NATIVE_QUOTE=1` in the Environment Profile or
  `FKST_X_PUBLISH_NATIVE_QUOTE=1` in Hosted `### Package Env`, in addition to the ordinary
  live-write gates.
- `link` appends exactly two newlines plus the canonical target URL and never sends
  `quote_tweet_id`.
- Native provider failure is terminal for that dispatch. The package never retries as Link Quote.
- The final publishable text uses X weighted-length validation, including Unicode/emoji weights and
  the transformed canonical Quote URL length.

- `native` 保持评论正文不变并发送 `quote_tweet_id`，除普通 live-write gate 外还要求
  Environment Profile 中的 `X_PUBLISH_NATIVE_QUOTE=1`，或 Hosted `### Package Env` 中的
  `FKST_X_PUBLISH_NATIVE_QUOTE=1`。
- `link` 在正文后追加两个换行和 canonical URL，绝不发送 `quote_tweet_id`。
- Native provider 失败即终止本次 dispatch，不会自动改发 Link Quote。
- 最终发布正文按 X weighted length 校验，包括 Unicode/emoji 权重和 Quote URL 转换长度。

## Content resolution

The publish payload stays pointer-only. For GitHub issue driven workflows, `content_ref` points to
the weekly content issue, typically `#42` relative to the schedule issue repo. The weekly content
issue must contain one explicit tweet text field, for example:

````md
type: weekly-content
project: chronoai
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
````

MVP live publishing supports one text-only X Post or Quote per content Issue, within X's weighted
280-character limit. Media upload, Thread, and Quote + Thread are intentionally separate follow-up
capabilities.

Invalid requests are skipped with a greppable log and never masquerade as successful publishes.
`core.preview_receipt(payload, "skipped")` exists as a safe shape helper for hosts/tests that need
an explicit skipped receipt, but the department does not raise it for invalid requests.

⟦AI:FKST⟧
