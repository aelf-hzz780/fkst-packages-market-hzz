local content_close = require("content_close")
local marketing_content = require("contract.marketing_content")
local one_shot_close = require("one_shot_close")
local testing = require("testkit.testing")
local t = fkst.test

local repo = "owner/repo"
local account = "test_primary"
local logical_label = "auto-x-test-primary"
local effective_label = "auto-x-test-primary-example-fkst"
local creator = "test-owner"
local digest = "sha256:" .. string.rep("a", 64)

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
  local ref = repo .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function authority()
  return {
    effective_work_label = effective_label,
    logical_work_label = logical_label,
    creator = creator,
    account = account,
  }
end

local function schedule_body(overrides)
  local fields = {
    contract = "auto-twitter-marketing.schedule-publish.v2",
    type = "schedule-publish",
    project = "chronoai",
    account = account,
    ["work-label"] = logical_label,
    week = "2026-W33",
    ["content-ref"] = "#61",
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
    lines[#lines + 1] = key .. ": " .. tostring(fields[key])
  end
  return table.concat(lines, "\n")
end

local function issue(number, body, overrides)
  local value = {
    number = number,
    source_ref = source_ref(number),
    body = body,
    state = "OPEN",
    labels = { effective_label },
    comments = {},
    assignees = { creator },
    author_login = creator,
  }
  for key, child in pairs(overrides or {}) do
    value[key] = child
  end
  return value
end

local function published_receipt()
  return {
    schema = "x-publisher.publish-receipt.v2",
    artifact_id = "auto-twitter-marketing/test_primary/chronoai/2026-W33/schedule",
    status = "published",
    platform = "x",
    platform_post_id = "1234567890",
    post_uri = "https://x.com/i/web/status/1234567890",
    account = account,
    authenticated_account = account,
    work_label = logical_label,
    content_ref = "#61",
    content_digest = digest,
    approval_id = "proposal-w33@2",
    channel = "live",
    dedup_key = "auto-twitter-marketing/test_primary/chronoai/2026-W33/schedule/"
      .. "owner/repo#issue/62/2026-08-17T00-00-00Z/x-publish",
    trace_id = "trace-one-shot-close",
    scheduled_at = "2026-08-17T00:00:00Z",
    metadata = { schedule_type = "one-shot" },
    source_ref = source_ref(62),
  }
end

local function receipt_ack(anchor_content)
  local receipt = published_receipt()
  local anchor_ref = anchor_content and source_ref(61) or nil
  local comment_key = anchor_content
    and assert(one_shot_close.content_anchor_dedup_key(receipt, anchor_ref))
    or (receipt.dedup_key .. "/status/x-publish-published")
  local handoff = assert(one_shot_close.handoff_for_receipt(receipt, comment_key, anchor_ref))
  local ack_ref = anchor_ref or source_ref(62)
  return {
    queue = "github-proxy.github_comment_written",
    payload = {
      schema = "github-proxy.comment-written.v1",
      repo = repo,
      target = "issue",
      issue_number = anchor_content and 61 or 62,
      comment_id = "comment-123",
      request_dedup_key = comment_key,
      dedup_key = comment_key .. "/written/comment-123",
      source_ref = ack_ref,
      handoff = handoff,
    },
  }
end

local function content_body()
  return assert(marketing_content.render({
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
end

local function content_ack()
  local body, content_digest = marketing_content.render({
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
  local request = assert(content_close.comment_request({
    schema = "auto-twitter-marketing.weekly-content-imported.v2",
    artifact_id = "auto-twitter-marketing/test_primary/chronoai/2026-W33/weekly-content/chronoai-w33-1",
    account = account,
    work_label = logical_label,
    content_id = "chronoai-w33-1",
    content_revision = 1,
    content_digest = content_digest,
    approval_id = "proposal-w33@2",
    dedup_key = "auto-twitter-marketing/test_primary/weekly/61/content-import",
    trace_id = "trace-content-close",
    source_ref = source_ref(61),
  }))
  return body, {
    queue = "github-proxy.github_comment_written",
    payload = {
      schema = "github-proxy.comment-written.v1",
      repo = repo,
      target = "issue",
      issue_number = 61,
      comment_id = "comment-456",
      request_dedup_key = request.dedup_key,
      dedup_key = request.dedup_key .. "/written/comment-456",
      source_ref = source_ref(61),
      handoff = request.handoff,
    },
  }
end

local function github_port(current_issue, options)
  local opts = options or {}
  local model = { issue = copy(current_issue), reads = {}, closes = {}, locks = {} }
  local github = { _test_model = model }
  function github.read_issue(ref, read_options)
    model.reads[#model.reads + 1] = { ref = copy(ref), options = copy(read_options) }
    return copy(model.issue)
  end
  function github.issue_close(target_repo, target_number, timeout)
    model.closes[#model.closes + 1] = { repo = target_repo, number = target_number, timeout = timeout }
    model.issue.state = "CLOSED"
    if opts.lose_close_response == true then
      error("simulated lost close response", 0)
    end
    return { exit_code = 0, stdout = "", stderr = "" }
  end
  return github, model
end

local function department(github)
  local old_pipeline = pipeline
  local module = require("departments.one_shot_terminalizer.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    github_write_enabled = function() return true end,
    session_authority = function() return authority() end,
    with_lock = function(key, fn)
      github._test_model.locks[#github._test_model.locks + 1] = key
      return fn()
    end,
  })
end

return {
  test_published_one_shot_ack_fresh_reads_correlated_v2_schedule_and_closes = function()
    local github, model = github_port(issue(62, schedule_body()))
    testing.run_fake(department(github), receipt_ack())
    t.eq(#model.reads, 1)
    t.eq(model.reads[1].options.force_fresh, true)
    t.eq(#model.locks, 1)
    t.eq(#model.closes, 1)
  end,

  test_content_anchored_publish_ack_fresh_reads_schedule_then_closes = function()
    local github, model = github_port(issue(62, schedule_body()))
    testing.run_fake(department(github), receipt_ack(true))
    t.eq(#model.reads, 1)
    t.eq(model.reads[1].ref.ref, repo .. "#issue/62")
    t.eq(#model.locks, 1)
    t.eq(#model.closes, 1)
  end,

  test_optional_sink_content_anchor_ack_drives_schedule_close = function()
    local sink_result = testing.run_fake(
      require("departments.optional_receipt_sink.main"),
      { queue = "x-publisher.x_published", payload = published_receipt() }
    )
    local anchor_request = nil
    for _, raised in ipairs(sink_result.raises) do
      if raised.payload.issue_number == 61 then
        anchor_request = raised.payload
      end
    end
    anchor_request = assert(anchor_request)
    local comment_id = "content-anchor-comment"
    local ack = {
      queue = "github-proxy.github_comment_written",
      payload = {
        schema = "github-proxy.comment-written.v1",
        repo = anchor_request.repo,
        target = "issue",
        issue_number = anchor_request.issue_number,
        comment_id = comment_id,
        request_dedup_key = anchor_request.dedup_key,
        dedup_key = anchor_request.dedup_key .. "/written/" .. comment_id,
        source_ref = anchor_request.source_ref,
        handoff = anchor_request.handoff,
      },
    }
    local github, model = github_port(issue(62, schedule_body()))
    testing.run_fake(department(github), ack)
    t.eq(#model.reads, 1)
    t.eq(model.reads[1].ref.ref, repo .. "#issue/62")
    t.eq(#model.closes, 1)
  end,

  test_weekly_content_import_ack_recomputes_digest_then_closes = function()
    local body, ack = content_ack()
    local github, model = github_port(issue(61, body))
    testing.run_fake(department(github), ack)
    t.eq(#model.reads, 1)
    t.eq(model.reads[1].options.force_fresh, true)
    t.eq(#model.closes, 1)
  end,

  test_terminalizer_blocks_changed_schedule_or_content_without_close = function()
    local body, content_event = content_ack()
    local cases = {
      { current = issue(62, schedule_body({ ["content-digest"] = "sha256:" .. string.rep("b", 64) })), event = receipt_ack() },
      { current = issue(62, schedule_body(), { labels = { "other" } }), event = receipt_ack() },
      { current = issue(61, (body:gsub("reviewed", "unreviewed"))), event = content_event },
      { current = issue(61, body, { assignees = { "test-secondary" } }), event = content_event },
    }
    for _, case in ipairs(cases) do
      local github, model = github_port(case.current)
      testing.run_fake(department(github), case.event)
      t.eq(#model.reads, 1)
      t.eq(#model.closes, 0)
    end
  end,

  test_terminalizer_converges_after_lost_close_response_and_on_replay = function()
    local github, model = github_port(issue(62, schedule_body()), { lose_close_response = true })
    testing.run_fake(department(github), receipt_ack())
    t.eq(#model.reads, 2)
    t.eq(#model.closes, 1)
    testing.run_fake(department(github), receipt_ack())
    t.eq(#model.closes, 1)
  end,
}
