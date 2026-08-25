local core = require("core")
local testing = require("testkit.testing")
local t = fkst.test

local repo = "owner/repo"
local W33_EPOCH = 1786320000
local W35_EPOCH = 1787529600

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

local function signal_issue(number, overrides)
  local values = {
    account = "test_primary",
    action = "add",
    author_login = "test-operator",
    contract = "marketing-radar.radar-signal.v2",
    topic = "publishing-gap",
    week = "2026-W33",
  }
  for key, value in pairs(overrides or {}) do values[key] = value end
  local lines = {
    "contract: " .. values.contract,
    "type: radar-signal",
    "project: chronoai",
    "account: " .. values.account,
    "work-label: auto-x-test-primary",
    "week: " .. values.week,
    "action: " .. values.action,
    "topic: " .. values.topic,
    "insight: Use cited evidence in the reviewed draft.",
  }
  if values.target_ref ~= nil then
    lines[#lines + 1] = "target-ref: " .. values.target_ref
  end
  return {
    number = number,
    body = table.concat(lines, "\n"),
    state = "OPEN",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = values.author_login,
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

local function rows_for(issues, state)
  local numbers = {}
  for number, _ in pairs(issues) do numbers[#numbers + 1] = number end
  table.sort(numbers)
  local rows = {}
  for _, number in ipairs(numbers) do
    local issue = issues[number]
    if state == "all" or tostring(issue.state):upper() == "OPEN" then
      rows[#rows + 1] = row(issue)
    end
  end
  return rows
end

local function github_port(issues)
  local github = {}
  function github.read_issue(ref, _options)
    return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
  end
  function github.api_paginate_slurp(path, _timeout)
    return rows_for(issues, tostring(path):find("state=all", 1, true) and "all" or "open")
  end
  return github
end

local function successful_draft(signals, revision)
  local evidence = {}
  for _, signal in ipairs(signals) do evidence[#evidence + 1] = signal.source_ref.ref end
  return {
    revision = revision,
    action = signals[1].action,
    target_ref = signals[1].target_ref,
    evidence_refs = evidence,
    tweet_text = "A reviewed weekly update is ready for explicit scheduling approval.",
  }
end

local function department(github, options)
  local values = options or {}
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
    draft_generator = values.draft_generator or successful_draft,
    clock = values.clock,
    past_week_migration_refs = values.past_week_migration_refs,
    evaluate_week_group = values.evaluate_week_group,
  })
end

local function raises_for(result, queue)
  local values = {}
  for _, raised in ipairs(result.raises or {}) do
    t.is_nil(tostring(raised.queue):find("x_publish", 1, true))
    t.is_nil(tostring(raised.queue):find("publish_x", 1, true))
    if raised.queue == queue or raised.queue == "marketing-radar." .. queue then
      values[#values + 1] = raised.payload
    end
  end
  return values
end

local function classified(signal)
  return assert(core.classify_issue(event(signal).payload, {
    session = session(),
    issue_body = signal.body,
    issue_labels = signal.labels,
    issue_assignees = signal.assignees,
    issue_author_login = signal.author_login,
    authorized_signal_authors = { "test-operator" },
  }))
end

local function review_issue_for_signals(number, signals, command, reason)
  local imported = {}
  for _, signal in ipairs(signals) do imported[#imported + 1] = classified(signal) end
  local proposal = assert(core.build_proposal(imported, session(), successful_draft(imported, 1)))
  local request = assert(core.weekly_plan_change_issue_request(proposal, session(), 1))
  local command_body = "/marketing " .. command .. " " .. proposal.proposal_id .. "@1 "
    .. proposal.proposal_digest
  if reason ~= nil then command_body = command_body .. " " .. reason end
  local review = {
    number = number,
    body = request.body .. "\n\n<!-- fkst:github-proxy:issue-create:"
      .. request.dedup_key .. " -->",
    state = "OPEN",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "fkst-test-bot",
    comments = { { id = number + 1000, author_login = "test-operator", body = command_body } },
    source_ref = source_ref(number),
  }
  return review, proposal
end

local function review_issue(number, signal, command, reason)
  return review_issue_for_signals(number, { signal }, command, reason)
end

local function add_terminal_status(review, proposal, status)
  local decision = assert(core.review_decision(review, {
    bot_login = "fkst-test-bot",
    authorized_reviewers = { "test-operator" },
  }))
  local item = {
    account = "test_primary",
    content_digest = proposal.content_digest,
    proposal_id = proposal.proposal_id,
    proposal_revision = proposal.revision,
    group_key = proposal.group_key,
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
  review.comments[#review.comments + 1] = {
    id = review.number + 2000,
    author_login = "fkst-test-bot",
    body = request.body .. "\n\n<!-- fkst:github-proxy:comment:"
      .. request.dedup_key .. " -->",
  }
end

return {
  test_default_historical_signal_is_visible_but_never_drafted = function()
    local signal = signal_issue(11)
    local clocks, drafts = 0, 0
    local result = testing.run_fake(department(github_port({ [11] = signal }), {
      clock = function() clocks = clocks + 1; return W35_EPOCH end,
      past_week_migration_refs = function() return nil end,
      draft_generator = function() drafts = drafts + 1; return nil, "must-not-run" end,
    }), event(signal))

    t.eq(clocks, 1)
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "radar_signal_imported"), 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("needs-triage: stale-signal-week", 1, true) ~= nil)
    t.is_nil(comments[1].dedup_key:find("/v2/triage/", 1, true))
  end,

  test_historical_group_migration_requires_complete_atomic_allowlist = function()
    local first, second = signal_issue(21), signal_issue(22)
    local issues = { [21] = first, [22] = second }
    local partial_clocks, partial_drafts = 0, 0
    local partial = testing.run_fake(department(github_port(issues), {
      clock = function() partial_clocks = partial_clocks + 1; return W35_EPOCH end,
      past_week_migration_refs = function() return "owner/repo#issue/21" end,
      draft_generator = function() partial_drafts = partial_drafts + 1; return nil, "must-not-run" end,
    }), event(first))
    t.eq(partial_clocks, 1)
    t.eq(partial_drafts, 0)
    t.eq(#raises_for(partial, "radar_signal_imported"), 0)
    t.eq(#raises_for(partial, "github-proxy.github_issue_create_request"), 0)
    local partial_comments = raises_for(partial, "github-proxy.github_issue_comment_request")
    t.eq(#partial_comments, 1)
    t.is_true(partial_comments[1].body:find("stale-signal-week", 1, true) ~= nil)
    t.is_nil(partial_comments[1].dedup_key:find("/v2/triage/", 1, true))

    local complete_clocks, complete_drafts = 0, 0
    local complete = testing.run_fake(department(github_port(issues), {
      clock = function() complete_clocks = complete_clocks + 1; return W35_EPOCH end,
      past_week_migration_refs = function()
        return "owner/repo#issue/21,owner/repo#issue/22"
      end,
      draft_generator = function(signals, revision)
        complete_drafts = complete_drafts + 1
        return successful_draft(signals, revision)
      end,
    }), event(first))
    t.eq(complete_clocks, 1)
    t.eq(complete_drafts, 1)
    t.eq(#raises_for(complete, "radar_signal_imported"), 1)
    t.eq(#raises_for(complete, "github-proxy.github_issue_create_request"), 1)
  end,

  test_fresh_signal_set_rechecks_policy_without_durable_failure_marker = function()
    local signal = signal_issue(31)
    local clocks, migrations, evaluations, drafts = 0, 0, 0, 0
    local result = testing.run_fake(department(github_port({ [31] = signal }), {
      clock = function() clocks = clocks + 1; return W33_EPOCH end,
      past_week_migration_refs = function() migrations = migrations + 1; return nil end,
      evaluate_week_group = function(signals, options)
        evaluations = evaluations + 1
        t.is_true(#signals >= 1)
        t.eq(options.reference_epoch_seconds, W33_EPOCH)
        if evaluations == 3 then return nil, "stale-signal-week" end
        return { status = "eligible", historical = false }, nil
      end,
      draft_generator = function() drafts = drafts + 1; return nil, "must-not-run" end,
    }), event(signal))

    t.eq(clocks, 1)
    t.eq(migrations, 1)
    t.eq(evaluations, 3)
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "radar_signal_imported"), 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("stale-signal-week", 1, true) ~= nil)
    t.is_nil(comments[1].dedup_key:find("/v2/triage/", 1, true))
  end,

  test_existing_identity_and_author_errors_win_without_reading_week_configuration = function()
    local cases = {
      { number = 41, overrides = { account = "test_secondary" }, reason = "account-session-mismatch" },
      { number = 42, overrides = { contract = "marketing-radar.radar-signal.v1" }, reason = "invalid-v2-contract" },
      { number = 43, overrides = { author_login = "untrusted-operator" }, reason = "unauthorized-signal-author" },
    }
    for _, case in ipairs(cases) do
      local signal = signal_issue(case.number, case.overrides)
      local clocks, migrations = 0, 0
      local result = testing.run_fake(department(github_port({ [signal.number] = signal }), {
        clock = function() clocks = clocks + 1; error("must-not-run") end,
        past_week_migration_refs = function()
          migrations = migrations + 1
          error("must-not-run")
        end,
      }), event(signal))

      t.eq(clocks, 0)
      t.eq(migrations, 0)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_true(comments[1].body:find(case.reason, 1, true) ~= nil)
    end
  end,

  test_stale_approve_and_request_changes_block_without_migration_override = function()
    for index, command in ipairs({ "approve", "request-changes" }) do
      local signal = signal_issue(50 + index * 10)
      local review = review_issue(signal.number + 1, signal, command,
        command == "request-changes" and "Add release evidence." or nil)
      local issues = { [signal.number] = signal, [review.number] = review }
      local drafts = 0
      local result = testing.run_fake(department(github_port(issues), {
        clock = function() return W35_EPOCH end,
        past_week_migration_refs = function() return nil end,
        draft_generator = function() drafts = drafts + 1; return nil, "must-not-run" end,
      }), event(review))

      t.eq(drafts, 0)
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_true(comments[1].body:find("blocked: stale-signal-week", 1, true) ~= nil)
    end
  end,

  test_complete_migration_override_allows_stale_approve_and_request_changes = function()
    for index, command in ipairs({ "approve", "request-changes" }) do
      local signal = signal_issue(90 + index * 10)
      local review = review_issue(signal.number + 1, signal, command,
        command == "request-changes" and "Add release evidence." or nil)
      local issues = { [signal.number] = signal, [review.number] = review }
      local drafts = 0
      local result = testing.run_fake(department(github_port(issues), {
        clock = function() return W35_EPOCH end,
        past_week_migration_refs = function() return signal.source_ref.ref end,
        draft_generator = function(signals, revision)
          drafts = drafts + 1
          return successful_draft(signals, revision)
        end,
      }), event(review))

      local creates = raises_for(result, "github-proxy.github_issue_create_request")
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      if command == "approve" then
        t.eq(drafts, 0)
        t.eq(#creates, 1)
        t.eq(#comments, 1)
        t.is_true(comments[1].body:find("awaiting-materialization", 1, true) ~= nil)
      else
        t.eq(drafts, 1)
        t.eq(#creates, 0)
        t.eq(#comments, 2)
        t.is_true(comments[2].body:find("proposal revision 2 generated", 1, true) ~= nil)
      end
    end
  end,

  test_review_of_historical_signal_set_requires_every_ref_in_allowlist = function()
    local first, second = signal_issue(121), signal_issue(122)
    local review = review_issue_for_signals(
      123, { first, second }, "approve", nil)
    local issues = { [121] = first, [122] = second, [123] = review }
    local drafts = 0
    local result = testing.run_fake(department(github_port(issues), {
      clock = function() return W35_EPOCH end,
      past_week_migration_refs = function() return first.source_ref.ref end,
      draft_generator = function() drafts = drafts + 1; return nil, "must-not-run" end,
    }), event(review))

    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("blocked: stale-signal-week", 1, true) ~= nil)
  end,

  test_invalid_clock_and_malformed_migration_refs_never_call_ai_or_create = function()
    local cases = {
      {
        number = 131,
        reason = "invalid-reference-week",
        clock = function() return "not-an-epoch" end,
        migration = function() return nil end,
      },
      {
        number = 132,
        reason = "invalid-migration-source-ref",
        clock = function() return W35_EPOCH end,
        migration = function() return "not-a-canonical-source-ref" end,
      },
      {
        number = 133,
        reason = "invalid-migration-source-ref",
        clock = function() return W35_EPOCH end,
        migration = function() error("package env unavailable") end,
      },
    }
    for _, case in ipairs(cases) do
      local signal = signal_issue(case.number)
      local drafts = 0
      local result = testing.run_fake(department(github_port({ [signal.number] = signal }), {
        clock = case.clock,
        past_week_migration_refs = case.migration,
        draft_generator = function() drafts = drafts + 1; return nil, "must-not-run" end,
      }), event(signal))
      t.eq(drafts, 0)
      t.eq(#raises_for(result, "radar_signal_imported"), 0)
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_true(comments[1].body:find(case.reason, 1, true) ~= nil)
      t.is_nil(comments[1].dedup_key:find("/v2/triage/", 1, true))
    end
  end,

  test_historical_revise_and_replan_remain_blocked_with_complete_allowlist = function()
    for index, action in ipairs({ "revise", "replan" }) do
      local signal = signal_issue(140 + index, {
        action = action,
        target_ref = action == "revise" and "content-42" or nil,
      })
      local drafts = 0
      local result = testing.run_fake(department(github_port({ [signal.number] = signal }), {
        clock = function() return W35_EPOCH end,
        past_week_migration_refs = function() return signal.source_ref.ref end,
        draft_generator = function() drafts = drafts + 1; return nil, "must-not-run" end,
      }), event(signal))
      t.eq(drafts, 0)
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      t.is_true(comments[1].body:find("historical-signal-requires-add", 1, true) ~= nil)
      t.is_nil(comments[1].dedup_key:find("/v2/triage/", 1, true))
    end
  end,

  test_coo_w33_w34_shadow_defaults_to_four_stale_acks_then_two_migrated_proposals = function()
    local signals = {
      [116] = signal_issue(116, { topic = "publishing-gap", week = "2026-W33" }),
      [117] = signal_issue(117, { topic = "publishing-gap", week = "2026-W33" }),
      [118] = signal_issue(118, { topic = "publishing-gap", week = "2026-W33" }),
      [124] = signal_issue(124, { topic = "content-supply-gap", week = "2026-W34" }),
    }
    local default_drafts, stale_acks = 0, 0
    for _, number in ipairs({ 116, 117, 118, 124 }) do
      local result = testing.run_fake(department(github_port(signals), {
        clock = function() return W35_EPOCH end,
        past_week_migration_refs = function() return nil end,
        draft_generator = function() default_drafts = default_drafts + 1; return nil, "must-not-run" end,
      }), event(signals[number]))
      t.eq(#raises_for(result, "radar_signal_imported"), 0)
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1)
      if comments[1].body:find("stale-signal-week", 1, true) ~= nil then
        stale_acks = stale_acks + 1
      end
      t.is_true(comments[1].body:find("publish_attempted: false", 1, true) ~= nil)
    end
    t.eq(default_drafts, 0)
    t.eq(stale_acks, 4)

    local allowlist = table.concat({
      signals[116].source_ref.ref,
      signals[117].source_ref.ref,
      signals[118].source_ref.ref,
      signals[124].source_ref.ref,
    }, ",")
    local migrated_drafts, proposals = 0, {}
    for _, number in ipairs({ 116, 124 }) do
      local result = testing.run_fake(department(github_port(signals), {
        clock = function() return W35_EPOCH end,
        past_week_migration_refs = function() return allowlist end,
        draft_generator = function(group, revision)
          migrated_drafts = migrated_drafts + 1
          return successful_draft(group, revision)
        end,
      }), event(signals[number]))
      t.eq(#raises_for(result, "radar_signal_imported"), 1)
      for _, raised in ipairs(result.raises or {}) do
        local queue = tostring(raised.queue or "")
        t.is_nil(queue:find("schedule", 1, true))
        t.is_nil(queue:find("x_publish", 1, true))
        t.is_nil(queue:find("publish_x", 1, true))
      end
      local creates = raises_for(result, "github-proxy.github_issue_create_request")
      t.eq(#creates, 1)
      proposals[#proposals + 1] = creates[1]
    end
    t.eq(migrated_drafts, 2)
    t.eq(#proposals, 2)
    t.is_true(proposals[1].body:find(signals[116].source_ref.ref, 1, true) ~= nil)
    t.is_true(proposals[1].body:find(signals[117].source_ref.ref, 1, true) ~= nil)
    t.is_true(proposals[1].body:find(signals[118].source_ref.ref, 1, true) ~= nil)
    t.is_true(proposals[2].body:find(signals[124].source_ref.ref, 1, true) ~= nil)
  end,

  test_stale_reject_terminates_without_reading_malformed_migration_env = function()
    local signal = signal_issue(71)
    local review = review_issue(72, signal, "reject", "Evidence is insufficient.")
    local issues = { [71] = signal, [72] = review }
    local clocks, migrations = 0, 0
    local result = testing.run_fake(department(github_port(issues), {
      clock = function() clocks = clocks + 1; return W35_EPOCH end,
      past_week_migration_refs = function()
        migrations = migrations + 1
        error("malformed migration env")
      end,
    }), event(review))

    t.eq(clocks, 0)
    t.eq(migrations, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 2)
    for _, comment in ipairs(comments) do t.eq(comment.handoff.review_command, "reject") end
  end,

  test_terminal_review_recovery_survives_removed_historical_override = function()
    local signal = signal_issue(81)
    local review, proposal = review_issue(82, signal, "reject", "Evidence is insufficient.")
    review.state = "CLOSED"
    add_terminal_status(review, proposal, "rejected: Evidence is insufficient.")
    local issues = { [81] = signal, [82] = review }
    local clocks, migrations, drafts = 0, 0, 0
    local result = testing.run_fake(department(github_port(issues), {
      clock = function()
        clocks = clocks + 1
        error("terminal recovery must not read the clock")
      end,
      past_week_migration_refs = function()
        migrations = migrations + 1
        error("terminal recovery must not read migration authority")
      end,
      draft_generator = function() drafts = drafts + 1; return nil, "must-not-run" end,
    }), event(signal))

    t.eq(clocks, 0)
    t.eq(migrations, 0)
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "radar_signal_imported"), 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.eq(comments[1].issue_number, signal.number)
    t.eq(comments[1].handoff.review_command, "reject")
  end,

  test_migration_authority_is_event_scoped_and_does_not_leak_after_takeover = function()
    local signal = signal_issue(171)
    local issues = { [171] = signal }
    local migration_refs = signal.source_ref.ref
    local drafts = 0
    local importer = department(github_port(issues), {
      clock = function() return W35_EPOCH end,
      past_week_migration_refs = function() return migration_refs end,
      draft_generator = function(signals, revision)
        drafts = drafts + 1
        return successful_draft(signals, revision)
      end,
    })

    local migrated = testing.run_fake(importer, event(signal))
    t.eq(#raises_for(migrated, "radar_signal_imported"), 1)
    t.eq(#raises_for(migrated, "github-proxy.github_issue_create_request"), 1)
    t.eq(drafts, 1)

    migration_refs = nil
    local takeover = testing.run_fake(importer, event(signal))
    t.eq(#raises_for(takeover, "radar_signal_imported"), 0)
    t.eq(#raises_for(takeover, "github-proxy.github_issue_create_request"), 0)
    t.eq(drafts, 1)
    local comments = raises_for(takeover, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("stale-signal-week", 1, true) ~= nil)
  end,
}
