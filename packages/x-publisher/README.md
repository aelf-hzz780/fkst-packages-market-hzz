# x-publisher

General X release package - **contract + preview implementation.** A reusable publish lane for X
that any host repo composes via `pkg.queue`: consume a safe publish request, validate that only
small control fields and a `source_ref` pointer are present, and emit a preview receipt.

- **consumes** `x_publish_request` - `{ artifact_id, source_ref, platform?, channel?, dedup_key?,
  trace_id?, approval_id?, scheduled_at?, metadata? }`.
- **produces** `x_published` - `{ artifact_id, platform = "x", status = "preview", post_uri = nil,
  source_ref, dedup_key?, trace_id?, approval_id?, ... }` for valid preview requests.
- **payload boundary** body/content fields (`tweet`, `body`, `text`, `message`, `media_bytes`,
  provider raw responses) and sensitive fields (`token`, `bearer`, `oauth`, `secret`,
  `credential`, authorization-like names) are rejected fail-closed.
- **posture** shadow-first: this package posts nothing. A real X write must be injected by a
  host-pinned egress skill such as `FKST_SKILL_PUBLISH_X` plus the host write switch.

Invalid requests are skipped with a greppable log and never masquerade as successful publishes.
`core.preview_receipt(payload, "skipped")` exists as a safe shape helper for hosts/tests that need
an explicit skipped receipt, but the department does not raise it for invalid requests.

⟦AI:FKST⟧
