# Auto Twitter marketing workflow v0.3.0

This document defines the v2 GitHub Issue contracts for the Auto Twitter marketing package set.
The official `github-proxy` remains the GitHub adapter; this repository owns only marketing
business behavior. v0.3.0 does not accept v1 marketing Content, Schedule, publish request, or
publish receipt payloads.

本文定义 Auto Twitter marketing package set 的 v2 GitHub Issue 合约。官方
`github-proxy` 仍是 GitHub adapter，本仓库只负责营销业务逻辑。v0.3.0 不接受 v1 的
marketing Content、Schedule、publish request 或 publish receipt payload。

## Runtime package set / 运行时 package 组合

Import the official GitHub adapter separately, then import the business manifest from one immutable
release tag. The manifest intentionally declares no shared work label.

请单独导入官方 GitHub adapter，再从同一个不可变 release tag 导入 business manifest。
Manifest 有意不声明共享 work label。

The operator procedure for the RC Shadow is
[`hzz780-v0.3.0-rc.3-acceptance.md`](hzz780-v0.3.0-rc.3-acceptance.md). It is the authoritative
runbook for fixture isolation, account normalization, evidence capture, canary approval, and
rollback.

RC Shadow 的运营步骤见
[`hzz780-v0.3.0-rc.3-acceptance.md`](hzz780-v0.3.0-rc.3-acceptance.md)。该 Runbook 是隔离
fixture、账号归一、证据留存、Canary 批准与回滚的权威操作说明。

```text
ChronoAIProject/fkst-hosted@packages:packages/github-proxy
aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.3:manifests/auto-twitter-marketing.json
```

Only the business manifest is immutable. Hosted currently cannot clone the official package from a
raw SHA, and no official tag contains `packages/github-proxy`, so the RC uses the supported
`@packages` branch with the SHA drift guard defined by the acceptance runbook. Local and CI composed
tests still use the exact SHA recorded in `fkst.workspace.toml`.

Do not start a Stable Hosted Session while stable_hosted_release=blocked.

只有 business manifest 是不可变引用。Hosted 当前不能从 raw SHA clone official package，且尚无
official tag 包含 `packages/github-proxy`，因此 RC 使用受支持的 `@packages` branch，并执行验收
Runbook 规定的 SHA drift guard；本地与 CI composed test 仍使用 `fkst.workspace.toml` 记录的
完整 SHA。

The isolated acceptance Session pins `v0.3.0-rc.3`. After shadow acceptance, freeze the evidence and
stop that Session. Do not create the `v0.3.0` descriptor or a Stable Hosted Session until the official
dependency has an immutable Hosted-supported ref, or a separately reviewed Host solution is
approved. Once the blocker is resolved, tag the exact clean commit, rerun `scripts/run.sh
formal-gate`, and only then plan a sequential work-label takeover.

隔离验收 Session 固定使用 `v0.3.0-rc.3`。Shadow 验收通过后只冻结证据并停止该 Session。在
official dependency 提供 Hosted 支持的 immutable ref，或单独评审批准 Host 方案前，不得创建
`v0.3.0` descriptor 或 Stable Hosted Session。Blocker 解除后，必须对精确 clean commit 打 tag、
重跑 `scripts/run.sh formal-gate`，之后才能规划顺序接管 work label。

Each X account has one Hosted Session with a stable, account-specific `### Work Label`. The Host
injects `FKST_SESSION_WORK_LABEL`, `FKST_SESSION_WORK_LABEL_MAP_JSON`, and
`FKST_SESSION_CREATOR`; package authors must not set those values through Package Env.

每个 X 账号使用一个 Hosted Session，并设置稳定、账号隔离的 `### Work Label`。Host 注入
`FKST_SESSION_WORK_LABEL`、`FKST_SESSION_WORK_LABEL_MAP_JSON` 和
`FKST_SESSION_CREATOR`，package author 不得通过 Package Env 设置这些值。

Every work Issue must carry the Session's effective label and exactly one assignee equal to the
Session creator. Its logical `work-label` and `account` fields must match the Session route and
`X_PUBLISH_EXPECTED_USERNAME`. A mismatch stays Open and cannot produce an X request.

