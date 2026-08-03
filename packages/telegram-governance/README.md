# Telegram Governance

`telegram-governance` 是 business-owned FKST composed package。它消费 official `github-proxy` 的 Issue events，把 GitHub Issue 作为事实来源，通过 NyxID 调用 Telethon Auto 的受限 Machine API，并把 command 状态写回原 Issue。

`telegram-governance` is a business-owned FKST composed package. It consumes Issue events from the official `github-proxy`, treats the GitHub Issue as the source of truth, calls Telethon Auto's restricted Machine API through NyxID, and writes command status receipts back to the source Issue.

## Package Graph / Package 流程

```text
github-proxy.github_issue_changed ─┐
github-proxy.github_issue_observed ├─> github_command_intake
                                  └─> telegram_command_request (pointer only)
                                      -> execute_command
                                      -> telegram_command_receipt
                                      -> receipt_sink
                                      -> github-proxy.github_issue_comment_request
```

`execute_command` 把 `telegram_command_request` 声明为 `published_seam`，因此其他已授权 composer 也能提交相同的 pointer-only contract。`dead_letter` 使用标准 `workflow.dead_letter` handler。

`execute_command` declares `telegram_command_request` as a `published_seam`, so another authorized composer can submit the same pointer-only contract. `dead_letter` uses the standard `workflow.dead_letter` handler.

## Issue Contract / Issue Contract

Issue 必须带 `telegram-governance` label，body 必须是一个不超过 32 KiB 的 JSON envelope。`mode` 只允许 `preview` 或 `live`，省略时为 `preview`；`command` 只允许 `action`、`target` 和 `parameters`。

The Issue must carry the `telegram-governance` label and its body must be a JSON envelope no larger than 32 KiB. `mode` is either `preview` or `live` and defaults to `preview`; `command` contains exactly `action`, `target`, and `parameters`.

```json
{
  "mode": "preview",
  "command": {
    "action": "group.sync",
    "target": { "group_id": -1001234567890 },
    "parameters": {}
  }
}
```

Package 固定支持 TG Machine API 的 14 个 actions：`group.sync`、`group.profile_scan`、`monitor.add`、`monitor.pause`、`monitor.resume`、`history.backfill`、`group.config.update`、`knowledge.bindings.replace`、`actor_policy.upsert`、`message.delete`、`user.restrict`、`user.ban`、`user.restore`、`reply.approve_send`。不支持建群、任意主动消息或 raw Telethon RPC。`group.profile_scan` 不能请求 `dry_run=false`。

The package supports exactly the 14 actions exposed by the TG Machine API: `group.sync`, `group.profile_scan`, `monitor.add`, `monitor.pause`, `monitor.resume`, `history.backfill`, `group.config.update`, `knowledge.bindings.replace`, `actor_policy.upsert`, `message.delete`, `user.restrict`, `user.ban`, `user.restore`, and `reply.approve_send`. Group creation, arbitrary proactive messages, and raw Telethon RPC are excluded. `group.profile_scan` cannot request `dry_run=false`.

## Preview And Live / Preview 与 Live

Preview 是默认行为：package 会解析并验证当前 Issue，生成 `preview` receipt，但不会检查 NyxID CLI、读取 `NYXID_ACCESS_TOKEN` 的值或调用任何 TG endpoint。

Preview is the default behavior: the package parses and validates the current Issue and emits a `preview` receipt, but it does not check the NyxID CLI, read the value of `NYXID_ACCESS_TOKEN`, or call a TG endpoint.

Live 会 force-fresh 重读 Issue 和 approval，再通过 ordinary NyxID service 调用相对于 `/api/machine/v1` base 的 `GET /capabilities`。Preflight 必须看到固定 14-action catalog、正确的 risk/scope matrix、`group.profile_scan` forced dry-run 和完整 exclusions。通过后才会 `POST /commands`，并设置稳定的 `Idempotency-Key`。

Live force-fresh re-reads the Issue and approval, then calls `GET /capabilities` relative to the `/api/machine/v1` base through the ordinary NyxID service. Preflight requires the fixed 14-action catalog, the expected risk/scope matrix, forced dry-run for `group.profile_scan`, and all exclusions. Only then does it `POST /commands` with a stable `Idempotency-Key`.

同一个 Issue 与相同 canonical command 始终生成相同 `client_command_id`、`trace_id` 和 idempotency key。周期性 `github_issue_observed` 会重复提交同一个 payload/key，让 TG 返回已有 command 的最新状态；不会更换 key 盲目重放 action。

The same Issue and canonical command always produce the same `client_command_id`, `trace_id`, and idempotency key. Periodic `github_issue_observed` events resubmit the same payload/key so TG returns the existing command's latest status; the package never changes the key to blindly replay an action.

## R2 Approval / R2 审批

`message.delete`、`user.restrict`、`user.ban`、`user.restore` 和 `reply.approve_send` 属于 R2。Live R2 同时要求：Issue 作者在 trusted allowlist；批准人与作者不同；批准人在 approver allowlist；批准评论 body 与 command 的排序压缩 canonical JSON 完全一致；普通与 destructive write switches 都开启；destructive service slug 与 ordinary service slug 不同。

`message.delete`, `user.restrict`, `user.ban`, `user.restore`, and `reply.approve_send` are R2 actions. Live R2 requires all of the following: the Issue author is trusted; the approver differs from the author; the approver is allowlisted; the approval comment body exactly equals the sorted compact canonical JSON for the command; both write switches are enabled; and the destructive service slug differs from the ordinary service slug.

批准评论只能包含 command 的 canonical JSON，不能带 Markdown fence、前后空白或换行。例如：

