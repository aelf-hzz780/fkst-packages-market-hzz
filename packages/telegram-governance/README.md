# Telegram Governance

`telegram-governance` 是 business-owned FKST composed package。它消费 official `github-proxy` 的 Issue events，把 GitHub Issue 作为 authority source，通过 NyxID 调用 Telethon Auto canonical `/api/automation/v1`，并把 command receipt 写回原 Issue。

`telegram-governance` is a business-owned FKST composed package. It consumes Issue events from the official `github-proxy`, treats the GitHub Issue as the authority source, calls Telethon Auto's canonical `/api/automation/v1` through NyxID, and writes command receipts back to the source Issue.

## Package Graph / Package 流程

```text
github-proxy.github_issue_changed ---\
                                       -> github_command_intake
github-proxy.github_issue_observed --/       -> telegram_command_request (pointer only)
                                                -> execute_command
                                                -> telegram_command_receipt
                                                -> receipt_sink
                                                -> github-proxy.github_issue_comment_request
```

`execute_command` 把 `telegram_command_request` 声明为 `published_seam`，其他已授权 composer 可以提交同一 pointer-only contract。`dead_letter` 使用标准 `workflow.dead_letter` handler。

`execute_command` declares `telegram_command_request` as a `published_seam`, so another authorized composer can submit the same pointer-only contract. `dead_letter` uses the standard `workflow.dead_letter` handler.

## Issue Contract / Issue Contract

Issue 必须带 `telegram-governance` label，body 必须是一个不超过 32 KiB 的 JSON envelope。Package mode 只允许 `preview` 或 `live`，默认是 `preview`。`command` 只允许 `account_ref`、`operation` 和 `payload`。

The Issue must carry the `telegram-governance` label and its body must be a JSON envelope no larger than 32 KiB. Package mode is either `preview` or `live` and defaults to `preview`. `command` contains exactly `account_ref`, `operation`, and `payload`.

```json
{
  "mode": "preview",
  "command": {
    "account_ref": "telegram-primary",
    "operation": "group.sync",
    "payload": { "group_id": -1001234567890 }
  }
}
```

Preview 在本地生成 shadow receipt，不调用 NyxID。Live 会向 TG 提交 `mode=live`。Payload 的最终 strict schema 由 TG OpenAPI/Pydantic contract 验证；package 同时限制 JSON 深度、大小、节点数和 credential-shaped fields。

Preview emits a local shadow receipt without calling NyxID. Live submits `mode=live` to TG. The TG OpenAPI/Pydantic contract remains authoritative for each strict payload schema; the package also bounds JSON depth, size, node count, and credential-shaped fields.

## Operation Contract / Operation Contract

Package pin 住 TG 发布的 24-operation catalog：

The package pins the 24-operation catalog published by TG:

- Groups: `group.monitor.add`, `group.monitor.pause`, `group.monitor.resume`, `group.sync`, `group.history.backfill`, `group.policy.update`, `group.knowledge_bindings.replace`, `group.moderation_profile.replace`, `group.actor_policy.upsert`, `group.actor_policy.revoke`, `group.actor_policy.sync_admins`
- Knowledge: `knowledge.collection.create`, `knowledge.collection.update`, `knowledge.collection.archive`, `knowledge.faq.create`, `knowledge.faq.update`, `knowledge.faq.archive`
- Analysis: `analysis.messages.run`, `moderation.messages.scan`, `moderation.feedback.record`
- Governed R2 execution: `reply.decision.execute`, `moderation.message.execute`, `moderation.profile.scan`, `moderation.user.restore`

Package 不支持群组创建、任意主动消息、raw Telegram RPC 或 caller-selected moderation。Delete/restrict/ban 只能来自 TG 当前 policy/decision；restore 必须引用同 group/user 的 confirmed restriction audit。

The package excludes group creation, arbitrary proactive messages, raw Telegram RPC, and caller-selected moderation. Delete/restrict/ban behavior can only come from current TG policy or an approved decision; restore must reference a confirmed restriction audit for the same group and user.

