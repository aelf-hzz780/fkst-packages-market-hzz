local core = require("core")
local testing = require("testkit.testing")
local t = fkst.test

local repo = "owner/repo"

local function session()
  return {
    effective_work_label = "host-test-primary",
    logical_work_label = "auto-x-test-primary",
    creator = "test-operator",
    account = "test_primary",
  }
end

local function source_ref(number)
  local ref = repo .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function signal_issue(number, week, topic)
  return {
    number = number,
    body = table.concat({
      "contract: marketing-radar.radar-signal.v2",
      "type: radar-signal",
      "project: chronoai",
      "account: test_primary",
      "work-label: auto-x-test-primary",
      "week: " .. tostring(week or "2026-W33"),
      "action: add",
      "topic: " .. tostring(topic or "publishing-gap"),
      "source-url: https://github.example/owner/repo/issues/" .. tostring(number),
      "insight: Use signal " .. tostring(number) .. " as cited drafting evidence.",
    }, "\n"),
    state = "OPEN",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "test-operator",
    comments = {},
    source_ref = source_ref(number),
  }
end

local function event(issue)
  return {
    queue = "github-proxy.github_issue_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue.number,
      labels = issue.labels,
      assignees = issue.assignees,
      source_ref = source_ref(issue.number),
    },
    source_ref = source_ref(issue.number),
  }
end

local function row(issue, overrides)
  local values = overrides or {}
  return {
    number = issue.number,
    body = values.body or issue.body,
    state = values.state or issue.state,
    labels = values.labels or issue.labels,
    assignees = values.assignees or issue.assignees,
    author = { login = values.author_login or issue.author_login },
  }
end

