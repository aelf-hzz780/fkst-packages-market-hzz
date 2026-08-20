local marketing_content = require("contract.marketing_content")
local marketing_schedule = require("contract.marketing_schedule")
local testing = require("testkit.testing")
local t = fkst.test

local repo = "owner/repo"
local account = "test_primary"
local logical_label = "auto-x-test-primary"
local effective_label = "auto-x-test-primary-example-fkst"
local creator = "test-owner"
local bot_login = "fkst-test-bot"
local scheduled_at = "2026-08-17T00:00:00Z"

local function source_ref(number)
  local ref = repo .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function approved_content(overrides)
  local record = {
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
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  local body, digest = marketing_content.render(record)
  return body, digest
end

local function schedule_body(digest, overrides)
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
    ["scheduled-at"] = scheduled_at,
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
    lines[#lines + 1] = key .. ": " .. tostring(fields[key])
  end
  return table.concat(lines, "\n")
end

local function issue(number, body, overrides)
  local value = {
    number = number,
    body = body,
    state = "OPEN",
    labels = { effective_label },
    assignees = { creator },
    comments = {},
    source_ref = source_ref(number),
  }
  for key, child in pairs(overrides or {}) do
    value[key] = child
  end
  return value
end

local function event(body, overrides)
  local value = {
    queue = "github-proxy.github_issue_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = 125,
      state = "OPEN",
      labels = { effective_label },
      assignees = { creator },
      updated_at = "2026-08-17T00:01:00Z",
      source_ref = source_ref(125),
      body = body,
    },
  }
  for key, child in pairs(overrides or {}) do
    value.payload[key] = child
  end
  return value
end

local function department(schedule, content, overrides)
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  local github = { reads = {} }
  function github.read_issue(ref, options)
    github.reads[#github.reads + 1] = { ref = ref.ref, options = options }
    if ref.ref == source_ref(125).ref then
      if overrides ~= nil and overrides.cached_schedule ~= nil
          and options.force_fresh ~= true then
        return overrides.cached_schedule
      end
      return schedule
    end
    if ref.ref == source_ref(124).ref then
      return content
    end
    error("unexpected issue read: " .. tostring(ref.ref), 0)
  end
  return module.make_department({
    github = github,
    session_authority = function()
      return {
        effective_work_label = effective_label,
        logical_work_label = logical_label,
        creator = creator,
        account = account,
      }
    end,
    live_options = function()
      return {
        live_write_enabled = true,
        nyxid_x_service = "api-twitter-test-primary-media",
        expected_username = account,
      }
    end,
    trusted_content_author_login = function()
      return bot_login
    end,
    once = function(_key, fn)
      fn()
      return true
    end,
  }), github
end

local function raised(result, queue)
  local found = {}
  for _, item in ipairs(result.raises or {}) do
    if item.queue == queue then
      found[#found + 1] = item.payload
    end
  end
  return found
end

return {
  test_stale_event_fresh_reads_rerouted_schedule_before_any_side_effect = function()
    local body, digest = approved_content()
    local stale_schedule = issue(125, schedule_body(digest))
    local current_schedule = issue(125, stale_schedule.body, {
      labels = { "another-session" },
      assignees = { "another-owner" },
    })
    local content = issue(124, body, { state = "CLOSED", author_login = bot_login })
    local handler, github = department(current_schedule, content, {
      cached_schedule = stale_schedule,
    })

    local result = testing.run_fake(handler, event(stale_schedule.body))

    t.eq(#github.reads, 1)
    t.eq(github.reads[1].ref, source_ref(125).ref)
    t.eq(github.reads[1].options.force_fresh, true)
    t.is_nil(github.reads[1].options.updated_at)
    t.eq(#raised(result, "github-proxy.github_issue_comment_request"), 0)
    t.eq(#raised(result, "x-publisher.x_publish_request"), 0)
  end,

  test_due_schedule_fresh_reads_matching_approved_content_before_v2_publish_request = function()
    local body, digest = approved_content()
    local schedule = issue(125, schedule_body(digest))
    local content = issue(124, body, { state = "CLOSED", author_login = bot_login })
    local handler, github = department(schedule, content)
    local result = testing.run_fake(handler, event(schedule.body))

    local requests = raised(result, "x-publisher.x_publish_request")
    t.eq(#requests, 1)
    t.eq(requests[1].schema, "x-publisher.publish-request.v2")
    t.eq(requests[1].account, account)
    t.eq(requests[1].work_label, logical_label)
    t.eq(requests[1].content_digest, digest)
    t.eq(requests[1].schedule_digest, assert(marketing_schedule.digest(schedule.body)))
    t.eq(requests[1].approval_id, "proposal-w33@2")
    t.eq(#github.reads, 2)
    t.eq(github.reads[2].ref, source_ref(124).ref)
    t.eq(github.reads[2].options.force_fresh, true)
  end,

  test_stale_cross_account_old_approval_tampered_or_superseded_content_never_requests_x = function()
    local original_body, digest = approved_content()
    local cases = {
      {
        name = "stale digest",
        schedule = schedule_body("sha256:" .. string.rep("b", 64)),
        content = issue(124, original_body, { state = "CLOSED", author_login = bot_login }),
      },
      {
        name = "cross account",
        schedule = schedule_body(digest),
        content = issue(124, approved_content({ account = "test_secondary" }), {
          state = "CLOSED", author_login = bot_login,
        }),
      },
      {
        name = "old approval",
        schedule = schedule_body(digest, { ["approval-id"] = "proposal-w33@1" }),
        content = issue(124, original_body, { state = "CLOSED", author_login = bot_login }),
      },
      {
        name = "tampered body",
        schedule = schedule_body(digest),
        content = issue(124, original_body:gsub("reviewed", "unreviewed"), {
          state = "CLOSED", author_login = bot_login,
        }),
      },
      {
        name = "superseded marker",
        schedule = schedule_body(digest),
        content = issue(124, original_body, {
          state = "CLOSED",
          author_login = bot_login,
          comments = {
            {
              author_login = "fkst-test-bot",
              body = '<!-- fkst:auto-twitter:content-superseded:v2 content_digest="' .. digest .. '" -->',
            },
          },
        }),
      },
    }

    for _, case in ipairs(cases) do
      local schedule = issue(125, case.schedule)
      local handler = department(schedule, case.content)
      local result = testing.run_fake(handler, event(schedule.body))
      t.eq(#raised(result, "x-publisher.x_publish_request"), 0)
      local comments = raised(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_true(comments[1].body:find("blocked", 1, true) ~= nil)
    end
  end,

  test_manually_authored_approved_content_never_requests_x = function()
    local body, digest = approved_content()
    local schedule = issue(125, schedule_body(digest))
    local forged = issue(124, body, { state = "CLOSED", author_login = creator })
    local handler = department(schedule, forged)
    local result = testing.run_fake(handler, event(schedule.body))

    t.eq(#raised(result, "x-publisher.x_publish_request"), 0)
    local comments = raised(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("content author is not trusted bot", 1, true) ~= nil)
  end,

  test_routed_schedule_contract_mismatch_comments_blocked_without_x_request = function()
    local _, digest = approved_content()
    local cases = {
      { account = "test_secondary", expected_reason = "account does not match session" },
      { ["work-label"] = "auto-x-test-secondary", expected_reason = "work label does not match session" },
      { contract = "auto-twitter-marketing.schedule-publish.v1", expected_reason = "unsupported schedule contract" },
    }

    for _, case in ipairs(cases) do
      local body = schedule_body(digest, case)
      local schedule = issue(125, body)
      local handler = department(schedule, nil)
      local result = testing.run_fake(handler, event(body))

      t.eq(#raised(result, "x-publisher.x_publish_request"), 0)
      local comments = raised(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_true(comments[1].body:find("schedule publish blocked at ingress", 1, true) ~= nil)
      t.is_true(comments[1].body:find("reason: " .. case.expected_reason, 1, true) ~= nil)
      t.is_true(comments[1].body:find("expected_account: " .. account, 1, true) ~= nil)
      t.is_true(comments[1].body:find("publish_attempted: false", 1, true) ~= nil)
      t.is_nil(comments[1].handoff)
    end
  end,

  test_unrouted_or_wrong_assignee_schedule_remains_owned_by_host = function()
    local _, digest = approved_content()
    local body = schedule_body(digest, { account = "test_secondary" })
    local cases = {
      {
        schedule = issue(125, body, { labels = { "another-session" } }),
        event_overrides = { labels = { "another-session" } },
      },
      {
        schedule = issue(125, body, { assignees = { "another-owner" } }),
        event_overrides = { assignees = { "another-owner" } },
      },
    }

    for _, case in ipairs(cases) do
      local handler = department(case.schedule, nil)
      local result = testing.run_fake(handler, event(body, case.event_overrides))
      t.eq(#raised(result, "github-proxy.github_issue_comment_request"), 0)
      t.eq(#raised(result, "x-publisher.x_publish_request"), 0)
    end
  end,

  test_mismatched_event_source_ref_is_rejected_before_github_read = function()
    local _, digest = approved_content()
    local body = schedule_body(digest)
    local schedule = issue(125, body)
    local handler, github = department(schedule, nil)
    local result = testing.run_fake(handler, event(body, { source_ref = source_ref(124) }))

    t.eq(#github.reads, 0)
    t.eq(#raised(result, "github-proxy.github_issue_comment_request"), 0)
    t.eq(#raised(result, "x-publisher.x_publish_request"), 0)
  end,
}
