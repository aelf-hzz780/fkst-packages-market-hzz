# Auto Twitter marketing workflow

This document defines the issue-driven contracts for the marketing package set. The host supplies GitHub events through the official `github-proxy` package; this repository supplies only the marketing business behavior.

## Runtime package set

Import the official GitHub adapter separately, then import this repository's
business-only marketing manifest:

```text
ChronoAIProject/fkst-hosted@packages:packages/github-proxy
aelf-hzz780/fkst-packages-market-hzz@dev:manifests/auto-twitter-marketing.json
```

The market manifest expands only to:

```text
aelf-hzz780/fkst-packages-market-hzz@dev:packages/x-publisher
aelf-hzz780/fkst-packages-market-hzz@dev:packages/github-auto-twitter-marketing
aelf-hzz780/fkst-packages-market-hzz@dev:packages/marketing-radar
```

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
4. Enable a user-owned NyxID/X Environment Profile, create a live schedule-publish issue, and verify one real X post.
5. Create a recurring interval issue with two near-term fire times and verify exactly one post per due window.
6. Create a daily recurring issue with a future fire time and verify the next scheduled fire is calculated without publishing early.
7. Create a radar-config plus radar-signal pair and verify generated weekly-content or schedule-publish issue requests.
8. Remove or break required NyxID configuration and verify live X publishing fails closed with a blocked receipt.

⟦AI:FKST⟧