## Preview, Live And Replay / Preview、Live 与 Replay

Live 会 force-fresh 重读 Issue 和 approval，再通过 ordinary NyxID service 调用相对于 `/api/automation/v1` base 的 `GET /capabilities`。Preflight 必须看到 `contract_version=automation.v1`、匹配的 `account_ref`、精确 24-operation risk/scope/side-effect/mode metadata、ordinary scope matrix、exclusions 和 limits，之后才会 `POST /commands`。

Live force-fresh re-reads the Issue and approval, then calls `GET /capabilities` relative to the `/api/automation/v1` base through the ordinary NyxID service. Preflight requires `contract_version=automation.v1`, the expected `account_ref`, the exact 24-operation risk/scope/side-effect/mode metadata, the ordinary scope matrix, exclusions, and limits before it can `POST /commands`.

同一个 Issue、mode 与 canonical command 始终生成相同 `client_command_id`、`trace_id` 和 `Idempotency-Key`。请求同时发送与 body 一致的 `X-Trace-ID`。周期性 `github_issue_observed` 会重新提交完全相同的 payload/key，让 TG 返回已有 command 的最新状态，不会换 key 重放 Telegram action。

The same Issue, mode, and canonical command always produce the same `client_command_id`, `trace_id`, and `Idempotency-Key`. Requests also send an `X-Trace-ID` identical to the body trace. Periodic `github_issue_observed` events resubmit the identical payload/key so TG returns the existing command's latest state; the package never changes the key to replay a Telegram action.

## R2 Approval / R2 审批

`reply.decision.execute`、`moderation.message.execute`、`moderation.profile.scan` 和 `moderation.user.restore` 属于 R2。Live R2 同时要求：Issue 作者在 trusted allowlist；批准人与作者不同；批准人在 approver allowlist；普通与 destructive write switches 都开启；两套 NyxID service 独立。

`reply.decision.execute`, `moderation.message.execute`, `moderation.profile.scan`, and `moderation.user.restore` are R2. Live R2 requires a trusted Issue author, a distinct allowlisted approver, both ordinary and destructive write switches, and independent NyxID services.

批准评论只能包含 TG approved command document 的 sorted compact canonical JSON，即 `account_ref`、`mode`、`operation` 和 `payload`，不能有 Markdown fence、前后空白或换行。例如：

The approval comment contains only the sorted compact canonical JSON for TG's approved command document: `account_ref`, `mode`, `operation`, and `payload`, with no Markdown fence, surrounding whitespace, or newline. For example:

```json
{"account_ref":"telegram-primary","mode":"live","operation":"moderation.user.restore","payload":{"group_id":-1001234567890,"restriction_audit_id":73,"user_id":42}}
```

R2 command 通过 destructive NyxID service 提交；capabilities preflight 始终通过 ordinary service 完成。TG 会再次验证 actor separation、comment/source binding、timestamp 和 canonical command，FKST 的判断不是最终授权边界。

R2 commands are submitted through the destructive NyxID service while capabilities preflight always uses the ordinary service. TG independently revalidates actor separation, comment/source binding, timestamp, and the canonical command; FKST is not the final authorization boundary.

## Environment Profile / Environment Profile

```sh
TELEGRAM_GOVERNANCE_WRITE=1
TELEGRAM_GOVERNANCE_DESTRUCTIVE_WRITE=1
TELEGRAM_GOVERNANCE_SERVICE_SLUG=telegram-automation-online
TELEGRAM_GOVERNANCE_DESTRUCTIVE_SERVICE_SLUG=telegram-automation-destructive-online
TELEGRAM_GOVERNANCE_TRUSTED_AUTHOR_LOGINS=alice
TELEGRAM_GOVERNANCE_APPROVER_LOGINS=bob,carol
NYXID_ACCESS_TOKEN=<session-exclusive-agent-key>
```

