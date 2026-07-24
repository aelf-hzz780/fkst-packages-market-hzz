# social-metrics

General social-media metrics package - **contract + preview implementation.** A reusable read lane
that any host repo composes via `pkg.queue` to normalize social metric observations without
special-casing each platform's raw payload.

- **consumes** `metrics_request` (on demand) and `metrics_tick` (the cron poll raiser).
- **produces** `social_metric` - `{ platform, post_uri, metric, value, artifact_id?, campaign_id?,
  observed_at?, trace_id? }`.
- **metric names** common names are normalized to `likes`, `replies`, `reposts`, `quotes`,
  `impressions`, `bookmarks`, `profile_clicks`, `url_clicks`, and `engagement`. Unknown metric
  names are conservatively preserved after simple lowercase/underscore normalization.
- **values** are total: missing, non-numeric, or negative values normalize to `0`, never `nil`.
- **posture** shadow-first: this package performs no network reads. A real metrics read must be
  injected by a host-pinned egress skill such as `FKST_SKILL_MEASURE_<PLATFORM>`.

Without a pinned host skill the department emits a zero-value preview metric so downstream
arithmetic remains deterministic.

⟦AI:FKST⟧