每个工作 Issue 必须携带 Session effective label，且唯一 assignee 必须等于 Session creator。
正文中的逻辑 `work-label` 与 `account` 必须分别匹配 Session route 和
`X_PUBLISH_EXPECTED_USERNAME`。任一不匹配都会保持 Open，且不能产生 X request。

## Signal contract / Signal 合约

A v2 `radar-signal` must be authored by the Session creator, an authorized Session collaborator,
or another login admitted by the Host author policy. `action` is mandatory and authoritative. The
AI draft step cannot change it or widen its scope.

v2 `radar-signal` 必须由 Session creator、已授权 Session collaborator，或 Host author
policy 明确允许的账号提交。`action` 必填且是权威输入；AI draft 步骤不能修改 action，也不能
扩大它的影响范围。

```yaml
type: radar-signal
project: example-project
account: test_primary
work-label: auto-x-test-primary
week: 2026-W33
action: add
topic: product-evidence
source-url: https://example.test/evidence/42
insight: Explain the verified user impact and cite the supplied evidence.
```

The action strategies are deliberately separate:

- `add`: `target-ref` is forbidden; existing Content and Schedules are unchanged.
- `revise`: `target-ref` is required and must point to one unpublished approved Content Issue.
- `replan`: `target-ref` is forbidden; every unpublished approved Content in the same account,
  project, and week is superseded. Published Content is never changed.

Action Strategy 相互独立：

- `add`：禁止 `target-ref`，不影响已有 Content 和 Schedule。
- `revise`：必须提供 `target-ref`，且只能指向一条未发布的 approved Content Issue。
- `replan`：禁止 `target-ref`，同账号、项目、周次下所有未发布的 approved Content 都会失效；
  已发布 Content 永不修改。

Missing action, conflicting controls, an unavailable target, an unauthorized author, or an attempt
to revise published Content enters `needs-triage`. A correction to published material must be a new
`add` Signal.

缺少 action、字段冲突、目标不存在、作者未授权，或尝试 revise 已发布 Content 时，Issue 进入
`needs-triage`。对已发布内容的纠正必须提交新的 `add` Signal。

Signals aggregate only when `account + project + week + canonical topic + action + target-ref`
match. Topic canonicalization is a migration/operator decision, not an AI side effect. Signal
digests use canonical business fields and body content; `updated_at` and `session_id` never enter
identity or deduplication.

只有 `account + project + week + canonical topic + action + target-ref` 全部一致的 Signal 才会
聚合。Topic canonicalization 由迁移或运营显式决定，不允许 AI 擅自归类。Signal digest 只使用
canonical 业务字段与正文；`updated_at` 和 `session_id` 不进入 identity 或 dedup。

When deterministic draft validation ends in `semantic-conflict` or exhausts its one bounded
overlength correction, every Signal in that aggregate receives a trusted Signal-set-bound triage
ACK. The marker binds the group, complete Signal-set digest, deterministic anchor, and target
Signal. Only the anchor marker, written by the trusted bot through `github-proxy`, is durable
authority; a sibling marker alone cannot freeze the group. Each replay rebuilds the current open
catalog and fresh-reads the anchor before it can stop ahead of Codex. A missing sibling ACK is
repaired without another AI call. Closing, rerouting, editing, or adding a Signal changes the group
or set identity and releases the old marker.

当 deterministic draft validation 返回 `semantic-conflict`，或唯一一次 bounded 超长纠正仍失败
时，聚合内每条 Signal 都会收到可信且绑定完整 Signal set 的 triage ACK。Marker 同时绑定 group、
完整 Signal-set digest、deterministic anchor 与目标 Signal。只有可信 bot 经 `github-proxy` 写入的
anchor marker 才是 durable authority；仅有 sibling marker 不能冻结整组。每次 replay 都会先重建
当前 open catalog 并 fresh-read anchor，再决定是否在 Codex 前停止；缺失的 sibling ACK 会在不
重跑 AI 的情况下补齐。关闭、改路由、编辑或新增 Signal 会改变 group 或 set identity，从而使旧
marker 失效。

## AI proposal and review / AI 提案与人工审核

The draft adapter sends bounded, authorized Signal controls plus bounded trusted Signal body context
to `spawn_codex_sync` with `sandbox = "read-only"` and a 600-second timeout. Output must be exactly
one JSON object containing only `tweet_text`, `evidence_refs`, `action`, `target_ref`,
`semantic_conflict`, and `conflict_reason`. Evidence must be the exact unique set of input Signal
refs, action/target must be unchanged, and `tweet_text` must pass X weighted-length validation.