TG API keys 只能保存在 NyxID。Environment Profile 只保存 session 独占的 NyxID agent key、service slugs、allowlists 和 switches。每个 FKST agent/session 使用独立的 `NYXID_ACCESS_TOKEN`，保留 audit isolation 和独立 revoke 能力。

TG API keys live only in NyxID. The Environment Profile contains only a session-exclusive NyxID agent key, service slugs, allowlists, and switches. Every FKST agent/session uses a distinct `NYXID_ACCESS_TOKEN` for audit isolation and independent revocation.

## Receipts And Failure Posture / Receipt 与失败策略

TG command 状态为 `accepted | running | succeeded | blocked | failed`。`execution_outcome` 独立表示 `not_attempted | confirmed_effect | confirmed_no_effect | unknown`。Receipt comment 按 `command_id/status/execution_outcome` 去重；preview 或 pre-submit blocked receipt 使用 `idempotency_key/status/execution_outcome`。

TG command states are `accepted | running | succeeded | blocked | failed`. The independent `execution_outcome` is `not_attempted | confirmed_effect | confirmed_no_effect | unknown`. Receipt comments deduplicate by `command_id/status/execution_outcome`; preview and pre-submit blocked receipts use `idempotency_key/status/execution_outcome`.

`execution_outcome=unknown` 必须人工介入。不要更换 idempotency key 自动重试；先核验 Telegram 实际状态和 TG audit evidence，再决定 reconcile、restore 或接受现状。Receipt 不包含 result、provider raw response、Issue body、approval body 或 credential-shaped fields。

`execution_outcome=unknown` requires human intervention. Do not retry with a new idempotency key; inspect actual Telegram state and TG audit evidence before reconciling, restoring, or accepting the result. Receipts exclude results, raw provider responses, Issue bodies, approval bodies, and credential-shaped fields.

## Canary And Rollback / Canary 与回滚

Canary 使用现有 `fkst-hosted` 创建独立 session，只加载 official `github-proxy` 和本 manifest，不修改 Auto Twitter session 或 `fkst-hosted` tracked files。顺序为 preview、`group.sync`、可恢复 config update、测试账号 restrict/restore、disposable message moderation、approved disposable reply，最后验证 online direct 与 local node-routed services。

Canary uses a dedicated session in the existing `fkst-hosted` runtime and loads only the official `github-proxy` plus this manifest. It does not change the Auto Twitter session or tracked `fkst-hosted` files. Run preview, `group.sync`, a reversible config update, test-account restrict/restore, disposable message moderation, an approved disposable reply, and finally both online-direct and local-node routes.

紧急停止顺序：关闭 destructive switch、关闭 ordinary switch、停止 hosted trigger Issue、revoke NyxID agent key、revoke 两套 TG API keys。保留 command、event、moderation audit 和 restore claim 数据用于调查。

Emergency stop order: disable the destructive switch, disable the ordinary switch, stop the hosted trigger Issue, revoke the NyxID agent key, then revoke both TG API keys. Preserve command, event, moderation audit, and restore claim data for investigation.

North Star 是获批 live command 在 10 分钟内获得 terminal receipt，目标不低于 99%。Guardrails 是未授权 destructive action、重复 Telegram action 和 credential leakage 均为零。

The North Star is at least 99% of approved live commands receiving a terminal receipt within 10 minutes. Guardrails require zero unauthorized destructive actions, duplicate Telegram actions, and credential leaks.

## Test Commands / 测试命令

```sh
scripts/run.sh check
scripts/run.sh test telegram-governance
scripts/run.sh test
scripts/run.sh test-composed
```

测试使用 fake GitHub/NyxID ports 或 FKST command mocks，不调用真实 GitHub、Telegram、NyxID service 或 credential。

Tests use fake GitHub/NyxID ports or FKST command mocks. They never call real GitHub, Telegram, NyxID services, or credentials.

⟦AI:FKST⟧
