local testing = require("testkit.testing")
local t = fkst.test

local repo = "owner/repo"
local issue_number = 62
local scheduled_at = "2026-07-25T09:00:00Z"
local receipt_dedup_key = "auto-twitter-marketing/chronoai/2026-W31/schedule/owner/repo#issue/62/"
  .. "2026-07-25T09-00-00Z/x-publish"
local comment_dedup_key = receipt_dedup_key .. "/status/x-publish-published"

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[copy(key)] = copy(child)
  end
  return out
end

local function source_ref(number)
  local ref = repo .. "#issue/" .. tostring(number or issue_number)
  return { kind = "external", ref = ref, reference = ref }
end

local function one_shot_issue(overrides)
  local issue = {
    number = issue_number,
    source_ref = source_ref(),
    body = table.concat({
      "type: schedule-publish",
      "project: chronoai",
      "week: 2026-W31",
      "calendar-ref: #61",
      "mode: live",
      "scheduled-at: 2026-07-25T09:00:00Z",
    }, "\n"),
    state = "OPEN",
    labels = { "auto-twitter-marketing" },
    comments = {},
    assignees = { "example_owner" },
    author_login = "example_owner",
  }
  for key, value in pairs(overrides or {}) do
    issue[key] = value
  end
  return issue
end

local function ack_event(overrides)
  local ref = source_ref()
  local payload = {
    schema = "github-proxy.comment-written.v1",
    repo = repo,
    target = "issue",
    issue_number = issue_number,
    comment_id = "comment-123",
    request_dedup_key = comment_dedup_key,
    dedup_key = comment_dedup_key .. "/written/comment-123",
    source_ref = ref,
    handoff = {
      schema = "auto-twitter-marketing.one-shot-close.v1",
      kind = "published-one-shot",
      status = "published",
      schedule_type = "one-shot",
      scheduled_at = scheduled_at,
      artifact_id = "auto-twitter-marketing/chronoai/2026-W31/schedule",
      content_ref = "#61",
      channel = "live",
      platform = "x",
      platform_post_id = "1234567890",
      post_uri = "https://x.com/i/web/status/1234567890",
      receipt_dedup_key = receipt_dedup_key,
      comment_dedup_key = comment_dedup_key,
      source_ref = ref,
      trace_id = "trace-one-shot-close",
    },
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return { queue = "github-proxy.github_comment_written", payload = payload, source_ref = payload.source_ref }
end

local function github_port(issue, options)
  local opts = options or {}
  local model = {
    issue = copy(issue),
    reads = {},
    closes = {},
    locks = {},
  }
  local github = { _test_model = model }

  function github.read_issue(ref, read_options)
    table.insert(model.reads, { source_ref = copy(ref), options = copy(read_options) })
    if opts.read_error ~= nil then
      error(opts.read_error, 0)
    end
    return copy(model.issue)
  end

  function github.issue_close(target_repo, target_number, timeout)
    table.insert(model.closes, {
      repo = target_repo,
      issue_number = target_number,
      timeout = timeout,
    })
    if opts.close_error_after_state_change == true then
      model.issue.state = "CLOSED"
      error("simulated lost close response", 0)
    end
    if opts.close_error ~= nil then
      error(opts.close_error, 0)
    end
    model.issue.state = "CLOSED"
    return { stdout = "", stderr = "", exit_code = 0 }
  end

  return github, model
end

local function department(github, write_enabled)
  local old_pipeline = pipeline
  local module = require("departments.one_shot_terminalizer.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    github_write_enabled = function()
      return write_enabled ~= false
    end,
    with_lock = function(_key, fn)
      table.insert(github._test_model.locks, _key)
      return fn()
    end,
  })
end