Draft adapter 会把经过授权且有长度上限的 Signal controls，以及有界的可信 Signal 正文上下文
发送给 `spawn_codex_sync`，固定使用 `sandbox = "read-only"` 和 600 秒 timeout。输出必须是唯一
一个 JSON object，且只能包含 `tweet_text`、`evidence_refs`、`action`、`target_ref`、
`semantic_conflict` 和 `conflict_reason`。Evidence 必须精确等于输入 Signal ref 的唯一集合，
action/target 不得变化，`tweet_text` 必须通过 X weighted-length 校验。

The package creates one `weekly-plan-change` Issue per active proposal group. Bot-authored proposal
revisions carry a canonical Signal-set digest, Proposal digest, Content digest, evidence refs, and
immutable revision number. Only explicitly authorized reviewers may issue these commands:

Package 为每个 active proposal group 创建一个 `weekly-plan-change` Issue。由 Bot 发布的每个
proposal revision 都携带 canonical Signal-set digest、Proposal digest、Content digest、evidence
refs 和不可变 revision number。只有明确授权的 reviewer 可以执行：

```text
/marketing approve <proposal-id>@<revision> <proposal-digest>
/marketing request-changes <proposal-id>@<revision> <proposal-digest> <reason>
/marketing reject <proposal-id>@<revision> <proposal-digest> <reason>
```

`request-changes` invokes a new read-only draft and publishes `revision + 1`; commands for older
revisions then fail closed. `approve` requests approved Content but does not close the proposal or
Signals until `github-proxy` has written a trusted durable issue-created marker and the created
Content passes a fresh identity/digest read. `reject` records the decision and terminates the
proposal without creating Content. Every command binds the exact Proposal digest shown on that
revision. The digest covers action/target scope, group identity, Signal lineage, evidence, and the
Content digest. Editing any of those fields cannot make an earlier approval apply, even if the
proposal ID, numeric revision, and tweet text are preserved.

`request-changes` 会重新调用 read-only draft 并发布 `revision + 1`，此后针对旧 revision 的命令
全部 fail closed。`approve` 只请求创建 approved Content；只有 `github-proxy` 写入可信的 durable
issue-created marker，且新 Content 通过 fresh identity/digest 校验后，proposal 与 Signals 才会
终结。`reject` 只记录决策并终结 proposal，不创建 Content。每条命令必须绑定该 revision 显示的
精确 Proposal digest；该 digest 覆盖 action/target scope、group identity、Signal lineage、
evidence 与 Content digest。即便 proposal ID、数字 revision 和 tweet text 保持不变，编辑其中
任一业务字段后，旧审批也不能继续生效。

If bounded generation for `request-changes` fails, a trusted marker binds the failure to the exact
proposal revision and review comment ID. Replays make zero AI calls. The first command remains the
authority unless that exact failure marker releases it; an authorized reviewer can then add a new
same-revision command to take over. Proposal text and untrusted comments cannot forge this state.
Review decisions always use the fresh REST shape, so failure markers and terminal Close handoffs
carry stable numeric GitHub comment IDs instead of GraphQL `IC_...` node IDs. Before closing a
Signal, the terminalizer fresh-reads both that Signal and its Review Issue under the close lock and
revalidates the exact review comment, revision, Proposal digest, and Content digest.

如果 `request-changes` 的 bounded generation 失败，可信 marker 会把失败精确绑定到 proposal
revision 与 review comment ID；重放不会再次调用 AI。首条命令仍是权威输入，只有绑定该命令的
精确 failure marker 才能释放它，随后授权 reviewer 可追加新的同 revision 命令接管。Proposal
文本与不可信评论都不能伪造这一状态。Review decision 始终使用 fresh REST shape，因此 failure
marker 与 terminal Close handoff 携带稳定的 GitHub numeric comment ID，而不是 GraphQL
`IC_...` node ID。关闭 Signal 前，terminalizer 会在 close lock 内同时 fresh-read 该 Signal 与其
Review Issue，并重新校验精确的 review comment、revision、Proposal digest 与 Content digest。

