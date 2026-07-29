local core = require("core")
local t = fkst.test

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
  }
end

local function issue(overrides)
  local payload = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    title = "Auto Twitter marketing",
    url = "https://github.example/owner/repo/issues/42",
    state = "OPEN",
    labels = { "auto-twitter-marketing" },
    updated_at = "2026-07-24T09:00:00Z",
    source_ref = source_ref(),
    dedup_key = "owner/repo#issue#42@2026-07-24T09:00:00Z",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

return {
  test_parse_control_fields_accepts_issue_body_contract = function()
    local fields = core.parse_control_fields([[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
scheduled-at: 2026-07-25T09:00:00Z
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
]])

    t.eq(fields.type, "schedule-publish")
    t.eq(fields.project, "chronoai")
    t.eq(fields.week, "2026-W31")
    t.eq(fields["calendar-ref"], "#124")
    t.eq(fields.mode, "shadow")
    t.eq(fields["scheduled-at"], "2026-07-25T09:00:00Z")
    t.eq(fields.recurrence, "daily")
    t.eq(fields.time, "11:10")
    t.eq(fields.timezone, "Asia/Shanghai")
  end,

  test_public_helpers_and_control_fields_filter_unsafe_values = function()
    local fields = core.parse_control_fields("project: chronoai\ntoken: secret\napi_key: secret\nowner: " .. string.rep("x", 513))

    t.eq(core.work_label(), "auto-twitter-marketing")
    t.eq(#core.saga_conformance_errors(), 0)
    t.eq(core.has_work_label(nil), false)
    t.eq(fields.project, "chronoai")
    t.is_nil(fields.token)
    t.is_nil(fields.api_key)
    t.is_nil(fields.owner)
  end,

  test_classify_strategy_issue_from_body = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: strategy
project: chronoai
account: main
]],
    })

    t.eq(classified.kind, "strategy")
    t.eq(classified.project, "chronoai")
    t.eq(classified.account, "main")
    t.eq(classified.source_ref.ref, "owner/repo#issue/42")
    t.eq(classified.trace_id, "github:auto-twitter-marketing:owner/repo#issue/42")
  end,

  test_classify_uses_source_ref_reference_and_repo_number_fallback = function()
    local from_reference = core.classify_issue(issue({
      source_ref = {
        kind = "external",
        reference = "owner/repo#issue/44",
        token = "not exported",
      },
    }), {
      issue_body = "type: strategy\nproject: chronoai\naccount: main\n",
    })
    local repo_number_payload = issue()
    repo_number_payload.source_ref = nil
    local from_repo_number = core.classify_issue(repo_number_payload, {
      issue_body = "type: strategy\nproject: chronoai\naccount: main\n",
    })
    local imported = core.strategy_imported(from_reference)

    t.eq(from_reference.source_ref.ref, "owner/repo#issue/44")
    t.eq(from_reference.source_ref.reference, "owner/repo#issue/44")
    t.is_nil(imported.source_ref.token)
    t.eq(from_repo_number.source_ref.ref, "owner/repo#issue/42")
  end,

  test_classify_sanitizes_ids_and_default_recurring_type_alias = function()
    local classified = core.classify_issue(issue({
      controls = {
        type = "daily-schedule-publish",
        project = "///!!!",
        account = string.rep("a", 200),
        week = "2026-W31",
        ["calendar-ref"] = "#124",
        time = "11:10",
        timezone = "UTC",
      },
    }))

    t.eq(classified.kind, "schedule-publish")
    t.eq(classified.project, "unknown")
    t.eq(#classified.account, 180)
    t.eq(classified.recurrence, "daily")
  end,

  test_classify_weekly_content_issue_from_controls = function()
    local classified = core.classify_issue(issue({
      body = nil,
      controls = {
        type = "weekly-content",
        project = "chronoai",
        week = "2026-W31",
        ["strategy-ref"] = "#123",
      },
    }))

    t.eq(classified.kind, "weekly-content")
    t.eq(classified.project, "chronoai")
    t.eq(classified.week, "2026-W31")
    t.eq(classified.strategy_ref, "#123")
    t.eq(classified.source_ref.ref, "owner/repo#issue/42")
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
    _, why = core.classify_issue(issue(), { issue_body = "type: strategy\n" })
    t.eq(why, "missing project")
    _, why = core.classify_issue({
      schema = "github-proxy.v1",
      type = "issue",
      labels = { "auto-twitter-marketing" },
      number = 42,
    }, {
      issue_body = "type: strategy\nproject: chronoai\n",
    })
    t.eq(why, "missing source_ref")
    _, why = core.classify_issue(issue(), { issue_body = "type: weekly-content\nproject: chronoai\n" })
    t.eq(why, "missing week")
    _, why = core.classify_issue(issue(), { issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\n" })
    t.eq(why, "missing schedule fields")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #42\nscheduled-at: not-a-date\n",
    })
    t.eq(why, "invalid scheduled-at")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #42\n",
    })
    t.eq(why, "missing schedule fields")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #42\nrecurrence: hourly\n",
    })
    t.eq(why, "unsupported recurrence")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #42\nrecurrence: daily\ntime: 25:00\ntimezone: UTC\n",
    })
    t.eq(why, "invalid recurring time")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #42\nrecurrence: daily\ntime: 11:10\ntimezone: Mars/Base\n",
    })
    t.eq(why, "invalid recurring timezone")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #42\nrecurrence: every-minutes\nscheduled-at: 2026-07-29T10:50:00Z\n",
    })
    t.eq(why, "missing recurring schedule fields")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #42\nrecurrence: every-minutes\nscheduled-at: 2026-07-29T10:50:00Z\ninterval-minutes: 1.5\n",
    })
    t.eq(why, "invalid interval-minutes")
    _, why = core.classify_issue(issue(), {
      issue_body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #42\nrecurrence: every-minutes\nscheduled-at: 2026-02-29T10:50:00Z\ninterval-minutes: 10\n",
    })
    t.eq(why, "invalid scheduled-at")
  end,

  test_classify_can_use_fetched_issue_body_without_payload_body = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: strategy