local function rows_for(issues, state, catalog_overrides)
  local numbers = {}
  for number, _ in pairs(issues) do numbers[#numbers + 1] = number end
  table.sort(numbers)
  local rows = {}
  for _, number in ipairs(numbers) do
    local issue = issues[number]
    local catalog_row = row(issue, catalog_overrides and catalog_overrides[number])
    if state == "all" or tostring(catalog_row.state):upper() == "OPEN" then
      rows[#rows + 1] = catalog_row
    end
  end
  return rows
end

local function github_port(issues, catalog_overrides)
  local github = {}
  function github.read_issue(ref, options)
    local issue = issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    if issue ~= nil and issue.author_login == "fkst-test-bot" then
      t.eq(options and options.force_fresh, true)
    end
    return issue
  end
  function github.api_paginate_slurp(path, _timeout)
    local state = tostring(path):find("state=all", 1, true) and "all" or "open"
    return rows_for(issues, state, catalog_overrides)
  end
  return github
end

local function successful_draft(signals, revision)
  local evidence_refs = {}
  for _, signal in ipairs(signals) do
    evidence_refs[#evidence_refs + 1] = signal.source_ref.ref
  end
  return {
    revision = revision,
    action = signals[1].action,
    target_ref = signals[1].target_ref,
    evidence_refs = evidence_refs,
    tweet_text = "FKST workflows turn reviewed signals into auditable weekly updates.",
  }
end

local function review_issue(number, signals, state, terminal)
  local proposal = assert(core.build_proposal(
    signals, session(), successful_draft(signals, 1)))
  local request = assert(core.weekly_plan_change_issue_request(proposal, session(), 1))
  local comments = {}
  if terminal then
    comments[1] = {
      id = 9000 + number,
      author_login = "test-operator",
      body = "/marketing approve " .. proposal.proposal_id .. "@1 "
        .. proposal.proposal_digest,
    }
  end
  return {
    number = number,
    body = request.body .. "\n\n<!-- fkst:github-proxy:issue-create:"
      .. request.dedup_key .. " -->",
    state = state,
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "fkst-test-bot",
    comments = comments,
    source_ref = source_ref(number),
  }, proposal, request
end

local function department(github, draft_generator)
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    session_authority = session,
    review_options = function()
      return {
        bot_login = "fkst-test-bot",
        authorized_reviewers = { "test-operator" },
      }
    end,
    signal_author_logins = function() return { "test-operator" } end,
    draft_generator = draft_generator or successful_draft,
  })
end

local function raises_for(result, queue)
  local values = {}
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue or raised.queue == "marketing-radar." .. queue then
      values[#values + 1] = raised.payload
    end
  end
  return values
end

local function assert_zero_create(result)
  t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
end

local function assert_awaiting_review(result, issue_number)
  local found = false
  for _, comment in ipairs(raises_for(result, "github-proxy.github_issue_comment_request")) do
    t.is_nil(tostring(comment.body):find("needs-triage", 1, true))
    found = found or comment.issue_number == issue_number
      and tostring(comment.body):find("awaiting-review", 1, true) ~= nil
  end
  t.is_true(found)
end

local function assert_weekly_plan_change_create(request)
  local proposal, why = core.parse_proposal(request.body)
  t.is_nil(why)
  t.is_true(proposal ~= nil)
  local fields, fields_why = core.parse_control_fields(request.body)
  t.is_nil(fields_why)
  t.eq(fields.type, "weekly-plan-change")
  t.is_true(fields.type ~= "weekly-content")
  t.is_true(fields.type ~= "schedule-publish")
  return proposal
end

return {
  test_open_canonical_proposal_created_during_draft_suppresses_duplicate_create = function()
    local source = signal_issue(301)
    local issues = { [source.number] = source }
    local drafts = 0
    local result = testing.run_fake(department(github_port(issues), function(signals, revision)
      drafts = drafts + 1
      issues[701] = review_issue(701, signals, "OPEN", false)
      return successful_draft(signals, revision)
    end), event(source))

    t.eq(drafts, 1)
    assert_zero_create(result)
    assert_awaiting_review(result, source.number)
  end,

  test_closed_terminal_proposal_created_during_draft_suppresses_duplicate_create = function()
    local source = signal_issue(302)
    local issues = { [source.number] = source }
    local drafts = 0
    local result = testing.run_fake(department(github_port(issues), function(signals, revision)
      drafts = drafts + 1
      issues[702] = review_issue(702, signals, "CLOSED", true)
      return successful_draft(signals, revision)
    end), event(source))

    t.eq(drafts, 1)
    assert_zero_create(result)
    assert_awaiting_review(result, source.number)
  end,

  test_stale_open_catalog_with_fresh_closed_terminal_suppresses_duplicate_create = function()
    local source = signal_issue(303)
    local issues = { [source.number] = source }
    local catalog_overrides = { [703] = { state = "OPEN" } }
    local result = testing.run_fake(department(
      github_port(issues, catalog_overrides), function(signals, revision)
        issues[703] = review_issue(703, signals, "CLOSED", true)
        return successful_draft(signals, revision)
      end
    ), event(source))

    assert_zero_create(result)
    assert_awaiting_review(result, source.number)
  end,

  test_stateful_coo_signal_sequence_materializes_exactly_two_review_proposals = function()
    local issues = {
      [116] = signal_issue(116, "2026-W33", "publishing-gap"),
      [117] = signal_issue(117, "2026-W33", "publishing-gap"),
      [118] = signal_issue(118, "2026-W33", "publishing-gap"),
      [124] = signal_issue(124, "2026-W34", "content-supply-gap"),
    }
    local github = github_port(issues)
    local graph = department(github, function(signals, revision)
      return successful_draft(signals, revision)
    end)
    local next_review_number = 800
    local materialized_by_dedup = {}
    local materialized = {}
    local total_creates = 0

    local function run(number, should_create)
      local result = testing.run_fake(graph, event(issues[number]))
      local creates = raises_for(result, "github-proxy.github_issue_create_request")
      t.eq(#creates, should_create and 1 or 0)
      total_creates = total_creates + #creates
      for _, request in ipairs(creates) do
        local proposal = assert_weekly_plan_change_create(request)
        t.is_nil(materialized_by_dedup[request.dedup_key])
        next_review_number = next_review_number + 1
        local review = {
          number = next_review_number,
          body = request.body .. "\n\n<!-- fkst:github-proxy:issue-create:"
            .. request.dedup_key .. " -->",
          state = "OPEN",
          labels = { "host-test-primary" },
          assignees = { "test-operator" },
          author_login = "fkst-test-bot",
          comments = {},
          source_ref = source_ref(next_review_number),
        }
        issues[next_review_number] = review
        materialized_by_dedup[request.dedup_key] = next_review_number
        materialized[#materialized + 1] = proposal
      end
      if not should_create then assert_awaiting_review(result, number) end
    end

    run(116, true)
    run(117, false)
    run(118, false)
    run(124, true)
    for _, number in ipairs({ 116, 117, 118, 124 }) do run(number, false) end

    t.eq(total_creates, 2)
    t.eq(#materialized, 2)
    local by_week = {}
    for _, proposal in ipairs(materialized) do
      t.is_nil(by_week[proposal.week])
      by_week[proposal.week] = proposal
    end
    t.eq(#assert(by_week["2026-W33"]).signals, 3)
    t.eq(#assert(by_week["2026-W34"]).signals, 1)
  end,
}
