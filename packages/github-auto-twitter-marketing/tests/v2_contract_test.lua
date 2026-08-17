local core = require("core")
local marketing_content = require("contract.marketing_content")
local t = fkst.test

local account = "test_primary"
local logical_label = "auto-x-test-primary"
local effective_label = "auto-x-test-primary-example-fkst"
local creator = "test-owner"
local bot_login = "fkst-test-bot"
local _, digest = marketing_content.render({
  project = "chronoai",
  account = account,
  work_label = logical_label,
  week = "2026-W33",
  content_id = "chronoai-w33-1",
  content_revision = 1,
  proposal_id = "proposal-w33",
  proposal_revision = 2,
  approval_id = "proposal-w33@2",
  content_status = "approved",
  tweet_text = "A reviewed test account post.",
})

local function source_ref(number)
  local ref = "owner/repo#issue/" .. tostring(number or 42)
  return { kind = "external", ref = ref, reference = ref }
end

local function issue(overrides)
  local payload = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    state = "OPEN",
    labels = { effective_label },
    assignees = { creator },
    updated_at = "2026-08-17T00:00:00Z",
    source_ref = source_ref(),
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

local function route_options(body, overrides)
  local options = {
    issue_body = body,
    issue_labels = { effective_label },
    issue_assignees = { creator },
    issue_author_login = bot_login,
    trusted_content_author_login = bot_login,
    effective_work_label = effective_label,
    logical_work_label = logical_label,
    session_creator = creator,
    expected_account = account,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return options
end

local function weekly_body(overrides)
  local body = assert(marketing_content.render({
    project = "chronoai",
    account = account,
    work_label = logical_label,
    week = "2026-W33",
    content_id = "chronoai-w33-1",
    content_revision = 1,
    proposal_id = "proposal-w33",
    proposal_revision = 2,
    approval_id = "proposal-w33@2",
    content_status = "approved",
    tweet_text = "A reviewed test account post.",
  }))
  if type(overrides) ~= "table" then
    return body
  end
  local lines = {}
  local seen = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    local key = line:match("^([%w-]+):")
    if key ~= nil and overrides[key] ~= nil then
      seen[key] = true
      if overrides[key] ~= false then
        lines[#lines + 1] = key .. ": " .. tostring(overrides[key])
      end
    else
      lines[#lines + 1] = line
    end
  end
  for key, value in pairs(overrides) do
    if not seen[key] and value ~= false then
      table.insert(lines, 1, key .. ": " .. tostring(value))
    end
  end
  return table.concat(lines, "\n")
end

local function schedule_body(overrides)
  local fields = {
    contract = "auto-twitter-marketing.schedule-publish.v2",
    type = "schedule-publish",
    project = "chronoai",
    account = account,
    ["work-label"] = logical_label,
    week = "2026-W33",
    ["content-ref"] = "#124",
    ["content-digest"] = digest,
    ["approval-id"] = "proposal-w33@2",
    mode = "live",
    ["scheduled-at"] = "2026-08-17T00:00:00Z",
  }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  local order = {
    "contract", "type", "project", "account", "work-label", "week",
    "content-ref", "content-digest", "approval-id", "mode", "scheduled-at",
  }
  local lines = {}
  for _, key in ipairs(order) do
    if fields[key] ~= false then
      lines[#lines + 1] = key .. ": " .. tostring(fields[key])
    end
  end
  return table.concat(lines, "\n")
end

return {
  test_weekly_content_v2_requires_session_route_account_and_single_creator_assignee = function()
    local item = core.classify_issue(issue(), route_options(weekly_body()))

    t.eq(item.account, account)
    t.eq(item.work_label, logical_label)
    t.eq(item.effective_work_label, effective_label)
    t.eq(item.content_id, "chronoai-w33-1")
    t.eq(item.content_revision, 1)
    t.eq(item.proposal_id, "proposal-w33")
    t.eq(item.proposal_revision, 2)
    t.eq(item.approval_id, "proposal-w33@2")
    t.eq(item.content_digest, digest)

    local cases = {
      { overrides = { issue_labels = { logical_label } }, why = "missing session work label" },
      { overrides = { issue_assignees = {} }, why = "session creator must be sole assignee" },
      { overrides = { issue_assignees = { creator, "another" } }, why = "session creator must be sole assignee" },
      { overrides = { issue_assignees = { "another" } }, why = "session creator must be sole assignee" },
      { overrides = { issue_author_login = creator }, why = "weekly content author is not trusted bot" },
      { body = weekly_body({ account = "test_secondary" }), why = "account does not match session" },
      { body = weekly_body({ ["work-label"] = "auto-x-other" }), why = "work label does not match session" },
    }
    for _, case in ipairs(cases) do
      local _, why = core.classify_issue(issue(), route_options(case.body or weekly_body(), case.overrides))
      t.eq(why, case.why)
    end
  end,

  test_weekly_content_v2_rejects_missing_or_invalid_approval_contract = function()
    local cases = {
      { field = "contract", value = "auto-twitter-marketing.weekly-content.v1", why = "unsupported weekly content contract" },
      { field = "account", value = false, why = "missing account" },
      { field = "work-label", value = false, why = "missing work label field" },
      { field = "content-id", value = false, why = "missing content id" },
      { field = "content-revision", value = "0", why = "invalid content revision" },
      { field = "proposal-id", value = false, why = "missing proposal id" },
      { field = "proposal-revision", value = "x", why = "invalid proposal revision" },
      { field = "approval-id", value = "old-approval", why = "approval does not match proposal revision" },
      { field = "content-status", value = "superseded", why = "content is not approved" },
      { field = "content-digest", value = "abc", why = "invalid content digest" },
    }
    for _, case in ipairs(cases) do
      local _, why = core.classify_issue(issue(), route_options(weekly_body({ [case.field] = case.value })))
      t.eq(why, case.why)
    end
  end,

  test_schedule_v2_requires_content_approval_and_emits_account_scoped_request = function()
    local item = core.classify_issue(issue(), route_options(schedule_body()))
    local decision = core.schedule_decision(item, core.parse_iso8601_seconds("2026-08-17T00:00:00Z"))
    local request = core.x_publish_request(item, {
      nyxid_x_service = "api-twitter-test-primary-media",
      live_write_enabled = true,
      expected_username = account,
    }, decision)

    t.eq(item.content_ref, "#124")
    t.eq(request.schema, "x-publisher.publish-request.v2")
    t.eq(request.account, account)
    t.eq(request.work_label, logical_label)
    t.eq(request.content_ref, "#124")
    t.eq(request.content_digest, digest)
    t.eq(request.schedule_digest, item.schedule_digest)
    t.is_true(request.schedule_digest:match("^sha256:[0-9a-f]+$") ~= nil)
    t.eq(request.approval_id, "proposal-w33@2")
    t.is_true(request.artifact_id:find("/test_primary/", 1, true) ~= nil)
    t.is_true(request.dedup_key:find("/test_primary/", 1, true) ~= nil)
    t.is_true(core.schedule_once_key(item, decision):find("/test_primary/", 1, true) ~= nil)
  end,

  test_live_schedule_request_never_downgrades_to_shadow_when_provider_config_is_missing = function()
    local item = core.classify_issue(issue(), route_options(schedule_body()))
    local decision = core.schedule_decision(item, core.parse_iso8601_seconds("2026-08-17T00:00:00Z"))
    local request = core.x_publish_request(item, {}, decision)

    t.eq(item.mode, "live")
    t.eq(request.channel, "live")
    t.eq(request.metadata.variant, "live")
  end,

  test_schedule_v2_rejects_legacy_or_cross_account_contract = function()
    local cases = {
      { body = schedule_body({ contract = "auto-twitter-marketing.schedule-publish.v1" }), why = "unsupported schedule contract" },
      { body = schedule_body({ ["content-ref"] = false }), why = "missing schedule content fields" },
      { body = schedule_body({ ["content-digest"] = "sha256:bad" }), why = "invalid content digest" },
      { body = schedule_body({ ["approval-id"] = false }), why = "missing schedule content fields" },
      { body = schedule_body({ account = "test_secondary" }), why = "account does not match session" },
    }
    for _, case in ipairs(cases) do
      local _, why = core.classify_issue(issue(), route_options(case.body))
      t.eq(why, case.why)
    end
  end,

  test_v2_dedup_is_stable_across_bot_comments_and_excludes_session_id = function()
    local first = core.classify_issue(issue({ updated_at = "2026-08-17T00:00:00Z" }), route_options(schedule_body()))
    local replay = core.classify_issue(issue({
      updated_at = "2026-08-17T01:00:00Z",
      session_id = "replacement-session",
    }), route_options(schedule_body()))

    t.eq(first.dedup_key, replay.dedup_key)
    t.is_true(first.dedup_key:find("replacement-session", 1, true) == nil)
  end,
}