The approval comment contains only the command's canonical JSON, with no Markdown fence, surrounding whitespace, or newline. For example:

```json
{"action":"message.delete","parameters":{"reason":"spam"},"target":{"group_id":-1001234567890,"message_id":9}}
```

R0/R1 不需要 destructive approval。R2 command 会通过 destructive NyxID service 提交，但 capabilities preflight 始终通过 ordinary service 完成，因此 destructive credential 不需要暴露 ordinary operate/configure authority。

R0/R1 does not require destructive approval. R2 commands are submitted through the destructive NyxID service, while capabilities preflight always uses the ordinary service, so the destructive credential does not need ordinary operate/configure authority.

## Environment Profile / Environment Profile

```sh
TELEGRAM_GOVERNANCE_WRITE=1
TELEGRAM_GOVERNANCE_DESTRUCTIVE_WRITE=1
TELEGRAM_GOVERNANCE_ORDINARY_SERVICE=telegram-machine-online
TELEGRAM_GOVERNANCE_DESTRUCTIVE_SERVICE=telegram-machine-destructive-online
TELEGRAM_GOVERNANCE_TRUSTED_AUTHOR_LOGINS=alice
TELEGRAM_GOVERNANCE_APPROVER_LOGINS=bob,carol
NYXID_ACCESS_TOKEN=<session-exclusive-agent-key>
```

TG Machine API keys 只能保存在 NyxID。Environment Profile 只能保存 session 独占的 NyxID agent key 和 service slugs，不能保存 TG key。每个 FKST agent/session 使用独立的 `NYXID_ACCESS_TOKEN`，以保留 audit isolation 和独立 revoke 能力。

TG Machine API keys live only in NyxID. The Environment Profile contains only the session-exclusive NyxID agent key and service slugs, never a TG key. Every FKST agent/session uses a distinct `NYXID_ACCESS_TOKEN` to preserve audit isolation and independent revocation.

## Receipts And Failure Posture / Receipt 与失败策略

TG 状态为 `queued | running | succeeded | failed | indeterminate | cancelled`。Receipt comment 按 `command_id/status` 去重；preview 或 pre-submit blocked receipt 按 `idempotency_key/status` 去重。Receipt 不包含 TG result、provider raw response、Issue body、approval comment body 或 credential-shaped fields。

TG statuses are `queued | running | succeeded | failed | indeterminate | cancelled`. Receipt comments deduplicate by `command_id/status`; preview and pre-submit blocked receipts deduplicate by `idempotency_key/status`. Receipts never include TG results, raw provider responses, Issue bodies, approval comment bodies, or credential-shaped fields.

`indeterminate` 是人工介入状态。不要更换 idempotency key 自动重试；先核验 Telegram 实际状态和 TG audit evidence，再决定 reconcile、restore 或接受现状。

`indeterminate` requires human intervention. Do not retry with a new idempotency key; inspect actual Telegram state and TG audit evidence before choosing to reconcile, restore, or accept the result.

本地 package 测试能验证 service routing、catalog/scope contract 和 fail-closed 行为，但 TG capabilities 不返回 Telegram account identity。Canary 必须额外对已知 group 执行 `group.sync` 并核对 group ID/title/username，才能验证 local node 或 online service 指向预期 account/instance。

Local package tests validate service routing, catalog/scope contracts, and fail-closed behavior, but TG capabilities does not expose Telegram account identity. Canary must additionally run `group.sync` for a known group and compare its ID/title/username to prove that a local-node or online service targets the expected account/instance.

## Canary And Rollback / Canary 与回滚

Canary 使用现有 `fkst-hosted` 创建独立的 `telegram-governance-canary` session，只加载 official `github-proxy` 和本 manifest，不修改 Auto Twitter session，也不要求修改 `fkst-hosted` tracked files。依次验证 preview 零副作用、`group.sync`、可恢复的 config update、测试账号 restrict/restore、disposable message delete、disposable approved draft send，最后分别验证 local node 和 online direct service。

Canary uses the existing `fkst-hosted` runtime to create an independent `telegram-governance-canary` session that loads only the official `github-proxy` and this manifest. It neither changes the Auto Twitter session nor requires tracked-file changes in `fkst-hosted`. Validate, in order: side-effect-free preview, `group.sync`, a reversible config update, restrict/restore for a test account, deletion of a disposable message, sending a disposable approved draft, and both local-node and online-direct service routes.

紧急停止顺序为：关闭 destructive switch、关闭 ordinary write switch、关闭 hosted trigger Issue、revoke NyxID agent key、最后 revoke TG Machine API keys。任何 `indeterminate` command 在调查完成前都保持停止状态。

Emergency stop order is: disable the destructive switch, disable the ordinary write switch, disable the hosted trigger Issue, revoke the NyxID agent key, and finally revoke TG Machine API keys. Keep any `indeterminate` command stopped until investigation completes.

North Star 是获批 live command 在 10 分钟内获得 terminal receipt，目标不低于 99%。Guardrails 是未授权 destructive action、重复 Telegram action和 credential leakage 均为零。

The North Star is at least 99% of approved live commands receiving a terminal receipt within 10 minutes. Guardrails require zero unauthorized destructive actions, duplicate Telegram actions, and credential leaks.

## Test Commands / 测试命令

```sh
scripts/run.sh check
scripts/run.sh test telegram-governance
scripts/run.sh test
scripts/run.sh test-composed
```

Tests use fake GitHub/NyxID ports or FKST command mocks. They do not call GitHub, Telegram, NyxID services, or credentials.

测试只使用 fake GitHub/NyxID ports 或 FKST command mocks，不会调用真实 GitHub、Telegram、NyxID service 或 credential。

⟦AI:FKST⟧