Package-only recovery has one explicit liveness limit: the Proposal controls and the trusted
`issue-create` marker both live in the mutable Proposal Issue body. If an operator rewrites both so
the original group and cycle disappear, this package cannot reconstruct that historical cycle from
GitHub alone and may reuse its external-effect dedup after durable runtime loss. Such an Issue is
manual triage: stop the Shadow lane, freeze the artifacts, and do not reuse the group. Eliminating
this limit requires an immutable receipt outside that body in the official package or Host, which is
outside v0.3.0 and requires separate review.

Package-only recovery 有一个明确的 liveness 边界：Proposal controls 与可信 `issue-create` marker
都位于可编辑的 Proposal Issue body。如果运营同时改写二者，导致原 group 与 cycle 都消失，
本 package 无法仅凭 GitHub 重建历史 cycle；durable runtime 丢失后可能复用 external-effect dedup。
遇到这种 Issue 必须进入人工 triage：停止 Shadow lane、冻结 artifact、禁止复用该 group。彻底消除
该限制需要 official package 或 Host 在正文之外提供 immutable receipt，不属于 v0.3.0，必须另行
评审。

## Immutable Content / 不可变 Content

Approved Content uses the exact `auto-twitter-marketing.weekly-content.v2` contract. The digest is
SHA-256 over the canonical fields and tweet text. The issue is imported, receives a durable digest
acknowledgement comment, is read fresh, and is then closed under a lock. A missing Close response is
resolved by rereading the Issue.

Approved Content 使用严格的 `auto-twitter-marketing.weekly-content.v2` 合约。Digest 是 canonical
字段和 tweet text 的 SHA-256。Issue 导入后先获得 durable digest ACK comment，再经 fresh read，
最后在 lock 内 Close；如果 Close response 丢失，则通过重新读取 Issue 收敛。

The Content Issue itself must be created by the configured GitHub Bot/App. The importer and
publisher independently canonicalize and verify its author; a human-authored Issue with otherwise
valid fields and digest cannot reach X.

Content Issue 本身必须由配置的 GitHub Bot/App 创建。Importer 与 publisher 会各自 canonicalize
并校验作者；即使字段与 digest 都合法，人工伪造的 Content Issue 也不能进入 X 发布链路。

````yaml
contract: auto-twitter-marketing.weekly-content.v2
type: weekly-content
project: example-project
account: test_primary
work-label: auto-x-test-primary
week: 2026-W33
content-id: content-example-w33
content-revision: 1
proposal-id: proposal-example-w33
proposal-revision: 1
approval-id: proposal-example-w33@1
content-status: approved
content-digest: sha256:<64-lowercase-hex>

tweet-text:
```
A reviewed post backed by the cited evidence.
```
````

For `revise` and `replan`, unpublished predecessor Content receives a digest-bound superseded
marker. Both the marketing importer and `x-publisher` fresh-read the Content and reject a matching
superseded marker. Published predecessors are preserved.

对 `revise` 与 `replan`，未发布的旧 Content 会收到绑定 digest 的 superseded marker。Marketing
importer 与 `x-publisher` 都会 fresh-read Content，并拒绝带匹配 superseded marker 的版本；已发布
旧版本保持不变。

## Manual Schedule and X gate / 人工排期与 X 门禁

Approval never creates a Schedule. An operator performs the second explicit approval by creating a
v2 Schedule that pins the exact Content ref, digest, approval, account, and logical work label.

Approve 永远不会自动创建 Schedule。运营人员通过手工创建 v2 Schedule 完成第二道明确批准；
Schedule 必须固定 exact Content ref、digest、approval、account 和逻辑 work label。

```yaml
contract: auto-twitter-marketing.schedule-publish.v2
type: schedule-publish
project: example-project
account: test_primary
work-label: auto-x-test-primary
week: 2026-W33
content-ref: "#42"
content-digest: sha256:<64-lowercase-hex>
approval-id: proposal-example-w33@1
mode: shadow
scheduled-at: 2026-08-17T08:00:00Z
```

Before any X write, both the importer and publisher fresh-read the Schedule and Content. The
following identities must all match: Schedule account, Content account, Session expected account,
and NyxID `/users/me` username. The Content must be CLOSED, approved, digest-identical, correctly
routed, assigned to the Session creator, and not superseded. Any failure emits/records a blocked
outcome and makes zero `POST /tweets` calls.

