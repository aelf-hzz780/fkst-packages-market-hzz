local core = require("core")
local t = fkst.test

local account = "test_primary"
local logical_label = "auto-x-test-primary"
local effective_label = "auto-x-test-primary-example-fkst"
local creator = "test-owner"
local digest = "sha256:" .. string.rep("a", 64)

local function source_ref(number)
  local ref = "owner/repo#issue/" .. tostring(number or 42)
  return { kind = "external", ref = ref, reference = ref }
end

local function payload(overrides)
  local value = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    labels = { effective_label },
    assignees = { creator },
    source_ref = source_ref(),
  }
  for key, child in pairs(overrides or {}) do
    value[key] = child
  end
  return value
end

local function options(body)
  return {
    session = {
      effective_work_label = effective_label,
      logical_work_label = logical_label,
      creator = creator,
      account = account,
    },
    issue_body = body,
    issue_labels = { effective_label },
    issue_assignees = { creator },
  }
end

local function schedule_body(fields)
  local value = {
    contract = "auto-twitter-marketing.schedule-publish.v2",
    type = "schedule-publish",
    project = "chronoai",
    account = account,
    ["work-label"] = logical_label,
    week = "2026-W33",
    ["content-ref"] = "#124",
    ["content-digest"] = digest,
    ["approval-id"] = "proposal-w33@2",
    mode = "shadow",
    ["scheduled-at"] = "2026-08-17T00:00:00Z",
  }
  for key, child in pairs(fields or {}) do
    value[key] = child
  end
  local order = {
    "contract", "type", "project", "account", "work-label", "week", "content-ref",
    "content-digest", "approval-id", "mode", "recurrence", "interval-minutes",
    "scheduled-at", "time", "timezone",
  }
  local lines = {}
  for _, key in ipairs(order) do
    if value[key] ~= false and value[key] ~= nil then
      lines[#lines + 1] = key .. ": " .. tostring(value[key])
    end
  end
  return table.concat(lines, "\n")
end

local function classify_schedule(fields)
  local body = schedule_body(fields)
  return core.classify_issue(payload(), options(body))
end

return {
  test_control_parser_keeps_only_bounded_nonsensitive_contract_fields = function()
    local fields = core.parse_control_fields(
      "project: chronoai\ncontent-ref: #124\ntoken: secret\nowner: " .. string.rep("x", 513)
    )
    t.eq(fields.project, "chronoai")
    t.eq(fields["content-ref"], "#124")
    t.is_nil(fields.token)
    t.is_nil(fields.owner)
    local fenced = core.parse_control_fields(table.concat({
      "account: test_primary",
      "tweet-text:",
      "````",
      "account: another_account",
      "content-ref: #999",
      "```",
      "````",
    }, "\n"))
    t.eq(fenced.account, "test_primary")
    t.is_nil(fenced["content-ref"])
    t.is_nil(core.work_label())
    t.eq(core.work_label(logical_label), logical_label)
    t.eq(#core.saga_conformance_errors(), 0)
  end,

  test_session_authority_resolves_reverse_map_and_rejects_conflicts = function()
    local authority = core.resolve_session_authority({
      FKST_SESSION_WORK_LABEL = effective_label,
      FKST_SESSION_WORK_LABEL_MAP_JSON = '{"' .. logical_label .. '":"' .. effective_label .. '"}',
      FKST_SESSION_CREATOR = "TEST-OWNER",
      X_PUBLISH_EXPECTED_USERNAME = "@TEST_PRIMARY",
    })
    t.eq(authority.effective_work_label, effective_label)
    t.eq(authority.logical_work_label, logical_label)
    t.eq(authority.creator, creator)
    t.eq(authority.account, account)

    local invalid, why = core.resolve_session_authority({
      FKST_SESSION_WORK_LABEL = effective_label,
      FKST_SESSION_CREATOR = creator,
      X_PUBLISH_EXPECTED_USERNAME = account,
      FKST_X_PUBLISH_EXPECTED_USERNAME = "test_secondary",
    })
    t.is_nil(invalid)
    t.eq(why, "conflicting expected account")

    local invalid_primary, primary_why = core.resolve_session_authority({
      FKST_SESSION_WORK_LABEL = effective_label,
      FKST_SESSION_CREATOR = creator,
      X_PUBLISH_EXPECTED_USERNAME = "not-valid!",
      FKST_X_PUBLISH_EXPECTED_USERNAME = account,
    })
    t.is_nil(invalid_primary)
    t.eq(primary_why, "invalid expected account")
  end,

  test_strategy_v2_is_account_scoped_and_source_pointer_only = function()
    local body = table.concat({
      "type: strategy",
      "project: chronoai",
      "account: " .. account,
      "work-label: " .. logical_label,
    }, "\n")
    local item = core.classify_issue(payload(), options(body))
    local imported = core.strategy_imported(item)
    t.eq(imported.schema, "auto-twitter-marketing.strategy-imported.v2")
    t.eq(imported.account, account)
    t.eq(imported.work_label, logical_label)
    t.is_true(imported.artifact_id:find("/test_primary/", 1, true) ~= nil)
    t.eq(imported.source_ref.ref, "owner/repo#issue/42")
    t.is_nil(imported.body)
  end,

  test_issue_source_ref_must_match_repo_number_and_itself = function()
    local body = table.concat({
      "type: strategy",
      "project: chronoai",
      "account: " .. account,
      "work-label: " .. logical_label,
    }, "\n")
    local derived = assert(core.canonical_issue_source_ref(payload({ source_ref = nil })))
    t.eq(derived.ref, "owner/repo#issue/42")

    for _, invalid in ipairs({
      source_ref(43),
      { kind = "external", ref = source_ref(42).ref, reference = source_ref(43).ref },
      { kind = "internal", ref = source_ref(42).ref, reference = source_ref(42).ref },
    }) do
      local item, why = core.classify_issue(payload({ source_ref = invalid }), options(body))
      t.is_nil(item)
      t.eq(why, "source_ref does not match issue identity")
    end
  end,

  test_one_shot_daily_and_interval_schedule_decisions_are_timezone_safe = function()
    local one_shot = classify_schedule()
    local before = core.schedule_decision(one_shot, core.parse_iso8601_seconds("2026-08-16T23:59:59Z"))
    local due = core.schedule_decision(one_shot, core.parse_iso8601_seconds("2026-08-17T00:00:00Z"))
    t.eq(before.due, false)
    t.eq(due.due, true)

    local daily = classify_schedule({
      type = "recurring-schedule-publish",
      recurrence = "daily",
      ["scheduled-at"] = false,
      time = "11:10",
      timezone = "Asia/Shanghai",
    })
    local daily_due = core.schedule_decision(daily, core.parse_iso8601_seconds("2026-08-17T03:10:00Z"))
    t.eq(daily_due.occurrence_id, "2026-08-17T11:10:00+08:00")

    local interval = classify_schedule({
      type = "recurring-schedule-publish",
      recurrence = "every-minutes",
      ["interval-minutes"] = 10,
    })
    local interval_due = core.schedule_decision(interval, core.parse_iso8601_seconds("2026-08-17T00:14:59Z"))
    t.eq(interval_due.occurrence_id, "2026-08-17T00:10:00+00:00")
  end,

  test_live_gate_requires_write_service_and_matching_expected_account = function()
    local item = classify_schedule({ mode = "live" })
    t.eq(core.live_gate(item, {}), false)
    t.eq(core.live_gate(item, {
      live_write_enabled = true,
      nyxid_x_service = "api-twitter-test-media",
      expected_username = "test_secondary",
    }), false)
    t.eq(core.live_gate(item, {
      live_write_enabled = true,
      nyxid_x_service = "api-twitter-test-media",
      expected_username = account,
    }), true)
  end,

  test_schedule_helpers_fail_closed_on_invalid_time_inputs = function()
    t.eq(core.schedule_decision(nil, 1).reason, "not schedule")
    t.eq(core.schedule_decision({ kind = "schedule-publish", scheduled_at = "bad" }, 1).reason,
      "invalid scheduled-at")
    t.is_nil(core.parse_iso8601_seconds("2026-02-29T00:00:00Z"))
    t.is_true(core.parse_iso8601_seconds("2028-02-29T00:00:00Z") ~= nil)
  end,
}
