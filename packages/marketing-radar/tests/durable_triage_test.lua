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

local function signal_body(number, insight)
  return table.concat({
    "contract: marketing-radar.radar-signal.v2",
    "type: radar-signal",
    "project: chronoai",
    "account: test_primary",
    "work-label: auto-x-test-primary",
    "week: 2026-W33",
    "action: add",
    "topic: FKST automation",
    "source-url: https://github.example/owner/repo/issues/" .. tostring(number),
    "insight: " .. tostring(insight or "Use cited evidence for the reviewed draft."),
  }, "\n")
end

local function signal_issue(number, insight)
  return {
    number = number,
    body = signal_body(number, insight),
    state = "OPEN",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "test-operator",
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

local function event(issue)
  return {
    queue = "github-proxy.github_issue_observed",
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

local function github_port(input)
  local issues = input.number ~= nil and { [input.number] = input } or input
  local github = { catalog_calls = 0 }
  function github.read_issue(ref, _options)
    local number = tonumber(tostring(ref.ref):match("#issue/(%d+)$"))
    return issues[number]
  end
  local function rows_for(state)
    local rows = {}
    for _, issue in pairs(issues) do
      if state == "all" or tostring(issue.state):upper() == "OPEN" then
        rows[#rows + 1] = row(issue)
      end
    end
    table.sort(rows, function(left, right) return left.number < right.number end)
    return rows
  end
  function github.issue_list_intake(_repo, _limit, _timeout)
    github.catalog_calls = github.catalog_calls + 1
    return rows_for("open")
  end
  function github.api_paginate_slurp(path, _timeout)
    github.catalog_calls = github.catalog_calls + 1
    return rows_for(tostring(path):find("state=all", 1, true) and "all" or "open")
  end
  return github
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
  end
  return values
end

local function classified(issue)
  return assert(core.classify_issue({
    schema = "github-proxy.v1",
    type = "issue",
    repo = repo,
    number = issue.number,
    labels = issue.labels,
    assignees = issue.assignees,
    body = issue.body,
    source_ref = issue.source_ref,
  }, {
    session = session(),
    issue_body = issue.body,
    issue_labels = issue.labels,
    issue_assignees = issue.assignees,
    issue_author_login = issue.author_login,
    authorized_signal_authors = { "test-operator" },
  }))
end

local function persisted_failure(issue, status, author_login)
  local failed = testing.run_fake(department(github_port(issue), function()
    return nil, status
  end), event(issue))
  local requests = raises_for(failed, "github-proxy.github_issue_comment_request")
  t.eq(#requests, 1)
  local request = requests[1]
  issue.comments[#issue.comments + 1] = {
    id = #issue.comments + 1,
    author_login = author_login or "app/fkst-test-bot",
    body = request.body .. "\n<!-- fkst:github-proxy:comment:" .. request.dedup_key .. " -->",
  }
  return request
end

local function persist_request(issue, request)
  issue.comments[#issue.comments + 1] = {
    id = 300 + issue.number,
    author_login = "fkst-test-bot",
    body = request.body .. "\n<!-- fkst:github-proxy:comment:"
      .. request.dedup_key .. " -->",
  }
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
  test_group_failure_marks_every_signal_and_blocks_cross_signal_replay = function()
    local first = signal_issue(190)
    local second = signal_issue(191)
    local issues = { [190] = first, [191] = second }
    local first_result = testing.run_fake(department(github_port(issues), function()
      return nil, "draft-correction-exhausted:invalid-x-text:text too long"
    end), event(first))
    local comments = raises_for(first_result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 2)
    local signals = { classified(first), classified(second) }
    local identity = assert(core.signal_set_identity(signals, session()))
    local anchor_number = tonumber(identity.first.source_ref.ref:match("#issue/(%d+)$"))
    t.eq(comments[#comments].issue_number, anchor_number)
    local dedup_keys = {}
    local set_hex = assert(identity.signal_set_digest:match("^sha256:([0-9a-f]+)$"))
    for _, request in ipairs(comments) do
      t.is_true(#request.dedup_key <= 512)
      t.is_true(request.dedup_key:find("/set-" .. set_hex .. "/", 1, true) ~= nil)
      t.is_nil(dedup_keys[request.dedup_key])
      dedup_keys[request.dedup_key] = true
    end
    for _, request in ipairs(comments) do
      local issue = assert(issues[request.issue_number])
      persist_request(issue, request)
    end

    local drafts = 0
    local replay_github = github_port(issues)
    local replay = testing.run_fake(department(replay_github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(second))
    t.eq(drafts, 0)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 0)

    second.state = "CLOSED"
    local resumed_drafts = 0
    local resumed = testing.run_fake(department(github_port(issues), function(signals, revision)
      resumed_drafts = resumed_drafts + 1
      return successful_draft(signals, revision)
    end), event(first))
    t.eq(resumed_drafts, 1)
    t.eq(#raises_for(resumed, "github-proxy.github_issue_create_request"), 1)
  end,

  test_partial_non_anchor_marker_does_not_freeze_the_signal_set = function()
    local first = signal_issue(192)
    local second = signal_issue(193)
    local issues = { [192] = first, [193] = second }
    local signals = { classified(first), classified(second) }
    local identity = assert(core.signal_set_identity(signals, session()))
    local anchor_number = tonumber(identity.first.source_ref.ref:match("#issue/(%d+)$"))
    local sibling_number = anchor_number == first.number and second.number or first.number
    local failed = testing.run_fake(department(github_port(issues), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(first))
    local comments = raises_for(failed, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 2)
    for _, request in ipairs(comments) do
      if request.issue_number == sibling_number then
        persist_request(assert(issues[sibling_number]), request)
      end
    end

    local drafts = 0
    local replay = testing.run_fake(department(github_port(issues), function()
      drafts = drafts + 1
      return nil, "semantic-conflict:action scope differs"
    end), event(issues[sibling_number]))
    t.eq(drafts, 1)
    t.eq(#raises_for(replay, "github-proxy.github_issue_comment_request"), 2)
  end,

  test_anchor_marker_suppresses_ai_and_repairs_missing_sibling_ack = function()
    local first = signal_issue(198)
    local second = signal_issue(199)
    local issues = { [198] = first, [199] = second }
    local identity = assert(core.signal_set_identity(
      { classified(first), classified(second) }, session()))
    local anchor_number = tonumber(identity.first.source_ref.ref:match("#issue/(%d+)$"))
    local sibling_number = anchor_number == first.number and second.number or first.number
    local failed = testing.run_fake(department(github_port(issues), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(first))
    local comments = raises_for(failed, "github-proxy.github_issue_comment_request")
    for _, request in ipairs(comments) do
      if request.issue_number == anchor_number then
        persist_request(assert(issues[anchor_number]), request)
      end
    end

    local drafts = 0
    local replay = testing.run_fake(department(github_port(issues), function()
      drafts = drafts + 1
      return nil, "must-not-run"
    end), event(issues[sibling_number]))
    local repairs = raises_for(replay, "github-proxy.github_issue_comment_request")
    t.eq(drafts, 0)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 0)
    t.eq(#repairs, 1)
    t.eq(repairs[1].issue_number, sibling_number)

    persist_request(assert(issues[sibling_number]), repairs[1])
    local converged_drafts = 0
    local converged = testing.run_fake(department(github_port(issues), function()
      converged_drafts = converged_drafts + 1
      return nil, "must-not-run"
    end), event(issues[sibling_number]))
    t.eq(converged_drafts, 0)
    t.eq(#raises_for(converged, "github-proxy.github_issue_create_request"), 0)
    t.eq(#raises_for(converged, "github-proxy.github_issue_comment_request"), 0)
    t.eq(#converged.raises, 1)
    t.eq(converged.raises[1].queue, "radar_signal_imported")
    t.eq(converged.raises[1].payload.dedup_key, classified(issues[sibling_number]).dedup_key)
  end,

  test_multiline_failure_reason_is_canonical_and_durable_across_replay = function()
    local issue = signal_issue(226)
    local failed = testing.run_fake(department(github_port(issue), function()
      return nil, "semantic-conflict:first line\r\nsecond line"
    end), event(issue))
    local request = assert(raises_for(
      failed, "github-proxy.github_issue_comment_request")[1])
    t.eq(request.body:match("^([^\r\n]*)"),
      "Marketing radar v0.3.0: needs-triage: semantic-conflict:first line second line")
    persist_request(issue, request)

    local drafts = 0
    local replay = testing.run_fake(department(github_port(issue), function()
      drafts = drafts + 1
      return nil, "must-not-run"
    end), event(issue))
    t.eq(drafts, 0)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 0)
    t.eq(#raises_for(replay, "github-proxy.github_issue_comment_request"), 0)
  end,

  test_anchor_replay_repairs_every_missing_sibling_not_only_the_trigger = function()
    local issues = {
      [220] = signal_issue(220),
      [221] = signal_issue(221),
      [222] = signal_issue(222),
    }
    local identity = assert(core.signal_set_identity({
      classified(issues[220]), classified(issues[221]), classified(issues[222]),
    }, session()))
    local anchor_number = tonumber(identity.first.source_ref.ref:match("#issue/(%d+)$"))
    local siblings = {}
    for number, _ in pairs(issues) do
      if number ~= anchor_number then siblings[#siblings + 1] = number end
    end
    table.sort(siblings)
    local failed = testing.run_fake(department(github_port(issues), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(issues[anchor_number]))
    for _, request in ipairs(raises_for(failed, "github-proxy.github_issue_comment_request")) do
      if request.issue_number ~= siblings[2] then
        persist_request(assert(issues[request.issue_number]), request)
      end
    end

    local drafts = 0
    local replay = testing.run_fake(department(github_port(issues), function()
      drafts = drafts + 1
      return nil, "must-not-run"
    end), event(issues[siblings[1]]))
    local repairs = raises_for(replay, "github-proxy.github_issue_comment_request")
    t.eq(drafts, 0)
    t.eq(#repairs, 1)
    t.eq(repairs[1].issue_number, siblings[2])
  end,

  test_anchor_authority_fresh_checks_non_anchor_members_before_skip = function()
    local issues = {
      [223] = signal_issue(223),
      [224] = signal_issue(224),
      [225] = signal_issue(225),
    }
    local identity = assert(core.signal_set_identity({
      classified(issues[223]), classified(issues[224]), classified(issues[225]),
    }, session()))
    local anchor_number = tonumber(identity.first.source_ref.ref:match("#issue/(%d+)$"))
    local others = {}
    for number, _ in pairs(issues) do
      if number ~= anchor_number then others[#others + 1] = number end
    end
    table.sort(others)
    local failed = testing.run_fake(department(github_port(issues), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(issues[anchor_number]))
    for _, request in ipairs(raises_for(failed, "github-proxy.github_issue_comment_request")) do
      persist_request(assert(issues[request.issue_number]), request)
    end
    local stale_rows = { row(issues[223]), row(issues[224]), row(issues[225]) }
    local changed_number = others[2]
    issues[changed_number].state = "CLOSED"
    local github = github_port(issues)
    local base_read = github.read_issue
    local changed_fresh_reads = 0
    function github.read_issue(ref, options)
      local number = tonumber(ref.ref:match("#issue/(%d+)$"))
      if number == changed_number and options and options.force_fresh == true then
        changed_fresh_reads = changed_fresh_reads + 1
      end
      return base_read(ref, options)
    end
    function github.api_paginate_slurp(_path, _timeout)
      return stale_rows
    end
    local drafts = 0
    local replay = testing.run_fake(department(github, function()
      drafts = drafts + 1
      return nil, "must-not-run"
    end), event(issues[others[1]]))

    t.eq(drafts, 0)
    t.is_true(changed_fresh_reads >= 1)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 0)
  end,

  test_group_member_business_change_invalidates_old_signal_set_failure = function()
    local first = signal_issue(194)
    local second = signal_issue(195)
    local issues = { [194] = first, [195] = second }
    local failed = testing.run_fake(department(github_port(issues), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(first))
    for _, request in ipairs(raises_for(failed, "github-proxy.github_issue_comment_request")) do
      persist_request(assert(issues[request.issue_number]), request)
    end

    second.body = signal_body(second.number, "Use corrected release evidence for the draft.")
    local drafts = 0
    local resumed = testing.run_fake(department(github_port(issues), function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(first))
    t.eq(drafts, 1)
    t.eq(#raises_for(resumed, "github-proxy.github_issue_create_request"), 1)
  end,

  test_new_group_member_invalidates_old_signal_set_failure = function()
    local first = signal_issue(196)
    local issues = { [196] = first }
    local failed = testing.run_fake(department(github_port(issues), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(first))
    persist_request(first, assert(raises_for(
      failed, "github-proxy.github_issue_comment_request")[1]))

    local second = signal_issue(197)
    issues[197] = second
    local drafts = 0
    local resumed = testing.run_fake(department(github_port(issues), function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(second))
    t.eq(drafts, 1)
    t.eq(#raises_for(resumed, "github-proxy.github_issue_create_request"), 1)
  end,

  test_trusted_durable_failures_skip_unchanged_observation_before_codex = function()
    for index, reason in ipairs({
      "semantic-conflict:body requests replan while action is add",
      "draft-correction-exhausted:invalid-x-text:text too long",
    }) do
      local issue = signal_issue(200 + index)
      persisted_failure(issue, reason)
      local drafts = 0
      local github = github_port(issue)
      local result = testing.run_fake(department(github, function()
        drafts = drafts + 1
        return successful_draft({ classified(issue) }, 1)
      end), event(issue))

      t.eq(drafts, 0)
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      t.eq(#raises_for(result, "github-proxy.github_issue_comment_request"), 0)
    end
  end,

  test_durable_authority_force_fresh_reads_past_markerless_same_second_cache = function()
    local issue = signal_issue(210)
    persisted_failure(issue, "semantic-conflict:body requests replan while action is add")
    local cached = signal_issue(210)
    local github = github_port(issue)
    local base_read = github.read_issue
    local fresh_reads = 0
    function github.read_issue(ref, options)
      if options and options.force_fresh == true then
        fresh_reads = fresh_reads + 1
        return base_read(ref, options)
      end
      return cached
    end
    local drafts = 0
    local replay = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(cached))

    t.eq(drafts, 0)
    t.is_true(fresh_reads >= 1)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 0)
    t.eq(#raises_for(replay, "github-proxy.github_issue_comment_request"), 0)
  end,

  test_untrusted_or_unmarked_failure_text_does_not_suppress_generation = function()
    local issue = signal_issue(211)
    local request = persisted_failure(issue,
      "draft-correction-exhausted:invalid-x-text:text too long", "attacker")
    issue.comments[#issue.comments + 1] = {
      id = 2,
      author_login = "fkst-test-bot",
      body = request.body,
    }
    local drafts = 0
    local result = testing.run_fake(department(github_port(issue), function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(issue))

    t.eq(drafts, 1)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 1)
  end,

  test_duplicate_proxy_marker_in_trusted_comment_cannot_authorize_failure = function()
    local issue = signal_issue(213)
    local failed = testing.run_fake(department(github_port(issue), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(issue))
    local request = assert(raises_for(
      failed, "github-proxy.github_issue_comment_request")[1])
    local marker = "<!-- fkst:github-proxy:comment:" .. request.dedup_key .. " -->"
    issue.comments[#issue.comments + 1] = {
      id = 1,
      author_login = "fkst-test-bot",
      body = request.body .. "\n" .. marker .. "\n" .. marker,
    }

    local drafts = 0
    local replay = testing.run_fake(department(github_port(issue), function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(issue))
    t.eq(drafts, 1)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 1)
  end,

  test_proxy_marker_suffix_must_exactly_match_the_visible_failure_status = function()
    local issue = signal_issue(214)
    local failed = testing.run_fake(department(github_port(issue), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(issue))
    local request = assert(raises_for(
      failed, "github-proxy.github_issue_comment_request")[1])
    issue.comments[#issue.comments + 1] = {
      id = 1,
      author_login = "fkst-test-bot",
      body = request.body .. "\n<!-- fkst:github-proxy:comment:"
        .. request.dedup_key .. "_forged -->",
    }

    local drafts = 0
    local replay = testing.run_fake(department(github_port(issue), function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(issue))
    t.eq(drafts, 1)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 1)
  end,

  test_existing_same_set_proposal_wins_over_a_late_triage_marker = function()
    local signal = signal_issue(215)
    local failed = testing.run_fake(department(github_port(signal), function()
      return nil, "semantic-conflict:action scope differs"
    end), event(signal))
    persist_request(signal, assert(raises_for(
      failed, "github-proxy.github_issue_comment_request")[1]))
    local proposal = assert(core.build_proposal(
      { classified(signal) }, session(), successful_draft({ classified(signal) }, 1)))
    local review = {
      number = 216,
      body = assert(core.render_proposal(proposal))
        .. "\n\n<!-- fkst:github-proxy:issue-create:"
        .. proposal.group_key .. "/create/cycle-1 -->",
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(216),
    }
    local issues = { [215] = signal, [216] = review }
    local drafts = 0
    local replay = testing.run_fake(department(github_port(issues), function()
      drafts = drafts + 1
      return nil, "must-not-run"
    end), event(signal))

    t.eq(drafts, 0)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(replay, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("awaiting-review", 1, true) ~= nil)
  end,

  test_signal_business_change_invalidates_old_failure_marker_and_retries = function()
    local issue = signal_issue(212)
    local old_digest = classified(issue).signal_digest
    persisted_failure(issue, "semantic-conflict:body requests replan while action is add")
    issue.body = signal_body(issue.number, "Use newly supplied release evidence for the draft.")
    t.is_true(classified(issue).signal_digest ~= old_digest)

    local drafts = 0
    local result = testing.run_fake(department(github_port(issue), function(signals, revision)
      drafts = drafts + 1
      return successful_draft(signals, revision)
    end), event(issue))

    t.eq(drafts, 1)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 1)
  end,
}
