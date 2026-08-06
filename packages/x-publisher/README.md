# x-publisher

General X release package - **contract + shadow-first live implementation.** A reusable publish lane
for X that any host repo composes via `pkg.queue`: consume a safe publish request, validate that only
small control fields plus source pointers are present, and emit a receipt.

- **consumes** `x_publish_request` - `{ artifact_id, source_ref, content_ref?, platform?, channel?,
  dedup_key?, trace_id?, approval_id?, scheduled_at?, metadata? }`.
- **produces** `x_published` - preview receipts in shadow mode, blocked receipts when a requested
  live write is not authorized, and published receipts after NyxID returns an X tweet id.
- **payload boundary** body/content fields (`tweet`, `body`, `text`, `message`, `media_bytes`,
  provider raw responses) and sensitive fields (`token`, `bearer`, `oauth`, `secret`,
  `credential`, authorization-like names) are rejected fail-closed.
- **posture** shadow-first: live writes require all of `channel = "live"`,
  `X_PUBLISH_WRITE=1`, `NYXID_X_SERVICE_SLUG=<service-slug>`,
  `NYXID_ACCESS_TOKEN`, and a `nyxid` CLI available on `PATH`.

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
