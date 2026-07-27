# GitHub Auto Twitter Marketing

`github-auto-twitter-marketing` is a hosted-facing composed package that maps
GitHub issue facts into the marketing seams already exposed by this repository.

It keeps reliable payloads pointer-only:

- strategy issues raise `strategy_imported`;
- weekly-content issues raise `weekly_content_imported`;
- schedule-publish issues raise `x-publisher.x_publish_request`;
- each handled issue raises a `github-proxy.github_issue_comment_request` status
  receipt.

The package recognizes the `auto-twitter-marketing` work label and accepts small
control fields either from a trusted `payload.controls` map or from simple
`key: value` lines in the issue body. Strategy text, weekly content, and final X
post content remain behind `source_ref`.

Live X writes are not authorized by this package. `mode: live` is only allowed
to become a live channel after a host/egress layer supplies both an explicit live
write switch and a NyxID X service slug. Without that gate, the package emits a
preview/shadow request only.

## Issue formats

Strategy import:

```md
type: strategy
project: chronoai
account: main
```

Weekly content import:

````md
type: weekly-content
project: chronoai
week: 2026-W31
strategy-ref: #41

tweet-text:
```
FKST live publish verification for hzz780 via NyxID. Test post.
```
````

Schedule publish:

```md
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #42
mode: live
scheduled-at: 2026-07-25T09:00:00Z
```

`calendar-ref` becomes the downstream `content_ref`. For `#42`, `x-publisher` resolves it relative
to the schedule issue repo and reads the weekly content issue through the GitHub adapter.

## Live env contract

Live mode requires host env:

```sh
X_PUBLISH_WRITE=1
NYXID_X_SERVICE_SLUG=api-twitter-2-media
X_PUBLISH_EXPECTED_USERNAME=hzz780
```

The username preflight is a safety guard: if NyxID resolves to any account other than `hzz780`, the
publish request is blocked and no tweet is created.