任何 X write 前，importer 与 publisher 都会 fresh-read Schedule 和 Content。Schedule account、
Content account、Session expected account、NyxID `/users/me` username 必须全部一致。Content
还必须是 CLOSED、approved、digest 完全一致、route 正确、唯一 assignee 为 Session creator，且
未被 supersede。任一失败都会产生或记录 blocked outcome，并保证 `POST /tweets` 调用数为 0。

Every blocked receipt records `publish_attempted`. It is `false` when the workflow stops before the
provider POST, and `true` only when `POST /tweets` was invoked but failed or returned an unusable
response.

每个 blocked receipt 都记录 `publish_attempted`。在 provider POST 前阻断时为 `false`；只有已经
调用 `POST /tweets`、但调用失败或响应不可用时才为 `true`。

The v2 `x_publish_request` and `x_published` receipt preserve account, authenticated account,
logical work label, Content digest, approval ID, source ref, account-scoped artifact/dedup identity,
and Trace ID. A successful live one-shot writes the same canonical published receipt to two anchors:
the Schedule Issue for operator history and the referenced Content Issue for terminal correlation.
The Schedule receipt has no close handoff. Only acknowledgement of the Content receipt carries the
correlated handoff; the terminalizer then fresh-reads and revalidates the Schedule, acquires its
local lock, and closes that Schedule. A lost Close response converges through a fresh reread.
Shadow, blocked, and recurring Schedules remain Open.

v2 `x_publish_request` 与 `x_published` receipt 会保留 account、authenticated account、逻辑 work
label、Content digest、approval ID、source ref、账号隔离的 artifact/dedup identity 和 Trace ID。
Live one-shot 成功后，会把同一份 canonical published receipt 分别写入 Schedule Issue 与被引用的
Content Issue：Schedule receipt 用于运营留痕且不携带 close handoff；只有 Content receipt 的 ACK
携带关联 handoff。Terminalizer 收到该 Content ACK 后，才会 fresh-read 并重新校验 Schedule、获取
本地 lock，再关闭 Schedule；Close response 丢失时通过 fresh reread 收敛。Shadow、blocked、
recurring Schedule 保持 Open。

Timeline reconciliation remains the crash-recovery backstop for "POST succeeded before receipt was
durable". It is not a distributed lease. Operators must never run two active Sessions for the same
account, repository, and work scope.

Timeline reconciliation 继续处理“POST 成功但 receipt 尚未持久化”的崩溃恢复；它不是 distributed
lease。运营侧不得让两个 active Session 同时接管同一账号、repo 和 work scope。

## Issue lifecycle / Issue 生命周期

| Issue | Terminal rule / 终态规则 |
|---|---|
| `radar-config` | Remains Open; Close means disabled / 保持 Open，Close 表示停用 |
| `radar-signal` | Close after applied/rejected; triage stays Open / applied 或 rejected 后 Close，triage 保持 Open |
| `weekly-plan-change` | Close after materialized/rejected; request-changes stays Open / materialized 或 rejected 后 Close，request-changes 保持 Open |
| `weekly-content` | Close after durable import ACK and fresh digest check / durable import ACK 与 fresh digest 校验后 Close |
| one-shot Schedule | Close only after the Content-anchored published/recovered receipt ACK and fresh Schedule validation / 仅在 Content 锚定的 published/recovered receipt ACK 与 Schedule fresh 校验后 Close |
| shadow, blocked, recurring Schedule | Remains Open / 保持 Open |

## Operational metrics / 运营指标

The North Star is the percentage of admitted Signals that receive an explicit applied or rejected
decision within 24 hours. Guardrails require zero wrong-account publishes, duplicate publishes,
unreviewed publishes, and duplicate active proposals for the same account/week/topic group. Routing
ACK P90 must stay below five minutes and draft generation P90 below ten minutes.

North Star 是已接收 Signal 在 24 小时内获得明确 applied 或 rejected 决策的比例。Guardrail
要求错账号发布、重复发布、未审核发布，以及同 account/week/topic group 的重复 active
Proposal 均为 0。Routing ACK P90 必须小于 5 分钟，draft generation P90 必须小于 10 分钟。

