# GitHub Auto Twitter Marketing

`github-auto-twitter-marketing` maps reviewed GitHub marketing content and manually created schedules
to the `x-publisher.x_publish_request` queue. Version 0.3.0 is a breaking contract release: it accepts
only account-bound weekly content and schedule v2 Issues.

`github-auto-twitter-marketing` 把已审核的 GitHub 营销内容与人工创建的 Schedule 映射到
`x-publisher.x_publish_request` 队列。v0.3.0 是 breaking contract release，只接受绑定账号的
weekly-content v2 与 schedule v2 Issue。

The package does not own Host behavior, X credentials, or generic GitHub operations. It uses the
official `github-proxy` package and the repository's `x-publisher` package through declared event
queues.

本 package 不负责 Host 行为、X credential 或通用 GitHub 操作；它只通过声明的 event queue
调用官方 `github-proxy` 与本仓库的 `x-publisher`。

See the [complete v0.3.0 workflow](../../docs/auto-twitter-marketing-workflow.md) and the
[hzz780 RC Shadow runbook](../../docs/hzz780-v0.3.0-rc.1-acceptance.md) for lifecycle and operator
procedures.

完整生命周期见 [v0.3.0 workflow](../../docs/auto-twitter-marketing-workflow.md)，RC Shadow 的
运营步骤见 [hzz780 Runbook](../../docs/hzz780-v0.3.0-rc.1-acceptance.md)。

## Session route / Session 路由

One active Session owns one X account and one work lane. The runtime must inject:

一个 active Session 只接管一个 X 账号和一个 work lane。Runtime 必须注入：

```sh
FKST_SESSION_CREATOR=<github-login>
FKST_SESSION_WORK_LABEL=<effective-github-label>
FKST_SESSION_WORK_LABEL_MAP_JSON='{"<logical-label>":"<effective-github-label>"}'
X_PUBLISH_EXPECTED_USERNAME=<x-username>
```

`FKST_X_PUBLISH_EXPECTED_USERNAME` is accepted only as the package-scoped equivalent of
`X_PUBLISH_EXPECTED_USERNAME`. If both are present they must identify the same account.

`FKST_X_PUBLISH_EXPECTED_USERNAME` 仅作为 `X_PUBLISH_EXPECTED_USERNAME` 的 package-scoped
等价配置；两者同时存在时必须指向同一账号。

Every admitted Issue must:

每个被接收的 Issue 必须：

- carry the effective Session label / 携带 Session effective label；
- have exactly one assignee equal to `FKST_SESSION_CREATOR` / 唯一 assignee 等于 Session creator；
- declare the logical `work-label` from the reverse label mapping / 声明反向映射得到的逻辑 label；
- declare an `account` equal to the expected X username / `account` 等于预期 X username。

Missing or conflicting authority fails closed. Session IDs are never part of artifact or dedup keys,
so a sequential Session takeover keeps the same business identity.

Authority 缺失或冲突时 fail closed。Session ID 不进入 artifact 或 dedup key，因此顺序接管会
保持同一业务 identity。

## Weekly content v2 / 周内容 v2

Approved content is immutable and digest-bound:

Approved Content 不可变，并与 digest 绑定：

````md
contract: auto-twitter-marketing.weekly-content.v2
type: weekly-content
project: example-project
account: test_account
work-label: auto-x-test-account
week: 2026-W33
content-id: example-project-w33-1
content-revision: 1
proposal-id: proposal-example-w33
proposal-revision: 2
approval-id: proposal-example-w33@2
content-status: approved
content-digest: sha256:<64-lowercase-hex>

tweet-text:
```
A reviewed post.
```
````

The digest is the canonical SHA-256 of the content contract excluding the declared digest itself.
The importer recomputes it. The Issue author must canonicalize to the configured
`FKST_GITHUB_BOT_LOGIN`; a manually authored Content Issue is rejected even when its body, route,
and digest look valid. A mismatch, non-approved status, stale approval, wrong account, wrong route,
or wrong assignee is also rejected.

Digest 是 Content 合约除自身声明 digest 外的 canonical SHA-256，Importer 会重新计算。Issue
author 必须 canonicalize 为配置的 `FKST_GITHUB_BOT_LOGIN`；即使正文、route 与 digest 看似
合法，人工创建的 Content Issue 也会被拒绝。字段不匹配、非 approved 状态、旧 approval、错
账号、错 route 或错 assignee 同样会被拒绝。

After `weekly_content_imported` reaches its sink, the package writes an idempotent import comment with
a close handoff. Only the resulting `github_comment_written` acknowledgement can trigger a fresh
read, digest revalidation, local lock, and final Close. A lost Close response converges by rereading
the Issue.

