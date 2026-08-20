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

local function signal_issue(number, project)
  return {
    number = number,
    body = table.concat({
      "contract: marketing-radar.radar-signal.v2",
      "type: radar-signal",
      "project: " .. tostring(project or "chronoai"),
      "account: test_primary",
      "work-label: auto-x-test-primary",
      "week: 2026-W33",
      "action: add",
      "topic: FKST automation",
      "insight: Use cited release evidence.",
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

local function classified(issue)
  return assert(core.classify_issue(event(issue).payload, {
    session = session(),
    issue_body = issue.body,
    issue_labels = issue.labels,
    issue_assignees = issue.assignees,
  }))
end

local function proposal(signal)
  return assert(core.build_proposal({ signal }, session(), {
    action = "add",
    evidence_refs = { signal.source_ref.ref },
    tweet_text = "A reviewed and bounded FKST automation update.",
  }))
end

local function row(issue)
  return {
    number = issue.number,
    body = issue.body,
    state = issue.state,
    labels = issue.labels,
    assignees = issue.assignees,
    author = { login = issue.author_login },
  }
end

local function review_command(command, proposal, reason, revision)
  local body = "/marketing " .. command .. " " .. proposal.proposal_id .. "@"
    .. tostring(revision ~= nil and revision or proposal.revision) .. " " .. proposal.proposal_digest
  if reason ~= nil and reason ~= "" then
    body = body .. " " .. reason
  end
  return body
end

local function department(github, generate_draft)
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    session_authority = session,
    review_options = function()
      return { bot_login = "fkst-test-bot", authorized_reviewers = { "test-operator" } }
    end,
    signal_author_logins = function() return { "test-operator" } end,
    draft_generator = generate_draft or function(signals, revision)
      local evidence_refs = {}
      for _, signal in ipairs(signals) do
        evidence_refs[#evidence_refs + 1] = signal.source_ref.ref
      end
      return {
        revision = revision,
        action = signals[1].action,
        evidence_refs = evidence_refs,
        tweet_text = "A reviewed and bounded FKST automation update.",
      }
    end,
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

local function add_terminal_status(review, terminal_proposal, status, overrides)
  local options = overrides or {}
  local decision = assert(core.review_decision(review, {
    bot_login = "fkst-test-bot",
    authorized_reviewers = { "test-operator" },
  }))
  local item = {
    account = "test_primary",
    content_digest = terminal_proposal.content_digest,
    proposal_id = terminal_proposal.proposal_id,
    proposal_revision = terminal_proposal.revision,
    group_key = terminal_proposal.group_key,
    source_ref = review.source_ref,
    repo = repo,
    issue_number = review.number,
    session_work_label = "host-test-primary",
    logical_work_label = "auto-x-test-primary",
    session_creator = "test-operator",
    trace_id = "github:marketing-radar:" .. review.source_ref.ref,
  }
  local request = core.status_comment(
    item, status, core.close_handoff(item, "weekly-plan-change", decision))
  local marker_key = options.marker_key or request.dedup_key
  local suffix = options.hosted_suffix or ""
  review.comments[#review.comments + 1] = {
    id = 502,
    author_login = options.author_login or "fkst-test-bot",
    body = request.body .. "\n\n<!-- fkst:github-proxy:comment:"
      .. marker_key .. " -->" .. suffix,
  }
  return request
end

return {
  test_foreign_create_marker_cannot_hide_current_group_cycle = function()
    local source = signal_issue(201)
    local current_proposal = proposal(classified(source))
    local foreign_proposal = proposal(classified(signal_issue(202, "another-project")))
    local foreign_request = core.weekly_plan_change_issue_request(foreign_proposal, session(), 1)
    local old = {
      number = 203,
      body = assert(core.render_proposal(current_proposal))
        .. "\n\n<!-- fkst:github-proxy:issue-create:" .. foreign_request.dedup_key .. " -->",
      state = "CLOSED",
      labels = { "other-session" },
      assignees = { "other-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(203),
    }
    local issues = { [source.number] = source, [old.number] = old }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(old) } or { row(source) }
    end

    local result = testing.run_fake(department(github), event(source))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find(
      "proposal-create-provenance-group-conflict", 1, true) ~= nil)
  end,

  test_closed_terminal_proposal_repairs_open_signal_without_new_cycle = function()
    local source = signal_issue(204)
    local terminal_proposal = proposal(classified(source))
    local request = core.weekly_plan_change_issue_request(terminal_proposal, session(), 1)
    local review = {
      number = 205,
      body = request.body
        .. "\n\n<!-- fkst:github-proxy:issue-create:" .. request.dedup_key .. " -->",
      state = "CLOSED",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {{
        id = 501,
        author_login = "test-operator",
        body = review_command("reject", terminal_proposal, "Evidence is insufficient."),
      }},
      source_ref = source_ref(205),
    }
    add_terminal_status(review, terminal_proposal, "rejected: Evidence is insufficient.")
    local issues = { [source.number] = source, [review.number] = review }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(review) } or { row(source) }
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function()
      drafts = drafts + 1
      return nil, "must-not-run"
    end), event(source))

    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.eq(comments[1].handoff.kind, "radar-signal")
    t.eq(comments[1].handoff.review_command, "reject")
    t.eq(comments[1].handoff.review_comment_id, 501)
  end,

  test_manual_closed_review_without_terminal_status_cannot_retire_signal = function()
    local source = signal_issue(206)
    local terminal_proposal = proposal(classified(source))
    local request = core.weekly_plan_change_issue_request(terminal_proposal, session(), 1)
    local review = {
      number = 207,
      body = request.body
        .. "\n\n<!-- fkst:github-proxy:issue-create:" .. request.dedup_key .. " -->",
      state = "CLOSED",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {{
        id = 503,
        author_login = "test-operator",
        body = review_command("reject", terminal_proposal, "This was closed manually."),
      }},
      source_ref = source_ref(207),
    }
    local issues = { [source.number] = source, [review.number] = review }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(review) } or { row(source) }
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function()
      drafts = drafts + 1
      return nil, "must-not-run"
    end), event(source))

    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_nil(comments[1].handoff)
    t.is_true(comments[1].body:find("terminal-review-status-missing", 1, true) ~= nil)
  end,

  test_closed_approved_proposal_recovers_with_hosted_comment_suffix = function()
    local source = signal_issue(208)
    local terminal_proposal = proposal(classified(source))
    local request = core.weekly_plan_change_issue_request(terminal_proposal, session(), 1)
    local review = {
      number = 209,
      body = request.body
        .. "\n\n<!-- fkst:github-proxy:issue-create:" .. request.dedup_key .. " -->",
      state = "CLOSED",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {{
        id = 504,
        author_login = "test-operator",
        body = review_command("approve", terminal_proposal),
      }},
      source_ref = source_ref(209),
    }
    add_terminal_status(
      review,
      terminal_proposal,
      "approved; immutable weekly-content requested",
      { hosted_suffix = table.concat({
        "\n\nWritten by session: [host-test-primary](https://github.com/owner/repo/issues/208)",
        "\n\n<!-- fkst:debug-stamp:v1 emitter=\"github-proxy.comment\"",
        " target=\"issue:owner/repo#209\" code_version=\"abc123\"",
        " dedup_hash=\"0123456789\" -->\n",
      }) }
    )
    local issues = { [source.number] = source, [review.number] = review }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(review) } or { row(source) }
    end
    local result = testing.run_fake(department(github, function()
      error("terminal recovery must not generate a new draft")
    end), event(source))

    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.eq(comments[1].issue_number, source.number)
    t.eq(comments[1].handoff.review_command, "approve")
    t.eq(comments[1].handoff.review_comment_id, 504)
  end,

  test_terminal_recovery_rejects_wrong_status_marker_or_bot = function()
    local cases = {
      { status = "rejected: wrong terminal outcome" },
      { marker_key = "marketing-radar/foreign-terminal-status" },
      { author_login = "foreign-bot" },
    }
    for index, mutation in ipairs(cases) do
      local source = signal_issue(210 + index * 2)
      local terminal_proposal = proposal(classified(source))
      local request = core.weekly_plan_change_issue_request(terminal_proposal, session(), index)
      local review = {
        number = source.number + 1,
        body = request.body
          .. "\n\n<!-- fkst:github-proxy:issue-create:" .. request.dedup_key .. " -->",
        state = "CLOSED",
        labels = { "host-test-primary" },
        assignees = { "test-operator" },
        author_login = "fkst-test-bot",
        comments = {{
          id = 510 + index,
          author_login = "test-operator",
          body = review_command("approve", terminal_proposal),
        }},
        source_ref = source_ref(source.number + 1),
      }
      add_terminal_status(
        review,
        terminal_proposal,
        mutation.status or "approved; immutable weekly-content requested",
        mutation
      )
      local issues = { [source.number] = source, [review.number] = review }
      local github = {}
      function github.read_issue(ref, _options)
        return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
      end
      function github.api_paginate_slurp(path, _timeout)
        return tostring(path):find("state=all", 1, true)
          and { row(source), row(review) } or { row(source) }
      end
      local result = testing.run_fake(department(github), event(source))
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_nil(comments[1].handoff)
      t.is_true(comments[1].body:find("terminal-review-status-missing", 1, true) ~= nil)
    end
  end,

  test_new_signal_waits_for_prior_terminal_handoff_then_gets_its_own_proposal = function()
    for index, command in ipairs({ "approve", "reject" }) do
      local first = signal_issue(220 + index * 10)
      local second = signal_issue(first.number + 1)
      local terminal_proposal = proposal(classified(first))
      local request = core.weekly_plan_change_issue_request(terminal_proposal, session(), 1)
      local status = command == "approve" and "approved; immutable weekly-content requested"
        or "rejected: Evidence is insufficient."
      local review = {
        number = first.number + 2,
        body = request.body
          .. "\n\n<!-- fkst:github-proxy:issue-create:" .. request.dedup_key .. " -->",
        state = "CLOSED",
        labels = { "host-test-primary" },
        assignees = { "test-operator" },
        author_login = "fkst-test-bot",
        comments = {{
          id = 520 + index,
          author_login = "test-operator",
          body = review_command(command, terminal_proposal,
            command == "reject" and "Evidence is insufficient." or nil),
        }},
        source_ref = source_ref(first.number + 2),
      }
      add_terminal_status(review, terminal_proposal, status)
      local issues = {
        [first.number] = first,
        [second.number] = second,
        [review.number] = review,
      }
      local github = {}
      function github.read_issue(ref, _options)
        return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
      end
      function github.api_paginate_slurp(path, _timeout)
        if tostring(path):find("state=all", 1, true) then
          return { row(first), row(second), row(review) }
        end
        local open = { row(second) }
        if first.state == "OPEN" then table.insert(open, 1, row(first)) end
        return open
      end

      local blocked = testing.run_fake(department(github), event(second))
      t.eq(#raises_for(blocked, "github-proxy.github_issue_create_request"), 0)
      local blocked_comments = raises_for(blocked, "github-proxy.github_issue_comment_request")
      local recovered_first = false
      local waiting_second = false
      for _, comment in ipairs(blocked_comments) do
        if comment.issue_number == first.number and comment.handoff ~= nil then
          recovered_first = comment.handoff.review_command == command
        elseif comment.issue_number == second.number and comment.handoff == nil then
          waiting_second = comment.body:find("awaiting-prior-terminal-handoff", 1, true) ~= nil
        end
      end
      t.is_true(recovered_first)
      t.is_true(waiting_second)

      first.state = "CLOSED"
      local resumed = testing.run_fake(department(github), event(second))
      local creates = raises_for(resumed, "github-proxy.github_issue_create_request")
      t.eq(#creates, 1)
      local next_proposal = assert(core.parse_proposal(creates[1].body))
      t.eq(#next_proposal.signals, 1)
      t.eq(next_proposal.signals[1].source_ref.ref, second.source_ref.ref)
    end
  end,
}
