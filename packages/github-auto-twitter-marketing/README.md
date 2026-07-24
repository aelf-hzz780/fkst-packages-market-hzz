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
