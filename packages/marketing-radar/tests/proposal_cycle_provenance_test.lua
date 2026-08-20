local core = require("core")
local marketing_content = require("contract.marketing_content")
local sha256 = require("contract.sha256")
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

local function signal_issue_in_group(number, week, topic)
  local issue = signal_issue(number)
  issue.body = assert(issue.body:gsub("week: 2026%-W33", "week: " .. week, 1))
  issue.body = assert(issue.body:gsub("topic: FKST automation", "topic: " .. topic, 1))
  return issue
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

local function rc2_legacy_group(signal)
  return table.concat({
    "marketing-radar",
    core.runtime_segment(signal.project),
    core.runtime_segment(signal.account),
    core.runtime_segment(signal.week),
    core.runtime_segment(signal.topic or "general"),
    core.runtime_segment(signal.action or "unknown"),
    core.runtime_segment(signal.target_ref or "none", 180),
    "weekly-plan-change",
  }, "/")
end

local function replace_once(value, from, to)
  local at = assert(tostring(value):find(from, 1, true))
  return value:sub(1, at - 1) .. to .. value:sub(at + #from)
end

local function rc2_legacy_review(number, source, state, cycle, with_terminal_command)
  local signal = classified(source)
  local legacy_group = rc2_legacy_group(signal)
  local signal_set_digest = assert(core.signal_set_identity({ signal }, session())).signal_set_digest
  local proposal_id = "proposal-"
    .. sha256.hex(legacy_group .. "\n" .. signal_set_digest):sub(1, 24)
  local content_id = "content-" .. sha256.hex(proposal_id):sub(1, 24)
  local tweet_text = "A reviewed and bounded FKST automation update."
  local content_digest = assert(marketing_content.digest({
    project = signal.project,
    account = signal.account,
    work_label = session().logical_work_label,
    week = signal.week,
    content_id = content_id,
    content_revision = 1,
    proposal_id = proposal_id,
    proposal_revision = 1,
    approval_id = proposal_id .. "@1",
    content_status = "approved",
    tweet_text = tweet_text,
  }))
  local legacy_proposal = {
    proposal_id = proposal_id,
  }
  local body = table.concat({
    "contract: marketing-radar.weekly-plan-change.v2",
    "type: weekly-plan-change",
    "project: " .. signal.project,
    "account: " .. signal.account,
    "work-label: " .. session().logical_work_label,
    "week: " .. signal.week,
    "topic: " .. signal.topic,
    "action: " .. signal.action,
    "change-scope: " .. signal.change_scope,
    "supersede-mode: " .. signal.supersede_mode,
    "proposal-id: " .. proposal_id,
    "proposal-revision: 1",
    "content-id: " .. content_id,
    "content-revision: 1",
    "signal-set-digest: " .. signal_set_digest,
    "content-digest: " .. content_digest,
    "status: awaiting-review",
    "signal: " .. signal.source_ref.ref .. " " .. signal.signal_digest,
    "evidence: " .. signal.source_ref.ref,
    "",
    "tweet-text:",
    "```",
    tweet_text,
    "```",
  }, "\n")
  local comments = {}
  if with_terminal_command then
    comments[1] = {
      id = 490,
      author_login = "test-operator",
      body = "/marketing approve " .. legacy_proposal.proposal_id .. "@1",
    }
  end
  return {
    number = number,
    body = body .. "\n\n<!-- fkst:github-proxy:issue-create:"
      .. legacy_group .. "/create/cycle-" .. tostring(cycle or 1) .. " -->",
    state = state,
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "fkst-test-bot",
    comments = comments,
    source_ref = source_ref(number),
  }, legacy_group
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
  test_frozen_real_rc2_root_is_recognized_as_exact_legacy = function()
    local body = table.concat({
      "contract: marketing-radar.weekly-plan-change.v2",
      "type: weekly-plan-change",
      "project: aelf-x-ops",
      "account: hzz780",
      "work-label: auto-x-hzz780",
      "week: 2026-W33",
      "topic: publishing-gap",
      "action: add",
      "change-scope: append",
      "supersede-mode: none",
      "proposal-id: proposal-d5b518f734bbd0e4f5192903",
      "proposal-revision: 1",
      "content-id: content-18e2957e615859b6d28fce50",
      "content-revision: 1",
      "signal-set-digest: sha256:082922131f38e884ac2bb1b5d6f4543c1165181d9f9f705f50f6c567f6e4d8dc",
      "content-digest: sha256:e3b206f7256915532c0dcfa632b15d14e5f49adce2f1f6abf691d8ec8aa5a0e0",
      "status: awaiting-review",
      "signal: aelf-hzz780/fkst-packages-market-hzz#issue/127 sha256:1397138abc2685c207738d00277588ec1da402e3f691001b508bb31329cee8d0",
      "signal: aelf-hzz780/fkst-packages-market-hzz#issue/128 sha256:3783deb9072ac46cbcbac12d459a5d5fdd004feff3dd4ba8a27264c8d78bdd56",
      "signal: aelf-hzz780/fkst-packages-market-hzz#issue/126 sha256:8ee5c62c820b43888a8536899d08338f4201e6c66f169444cb6a302b0962ac59",
      "evidence: aelf-hzz780/fkst-packages-market-hzz#issue/126",
      "evidence: aelf-hzz780/fkst-packages-market-hzz#issue/127",
      "evidence: aelf-hzz780/fkst-packages-market-hzz#issue/128",
      "",
      "tweet-text:",
      "```",
      "Can a payment retry avoid a second signature when the network stalls? In our tDVV pilot, the retry returned the same tx reference, not another signature. Read the test boundary and evidence links before you ship the flow.",
      "```",
      "",
      "<!-- fkst:github-proxy:issue-create:marketing-radar/aelf-x-ops/hzz780/2026-W33/publishing-gap/add/none/weekly-plan-change/create/cycle-1 -->",
    }, "\n")
    local legacy, why = core.inspect_rc2_proposal(body)
    t.is_nil(why)
    t.eq(legacy.group_key,
      "marketing-radar/aelf-x-ops/hzz780/2026-W33/publishing-gap/add/none/weekly-plan-change")
    t.eq(legacy.proposal_id, "proposal-d5b518f734bbd0e4f5192903")
    t.eq(#legacy.signals, 3)
  end,

  test_closed_current_root_with_rc2_marker_fails_closed = function()
    local source = signal_issue(186)
    local current = proposal(classified(source))
    local request = core.weekly_plan_change_issue_request(current, session(), 1)
    local legacy_group = rc2_legacy_group(classified(source))
    local review = {
      number = 187,
      body = request.body .. "\n\n<!-- fkst:github-proxy:issue-create:"
        .. legacy_group .. "/create/cycle-1 -->",
      state = "CLOSED",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(187),
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
    t.is_true(comments[1].body:find(
      "active-review-invalid:proposal-create-provenance-group-mismatch", 1, true) ~= nil)
  end,

  test_closed_exact_rc2_legacy_review_starts_new_canonical_cycle_one = function()
    local source = signal_issue(190)
    local legacy, legacy_group = rc2_legacy_review(191, source, "CLOSED", 1, true)
    t.eq(legacy_group,
      "marketing-radar/chronoai/test_primary/2026-W33/FKST_automation/add/none/weekly-plan-change")
    local issues = { [source.number] = source, [legacy.number] = legacy }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(legacy) } or { row(source) }
    end

    local drafts = 0
    local result = testing.run_fake(department(github, function(signals, revision)
      drafts = drafts + 1
      return {
        revision = revision,
        action = signals[1].action,
        evidence_refs = { signals[1].source_ref.ref },
        tweet_text = "A reviewed and bounded FKST automation update.",
      }
    end), event(source))
    t.eq(drafts, 1)
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:find("/sha256-", 1, true) ~= nil)
    t.is_true(creates[1].dedup_key:sub(-#"/create/cycle-1") == "/create/cycle-1")
    local created = assert(core.parse_proposal(creates[1].body))
    t.eq(#created.signals, 1)
    t.eq(created.signals[1].source_ref.ref, source.source_ref.ref)
    for _, comment in ipairs(raises_for(result, "github-proxy.github_issue_comment_request")) do
      t.is_nil(comment.handoff)
      t.is_nil(comment.body:find("needs-triage", 1, true))
    end
    t.eq(#raises_for(result, "x-publisher.x_publish_request"), 0)
    t.eq(#raises_for(result, "x-publisher.x_published"), 0)
  end,

  test_open_exact_rc2_legacy_review_remains_fail_closed = function()
    local source = signal_issue(192)
    local legacy = rc2_legacy_review(193, source, "OPEN", 1, false)
    local issues = { [source.number] = source, [legacy.number] = legacy }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(_path, _timeout)
      return { row(source), row(legacy) }
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
    t.is_true(comments[1].body:find(
      "active-review-invalid:legacy-proposal-requires-retirement", 1, true) ~= nil)
    t.eq(#raises_for(result, "x-publisher.x_publish_request"), 0)
    t.eq(#raises_for(result, "x-publisher.x_published"), 0)
  end,

  test_catalog_closed_fresh_open_rc2_legacy_review_remains_fail_closed = function()
    local source = signal_issue(198)
    local legacy = rc2_legacy_review(199, source, "CLOSED", 1, false)
    local catalog_legacy = row(legacy)
    legacy.state = "OPEN"
    local issues = { [source.number] = source, [legacy.number] = legacy }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), catalog_legacy } or { row(source) }
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
    t.is_true(comments[1].body:find(
      "active-review-invalid:legacy-proposal-requires-retirement", 1, true) ~= nil)
  end,

  test_rc2_history_is_revalidated_after_draft_before_create = function()
    local mutations = {
      function(issue) issue.state = "OPEN" end,
      function(issue) issue.labels = { "other-session" } end,
      function(issue) issue.assignees = { "other-operator" } end,
      function(issue)
        issue.body = replace_once(issue.body, "/create/cycle-1", "/create/cycle-2")
      end,
    }
    for index, mutate in ipairs(mutations) do
      local source = signal_issue(300 + index * 2)
      local legacy = rc2_legacy_review(source.number + 1, source, "CLOSED", 1, true)
      local issues = { [source.number] = source, [legacy.number] = legacy }
      local github = {}
      function github.read_issue(ref, _options)
        return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
      end
      function github.api_paginate_slurp(path, _timeout)
        return tostring(path):find("state=all", 1, true)
          and { row(source), row(legacy) } or { row(source) }
      end

      local result = testing.run_fake(department(github, function(signals, revision)
        mutate(legacy)
        return {
          revision = revision,
          action = signals[1].action,
          evidence_refs = { signals[1].source_ref.ref },
          tweet_text = "A reviewed and bounded FKST automation update.",
        }
      end), event(source))
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_true(comments[1].body:find(
        "proposal-history-changed-before-create", 1, true) ~= nil)
    end
  end,

  test_rc2_provenance_bounds_the_complete_legacy_dedup_key = function()
    local suffix = "/weekly-plan-change"
    local prefix = "marketing-radar/"
    local function group_of_length(length)
      return prefix .. string.rep("a", length - #prefix - #suffix) .. suffix
    end
    local group = group_of_length(489)
    local body = "<!-- fkst:github-proxy:issue-create:" .. group .. "/create/cycle-1 -->"
    local strict = core.proposal_create_provenance(body)
    t.is_nil(strict)
    local legacy, legacy_why = core.proposal_create_provenance(body, {
      allow_legacy_group = true,
    })
    t.is_nil(legacy_why)
    t.eq(legacy.group_key, group)

    local max_cycle_group = group_of_length(488)
    local max_cycle = core.proposal_create_provenance(
      "<!-- fkst:github-proxy:issue-create:" .. max_cycle_group
        .. "/create/cycle-2147483647 -->",
      { allow_legacy_group = true })
    t.eq(max_cycle.group_key, max_cycle_group)

    local oversized = core.proposal_create_provenance(
      "<!-- fkst:github-proxy:issue-create:" .. group_of_length(498)
        .. "/create/cycle-1 -->",
      { allow_legacy_group = true })
    t.is_nil(oversized)
    local long_cycle = core.proposal_create_provenance(
      "<!-- fkst:github-proxy:issue-create:" .. group
        .. "/create/cycle-2147483647 -->",
      { allow_legacy_group = true })
    t.is_nil(long_cycle)
  end,

  test_closed_rc2_legacy_marker_does_not_change_canonical_cycle_number = function()
    local source = signal_issue(194)
    local legacy = rc2_legacy_review(195, source, "CLOSED", 7, false)
    local canonical_proposal = proposal(classified(signal_issue(196)))
    local canonical_request = core.weekly_plan_change_issue_request(canonical_proposal, session(), 3)
    local canonical = {
      number = 197,
      body = canonical_request.body
        .. "\n\n<!-- fkst:github-proxy:issue-create:" .. canonical_request.dedup_key .. " -->",
      state = "CLOSED",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      comments = {},
      source_ref = source_ref(197),
    }
    local issues = {
      [source.number] = source,
      [legacy.number] = legacy,
      [canonical.number] = canonical,
    }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(legacy), row(canonical) } or { row(source) }
    end

    local result = testing.run_fake(department(github), event(source))
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:sub(-#"/create/cycle-4") == "/create/cycle-4")
  end,

  test_rc2_closed_history_allows_exactly_two_w33_w34_canonical_proposals = function()
    local w33_a = signal_issue_in_group(260, "2026-W33", "publishing-gap")
    local w33_b = signal_issue_in_group(261, "2026-W33", "publishing-gap")
    local w33_c = signal_issue_in_group(262, "2026-W33", "publishing-gap")
    local w34 = signal_issue_in_group(263, "2026-W34", "content-supply-gap")
    local legacy_w33 = rc2_legacy_review(264, w33_a, "CLOSED", 1, true)
    local legacy_w34 = rc2_legacy_review(265, w34, "CLOSED", 1, true)
    local issues = {
      [w33_a.number] = w33_a,
      [w33_b.number] = w33_b,
      [w33_c.number] = w33_c,
      [w34.number] = w34,
      [legacy_w33.number] = legacy_w33,
      [legacy_w34.number] = legacy_w34,
    }
    local open_rows = { row(w33_a), row(w33_b), row(w33_c), row(w34) }
    local all_rows = {
      row(w33_a), row(w33_b), row(w33_c), row(w34), row(legacy_w33), row(legacy_w34),
    }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true) and all_rows or open_rows
    end

    local w33_result = testing.run_fake(department(github), event(w33_a))
    local w34_result = testing.run_fake(department(github), event(w34))
    local creates = {}
    for _, result in ipairs({ w33_result, w34_result }) do
      for _, request in ipairs(raises_for(result, "github-proxy.github_issue_create_request")) do
        creates[#creates + 1] = request
      end
    end
    t.eq(#creates, 2)
    local by_week = {}
    for _, request in ipairs(creates) do
      t.is_true(request.dedup_key:find("/sha256-", 1, true) ~= nil)
      t.is_true(request.dedup_key:sub(-#"/create/cycle-1") == "/create/cycle-1")
      local created = assert(core.parse_proposal(request.body))
      by_week[created.week] = created
    end
    t.eq(#assert(by_week["2026-W33"]).signals, 3)
    t.eq(#assert(by_week["2026-W34"]).signals, 1)
    t.eq(#raises_for(w33_result, "x-publisher.x_publish_request"), 0)
    t.eq(#raises_for(w34_result, "x-publisher.x_publish_request"), 0)
    t.eq(#raises_for(w33_result, "x-publisher.x_published"), 0)
    t.eq(#raises_for(w34_result, "x-publisher.x_published"), 0)
  end,

  test_rc2_compatibility_rejects_non_exact_marker_variants = function()
    for index, variant in ipairs({ "foreign", "leading-zero", "duplicate" }) do
      local source = signal_issue(270 + index * 3)
      local legacy, legacy_group = rc2_legacy_review(
        source.number + 1, source, "CLOSED", 1, true)
      if variant == "foreign" then
        local foreign_group = rc2_legacy_group(classified(
          signal_issue(source.number + 2, "another-project")))
        legacy.body = replace_once(legacy.body, legacy_group, foreign_group)
      elseif variant == "leading-zero" then
        legacy.body = replace_once(legacy.body, "/create/cycle-1", "/create/cycle-01")
      else
        local marker = "<!-- fkst:github-proxy:issue-create:"
          .. legacy_group .. "/create/cycle-1 -->"
        legacy.body = legacy.body .. "\n" .. marker
      end
      local issues = { [source.number] = source, [legacy.number] = legacy }
      local github = {}
      function github.read_issue(ref, _options)
        return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
      end
      function github.api_paginate_slurp(path, _timeout)
        return tostring(path):find("state=all", 1, true)
          and { row(source), row(legacy) } or { row(source) }
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
      t.is_true(comments[1].body:find("active-review-invalid:proposal-create-provenance-", 1, true)
        ~= nil)
    end
  end,

  test_foreign_exact_rc2_history_does_not_poison_current_group = function()
    local source = signal_issue(282)
    local foreign_source = signal_issue(283, "another-project")
    local foreign_legacy = rc2_legacy_review(284, foreign_source, "CLOSED", 1, true)
    local issues = {
      [source.number] = source,
      [foreign_source.number] = foreign_source,
      [foreign_legacy.number] = foreign_legacy,
    }
    local github = {}
    function github.read_issue(ref, _options)
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    function github.api_paginate_slurp(path, _timeout)
      return tostring(path):find("state=all", 1, true)
        and { row(source), row(foreign_legacy) } or { row(source) }
    end

    local result = testing.run_fake(department(github), event(source))
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.is_true(creates[1].dedup_key:sub(-#"/create/cycle-1") == "/create/cycle-1")
  end,

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
