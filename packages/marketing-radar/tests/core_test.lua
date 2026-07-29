local core = require("core")
local t = fkst.test

local function source_ref(issue_number)
  local ref = "owner/repo#issue/" .. tostring(issue_number or 42)
  return {
    kind = "external",
    ref = ref,
    reference = ref,
  }
end

local function issue(overrides)
  local payload = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    title = "Marketing radar",
    url = "https://github.example/owner/repo/issues/42",
    state = "OPEN",
    labels = { "auto-twitter-marketing" },
    updated_at = "2026-07-28T09:00:00Z",
    source_ref = source_ref(42),
    dedup_key = "owner/repo#issue#42@2026-07-28T09:00:00Z",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

return {
  test_parse_control_fields_accepts_radar_issue_contract = function()
    local fields = core.parse_control_fields([[
type: radar-run
project: chronoai
week: 2026-W31
strategy-ref: #24
topic: FKST hosted automation
source-url: https://github.com/OWNER/CONTENT_REPO/issues/24
insight: Local hosted can import issues and schedule X posts.
assignee: github-username
output: weekly-content
time: 11:10
timezone: Asia/Shanghai
mode: shadow
]])

    t.eq(fields.type, "radar-run")
    t.eq(fields.project, "chronoai")
    t.eq(fields.week, "2026-W31")
    t.eq(fields["strategy-ref"], "#24")
    t.eq(fields.topic, "FKST hosted automation")
    t.eq(fields["source-url"], "https://github.com/OWNER/CONTENT_REPO/issues/24")
    t.eq(fields.assignee, "github-username")
  end,

  test_public_helpers_and_control_fields_filter_unsafe_values = function()
    local fields = core.parse_control_fields("project: chronoai\ntoken: secret\nraw_response: secret\ninsight: " .. string.rep("x", 513))
    local empty_fields = core.parse_control_fields("")

    t.eq(core.work_label(), "auto-twitter-marketing")
    t.eq(#core.saga_conformance_errors(), 0)
    t.eq(core.has_work_label(nil), false)
    t.is_nil(empty_fields.project)
    t.eq(fields.project, "chronoai")
    t.is_nil(fields.token)
    t.is_nil(fields["raw-response"])
    t.is_nil(fields.insight)
  end,

  test_classify_radar_config_is_pointer_only = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: radar-config
project: chronoai
account: example_user
cadence: daily
timezone: Asia/Shanghai
]],
    })

    t.eq(classified.kind, "radar-config")
    t.eq(classified.project, "chronoai")
    t.eq(classified.account, "example_user")
    t.eq(classified.source_ref.ref, "owner/repo#issue/42")
    t.eq(classified.trace_id, "github:marketing-radar:owner/repo#issue/42")
    t.is_nil(classified.token)
    t.is_nil(classified.secret)
  end,

  test_classify_uses_source_ref_reference_and_repo_number_fallback = function()
    local from_reference = core.classify_issue(issue({
      source_ref = {
        kind = "external",
        reference = "owner/repo#issue/44",
        token = "not exported",
      },
    }), {
      issue_body = "type: radar-config\nproject: chronoai\n",
    })
    local repo_number_payload = issue()
    repo_number_payload.source_ref = nil
    local from_repo_number = core.classify_issue(repo_number_payload, {
      issue_body = "type: radar-config\nproject: chronoai\n",
    })
    local imported = core.radar_config_imported(from_reference)

    t.eq(from_reference.source_ref.ref, "owner/repo#issue/44")
    t.eq(from_reference.source_ref.reference, "owner/repo#issue/44")
    t.is_nil(imported.source_ref.token)
    t.eq(from_repo_number.source_ref.ref, "owner/repo#issue/42")
  end,

  test_classify_sanitizes_ids_and_truncates_fenced_tweet_text = function()
    local classified = core.classify_issue(issue(), {
      issue_body = "type: radar-run\nproject: ///!!!\nweek: 2026-W31\ntweet-text:\n```\n" .. string.rep("x", 1300) .. "\n```\n",
    })

    t.eq(classified.project, "unknown")
    t.eq(#classified.tweet_text, 1200)
  end,

  test_classify_radar_signal_requires_label_and_project = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: radar-signal
project: chronoai
week: 2026-W31
topic: FKST hosted automation
insight: GitHub issue inputs can drive publishing.
]],
    })
    t.eq(classified.kind, "radar-signal")
    t.eq(classified.project, "chronoai")

    local missing_label = core.classify_issue(issue({ labels = { "other" } }), {
      issue_body = "type: radar-signal\nproject: chronoai\n",
    })
    t.is_nil(missing_label)
  end,

  test_classify_rejects_invalid_issue_contracts = function()
    local _, why

    _, why = core.classify_issue("bad")
    t.eq(why, "invalid payload")
    _, why = core.classify_issue(issue({ schema = "other.v1" }))
    t.eq(why, "unsupported schema")
    _, why = core.classify_issue(issue({ type = "pull_request" }))
    t.eq(why, "not issue")
    _, why = core.classify_issue(issue(), { issue_body = "project: chronoai\n" })
    t.eq(why, "missing type")
    _, why = core.classify_issue(issue(), { issue_body = "type: radar-run\n" })
    t.eq(why, "missing project")
    _, why = core.classify_issue({
      schema = "github-proxy.v1",
      type = "issue",
      labels = { "auto-twitter-marketing" },
      number = 42,
    }, {
      issue_body = "type: radar-config\nproject: chronoai\n",
    })
    t.eq(why, "missing source_ref")
    _, why = core.classify_issue(issue(), { issue_body = "type: radar-run\nproject: chronoai\n" })
    t.eq(why, "missing week")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: radar-run\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #25\nrecurrence: weekly\n",
    })
    t.eq(why, "unsupported recurrence")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: radar-run\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #25\nrecurrence: daily\n",
    })
    t.eq(why, "missing recurring schedule fields")
  end,

  test_radar_run_parses_tweet_text_variants_and_sanitizes_assignee = function()
    local inline = core.classify_issue(issue(), {
      issue_body = "type: radar-run\nproject: chronoai\nweek: 2026-W31\ntweet-text: Inline radar post\nassignee: bad login!\n",
    })
    local quoted = core.classify_issue(issue(), {
      issue_body = "type: radar-run\nproject: chronoai\nweek: 2026-W31\ntweet-text: |\nRadar post from next line\n",
    })
    local unterminated = core.classify_issue(issue(), {
      issue_body = "type: radar-run\nproject: chronoai\nweek: 2026-W31\ntweet-text:\n```\nUnterminated radar post\n",
    })
    local long_field = core.classify_issue(issue({
      controls = {
        type = "radar-signal",
        project = "chronoai",
        insight = string.rep("x", 600),
      },
    }))

    t.eq(inline.tweet_text, "Inline radar post")
    t.is_nil(inline.assignee)
    t.eq(quoted.tweet_text, "Radar post from next line")
    t.eq(unterminated.tweet_text, "Unterminated radar post")
    t.is_nil(long_field.insight)
  end,

  test_radar_run_builds_weekly_content_issue_request = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: radar-run
