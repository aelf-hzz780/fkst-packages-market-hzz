# lark-approval

Universal human-in-the-loop approval gate via Lark/Feishu - **contract + preview implementation.**
Any host repo composes it via `pkg.queue` to require a human decision before an irreversible effect
fires.

- **consumes** `approval_request` - `{ approval_id? | artifact_id, subject?, source_ref, trace_id?,
  dedup_key? }`. `approval_id` can be supplied directly or deterministically derived as
  `approval:<artifact_id>`.
- **produces** `approval_decided` - `{ approval_id, artifact_id?, decision = "pending", source_ref,
  trace_id?, dedup_key? }` for valid requests.
- **payload boundary** the request may carry only small subject fields (`title`, `summary`, `kind`,
  `locale`) and a source pointer. Lark card bodies, message text, raw replies, provider responses,
  tokens, OAuth material, credentials, and authorization-like fields are rejected fail-closed.
- **reply parser** `decision_from_reply` accepts only explicit approve/deny tokens. Empty, mixed,
  unknown, or ambiguous replies remain `pending`.
- **posture** shadow-first + **fail-closed**: no Lark card is sent from this package. A real card
  send and reply observation must be injected by a host-pinned Lark/Feishu egress skill.

The department raises a pending decision only for valid requests. Invalid requests are skipped and
can never auto-approve.

⟦AI:FKST⟧
