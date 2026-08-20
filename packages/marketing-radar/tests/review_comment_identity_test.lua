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
local function signal_issue(number)
  return {
    number = number,
    body = table.concat({
      "contract: marketing-radar.radar-signal.v2",
      "type: radar-signal",
      "project: chronoai",
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
local function ungroupable_proposal_issue(number, values)
  local options = values or {}
  return {
    number = number,
    body = table.concat({
      "contract: marketing-radar.weekly-plan-change.v2",
      "type: weekly-plan-change",
      "status: awaiting-review",
    }, "\n"),
    state = options.state or "OPEN",
    labels = options.labels or { "host-test-primary" },
    assignees = options.assignees or { "test-operator" },
    author_login = "fkst-test-bot",
    comments = {},
    source_ref = source_ref(number),
  }
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
local function with_create_marker(body, group_key, cycle)
  return tostring(body) .. "\n\n<!-- fkst:github-proxy:issue-create:"
    .. tostring(group_key) .. "/create/cycle-" .. tostring(cycle) .. " -->"
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
local function split_identity_fixture(command, source_number, review_number, graphql_id, rest_id)
  local source = signal_issue(source_number)
  local signal = assert(core.classify_issue(event(source).payload, {
    session = session(),
    issue_body = source.body,
    issue_labels = source.labels,
    issue_assignees = source.assignees,
  }))
  local proposal = assert(core.build_proposal({ signal }, session(), {
    action = "add",
    evidence_refs = { signal.source_ref.ref },
    tweet_text = "The initial reviewed draft.",
  }))
  local command_body = "/marketing " .. command .. " " .. proposal.proposal_id .. "@"
    .. proposal.revision .. " " .. proposal.proposal_digest .. (command == "request-changes"
      and " Add all release evidence." or " Evidence is insufficient.")
  local common = {
    number = review_number,
    body = with_create_marker(assert(core.render_proposal(proposal)), proposal.group_key, 1),
    state = "OPEN",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "fkst-test-bot",
    source_ref = source_ref(review_number),
  }
  local graphql_issue = {
    number = common.number, body = common.body, state = common.state,
    labels = common.labels, assignees = common.assignees,
    author_login = common.author_login, source_ref = common.source_ref,
    comments = { { id = graphql_id, author_login = "test-operator", body = command_body } },
  }
  local rest_issue = {
    number = common.number, body = common.body, state = common.state,
    labels = common.labels, assignees = common.assignees,
    author_login = common.author_login, source_ref = common.source_ref,
    comments = { { id = rest_id, author_login = "test-operator", body = command_body } },
  }
  local issues = { [source_number] = source, [review_number] = rest_issue }
  local catalog = { row(source), row(rest_issue) }
  local github = { fresh_review_reads = 0 }
  function github.read_issue(ref, options)
    local number = tonumber(ref.ref:match("#issue/(%d+)$"))
    if number == review_number then
      if options and options.force_fresh == true then
        github.fresh_review_reads = github.fresh_review_reads + 1
        return rest_issue
      end
      return graphql_issue
    end
    return issues[number]
  end
  function github.api_paginate_slurp(_path, _timeout)
    return catalog
  end
  return source, graphql_issue, github, proposal, rest_issue
end
local function department(github, draft_generator)
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    session_authority = session,
    review_options = function()
      return { bot_login = "fkst-test-bot", authorized_reviewers = { "test-operator" } }
    end,
    signal_author_logins = function()
      return { "test-operator" }
    end,
    draft_generator = draft_generator,
  })
end
local function raises_for(result, queue)
  local values = {}
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue or raised.queue == "marketing-radar." .. queue then
      values[#values + 1] = raised.payload
    end
    t.eq(tostring(raised.queue):find("x_publish", 1, true), nil)
    t.eq(tostring(raised.queue):find("publish_x", 1, true), nil)
  end
  return values
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
    tweet_text = "A reviewed and bounded FKST automation update.",
  }
end
return {
  test_request_changes_failure_uses_fresh_rest_comment_identity = function()
    local _source, graphql_review, github = split_identity_fixture(
      "request-changes", 127, 128, "IC_graphql_201", 201)
    local result = testing.run_fake(department(github, function()
      return nil, "draft-correction-exhausted:invalid-x-text:text too long"
    end), event(graphql_review))
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.eq(comments[1].issue_number, graphql_review.number)
    t.is_true(comments[1].body:find('comment_id="201"', 1, true) ~= nil)
    t.eq(comments[1].body:find("IC_graphql_201", 1, true), nil)
    t.is_true(github.fresh_review_reads >= 1)
  end,
  test_reject_terminal_handoff_uses_fresh_rest_comment_identity = function()
    local _source, graphql_review, github = split_identity_fixture(
      "reject", 138, 139, "IC_graphql_97", 97)
    local result = testing.run_fake(department(github), event(graphql_review))
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 2)
    for _, comment in ipairs(comments) do
      t.eq(comment.handoff.review_comment_id, 97)
    end
    t.is_true(github.fresh_review_reads >= 1)
  end,
  test_signal_replay_fails_closed_when_matching_review_read_is_missing = function()
    local source, graphql_review, github = split_identity_fixture(
      "reject", 140, 141, "IC_graphql_301", 301)
    local base_read = github.read_issue
    function github.read_issue(ref, options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      if number == graphql_review.number then return nil end
      return base_read(ref, options)
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
    t.is_true(comments[1].body:find("review-read-failed", 1, true) ~= nil)
  end,
  test_signal_replay_fails_closed_on_conflicting_bot_proposal_revision = function()
    local source, _graphql_review, github, proposal, rest_review = split_identity_fixture(
      "reject", 142, 143, "IC_graphql_302", 302)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local conflicting = assert(core.build_proposal({ signal }, session(), {
      action = "add",
      evidence_refs = { signal.source_ref.ref },
      tweet_text = "A conflicting draft for the same proposal revision.",
    }, {
      proposal_id = proposal.proposal_id,
      content_id = proposal.content_id,
      content_revision = proposal.content_revision,
    }))
    rest_review.comments[#rest_review.comments + 1] = {
      id = 303,
      author_login = "fkst-test-bot",
      body = assert(core.render_proposal(conflicting))
        .. "\n\n<!-- fkst:github-proxy:comment:" .. conflicting.group_key
        .. "/revision/1/" .. conflicting.signal_set_digest .. " -->",
    }
    local drafts = 0
    local result = testing.run_fake(department(github, function()
      drafts = drafts + 1
      return nil, "must-not-run"
    end), event(source))
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("conflicting-bot-proposal-revision", 1, true) ~= nil)
  end,
  test_user_authored_proposal_copy_is_ignored_during_discovery = function()
    local source = signal_issue(144)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local copied_review = {
      number = 145,
      body = assert(core.render_proposal(proposal)),
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "attacker",
      comments = {},
      source_ref = source_ref(145),
    }
    local issues = { [source.number] = source, [copied_review.number] = copied_review }
    local catalog = { row(source), row(copied_review) }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(_path, _timeout)
      return catalog
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.eq(drafts, 1)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 1)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("awaiting-review", 1, true) ~= nil)
  end,
  test_bot_authored_malformed_proposal_for_group_fails_closed = function()
    local source = signal_issue(146)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local malformed_body = assert(core.render_proposal(proposal)):gsub(
      proposal.content_digest, "sha256:" .. string.rep("0", 64), 1)
    malformed_body = with_create_marker(malformed_body, proposal.group_key, 1)
    local malformed_review = {
      number = 147,
      body = malformed_body,
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(147),
    }
    local issues = { [source.number] = source, [malformed_review.number] = malformed_review }
    local catalog = { row(source), row(malformed_review) }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(_path, _timeout)
      return catalog
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("active-review-invalid", 1, true) ~= nil)
  end,
  test_early_duplicate_control_in_bot_proposal_fails_closed = function()
    local source = signal_issue(150)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local malformed_review = {
      number = 151,
      body = with_create_marker(assert(core.render_proposal(proposal)):gsub(
        "type: weekly%-plan%-change\n",
        "type: weekly-plan-change\ncontract: marketing-radar.weekly-plan-change.v2\n", 1),
        proposal.group_key, 1),
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(151),
    }
    local issues = { [source.number] = source, [malformed_review.number] = malformed_review }
    local catalog = { row(source), row(malformed_review) }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(_path, _timeout)
      return catalog
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("active-review-invalid", 1, true) ~= nil)
  end,
  test_late_valid_controls_after_bad_first_values_still_fail_closed = function()
    local source = signal_issue(164)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local rendered = assert(core.render_proposal(proposal))
    local variants = {
      (rendered:gsub("type: weekly%-plan%-change\n", "", 1)),
      (rendered:gsub(
        "contract: marketing%-radar%.weekly%-plan%-change%.v2\n", "", 1)),
      string.rep("x", 32001) .. "\n" .. rendered,
      "```yaml\n" .. rendered,
      (rendered:gsub("project: chronoai\n", "project: other-project\nproject: chronoai\n", 1)),
      (rendered:gsub(
        "contract: marketing%-radar%.weekly%-plan%-change%.v2\n"
          .. "type: weekly%-plan%-change\n",
        "contract: damaged-contract\n"
          .. "type: damaged-type\n"
          .. "contract: marketing-radar.weekly-plan-change.v2\n"
          .. "type: weekly-plan-change\n",
        1)),
      (rendered:gsub(
        "contract: marketing%-radar%.weekly%-plan%-change%.v2\n"
          .. "type: weekly%-plan%-change\n",
        "contract: " .. string.rep("x", 513) .. "\n"
          .. "type: " .. string.rep("x", 513) .. "\n"
          .. "contract: marketing-radar.weekly-plan-change.v2\n"
          .. "type: weekly-plan-change\n",
        1)),
    }

    local _, fenced_intent = core.proposal_catalog_group(
      "```yaml\ncontract: marketing-radar.weekly-plan-change.v2\ntype: weekly-plan-change\n```")
    local _, beyond_limit_intent = core.proposal_catalog_group(
      string.rep("x", 32001) .. "\n" .. rendered)
    local _, unclosed_fence_intent = core.proposal_catalog_group("```yaml\n" .. rendered)
    t.eq(fenced_intent, false)
    t.eq(beyond_limit_intent, true)
    t.eq(unclosed_fence_intent, true)

    for index, body in ipairs(variants) do
      local malformed_review = {
        number = 164 + index,
        body = with_create_marker(body, proposal.group_key, 1),
        state = "OPEN",
        labels = { "host-test-primary" },
        assignees = { "test-operator" },
        author_login = "fkst-test-bot",
        comments = {},
        source_ref = source_ref(164 + index),
      }
      local issues = { [source.number] = source, [malformed_review.number] = malformed_review }
      local github = { review_reads = 0 }
      function github.read_issue(ref, _options)
        local number = tonumber(ref.ref:match("#issue/(%d+)$"))
        if number == malformed_review.number then github.review_reads = github.review_reads + 1 end
        return issues[number]
      end
      function github.api_paginate_slurp(_path, _timeout)
        return { row(source), row(malformed_review) }
      end

      local drafts = 0
      local result = testing.run_fake(department(github, function(signals, revision)
        drafts = drafts + 1
        return successful_draft(signals, revision)
      end), event(source))
      t.eq(github.review_reads, 1)
      t.eq(drafts, 0)
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_true(comments[1].body:find("active-review-invalid", 1, true) ~= nil)
    end
  end,
  test_equivalent_account_spelling_cannot_hide_bot_proposal = function()
    local source = signal_issue(152)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local normalized_body = assert(core.render_proposal(proposal)):gsub(
      "account: test_primary", "account: @TEST_PRIMARY", 1)
    normalized_body = with_create_marker(normalized_body, proposal.group_key, 1)
    t.eq(assert(core.parse_proposal(normalized_body)).group_key, proposal.group_key)
    local review = {
      number = 153,
      body = normalized_body,
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(153),
    }
    local issues = { [source.number] = source, [review.number] = review }
    local catalog = { row(source), row(review) }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(_path, _timeout)
      return catalog
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("awaiting-review", 1, true) ~= nil)
  end,
  test_open_ungroupable_bot_proposal_on_current_route_fails_closed = function()
    local source = signal_issue(154)
    local malformed = ungroupable_proposal_issue(155)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    malformed.body = with_create_marker(malformed.body, core.proposal_group_key(signal), 1)
    local issues = { [source.number] = source, [malformed.number] = malformed }
    local catalog = { row(source), row(malformed) }
    local github = { malformed_reads = 0 }
    function github.read_issue(ref, _options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      if number == malformed.number then github.malformed_reads = github.malformed_reads + 1 end
      return issues[number]
    end
    function github.api_paginate_slurp(_path, _timeout) return catalog end

    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.eq(github.malformed_reads, 1)
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find(
      "active-review-invalid:incomplete-proposal-group", 1, true) ~= nil)
  end,
  test_open_ungroupable_bot_proposal_on_wrong_route_is_ignored = function()
    local source = signal_issue(156)
    local malformed = ungroupable_proposal_issue(157, {
      labels = { "other-session" }, assignees = { "other-operator" },
    })
    local issues = { [source.number] = source, [malformed.number] = malformed }
    local catalog = { row(source), row(malformed) }
    local github = { malformed_reads = 0 }
    function github.read_issue(ref, _options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      if number == malformed.number then github.malformed_reads = github.malformed_reads + 1 end
      return issues[number]
    end
    function github.api_paginate_slurp(_path, _timeout) return catalog end

    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.is_true(github.malformed_reads >= 1)
    t.eq(drafts, 1)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 1)
  end,
  test_grouped_candidate_uses_fresh_route_not_stale_catalog_route = function()
    local source = signal_issue(158)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local review = {
      number = 159,
      body = with_create_marker(assert(core.render_proposal(proposal)), proposal.group_key, 1),
      state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", comments = {}, source_ref = source_ref(159),
    }
    local stale = row(review)
    stale.labels = { "stale-other-session" }
    stale.assignees = { "stale-operator" }
    local issues = { [source.number] = source, [review.number] = review }
    local github = { review_reads = 0 }
    function github.read_issue(ref, _options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      if number == review.number then github.review_reads = github.review_reads + 1 end
      return issues[number]
    end
    function github.api_paginate_slurp(_path, _timeout) return { row(source), stale } end

    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.eq(github.review_reads, 1)
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("awaiting-review", 1, true) ~= nil)
  end,
  test_grouped_candidate_fails_when_fresh_identity_disappears = function()
    local source = signal_issue(172)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local marker = "<!-- fkst:github-proxy:issue-create:"
      .. proposal.group_key .. "/create/cycle-1 -->"
    local catalog_issue = {
      number = 173, body = assert(core.render_proposal(proposal)) .. "\n\n" .. marker,
      state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", comments = {}, source_ref = source_ref(173),
    }
    local fresh_issue = {
      number = 173, body = "status: body-was-replaced\n\n" .. marker, state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", comments = {}, source_ref = source_ref(173),
    }
    local github = { candidate_reads = 0 }
    function github.read_issue(ref, _options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      if number == fresh_issue.number then
        github.candidate_reads = github.candidate_reads + 1
        return fresh_issue
      end
      return source
    end
    function github.api_paginate_slurp(_path, _timeout)
      return { row(source), row(catalog_issue) }
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.eq(github.candidate_reads, 1)
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("active-review-invalid", 1, true) ~= nil)
  end,
  test_ungroupable_candidate_ignores_stale_catalog_route_after_fresh_read = function()
    local source = signal_issue(162)
    local catalog_issue = ungroupable_proposal_issue(163)
    local fresh_issue = ungroupable_proposal_issue(163, {
      labels = { "other-session" }, assignees = { "other-operator" },
    })
    local github = { candidate_reads = 0 }
    function github.read_issue(ref, _options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      if number == fresh_issue.number then
        github.candidate_reads = github.candidate_reads + 1
        return fresh_issue
      end
      return source
    end
    function github.api_paginate_slurp(_path, _timeout)
      return { row(source), row(catalog_issue) }
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.is_true(github.candidate_reads >= 1)
    t.eq(drafts, 1)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 1)
  end,
  test_ungroupable_candidate_uses_fresh_current_route_after_takeover = function()
    local source = signal_issue(168)
    local fresh_issue = ungroupable_proposal_issue(169)
    local stale_issue = ungroupable_proposal_issue(169, {
      labels = { "other-session" }, assignees = { "other-operator" },
    })
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local group = core.proposal_group_key(signal)
    fresh_issue.body = with_create_marker(fresh_issue.body, group, 1)
    stale_issue.body = with_create_marker(stale_issue.body, group, 1)
    local github = { candidate_reads = 0 }
    function github.read_issue(ref, _options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      if number == fresh_issue.number then
        github.candidate_reads = github.candidate_reads + 1
        return fresh_issue
      end
      return source
    end
    function github.api_paginate_slurp(_path, _timeout)
      return { row(source), row(stale_issue) }
    end
    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(source))
    t.eq(github.candidate_reads, 1)
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("active-review-invalid", 1, true) ~= nil)
  end,
  test_closed_ungroupable_bot_proposal_on_current_route_advances_cycle = function()
    local source = signal_issue(160)
    local malformed = ungroupable_proposal_issue(161, { state = "CLOSED" })
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    malformed.body = with_create_marker(malformed.body, core.proposal_group_key(classified), 1)
    local issues = { [source.number] = source, [malformed.number] = malformed }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      if tostring(path):find("state=all", 1, true) then
        return { row(source), row(malformed) }
      end
      return { row(source) }
    end
    local result = testing.run_fake(department(github, successful_draft), event(source))
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:find("/create/cycle-2", 1, true) ~= nil)
  end,
  test_closed_ungroupable_bot_proposal_on_stale_route_advances_cycle = function()
    local source = signal_issue(170)
    local malformed = ungroupable_proposal_issue(171, {
      state = "CLOSED",
      labels = { "other-session" },
      assignees = { "other-operator" },
    })
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    malformed.body = with_create_marker(malformed.body, core.proposal_group_key(classified), 1)
    local github = {}
    function github.read_issue(ref, _options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      return number == source.number and source or malformed
    end
    function github.api_paginate_slurp(path, _timeout)
      if tostring(path):find("state=all", 1, true) then
        return { row(source), row(malformed) }
      end
      return { row(source) }
    end
    local result = testing.run_fake(department(github, successful_draft), event(source))
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:find("/create/cycle-2", 1, true) ~= nil)
  end,
  test_closed_malformed_bot_proposal_advances_create_cycle = function()
    local source = signal_issue(148)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local closed_review = {
      number = 149,
      body = assert(core.render_proposal(proposal)):gsub(
        "type: weekly%-plan%-change\n",
        "type: weekly-plan-change\ncontract: marketing-radar.weekly-plan-change.v2\n", 1),
      state = "CLOSED",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(149),
    }
    closed_review.body = with_create_marker(closed_review.body, proposal.group_key, 1)
    local issues = { [source.number] = source, [closed_review.number] = closed_review }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      if tostring(path):find("state=all", 1, true) then
        return { row(source), row(closed_review) }
      end
      return { row(source) }
    end
    local result = testing.run_fake(department(github, successful_draft), event(source))
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:find("/create/cycle-2", 1, true) ~= nil)
  end,
  test_approved_content_create_marker_does_not_poison_proposal_cycles = function()
    local source = signal_issue(187)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local request = core.approved_weekly_content_issue_request(proposal, session())
    local content = {
      number = 188,
      body = request.body .. "\n\n<!-- fkst:github-proxy:issue-create:"
        .. request.dedup_key .. " -->",
      state = "CLOSED",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(188),
    }
    local issues = { [source.number] = source, [content.number] = content }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(content) } or { row(source) }
    end

    local result = testing.run_fake(department(github, successful_draft), event(source))
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:find("/create/cycle-1", 1, true) ~= nil)
  end,
  test_create_cycle_uses_max_trusted_provenance_after_controls_change = function()
    local source = signal_issue(174)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local old = ungroupable_proposal_issue(175, {
      state = "CLOSED", labels = { "other-session" }, assignees = { "other-operator" },
    })
    old.body = with_create_marker(table.concat({
      "contract: marketing-radar.weekly-plan-change.v2",
      "type: weekly-plan-change",
      "project: another-project",
      "account: another_account",
      "week: 2025-W01",
      "action: add",
    }, "\n"), core.proposal_group_key(signal), 7)
    local github = {}
    function github.read_issue(ref, _options)
      return tonumber(ref.ref:match("#issue/(%d+)$")) == source.number and source or old
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(old) } or { row(source) }
    end

    local result = testing.run_fake(department(github, successful_draft), event(source))
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:find("/create/cycle-8", 1, true) ~= nil)
  end,
  test_missing_create_provenance_for_closed_proposal_fails_closed = function()
    local source = signal_issue(176)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local old = {
      number = 177, body = assert(core.render_proposal(proposal)), state = "CLOSED",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", comments = {}, source_ref = source_ref(177),
    }
    local github = {}
    function github.read_issue(ref, _options)
      return tonumber(ref.ref:match("#issue/(%d+)$")) == source.number and source or old
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(old) } or { row(source) }
    end

    local result = testing.run_fake(department(github, successful_draft), event(source))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("proposal-create-provenance-missing", 1, true) ~= nil)
  end,

  test_missing_create_provenance_for_active_proposal_fails_closed = function()
    local source = signal_issue(185)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ signal }, session(),
      successful_draft({ signal }, 1)))
    local active = {
      number = 186, body = assert(core.render_proposal(proposal)), state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", comments = {}, source_ref = source_ref(186),
    }
    local issues = { [source.number] = source, [active.number] = active }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(_path, _timeout)
      return { row(source), row(active) }
    end

    local result = testing.run_fake(department(github, successful_draft), event(source))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find(
      "active-review-invalid:proposal-create-provenance-missing", 1, true) ~= nil)
  end,

  test_malformed_create_marker_fails_closed_even_after_controls_change = function()
    local source = signal_issue(178)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local other = ungroupable_proposal_issue(179, { state = "CLOSED" })
    other.body = other.body .. "\n<!-- fkst:github-proxy:issue-create:"
      .. core.proposal_group_key(signal) .. "/create/cycle-01 -->"
    local issues = { [source.number] = source, [other.number] = other }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(other) } or { row(source) }
    end
    local result = testing.run_fake(department(github, successful_draft), event(source))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("proposal-create-provenance-invalid", 1, true) ~= nil)
  end,

  test_duplicate_create_cycle_across_issues_fails_closed = function()
    local source = signal_issue(180)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local group = core.proposal_group_key(signal)
    local first = ungroupable_proposal_issue(181, { state = "CLOSED" })
    local second = ungroupable_proposal_issue(182, { state = "CLOSED" })
    first.body = with_create_marker(first.body, group, 3)
    second.body = with_create_marker(second.body, group, 3)
    local issues = { [source.number] = source, [first.number] = first, [second.number] = second }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(first), row(second) } or { row(source) }
    end
    local result = testing.run_fake(department(github, successful_draft), event(source))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("proposal-create-provenance-cycle-conflict", 1, true) ~= nil)
  end,

  test_create_marker_inside_tweet_fence_is_not_provenance = function()
    local source = signal_issue(183)
    local signal = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local hidden = ungroupable_proposal_issue(184, { state = "CLOSED" })
    hidden.body = table.concat({
      "type: note",
      "tweet-text:",
      "````",
      "<!-- fkst:github-proxy:issue-create:" .. core.proposal_group_key(signal)
        .. "/create/cycle-9 -->",
      "````",
    }, "\n")
    local issues = { [source.number] = source, [hidden.number] = hidden }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(hidden) } or { row(source) }
    end
    local result = testing.run_fake(department(github, successful_draft), event(source))
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:find("/create/cycle-1", 1, true) ~= nil)
  end,
}