project: chronoai
account: main
]],
    })

    t.eq(classified.kind, "strategy")
    t.eq(classified.project, "chronoai")
    t.eq(classified.source_ref.ref, "owner/repo#issue/42")
  end,

  test_classify_requires_work_label = function()
    local classified = core.classify_issue(issue({ labels = { "other" } }), {
      issue_body = "type: strategy\nproject: chronoai\naccount: main\n",
    })
    t.is_nil(classified)
  end,

  test_schedule_publish_builds_pointer_only_x_request = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
scheduled-at: 2026-07-25T09:00:00Z
]],
    })
    local request = core.x_publish_request(classified)

    t.eq(request.artifact_id, "auto-twitter-marketing/chronoai/2026-W31/schedule")
    t.eq(request.platform, "x")
    t.eq(request.channel, "shadow")
    t.eq(request.source_ref.ref, "owner/repo#issue/42")
    t.eq(request.scheduled_at, "2026-07-25T09:00:00Z")
    t.eq(request.metadata.campaign_id, "chronoai")
    t.eq(request.metadata.content_type, "weekly-content")
    t.eq(request.metadata.tag, "calendar:#124")
    t.is_nil(request.body)
    t.is_nil(request.text)
    t.is_nil(request.token)
  end,

  test_one_shot_schedule_waits_until_scheduled_at = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
scheduled-at: 2026-07-25T09:00:00Z
]],
    })

    local before = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-25T08:59:59Z"))
    local at_time = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-25T09:00:00Z"))

    t.eq(before.due, false)
    t.eq(before.reason, "not due")
    t.eq(at_time.due, true)
    t.eq(at_time.occurrence_id, "2026-07-25T09:00:00Z")
  end,

  test_daily_schedule_uses_timezone_local_occurrence = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
]],
    })

    local before = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-28T03:09:59Z"))
    local due = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-28T03:10:00Z"))
    local request = core.x_publish_request(classified, nil, due)

    t.eq(classified.recurrence, "daily")
    t.eq(before.due, false)
    t.eq(due.due, true)
    t.eq(due.scheduled_at, "2026-07-28T11:10:00+08:00")
    t.eq(due.occurrence_id, "2026-07-28T11:10:00+08:00")
    t.eq(request.scheduled_at, "2026-07-28T11:10:00+08:00")
    t.eq(request.metadata.schedule_type, "daily")
    t.eq(request.metadata.occurrence_id, "2026-07-28T11:10:00+08:00")
    t.is_true(request.dedup_key:find("2026-07-28T11-10-00-08-00", 1, true) ~= nil)
  end,

  test_every_minutes_schedule_uses_anchor_and_interval_occurrence = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