These measures are derived from GitHub Issue/comment timestamps and Trace-ID-correlated Session
logs. v0.3.0 does not introduce a separate telemetry backend; the RC evidence bundle records the
raw timestamps, proposal IDs, account checks, and publish receipts needed to calculate them.

上述指标从 GitHub Issue/comment timestamp 与按 Trace ID 关联的 Session log 中计算。v0.3.0 不
新增独立 telemetry backend；RC 证据包保留计算所需的原始 timestamp、proposal ID、账号校验与
publish receipt。

## Migration, validation, and rollback / 迁移、验收与回滚

Legacy Signals are not silently upgraded. Before routing them to v0.3.0, migration must add an
explicit `action`, logical `work-label`, and operator-approved canonical topic. Shadow copies may
replace `account` with the dedicated test account, but production Signals must never have their
account silently rewritten.

Legacy Signal 不会被静默升级。路由到 v0.3.0 前，迁移必须显式补充 `action`、逻辑
`work-label` 和运营确认的 canonical topic。Shadow copy 可以把 `account` 替换成专用测试账号，
但生产 Signal 的账号绝不能被静默改写。

Formal local gates use mocked GitHub, Codex, NyxID, and X boundaries:

正式本地门禁会 mock GitHub、Codex、NyxID 和 X boundary：

```bash
scripts/run.sh formal-gate
```

The release gate ignores `.fkst/env`, rejects framework and official-source pin overrides, and runs
`verify-framework`, `check`, `test`, and `test-composed` sequentially. The resulting evidence must
show the tracked/effective official URL/ref, fetched official commit SHA, and locked tree digest.
The checker intentionally reports `hosted_ref_class=mutable-shadow-only` and
`stable_hosted_release=blocked`: passing this gate does not turn the official branch into an
immutable Stable Hosted dependency. Alternate framework runs remain diagnostics and are not release
evidence.

Release gate 会忽略 `.fkst/env`，拒绝 framework 与 official-source pin override，并顺序执行
`verify-framework`、`check`、`test` 与 `test-composed`。门禁证据必须包含 tracked/effective
official URL/ref、实际 fetch 的 official commit SHA 与 locked tree digest。Checker 会明确输出
`hosted_ref_class=mutable-shadow-only` 与 `stable_hosted_release=blocked`；门禁通过不会把
official branch 变成 Stable Hosted 的不可变依赖。Alternate framework 运行仍只属于 diagnostic，
不能作为发布证据。

The RC Hosted Shadow temporarily uses the `hzz780` account and the isolated `auto-x-hzz780` lane.
It creates copies of source Issues `#116/#117/#118/#124`, normalizes only those copies to
`account: hzz780`, explicitly supplies `action: add`, and uses one canonical topic for the same-week
group. The original Issues are not relabeled, reassigned, rewritten, or migrated. `aelfblockchain`
appears only in an isolated account-mismatch negative test. Radar Signals do not carry a publish
`mode`; Shadow isolation is enforced by disabling X writes and creating no Schedule. Expected output
is exactly two review proposals, zero automatic Schedules, and zero X writes. A live X canary requires
a separate explicit approval after the Shadow evidence, exact account, and final text are reviewed.

RC Hosted Shadow 暂时使用 `hzz780` 账号与隔离的 `auto-x-hzz780` lane。它为来源 Issue
`#116/#117/#118/#124` 创建副本，只把这些副本归一为 `account: hzz780`，显式设置
`action: add`，并为同周组设置同一个 canonical topic。原 Issue 不改 label、不改 assignee、不改
正文，也不迁移；`aelfblockchain` 只出现在隔离的账号错配负测中。Radar Signal 不携带发布
`mode`；Shadow 隔离由关闭 X write 且不创建 Schedule 保证。预期结果是严格两个 review
proposal、零自动 Schedule、零 X write。Live X Canary 必须在 Shadow 证据、确切账号与最终文案
复核后另行明确批准。

Rollback stops v0.3 Sessions, restores the v0.2.2 route, and freezes v2 Issues. v1 and v2 must not
run against the same work label. No rollback step deletes or mutates already published X content.

回滚时停止 v0.3 Session，恢复 v0.2.2 route，并冻结 v2 Issue。v1 与 v2 不得在同一个 work
label 下混跑。回滚不会删除或修改任何已经发布到 X 的内容。

⟦AI:FKST⟧