project: chronoai
week: 2026-W31
strategy-ref: #24
topic: FKST hosted automation
source-url: https://github.com/OWNER/CONTENT_REPO/issues/24
insight: Local hosted can import strategy and weekly content issues.
tweet-text:
```
Radar generated test post for FKST auto-twitter.
```
assignee: github-username
]],
    })
    local request = core.weekly_content_issue_request(classified)

    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.eq(request.repo, "owner/repo")
    t.eq(request.labels[1], "auto-twitter-marketing")
    t.eq(request.assignees[1], "github-username")
    t.is_true(request.body:find("type: weekly-content", 1, true) ~= nil)
    t.is_true(request.body:find("strategy-ref: #24", 1, true) ~= nil)
    t.is_true(request.body:find("Radar generated test post for FKST auto-twitter.", 1, true) ~= nil)
    t.is_true(request.dedup_key:find("/weekly-content", 1, true) ~= nil)
    t.eq(request.source_ref.ref, "owner/repo#issue/42")
  end,

  test_weekly_content_request_uses_fallback_brief_ref_and_default_tweet_text = function()
    local topic_item = core.classify_issue(issue(), {
      issue_body = [[
type: radar-run
project: chronoai
week: 2026-W31
topic: FKST hosted automation
]],
    })
    local default_item = core.classify_issue(issue(), {
      issue_body = [[
type: radar-run
project: chronoai
week: 2026-W31
]],
    })
    local insight_item = core.classify_issue(issue(), {
      issue_body = [[
type: radar-run
project: chronoai
week: 2026-W31
insight: Insight fallback post.
]],
    })
    topic_item.issue_number = nil
    local topic_request = core.weekly_content_issue_request(topic_item)
    local default_request = core.weekly_content_issue_request(default_item)
    local insight_request = core.weekly_content_issue_request(insight_item)

    t.is_true(topic_request.body:find("radar-brief-ref: owner/repo#issue/42", 1, true) ~= nil)
    t.is_true(topic_request.body:find("Radar brief: FKST hosted automation", 1, true) ~= nil)
    t.is_true(default_request.body:find("Radar generated weekly content for chronoai 2026-W31.", 1, true) ~= nil)
    t.is_true(insight_request.body:find("Insight fallback post.", 1, true) ~= nil)
    t.eq(#topic_request.assignees, 0)
  end,

  test_issue_request_builders_truncate_large_generated_bodies_and_keys = function()
    local item = {
      project = string.rep("p", 200),
      week = "2026-W31",
      calendar_ref = "#25",
      mode = "shadow",
      recurrence = "daily",
      time = "11:10",
      timezone = "UTC",
      repo = "owner/repo",
      issue_number = 42,
      source_ref = source_ref(42),
    }
    local weekly_request = core.weekly_content_issue_request({
      project = string.rep("p", 12000),
      week = "2026-W31",
      repo = "owner/repo",
      source_ref = source_ref(42),
    })
    local schedule_request = core.schedule_issue_request(item)

    t.is_true(#weekly_request.body > 11000)
    t.is_true(weekly_request.body:find("truncated by marketing-radar issue body guard", 1, true) ~= nil)
    t.is_true(schedule_request.dedup_key:find("marketing%-radar/") ~= nil)
    t.is_true(#schedule_request.dedup_key < 420)
  end,

  test_radar_run_builds_schedule_issue_request_when_calendar_ref_is_known = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: radar-run
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
assignee: github-username
]],
    })
    local request = core.schedule_issue_request(classified)

    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.is_true(request.body:find("type: schedule-publish", 1, true) ~= nil)
    t.is_true(request.body:find("calendar-ref: #25", 1, true) ~= nil)
    t.is_true(request.body:find("mode: live", 1, true) ~= nil)
    t.is_true(request.body:find("time: 11:10", 1, true) ~= nil)
    t.eq(request.assignees[1], "github-username")
  end,
}