recurrence: every-minutes
interval-minutes: 10
scheduled-at: 2026-07-29T10:50:00+08:00
]],
    })

    local before = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-29T10:49:59+08:00"))
    local first = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-29T10:50:00+08:00"))
    local second_window = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-29T11:04:59+08:00"))
    local second = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-29T11:00:00+08:00"))
    local request = core.x_publish_request(classified, nil, second)

    t.eq(classified.recurrence, "every-minutes")
    t.eq(classified.interval_minutes, 10)
    t.eq(before.due, false)
    t.eq(before.scheduled_at, "2026-07-29T10:50:00+08:00")
    t.eq(first.due, true)
    t.eq(first.occurrence_id, "2026-07-29T10:50:00+08:00")
    t.eq(second_window.occurrence_id, "2026-07-29T11:00:00+08:00")
    t.eq(second.occurrence_id, "2026-07-29T11:00:00+08:00")
    t.eq(request.scheduled_at, "2026-07-29T11:00:00+08:00")
    t.eq(request.metadata.schedule_type, "every-minutes")
    t.eq(request.metadata.interval_minutes, 10)
    t.eq(request.metadata.occurrence_id, "2026-07-29T11:00:00+08:00")
  end,

  test_daily_schedule_supports_compact_negative_timezone = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
recurrence: daily
time: 11:10
timezone: -0530
]],
    })

    local before = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-28T16:39:59Z"))
    local due = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-28T16:40:00Z"))

    t.eq(before.due, false)
    t.eq(due.due, true)
    t.eq(due.scheduled_at, "2026-07-28T11:10:00-05:30")
  end,

  test_schedule_decision_handles_invalid_inputs = function()
    t.eq(core.schedule_decision(nil, 1).reason, "not schedule")
    t.eq(core.schedule_decision({ kind = "strategy" }, 1).reason, "not schedule")
    t.eq(core.schedule_decision({ kind = "schedule-publish", scheduled_at = "2026-07-25T09:00:00Z" }, "bad").reason, "invalid now")
    t.eq(core.schedule_decision({ kind = "schedule-publish", scheduled_at = "bad" }, 1).reason, "invalid scheduled-at")
    t.eq(core.schedule_decision({ kind = "schedule-publish", recurrence = "daily", time = "bad", timezone = "UTC" }, 1).reason, "invalid daily time")
    t.eq(core.schedule_decision({ kind = "schedule-publish", recurrence = "daily", time = "11:10", timezone = "Mars/Base" }, 1).reason, "unsupported timezone")
    t.eq(core.schedule_decision({ kind = "schedule-publish", recurrence = "every-minutes", scheduled_at = "bad", interval_minutes = 10 }, 1).reason, "invalid scheduled-at")
    t.eq(core.schedule_decision({ kind = "schedule-publish", recurrence = "every-minutes", scheduled_at = "2026-07-29T10:50:00Z" }, 1).reason, "invalid interval-minutes")
    t.is_nil(core.parse_iso8601_seconds("2026-02-29T00:00:00Z"))
    t.is_true(core.parse_iso8601_seconds("2028-02-29T00:00:00Z") ~= nil)
    t.is_true(core.parse_iso8601_seconds("2026-07-25T09:00Z") ~= nil)
    t.is_nil(core.parse_iso8601_seconds("2201-01-01T00:00:00Z"))
    t.is_nil(core.parse_iso8601_seconds("2026-01-01T00:00:00+24:00"))
  end,

  test_daily_schedule_requires_explicit_timezone = function()
    local classified, why = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
recurrence: daily
time: 11:10
]],
    })

    t.is_nil(classified)
    t.eq(why, "missing recurring schedule fields")
  end,

  test_live_publish_requires_nyxid_service_gate = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: live
scheduled-at: 2026-07-25T09:00:00Z
]],
    })

    t.eq(core.live_gate(classified, {}), false)
    t.eq(core.live_gate(classified, { nyxid_x_service = "x-main" }), false)
    t.eq(core.live_gate(classified, { live_write_enabled = true }), false)
    t.eq(core.live_gate(classified, { nyxid_x_service = "x-main", live_write_enabled = true }), true)
  end,

  test_schedule_keys_truncate_and_request_carries_optional_metadata = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: live
scheduled-at: 2026-07-25T09:00:00Z
locale: en-US
owner: content-owner
]],
    })
    local decision = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-25T09:00:00Z"))
    local request = core.x_publish_request(classified, {
      nyxid_x_service = "x-main",
      live_write_enabled = true,
    }, decision)
    local segment = core.runtime_key_segment(string.rep("unsafe/", 40), 40)

    t.is_true(#segment <= 40)
    t.eq(request.channel, "live")
    t.eq(request.metadata.locale, "en-US")
    t.eq(request.metadata.owner, "content-owner")
    t.is_true(core.schedule_once_key(classified, decision):find("auto%-twitter%-marketing/schedule") ~= nil)
  end,
}
