local core = require("core")
local marketing_content = require("contract.marketing_content")
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

local function signal_body(number, overrides)
  local fields = {
    contract = "marketing-radar.radar-signal.v2",
    type = "radar-signal",
    project = "chronoai",
    account = "test_primary",
    ["work-label"] = "auto-x-test-primary",
    week = "2026-W33",
    action = "add",
    topic = "FKST automation",
    ["source-url"] = "https://github.example/owner/repo/issues/" .. tostring(number),
    insight = "Use signal " .. tostring(number) .. " as cited drafting evidence.",
  }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  local lines = {}
  for _, key in ipairs({ "contract", "type", "project", "account", "work-label", "week", "action", "target-ref", "topic", "source-url", "insight" }) do
    if fields[key] ~= nil then
      lines[#lines + 1] = key .. ": " .. fields[key]
    end
  end
  return table.concat(lines, "\n")
end

local function signal_issue(number, overrides)
  local issue = {
    number = number,
    body = signal_body(number),
    state = "OPEN",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "test-operator",
    comments = {},
    source_ref = source_ref(number),
  }
  for key, value in pairs(overrides or {}) do
    issue[key] = value
  end
  return issue
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

local function rest_row(number, body, state)
  return {
    number = number,
    body = body,
    state = state or "closed",
    labels = { { name = "host-test-primary" } },
    assignees = { { login = "test-operator" } },
    user = { login = "fkst-test-bot" },
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

local function github_port(issues, catalog, all_catalog)
  local github = { reads = {} }
  function github.read_issue(ref, _options)
    github.reads[#github.reads + 1] = ref.ref
    local number = tonumber(ref.ref:match("#issue/(%d+)$"))
    return issues[number]
  end
  function github.issue_list_intake(_repo, _limit, _timeout)
    return catalog
  end
  function github.api_paginate_slurp(path, _timeout)
    if path == "repos/owner/repo/issues?state=open&per_page=100" then
      return catalog
    end
    t.eq(path, "repos/owner/repo/issues?state=all&per_page=100")
    return all_catalog or catalog
  end
  function github.issue_search(_repo, query, _fields, _timeout)
    local digest = tostring(query):match('"content_digest: (sha256:[0-9a-f]+)"')
    local matches = {}
    for number, issue in pairs(issues) do
      for _, comment in ipairs(type(issue) == "table" and issue.comments or {}) do
        local body = tostring(type(comment) == "table" and comment.body or "")
        if digest ~= nil and body:find("schema: x-publisher.publish-receipt.v2", 1, true)
            and body:find("content_digest: " .. digest, 1, true) then
          matches[#matches + 1] = { number = number }
          break
        end
      end
    end
    return matches
  end
  return github
end

local function department(github, overrides)
  local options = overrides or {}
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    session_authority = options.session_authority or session,
    route_authority = options.route_authority,
    review_options = function()
      return { bot_login = "fkst-test-bot", authorized_reviewers = { "test-operator" } }
    end,
    signal_author_logins = function()
      return { "test-operator", "test-collaborator" }
    end,
    draft_generator = options.draft_generator or function(_signals, revision)
      local evidence = {}
      for _, signal in ipairs(_signals) do
        evidence[#evidence + 1] = signal.source_ref.ref
      end
      return {
        revision = revision,
        action = _signals[1].action,
        target_ref = _signals[1].target_ref,
        evidence_refs = evidence,
        tweet_text = "FKST workflows turn reviewed signals into auditable weekly updates.",
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

local function no_publish_raises(result)
  for _, raised in ipairs(result.raises or {}) do
    t.eq(tostring(raised.queue):find("x_publish", 1, true), nil)
    t.eq(tostring(raised.queue):find("publish_x", 1, true), nil)
  end
end

return {
  test_mismatched_event_source_ref_stops_before_github_or_ai = function()
    local source = signal_issue(116)
    local github = github_port({ [116] = source }, { row(source) }, { row(source) })
    local changed = event(source)
    changed.payload.source_ref = source_ref(117)
    local drafts = 0
    local result = testing.run_fake(department(github, {
      draft_generator = function()
        drafts = drafts + 1
        return nil, "must-not-run"
      end,
    }), changed)
    t.eq(#github.reads, 0)
    t.eq(drafts, 0)
    t.eq(#result.raises, 0)
  end,

  test_three_same_week_signals_create_one_deterministic_grouped_proposal_request = function()
    local issues = {
      [116] = signal_issue(116),
      [117] = signal_issue(117),
      [118] = signal_issue(118),
    }
    local catalog = { row(issues[116]), row(issues[117]), row(issues[118]) }
    local first = testing.run_fake(department(github_port(issues, catalog)), event(issues[116]))
    local replay = testing.run_fake(department(github_port(issues, catalog)), event(issues[118]))
    local first_creates = raises_for(first, "github-proxy.github_issue_create_request")
    local replay_creates = raises_for(replay, "github-proxy.github_issue_create_request")

    t.eq(#first_creates, 1)
    t.eq(#replay_creates, 1)
    t.eq(first_creates[1].dedup_key, replay_creates[1].dedup_key)
    t.eq(select(2, first_creates[1].body:gsub("\nsignal: ", "")), 3)
    t.eq(first_creates[1].labels[1], "host-test-primary")
    t.eq(first_creates[1].assignees[1], "test-operator")
    no_publish_raises(first)
  end,

  test_staggered_signals_share_pending_group_create_dedup_before_materialization = function()
    local first_signal = signal_issue(116)
    local second_signal = signal_issue(117)
    local first = testing.run_fake(department(github_port(
      { [116] = first_signal }, { row(first_signal) }, { row(first_signal) }
    )), event(first_signal))
    local staggered = testing.run_fake(department(github_port(
      { [116] = first_signal, [117] = second_signal },
      { row(first_signal), row(second_signal) },
      { row(first_signal), row(second_signal) }
    )), event(second_signal))
    local first_create = raises_for(first, "github-proxy.github_issue_create_request")[1]
    local staggered_create = raises_for(staggered, "github-proxy.github_issue_create_request")[1]
    t.is_true(first_create ~= nil)
    t.is_true(staggered_create ~= nil)
    t.eq(first_create.dedup_key, staggered_create.dedup_key)
    t.is_true(first_create.body ~= staggered_create.body)
  end,

  test_materialized_first_wins_proposal_converges_to_union_revision = function()
    local first_signal = signal_issue(116)
    local second_signal = signal_issue(117)
    local first_result = testing.run_fake(department(github_port(
      { [116] = first_signal }, { row(first_signal) }, { row(first_signal) }
    )), event(first_signal))
    local first_create = assert(raises_for(
      first_result, "github-proxy.github_issue_create_request")[1])
    local first_proposal = assert(core.parse_proposal(first_create.body))
    local review = {
      number = 700,
      body = first_create.body,
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "app/fkst-test-bot",
      source_ref = source_ref(700),
      comments = {},
    }
    local converged = testing.run_fake(department(github_port(
      { [116] = first_signal, [117] = second_signal, [700] = review },
      { row(first_signal), row(second_signal), row(review) },
      { row(first_signal), row(second_signal), row(review) }
    )), event(second_signal))

    t.eq(#raises_for(converged, "github-proxy.github_issue_create_request"), 0)
    local union = nil
    for _, request in ipairs(raises_for(
        converged, "github-proxy.github_issue_comment_request")) do
      union = union or core.parse_proposal(request.body)
    end
    union = assert(union)
    t.eq(union.proposal_id, first_proposal.proposal_id)
    t.eq(union.revision, first_proposal.revision + 1)
    t.eq(#union.signals, 2)
    t.is_true(union.signal_set_digest ~= first_proposal.signal_set_digest)
  end,

  test_trusted_body_action_conflict_enters_triage_without_proposal = function()
    local source = signal_issue(125, {
      body = signal_body(125) .. "\n\nOperator narrative: replan every unpublished item this week.",
    })
    local result = testing.run_fake(department(
      github_port({ [125] = source }, { row(source) }, { row(source) }), {
        draft_generator = function(signals)
          t.is_true(signals[1].trusted_body_context:find(
            "replan every unpublished item", 1, true) ~= nil)
          return nil, "semantic-conflict:body requests replan while action is add"
        end,
      }
    ), event(source))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("needs-triage: semantic-conflict", 1, true) ~= nil)
    no_publish_raises(result)
  end,

  test_w33_116_to_118_and_w34_124_create_exactly_two_shadow_proposals = function()
    local issues = {
      [116] = signal_issue(116),
      [117] = signal_issue(117),
      [118] = signal_issue(118),
      [124] = signal_issue(124, { body = signal_body(124, { week = "2026-W34" }) }),
    }
    local catalog = {
      row(issues[116]), row(issues[117]), row(issues[118]), row(issues[124]),
    }
    local w33 = testing.run_fake(department(github_port(issues, catalog)), event(issues[116]))
    local w34 = testing.run_fake(department(github_port(issues, catalog)), event(issues[124]))
    local w33_creates = raises_for(w33, "github-proxy.github_issue_create_request")
    local w34_creates = raises_for(w34, "github-proxy.github_issue_create_request")
    t.eq(#w33_creates + #w34_creates, 2)
    t.eq(assert(core.parse_proposal(w33_creates[1].body)).week, "2026-W33")
    t.eq(assert(core.parse_proposal(w34_creates[1].body)).week, "2026-W34")
    no_publish_raises(w33)
    no_publish_raises(w34)
  end,

  test_closed_proposal_does_not_block_new_signal_set_from_creating_a_new_review = function()
    local old_signal = signal_issue(116)
    local new_signal = signal_issue(119)
    local old_result = testing.run_fake(
      department(github_port(
        { [116] = old_signal }, { row(old_signal) }, { row(old_signal) }
      )), event(old_signal))
    local old_create = raises_for(old_result, "github-proxy.github_issue_create_request")[1]
    local old_review = {
      number = 700, body = old_create.body, state = "CLOSED",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", source_ref = source_ref(700), comments = {},
    }
    local new_result = testing.run_fake(
      department(github_port(
        { [119] = new_signal }, { row(new_signal) }, { row(new_signal), row(old_review) }
      )), event(new_signal))
    local new_create = raises_for(new_result, "github-proxy.github_issue_create_request")[1]
    local old_proposal = assert(core.parse_proposal(old_create.body))
    local new_proposal = assert(core.parse_proposal(new_create.body))
    t.is_true(old_proposal.proposal_id ~= new_proposal.proposal_id)
    t.is_true(old_create.dedup_key ~= new_create.dedup_key)
  end,

  test_paginated_existing_review_makes_unchanged_replay_a_zero_ai_noop = function()
    local source = signal_issue(116)
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "add", evidence_refs = { classified.source_ref.ref },
      tweet_text = "A stable reviewed proposal.",
    }))
    local review_request = core.weekly_plan_change_issue_request(proposal, session())
    local review = {
      number = 700, body = review_request.body, state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "app/fkst-test-bot", source_ref = source_ref(700), comments = {},
    }
    local first_page = { row(source) }
    for number = 200, 298 do
      first_page[#first_page + 1] = {
        number = number, body = "type: unrelated", state = "open",
        labels = {}, assignees = {}, author = { login = "test-operator" },
      }
    end
    t.eq(#first_page, 100)
    local result = testing.run_fake(department(github_port(
      { [116] = source, [700] = review }, { first_page, { row(review) } }
    ), {
      draft_generator = function()
        error("unchanged replay must not call Codex")
      end,
    }), event(source))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_comment_request"), 1)
    no_publish_raises(result)
  end,

  test_triage_and_account_mismatch_never_create_proposal = function()
    local conflict = signal_issue(120, { body = signal_body(120, { ["target-ref"] = "#99" }) })
    local mismatch = signal_issue(121, { body = signal_body(121, { account = "test_secondary" }) })
    local conflict_result = testing.run_fake(department(github_port({ [120] = conflict }, { row(conflict) })), event(conflict))
    local mismatch_result = testing.run_fake(department(github_port({ [121] = mismatch }, { row(mismatch) })), event(mismatch))

    t.eq(#raises_for(conflict_result, "github-proxy.github_issue_create_request"), 0)
    t.eq(#raises_for(conflict_result, "github-proxy.github_issue_comment_request"), 1)
    t.eq(#raises_for(mismatch_result, "github-proxy.github_issue_create_request"), 0)
    local mismatch_comments = raises_for(mismatch_result, "github-proxy.github_issue_comment_request")
    t.eq(#mismatch_comments, 1)
    t.is_true(mismatch_comments[1].body:find(
      "needs-triage: account-session-mismatch", 1, true) ~= nil)
    t.is_true(mismatch_comments[1].body:find("publish_attempted: false", 1, true) ~= nil)
    no_publish_raises(conflict_result)
    no_publish_raises(mismatch_result)
  end,

  test_missing_profile_is_visible_only_when_the_issue_is_safely_routed = function()
    local source = signal_issue(125)
    local missing_account = function()
      return nil, "missing-session-account"
    end
    local routed = testing.run_fake(department(github_port(
      { [125] = source }, { row(source) }
    ), {
      session_authority = missing_account,
      route_authority = function()
        return {
          effective_work_label = "host-test-primary",
          logical_work_label = "auto-x-test-primary",
          creator = "test-operator",
        }
      end,
    }), event(source))
    local comments = raises_for(routed, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("blocked/unrouted", 1, true) ~= nil)
    t.is_true(comments[1].body:find("publish_attempted: false", 1, true) ~= nil)

    local host_owned = signal_issue(126, { labels = { "other-session" } })
    local unrouted = testing.run_fake(department(github_port(
      { [126] = host_owned }, { row(host_owned) }
    ), {
      session_authority = missing_account,
      route_authority = function()
        return {
          effective_work_label = "host-test-primary",
          logical_work_label = "auto-x-test-primary",
          creator = "test-operator",
        }
      end,
    }), event(host_owned))
    t.eq(#raises_for(unrouted, "github-proxy.github_issue_comment_request"), 0)
    no_publish_raises(routed)
    no_publish_raises(unrouted)
  end,

  test_approval_waits_for_trusted_materialization_before_terminal_comments = function()
    local source = signal_issue(116)
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(),
      issue_body = source.body,
      issue_labels = source.labels,
      issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "add",
      evidence_refs = { classified.source_ref.ref },
      tweet_text = "A reviewed test_primary acceptance update.",
    }))
    local request = core.weekly_plan_change_issue_request(proposal, session())
    local review = {
      number = 130,
      body = request.body,
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      source_ref = source_ref(130),
      comments = {
        { id = 91, author_login = "test-operator", body = "/marketing approve "
          .. proposal.proposal_id .. "@" .. proposal.revision },
      },
    }
    local first = testing.run_fake(department(github_port(
      { [116] = source, [130] = review }, { row(source), row(review) }
    )), event(review))
    local creates = raises_for(first, "github-proxy.github_issue_create_request")
    local first_comments = raises_for(first, "github-proxy.github_issue_comment_request")

    t.eq(#creates, 1)
    t.is_true(creates[1].body:find("contract: auto-twitter-marketing.weekly-content.v2", 1, true) ~= nil)
    t.is_true(creates[1].body:find("content-status: approved", 1, true) ~= nil)
    t.eq(#first_comments, 1)
    t.is_nil(first_comments[1].handoff)

    local content_number = 150
    review.comments[#review.comments + 1] = {
      id = 93,
      author_login = "fkst-test-bot",
      body = 'Opened sub-issue #150 for this task.\n\n<!-- fkst:github-proxy:issue-created:v1 dedup="'
        .. creates[1].dedup_key .. '" issue="150" -->',
    }
    local content = {
      number = content_number,
      body = creates[1].body,
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      source_ref = source_ref(content_number),
      comments = {},
    }
    local pending = testing.run_fake(department(github_port(
      { [116] = source, [130] = review, [150] = content }, { row(source), row(review), row(content) }
    )), event(review))
    local pending_comments = raises_for(pending, "github-proxy.github_issue_comment_request")
    t.eq(#pending_comments, 1)
    t.is_true(pending_comments[1].body:find("awaiting-content-import", 1, true) ~= nil)

    content.state = "CLOSED"
    local replay = testing.run_fake(department(github_port(
      { [116] = source, [130] = review, [150] = content }, { row(source), row(review) }
    )), event(review))
    local replay_comments = raises_for(replay, "github-proxy.github_issue_comment_request")
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 0)
    t.eq(#replay_comments, 2)
    t.is_true(replay_comments[1].handoff ~= nil)
    t.is_true(replay_comments[2].handoff ~= nil)
    no_publish_raises(first)
    no_publish_raises(pending)
    no_publish_raises(replay)
  end,

  test_unauthorized_and_stale_review_commands_create_no_content = function()
    local source = signal_issue(116)
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "add",
      evidence_refs = { classified.source_ref.ref },
      tweet_text = "A reviewed update.",
    }))
    local request = core.weekly_plan_change_issue_request(proposal, session())
    for _, command in ipairs({
      { author = "outsider", revision = proposal.revision },
      { author = "test-operator", revision = 99 },
    }) do
      local review = {
        number = 131,
        body = request.body,
        state = "OPEN",
        labels = { "host-test-primary" },
        assignees = { "test-operator" },
        author_login = "fkst-test-bot",
        source_ref = source_ref(131),
        comments = {
          { id = 92, author_login = command.author, body = "/marketing approve "
            .. proposal.proposal_id .. "@" .. command.revision },
        },
      }
      local result = testing.run_fake(department(github_port({ [131] = review }, { row(review) })), event(review))
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
      no_publish_raises(result)
    end
  end,

  test_approve_fails_closed_when_signal_changed_or_same_group_signal_arrived = function()
    local original = signal_issue(116)
    local classified = assert(core.classify_issue(event(original).payload, {
      session = session(), issue_body = original.body,
      issue_labels = original.labels, issue_assignees = original.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "add", evidence_refs = { classified.source_ref.ref },
      tweet_text = "An approval candidate bound to one signal version.",
    }))
    local request = core.weekly_plan_change_issue_request(proposal, session())
    local function review_issue_for(number)
      return {
        number = number, body = request.body, state = "OPEN",
        labels = { "host-test-primary" }, assignees = { "test-operator" },
        author_login = "fkst-test-bot", source_ref = source_ref(number),
        comments = { { id = 801, author_login = "test-operator", body = "/marketing approve "
          .. proposal.proposal_id .. "@" .. proposal.revision } },
      }
    end

    local edited = signal_issue(116, {
      body = signal_body(116, { insight = "The business instruction changed before approval." }),
    })
    local edited_review = review_issue_for(810)
    local edited_result = testing.run_fake(department(github_port(
      { [116] = edited, [810] = edited_review }, { row(edited), row(edited_review) }
    )), event(edited_review))
    t.eq(#raises_for(edited_result, "github-proxy.github_issue_create_request"), 0)

    local added = signal_issue(117)
    local added_review = review_issue_for(811)
    local added_result = testing.run_fake(department(github_port(
      { [116] = original, [117] = added, [811] = added_review },
      { row(original), row(added), row(added_review) }
    )), event(added_review))
    t.eq(#raises_for(added_result, "github-proxy.github_issue_create_request"), 0)
    t.is_true(raises_for(added_result, "github-proxy.github_issue_comment_request")[1].body
      :find("signal-set-changed-during-review", 1, true) ~= nil)
    no_publish_raises(edited_result)
    no_publish_raises(added_result)
  end,

  test_request_changes_generates_next_revision_and_keeps_review_open = function()
    local source = signal_issue(116)
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "add",
      evidence_refs = { classified.source_ref.ref },
      tweet_text = "The first reviewed draft.",
    }))
    local request = core.weekly_plan_change_issue_request(proposal, session())
    local review = {
      number = 135,
      body = request.body,
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      source_ref = source_ref(135),
      comments = {
        { id = 94, author_login = "test-operator", body = "/marketing request-changes "
          .. proposal.proposal_id .. "@" .. proposal.revision .. " Add release evidence." },
      },
    }
    local result = testing.run_fake(department(github_port(
      { [116] = source, [135] = review }, { row(source), row(review) }
    )), event(review))
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    t.eq(#comments, 2)
    local next_proposal = core.parse_proposal(comments[1].body)
    if next_proposal == nil then
      next_proposal = assert(core.parse_proposal(comments[2].body))
    end
    t.eq(next_proposal.revision, proposal.revision + 1)
    t.eq(next_proposal.proposal_id, proposal.proposal_id)
    t.is_nil(comments[1].handoff)
    t.is_nil(comments[2].handoff)
    no_publish_raises(result)
  end,

  test_reject_emits_terminal_handoffs_for_review_and_all_signals_without_content = function()
    local source = signal_issue(136)
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "add", evidence_refs = { classified.source_ref.ref },
      tweet_text = "A proposal that the reviewer rejects.",
    }))
    local request = core.weekly_plan_change_issue_request(proposal, session())
    local review = {
      number = 137, body = request.body, state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", source_ref = source_ref(137),
      comments = { { id = 97, author_login = "test-operator", body = "/marketing reject "
        .. proposal.proposal_id .. "@" .. proposal.revision .. " Evidence is insufficient." } },
    }
    local result = testing.run_fake(department(github_port(
      { [136] = source, [137] = review }, { row(source), row(review) }, { row(source), row(review) }
    )), event(review))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 2)
    local kinds = {}
    for _, comment in ipairs(comments) do
      t.eq(comment.handoff.review_command, "reject")
      t.eq(comment.handoff.review_comment_id, 97)
      kinds[comment.handoff.kind] = true
    end
    t.is_true(kinds["weekly-plan-change"])
    t.is_true(kinds["radar-signal"])
    no_publish_raises(result)
  end,

  test_replan_fails_closed_when_state_all_catalog_has_malformed_fields = function()
    local source = signal_issue(140, { body = signal_body(140, { action = "replan" }) })
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "replan",
      evidence_refs = { classified.source_ref.ref },
      tweet_text = "A fully reviewed replacement plan.",
    }))
    local request = core.weekly_plan_change_issue_request(proposal, session())
    local review = {
      number = 141,
      body = request.body,
      state = "OPEN",
      labels = { "host-test-primary" },
      assignees = { "test-operator" },
      author_login = "fkst-test-bot",
      source_ref = source_ref(141),
      comments = {
        { id = 95, author_login = "test-operator", body = "/marketing approve "
          .. proposal.proposal_id .. "@" .. proposal.revision },
      },
    }
    local content_request = core.approved_weekly_content_issue_request(proposal, session())
    review.comments[#review.comments + 1] = {
      id = 96,
      author_login = "fkst-test-bot",
      body = '<!-- fkst:github-proxy:issue-created:v1 dedup="' .. content_request.dedup_key
        .. '" issue="142" -->',
    }
    local content = {
      number = 142, body = content_request.body, state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", source_ref = source_ref(142), comments = {},
    }
    local malformed_catalog = {
      { number = 201, body = "", state = "closed", labels = {}, assignees = {} },
    }
    local failure = testing.run_fake_expecting_failure(
      department(github_port(
        { [140] = source, [141] = review, [142] = content }, { row(source), row(review) }, malformed_catalog
      )), event(review))
    t.is_true(tostring(failure.failure.error):find(
      "issue catalog contains malformed issue fields", 1, true) ~= nil)
  end,

  test_revise_waits_for_durable_supersession_before_terminal_ack = function()
    local old_body = assert(marketing_content.render({
      project = "chronoai", account = "test_primary", work_label = "auto-x-test-primary",
      week = "2026-W33", content_id = "content-old", content_revision = 1,
      proposal_id = "proposal-old", proposal_revision = 1, approval_id = "proposal-old@1",
      content_status = "approved", tweet_text = "The previous unpublished content.",
    }))
    local old_content = {
      number = 41, body = old_body, state = "CLOSED",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "app/fkst-test-bot", source_ref = source_ref(41), comments = {},
    }
    local source = signal_issue(170, {
      body = signal_body(170, { action = "revise", ["target-ref"] = "#41" }),
    })
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "revise", target_ref = "#41",
      evidence_refs = { classified.source_ref.ref },
      tweet_text = "The approved replacement for the previous unpublished content.",
    }, { content_id = "content-old", content_revision = 2 }))
    local review_request = core.weekly_plan_change_issue_request(proposal, session())
    local review = {
      number = 171, body = review_request.body, state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", source_ref = source_ref(171),
      comments = { { id = 98, author_login = "test-operator", body = "/marketing approve "
        .. proposal.proposal_id .. "@" .. proposal.revision } },
    }
    local content_request = core.approved_weekly_content_issue_request(proposal, session())
    review.comments[#review.comments + 1] = {
      id = 99, author_login = "fkst-test-bot",
      body = '<!-- fkst:github-proxy:issue-created:v1 dedup="' .. content_request.dedup_key
        .. '" issue="172" -->',
    }
    local replacement = {
      number = 172, body = content_request.body, state = "CLOSED",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", source_ref = source_ref(172), comments = {},
    }
    local issues = {
      [41] = old_content, [170] = source, [171] = review, [172] = replacement,
    }
    local open_catalog = { row(source), row(review) }
    local all_catalog = { rest_row(41, old_body), rest_row(172, content_request.body) }

    local pending = testing.run_fake(department(github_port(
      issues, open_catalog, all_catalog
    )), event(review))
    local pending_comments = raises_for(pending, "github-proxy.github_issue_comment_request")
    t.eq(#pending_comments, 2)
    local marker_request = nil
    for _, request in ipairs(pending_comments) do
      if request.issue_number == 41 then marker_request = request end
      t.is_nil(request.handoff)
    end
    t.is_true(marker_request ~= nil)
    t.is_true(marker_request.body:find("content-superseded:v2", 1, true) ~= nil)

    old_content.comments[#old_content.comments + 1] = {
      id = 100, author_login = "app/fkst-test-bot", body = marker_request.body,
    }
    local replay = testing.run_fake(department(github_port(
      issues, open_catalog, all_catalog
    )), event(review))
    local replay_comments = raises_for(replay, "github-proxy.github_issue_comment_request")
    t.eq(#replay_comments, 2)
    for _, request in ipairs(replay_comments) do
      t.is_true(request.handoff ~= nil)
      t.is_true(request.issue_number ~= 41)
    end
    t.eq(#raises_for(pending, "github-proxy.github_issue_create_request"), 0)
    t.eq(#raises_for(replay, "github-proxy.github_issue_create_request"), 0)
    no_publish_raises(pending)
    no_publish_raises(replay)
  end,

  test_published_revision_target_enters_triage_without_creating_content = function()
    local source = signal_issue(160, { body = signal_body(160, { action = "revise", ["target-ref"] = "#41" }) })
    local classified = assert(core.classify_issue(event(source).payload, {
      session = session(), issue_body = source.body,
      issue_labels = source.labels, issue_assignees = source.assignees,
    }))
    local proposal = assert(core.build_proposal({ classified }, session(), {
      action = "revise",
      target_ref = "#41",
      evidence_refs = { classified.source_ref.ref },
      tweet_text = "A reviewed revision draft.",
    }, { content_id = "content-old", content_revision = 2 }))
    local request = core.weekly_plan_change_issue_request(proposal, session())
    local review = {
      number = 161, body = request.body, state = "OPEN",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", source_ref = source_ref(161),
      comments = {
        { id = 97, author_login = "test-operator", body = "/marketing approve "
          .. proposal.proposal_id .. "@" .. proposal.revision },
      },
    }
    local old_body, old_digest = marketing_content.render({
      project = "chronoai", account = "test_primary", work_label = "auto-x-test-primary",
      week = "2026-W33", content_id = "content-old", content_revision = 1,
      proposal_id = "proposal-old", proposal_revision = 1, approval_id = "proposal-old@1",
      content_status = "approved", tweet_text = "Already published content.",
    })
    local schedule_body = table.concat({
      "contract: auto-twitter-marketing.schedule-publish.v2", "type: schedule-publish",
      "project: chronoai", "account: test_primary", "work-label: auto-x-test-primary",
      "week: 2026-W33", "content-ref: #41", "content-digest: " .. old_digest,
      "approval-id: proposal-old@1", "mode: live", "scheduled-at: 2026-08-17T08:00:00Z",
    }, "\n")
    local published_schedule = {
      number = 52, body = schedule_body, state = "CLOSED",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "fkst-test-bot", source_ref = source_ref(52),
      comments = { { author_login = "app/fkst-test-bot", body = table.concat({
        "Auto Twitter marketing: X published", "",
        "schema: x-publisher.publish-receipt.v2", "status: published",
        "account: test_primary", "authenticated_account: test_primary",
        "content_digest: " .. old_digest, "approval_id: proposal-old@1",
        "post_uri: https://x.com/i/web/status/1234567890",
        "dedup_key: auto-twitter/chronoai/test_primary/52/x-publish", "",
        "<!-- fkst:github-proxy:comment:auto-twitter/chronoai/test_primary/52/x-publish/status/x-publish-published -->",
      }, "\n") } },
    }
    local old_content = {
      number = 41, body = old_body, state = "CLOSED",
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      author_login = "app/fkst-test-bot", source_ref = source_ref(41), comments = {},
    }
    local all_pages = { {
      rest_row(41, old_body),
      rest_row(52, schedule_body),
      { number = 999, body = "ignored", state = "open", labels = {}, assignees = {},
        user = { login = "fkst-test-bot" }, pull_request = {} },
    } }
    local result = testing.run_fake(department(github_port(
      { [41] = old_content, [52] = published_schedule, [160] = source, [161] = review },
      { row(source), row(review) }, all_pages
    )), event(review))
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("published-content-requires-add-correction", 1, true) ~= nil)
  end,
}