`weekly_content_imported` 到达 sink 后，package 先写入幂等 import comment 与 close handoff。
只有对应的 `github_comment_written` ACK 才能触发 fresh read、digest 复验、本地 lock 与最终
Close；Close response 丢失时通过重新读取 Issue 收敛。

## Schedule publish v2 / 发布排期 v2

Schedules are a separate manual approval step:

Schedule 是独立的人工批准步骤：

```md
contract: auto-twitter-marketing.schedule-publish.v2
type: schedule-publish
project: example-project
account: test_account
work-label: auto-x-test-account
week: 2026-W33
content-ref: #124
content-digest: sha256:<64-lowercase-hex>
approval-id: proposal-example-w33@2
mode: shadow
scheduled-at: 2026-08-17T09:00:00Z
```

Recurring schedules use `type: recurring-schedule-publish` and either:

Recurring Schedule 使用 `type: recurring-schedule-publish`，并选择：

- `recurrence: daily` with `time` and `timezone` / 搭配 `time` 与 `timezone`；或
- `recurrence: every-minutes` with `interval-minutes` and `scheduled-at` / 搭配间隔与起始时间。

Before raising any X request, a due schedule force-refreshes `content-ref` and requires a closed,
approved, digest-valid content Issue with the same account, work label, project, week, digest, and
approval ID. A trusted superseded marker also blocks the request:

在 raise X request 前，到期 Schedule 会 force-refresh `content-ref`，并要求 Content Issue 已
Close、approved、digest 有效，且 account、work label、project、week、digest 与 approval ID
完全匹配。可信 superseded marker 也会阻断请求：

```html
<!-- fkst:auto-twitter:content-superseded:v2 content_digest="sha256:<64-lowercase-hex>" -->
```

Blocked validation writes a status comment and raises no X request. The queue payload schema is
`x-publisher.publish-request.v2`; it carries `account`, `work_label`, `content_ref`,
`content_digest`, canonical `schedule_digest`, and `approval_id` through the publish lifecycle.
`x-publisher` force-refreshes the Schedule and recomputes that digest before accepting one-shot or
recurring publish authority, so a queued event cannot publish after any Schedule revision changes.

校验失败时只写状态评论，不产生 X request。Queue payload 使用
`x-publisher.publish-request.v2`，并贯穿传递 account、work label、Content ref/digest、canonical
Schedule digest 与 approval ID。`x-publisher` 接受 one-shot 或 recurring publish authority 前会
force-refresh Schedule 并复算 digest，因此 Schedule 被修改后，旧 queue event 不能继续发布。

## Publish completion / 发布收尾

`x-publisher.publish-receipt.v2` comments preserve the expected account, authenticated account,
work label, content digest, approval ID, and `publish_attempted`. A blocked receipt sets that flag to
`false` before `POST /tweets`, and to `true` only when the provider POST was invoked but failed or
returned an unusable response.

`x-publisher.publish-receipt.v2` comment 保留 expected account、authenticated account、work
label、Content digest、approval ID 与 `publish_attempted`。在 `POST /tweets` 前阻断时该值为
`false`；只有 provider POST 已调用但失败或响应不可用时才为 `true`。

A successful live one-shot writes the same canonical published receipt to both the Schedule and its
referenced Content. The Schedule receipt is operator history and has no close handoff. Only the
Content receipt acknowledgement carries the handoff; after that ACK, the terminalizer fresh-reads
and revalidates the Schedule, acquires the local lock, and closes the Schedule.

成功的 live one-shot 会把同一份 canonical published receipt 同时写入 Schedule 与其引用的
Content。Schedule receipt 只用于运营留痕，不携带 close handoff；只有 Content receipt ACK
携带 handoff。Terminalizer 收到 Content ACK 后，才 fresh-read 并复验 Schedule、获取本地 lock，
然后关闭 Schedule。

Shadow, preview, blocked, skipped, and recurring schedules remain open. A published or timeline-
recovered one-shot follows the same comment acknowledgement, fresh-read, lock, and Close path.

Shadow、preview、blocked、skipped 与 recurring Schedule 保持 Open。Published 或 timeline
recovered one-shot 都遵循相同的 comment ACK、fresh-read、lock 与 Close 路径。

Live writes additionally require user-owned Environment Profile values:

Live write 还要求用户自有 Environment Profile 提供：

```sh
X_PUBLISH_WRITE=1
NYXID_URL=<nyxid-api-url>
NYXID_X_SERVICE_SLUG=<user-owned-service-slug>
X_PUBLISH_EXPECTED_USERNAME=<x-username>
NYXID_ACCESS_TOKEN=<secret-agent-key>
```

Credentials must never appear in Issues, manifests, package source, comments, or logs.

Credential 不得出现在 Issue、manifest、package source、comment 或 log 中。