return {
  test_matching_published_one_shot_ack_closes_schedule_issue_after_fresh_read = function()
    local github, model = github_port(one_shot_issue())
    local result = testing.run_fake(department(github), ack_event())

    t.eq(#result.raises, 0)
    t.eq(#model.reads, 1)
    t.eq(#model.locks, 1)
    t.eq(model.reads[1].source_ref.ref, repo .. "#issue/" .. tostring(issue_number))
    t.eq(model.reads[1].options.force_fresh, true)
    t.eq(#model.closes, 1)
    t.eq(model.closes[1].repo, repo)
    t.eq(model.closes[1].issue_number, issue_number)
    t.eq(model.closes[1].timeout, 30)
  end,

  test_terminalizer_never_closes_recurring_or_non_schedule_current_issue = function()
    for _, body in ipairs({
      "type: recurring-schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #61\ntime: 11:10\ntimezone: UTC",
      "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #61\nrecurrence: every-minutes\ninterval-minutes: 10\nscheduled-at: 2026-07-25T09:00:00Z",
      "type: weekly-content\nproject: chronoai\nweek: 2026-W31",
    }) do
      local github, model = github_port(one_shot_issue({ body = body }))
      testing.run_fake(department(github), ack_event())
      t.eq(#model.closes, 0)
    end
  end,

  test_terminalizer_skips_when_current_issue_changed_after_publish = function()
    for _, overrides in ipairs({
      { labels = { "other" } },
      { body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #61\nmode: live\nscheduled-at: 2026-07-26T09:00:00Z" },
      { body = "type: schedule-publish\nproject: another-project\nweek: 2026-W31\ncalendar-ref: #61\nmode: live\nscheduled-at: 2026-07-25T09:00:00Z" },
      { body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #99\nmode: live\nscheduled-at: 2026-07-25T09:00:00Z" },
      { body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #61\nmode: shadow\nscheduled-at: 2026-07-25T09:00:00Z" },
      { body = "type: schedule-publish\nproject: chronoai\nweek: 2026-W31\ncalendar-ref: #61\nmode: live" },
    }) do
      local github, model = github_port(one_shot_issue(overrides))
      testing.run_fake(department(github), ack_event())
      t.eq(#model.reads, 1)
      t.eq(#model.closes, 0)
    end
  end,

  test_terminalizer_rejects_malformed_or_mismatched_ack_without_read_or_close = function()
    local cases = {
      { schema = "unknown.v1" },
      { target = "pr" },
      { remove = "comment_id" },
      { repo = "other/repo" },
      { issue_number = 99 },
      { request_dedup_key = "wrong/comment-key" },
      { dedup_key = "wrong/ack-key" },
      { source_ref = source_ref(99) },
      { source_ref = { kind = "external", ref = repo .. "#issue/62", reference = repo .. "#issue/99" } },
      { handoff = { schema = "unknown.v1" } },
      { remove_handoff = "trace_id" },
      { remove_handoff = "scheduled_at" },
      { remove_handoff = "content_ref" },
      { remove_handoff = "platform" },
      { remove_handoff = "platform_post_id" },
      { remove_handoff = "post_uri" },
      { handoff_override = { platform = "twitter" } },
      { handoff_override = { platform_post_id = "not-a-post-id" } },
      { handoff_override = { post_uri = "https://x.com/i/web/status/999" } },
    }
    for _, override in ipairs(cases) do
      local github, model = github_port(one_shot_issue())
      local event = ack_event(override)
      if override.remove ~= nil then
        event.payload[override.remove] = nil
      end
      if override.remove_handoff ~= nil then
        event.payload.handoff[override.remove_handoff] = nil
      end
      for key, value in pairs(override.handoff_override or {}) do
        event.payload.handoff[key] = value
      end
      testing.run_fake(department(github), event)
      t.eq(#model.reads, 0)
      t.eq(#model.closes, 0)
    end
  end,

  test_terminalizer_skips_when_github_write_is_disabled = function()
    local github, model = github_port(one_shot_issue())
    testing.run_fake(department(github, false), ack_event())

    t.eq(#model.reads, 0)
    t.eq(#model.closes, 0)
  end,

  test_terminalizer_treats_closed_issue_as_converged = function()
    local github, model = github_port(one_shot_issue({ state = "CLOSED" }))
    testing.run_fake(department(github), ack_event())

    t.eq(#model.reads, 1)
    t.eq(#model.closes, 0)
  end,

  test_terminalizer_propagates_fresh_read_and_close_failures = function()
    local read_github, read_model = github_port(one_shot_issue(), { read_error = "fresh read failed" })
    testing.run_fake_expecting_failure(department(read_github), ack_event())
    t.eq(#read_model.closes, 0)

    local close_github, close_model = github_port(one_shot_issue(), { close_error = "close failed" })
    testing.run_fake_expecting_failure(department(close_github), ack_event())
    t.eq(#close_model.closes, 1)
  end,

  test_terminalizer_converges_when_close_succeeded_but_response_was_lost = function()
    local github, model = github_port(one_shot_issue(), { close_error_after_state_change = true })
    testing.run_fake(department(github), ack_event())

    t.eq(#model.closes, 1)
    t.eq(#model.reads, 2)

    testing.run_fake(department(github), ack_event())
    t.eq(#model.closes, 1)
    t.eq(#model.reads, 3)
  end,
}
