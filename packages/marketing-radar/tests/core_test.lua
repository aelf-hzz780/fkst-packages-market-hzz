local core = require("core")
local proposal_identity = require("proposal_identity")
local proposal_provenance = require("proposal_provenance")
local sha256 = require("contract.sha256")
local t = fkst.test

local function session()
  return {
    effective_work_label = "host-test-primary",
    logical_work_label = "auto-x-test-primary",
    creator = "test-operator",
    account = "test_primary",
  }
end

local function source_ref(number)
  local ref = "owner/repo#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function signal(number, action, target_ref)
  local lines = {
    "contract: marketing-radar.radar-signal.v2",
    "type: radar-signal",
    "project: chronoai",
    "account: test_primary",
    "work-label: auto-x-test-primary",
    "week: 2026-W33",
    "action: " .. tostring(action or "add"),
  }
  if target_ref ~= nil then
    lines[#lines + 1] = "target-ref: " .. target_ref
  end
  lines[#lines + 1] = "topic: FKST automation"
  lines[#lines + 1] = "source-url: https://github.example/owner/repo/issues/" .. tostring(number)
  lines[#lines + 1] = "insight: Generate a reviewed update from cited evidence."
  local body = table.concat(lines, "\n")
  return assert(core.classify_issue({
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = number,
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    body = body,
    source_ref = source_ref(number),
  }, { session = session() }))
end

local function draft(signals, tweet_text, revision)
  local evidence = {}
  for _, item in ipairs(signals) do
    evidence[#evidence + 1] = item.source_ref.ref
  end
  return {
    action = signals[1].action,
    target_ref = signals[1].target_ref,
    evidence_refs = evidence,
    tweet_text = tweet_text,
    revision = revision,
  }
end

local function proposal_root_body(proposal, cycle)
  return assert(core.render_proposal(proposal))
    .. "\n\n<!-- fkst:github-proxy:issue-create:" .. proposal.group_key
    .. "/create/cycle-" .. tostring(cycle or 1) .. " -->"
end

local function proposal_revision_body(proposal)
  local request = core.proposal_revision_comment_request({ source_ref = source_ref(99) }, proposal)
  return request.body
    .. "\n\n<!-- fkst:github-proxy:comment:" .. request.dedup_key .. " -->"
end

local function review_command(command, proposal, reason, revision)
  local body = "/marketing " .. command .. " " .. proposal.proposal_id .. "@"
    .. tostring(revision ~= nil and revision or proposal.revision) .. " " .. proposal.proposal_digest
  if reason ~= nil and reason ~= "" then
    body = body .. " " .. reason
  end
  return body
end

return {
  test_control_parser_limits_fields_to_the_v2_allowlist = function()
    local fields, why = core.parse_control_fields(table.concat({
      "type: radar-signal",
      "project: chronoai",
      "account: test_primary",
      "action: add",
      "```yaml",
      "action: replan",
      "```",
      "token: must-not-pass",
      "raw-response: must-not-pass",
    }, "\n"))
    t.is_nil(why)
    t.eq(fields.type, "radar-signal")
    t.eq(fields.action, "add")
    t.is_nil(fields.token)
    t.is_nil(fields["raw-response"])

    local _, duplicate_why = core.parse_control_fields("type: radar-signal\naction: add\naction: replan")
    t.eq(duplicate_why, "duplicate-control-field:action")
  end,

  test_proposal_catalog_intent_and_fences_fail_closed = function()
    local group_fields = table.concat({
      "project: chronoai",
      "account: test_primary",
      "week: 2026-W33",
      "action: revise",
      "target-ref: content-42",
    }, "\n")
    local contract = "contract: marketing-radar.weekly-plan-change.v2"
    local proposal_type = "type: weekly-plan-change"

    for _, body in ipairs({
      contract .. "\n" .. group_fields,
      proposal_type .. "\n" .. group_fields,
      string.rep("x", 32001) .. "\n" .. contract .. "\n" .. proposal_type .. "\n" .. group_fields,
      "```yaml\n" .. contract .. "\n" .. proposal_type .. "\n" .. group_fields,
    }) do
      local group, intent = core.proposal_catalog_group(body)
      t.is_nil(group)
      t.eq(intent, true)
    end

    for _, field in ipairs({ "project", "account", "week", "action", "target-ref" }) do
      local body = contract .. "\n" .. proposal_type .. "\n"
        .. field .. ": wrong\n" .. group_fields
      local group, intent, why = core.proposal_catalog_group(body)
      t.is_nil(group)
      t.eq(intent, true)
      t.eq(why, "duplicate-control-field:" .. field)
    end

    local hidden = contract .. "\n" .. proposal_type .. "\n" .. group_fields
    for _, body in ipairs({
      "~~~yaml\n" .. hidden .. "\n~~~",
      "````yaml\n```\n" .. hidden .. "\n````",
    }) do
      local group, intent = core.proposal_catalog_group(body)
      t.is_nil(group)
      t.eq(intent, false)
    end
  end,

  test_group_rejects_mixed_actions_and_targets = function()
    local signals = { signal(11, "add"), signal(12, "revise", "#8") }
    local proposal, why = core.build_proposal(signals, session(), draft(signals, "A reviewed update."))
    t.is_nil(proposal)
    t.eq(why, "mixed-signal-actions")
    t.is_true(core.proposal_group_key(signals[1]) ~= core.proposal_group_key(signals[2]))
    t.is_true(core.proposal_group_key(signal(13, "revise", "#8"))
      ~= core.proposal_group_key(signal(14, "revise", "#9")))
    local spaced, punctuated = signal(15), signal(16)
    spaced.topic = "release one"
    punctuated.topic = "release@one"
    t.is_true(core.proposal_group_key(spaced) ~= core.proposal_group_key(punctuated))
  end,

  test_action_strategies_bound_supersession_scope = function()
    local add = assert(core.action_strategy("add"))
    local revise = assert(core.action_strategy("revise", "#8"))
    local replan = assert(core.action_strategy("replan"))
    t.eq(add.change_scope, "append")
    t.eq(add.supersede_mode, "none")
    t.eq(revise.change_scope, "target-only")
    t.eq(revise.supersede_mode, "target-unpublished")
    t.eq(replan.change_scope, "week-unpublished")
    t.eq(replan.supersede_mode, "all-unpublished")
  end,

  test_signal_author_must_be_session_creator_collaborator_or_globally_authorized = function()
    local body = signal(11).source_ref and table.concat({
      "contract: marketing-radar.radar-signal.v2", "type: radar-signal", "project: chronoai",
      "account: test_primary", "work-label: auto-x-test-primary", "week: 2026-W33",
      "action: add", "topic: FKST automation",
    }, "\n")
    local payload = {
      schema = "github-proxy.v1", type = "issue", repo = "owner/repo", number = 11,
      labels = { "host-test-primary" }, assignees = { "test-operator" },
      body = body, source_ref = source_ref(11),
    }
    local authorized = assert(core.classify_issue(payload, {
      session = session(), issue_author_login = "test-collaborator",
      authorized_signal_authors = { "test-operator", "test-collaborator" },
    }))
    local blocked = assert(core.classify_issue(payload, {
      session = session(), issue_author_login = "untrusted-author",
      authorized_signal_authors = { "test-operator", "test-collaborator" },
    }))
    t.eq(authorized.status, "awaiting-review")
    t.eq(authorized.signal_authorized, true)
    t.eq(blocked.status, "needs-triage")
    t.eq(blocked.triage_reason, "unauthorized-signal-author")
  end,

  test_proposal_round_trip_rejects_tampered_tweet_text = function()
    local signals = { signal(11) }
    local proposal = assert(core.build_proposal(signals, session(), draft(signals, "A reviewed update.")))
    local body = core.render_proposal(proposal)
    local parsed = assert(core.parse_proposal(body))
    t.eq(parsed.content_digest, proposal.content_digest)
    local tampered, why = core.parse_proposal(body:gsub("A reviewed update", "An unapproved replacement"))
    t.is_nil(tampered)
    t.eq(why, "proposal-content-digest-mismatch")
    local status_tampered, status_why = core.parse_proposal(
      body:gsub("status: awaiting%-review", "status: approved", 1))
    t.is_nil(status_tampered)
    t.eq(status_why, "invalid-proposal-contract")

    for _, text in ipairs({
      "A fence-like line follows.\n```\nThe approved text continues.",
      "This is not a closing delimiter.\n```trailing text\nThe approved text continues.",
      "A longer run follows.\n````\nThe approved text continues.",
      "These are tweet lines, not lineage.\nsignal: owner/repo#issue/999 sha256:"
        .. string.rep("f", 64) .. "\nevidence: owner/repo#issue/999",
    }) do
      local fenced = assert(core.build_proposal(signals, session(), draft(signals, text)))
      local round_trip = assert(core.parse_proposal(assert(core.render_proposal(fenced))))
      t.eq(round_trip.tweet_text, text)
      t.eq(round_trip.content_digest, fenced.content_digest)
      t.eq(#round_trip.signals, 1)
      t.eq(#round_trip.evidence_refs, 1)
    end
  end,

  test_proposal_digest_is_canonical_across_lineage_order = function()
    local signals = { signal(11), signal(12) }
    local proposal = assert(core.build_proposal(
      signals, session(), draft(signals, "An order-independent reviewed draft.", 1)))
    local reordered = {}
    for key, value in pairs(proposal) do
      reordered[key] = value
    end
    reordered.signals = { proposal.signals[2], proposal.signals[1] }
    reordered.evidence_refs = { proposal.evidence_refs[2], proposal.evidence_refs[1] }
    t.eq(proposal_identity.proposal_digest(reordered), proposal.proposal_digest)
  end,

  test_review_digest_rejects_replaced_bot_root_with_same_proposal_revision = function()
    local signals = { signal(11) }
    local original = assert(core.build_proposal(
      signals, session(), draft(signals, "The originally approved draft.", 1)))
    local replacement = assert(core.build_proposal(
      signals, session(), draft(signals, "A silently replaced draft.", original.revision), {
        proposal_id = original.proposal_id,
        content_id = original.content_id,
        content_revision = original.content_revision,
      }))

    t.eq(replacement.proposal_id, original.proposal_id)
    t.eq(replacement.revision, original.revision)
    t.is_true(replacement.content_digest ~= original.content_digest)

    local decision, why = core.review_decision({
      body = proposal_root_body(replacement),
      author_login = "fkst-test-bot",
      comments = {
        { id = 41, author_login = "test-operator", body = review_command("approve", original) },
      },
    }, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "stale-proposal-digest")
  end,

  test_review_digest_binds_proposal_scope_and_signal_lineage = function()
    local original_signal = signal(11)
    local original = assert(core.build_proposal(
      { original_signal }, session(), draft({ original_signal }, "A scope-bound draft.", 1)))
    local replacement_signal = signal(12, "revise", "content-other")
    local replacement = assert(core.build_proposal(
      { replacement_signal }, session(),
      draft({ replacement_signal }, original.tweet_text, original.revision), {
        proposal_id = original.proposal_id,
        content_id = original.content_id,
        content_revision = original.content_revision,
      }))

    t.eq(replacement.content_digest, original.content_digest)
    t.is_true(replacement.group_key ~= original.group_key)
    t.is_true(replacement.signal_set_digest ~= original.signal_set_digest)

    local decision, why = core.review_decision({
      body = proposal_root_body(replacement),
      author_login = "fkst-test-bot",
      comments = {
        { id = 42, author_login = "test-operator", body = review_command("approve", original) },
      },
    }, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "stale-proposal-digest")
  end,

  test_proposal_signal_lineage_is_bound_to_declared_set_digest = function()
    local first, replacement = signal(11), signal(12)
    local original = assert(core.build_proposal(
      { first }, session(), draft({ first }, "A lineage-bound draft.", 1)))
    local tampered_root = assert(core.render_proposal(original))
      :gsub(first.source_ref.ref, replacement.source_ref.ref)
      :gsub(first.signal_digest, replacement.signal_digest)
    local parsed, why = core.parse_proposal(tampered_root)
    t.is_nil(parsed)
    t.eq(why, "proposal-signal-set-digest-mismatch")
    local latest, latest_why = core.latest_proposal({
      body = tampered_root .. "\n<!-- fkst:github-proxy:issue-create:"
        .. original.group_key .. "/create/cycle-1 -->",
      author_login = "fkst-test-bot", comments = {},
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(latest_why,
      "malformed-bot-proposal-root:proposal-signal-set-digest-mismatch")

    local second_signal, revision_replacement = signal(13), signal(14)
    local root = assert(core.build_proposal(
      { first, second_signal }, session(),
      draft({ first, second_signal }, "The root lineage.", 1)))
    local revision = assert(core.build_proposal(
      { first, second_signal }, session(),
      draft({ first, second_signal }, "The revised lineage.", 2), {
        proposal_id = root.proposal_id, content_id = root.content_id, content_revision = 2,
      }))
    local tampered_revision = proposal_revision_body(revision)
      :gsub(second_signal.source_ref.ref, revision_replacement.source_ref.ref)
      :gsub(second_signal.signal_digest, revision_replacement.signal_digest)
    latest, latest_why = core.latest_proposal({
      body = proposal_root_body(root), author_login = "fkst-test-bot",
      comments = { { author_login = "fkst-test-bot", body = tampered_revision } },
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(latest_why,
      "malformed-bot-proposal-revision:proposal-signal-set-digest-mismatch")
  end,

  test_proposal_root_and_content_revision_lineage_fail_closed = function()
    local signals = { signal(11) }
    local invalid, invalid_why = core.build_proposal(
      signals, session(), draft(signals, "An invalid content lineage.", 2), {
        content_revision = 7,
      })
    t.is_nil(invalid)
    t.eq(invalid_why, "invalid-content-lineage")

    local root_revision_two = assert(core.build_proposal(
      signals, session(), draft(signals, "A root that skipped revision one.", 2)))
    local latest, latest_why = core.latest_proposal({
      body = proposal_root_body(root_revision_two),
      author_login = "fkst-test-bot",
      comments = {},
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(latest_why, "invalid-bot-proposal-root-revision")
  end,

  test_proposal_root_and_revision_require_exact_proxy_provenance = function()
    local signals = { signal(11) }
    local first = assert(core.build_proposal(
      signals, session(), draft(signals, "The first provenance-bound draft.", 1)))
    local latest, why = core.latest_proposal({
      body = assert(core.render_proposal(first)),
      author_login = "fkst-test-bot",
      comments = {},
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.is_true(why:find("proposal-create-provenance-missing", 1, true) ~= nil)

    local foreign_group = core.proposal_group_key({
      project = first.project, account = first.account, week = first.week,
      topic = "foreign-topic", action = first.action,
    })
    latest, why = core.latest_proposal({
      body = assert(core.render_proposal(first))
        .. "\n<!-- fkst:github-proxy:issue-create:" .. foreign_group .. "/create/cycle-1 -->",
      author_login = "fkst-test-bot",
      comments = {},
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(why, "conflicting-bot-proposal-root-provenance")

    local second = assert(core.build_proposal(
      signals, session(), draft(signals, "The second provenance-bound draft.", 2), {
        proposal_id = first.proposal_id,
        content_id = first.content_id,
        content_revision = 2,
      }))
    latest, why = core.latest_proposal({
      body = proposal_root_body(first),
      author_login = "fkst-test-bot",
      comments = { {
        author_login = "fkst-test-bot",
        body = assert(core.render_proposal(second)),
      } },
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.is_true(why:find("proposal-revision-provenance-missing", 1, true) ~= nil)
  end,

  test_extreme_group_identity_keeps_all_proxy_dedup_keys_bounded = function()
    local extreme = {
      project = string.rep("p", 180), account = string.rep("a", 15),
      week = "2026-W33", topic = string.rep("t", 512), action = "revise",
      target_ref = string.rep("r", 512),
    }
    local group = core.proposal_group_key(extreme)
    local changed = {}
    for key, value in pairs(extreme) do changed[key] = value end
    changed.target_ref = changed.target_ref .. "x"
    t.eq(#group, 400)
    t.is_true(group:sub(-#"/weekly-plan-change") == "/weekly-plan-change")
    t.is_true(group ~= core.proposal_group_key(changed))

    local signals = { signal(11) }
    local proposal = assert(core.build_proposal(
      signals, session(), draft(signals, "A bounded dedup draft.", 1)))
    proposal.group_key = group
    local create = core.weekly_plan_change_issue_request(proposal, session(), 2147483647)
    local content = core.approved_weekly_content_issue_request(proposal, session())
    local status = core.status_comment({
      group_key = group, account = proposal.account, source_ref = proposal.source_ref,
    }, string.rep("long-status-", 20))
    proposal.revision = 2147483647
    proposal.content_revision = 2147483647
    local revision = core.proposal_revision_comment_request({ source_ref = source_ref(99) }, proposal)
    for _, request in ipairs({ create, content, status, revision }) do
      t.is_true(#request.dedup_key <= 512)
    end
    t.is_true(create.dedup_key:sub(-#"/create/cycle-2147483647")
      == "/create/cycle-2147483647")
    local revision_suffix = "/revision/2147483647/" .. proposal.signal_set_digest
    t.is_true(revision.dedup_key:sub(-#revision_suffix) == revision_suffix)
  end,

  test_proxy_dedup_and_provenance_namespaces_are_exact = function()
    local at_limit = assert(proposal_identity.dedup_key(string.rep("d", 512), ""))
    t.eq(#at_limit, 512)
    local over_limit, over_why = proposal_identity.dedup_key(string.rep("d", 513), "")
    t.is_nil(over_limit)
    t.eq(over_why, "proposal-dedup-key-too-large")

    local group = core.proposal_group_key(signal(11))
    local unrelated_create = "<!-- fkst:github-proxy:issue-create:" .. group
      .. "/approved-content/sha256:" .. string.rep("a", 64) .. " -->"
    local marker, marker_why, marker_intent = proposal_provenance.issue_create(unrelated_create)
    t.is_nil(marker)
    t.eq(marker_why, "proposal-create-provenance-missing")
    t.eq(marker_intent, false)

    local revision_topic_group = core.proposal_group_key({
      project = "chronoai", account = "test_primary", week = "2026-W33",
      topic = "revision", action = "add",
    })
    local unrelated_comment = "<!-- fkst:github-proxy:comment:" .. revision_topic_group
      .. "/status/awaiting-review -->"
    marker, marker_why, marker_intent = proposal_provenance.revision_comment(unrelated_comment)
    t.is_nil(marker)
    t.is_nil(marker_why)
    t.eq(marker_intent, false)
  end,

  test_pending_proposal_create_dedup_remains_group_cycle_scoped = function()
    local first_signals = { signal(11) }
    local second_signals = { signal(12) }
    local first = assert(core.build_proposal(
      first_signals, session(), draft(first_signals, "The first reviewed set.", 1)))
    local second = assert(core.build_proposal(
      second_signals, session(), draft(second_signals, "The second reviewed set.", 1)))
    t.eq(first.group_key, second.group_key)
    t.is_true(first.signal_set_digest ~= second.signal_set_digest)

    local first_request = core.weekly_plan_change_issue_request(first, session(), 1)
    local second_request = core.weekly_plan_change_issue_request(second, session(), 1)
    t.eq(first_request.dedup_key, second_request.dedup_key)
    t.is_true(first.proposal_id ~= second.proposal_id)
  end,

  test_proposal_revision_exhaustion_is_explicit = function()
    local next_revision, why = core.next_proposal_revision(2147483647)
    t.is_nil(next_revision)
    t.eq(why, "proposal-revision-exhausted")
    t.eq(core.next_proposal_revision(2147483646), 2147483647)
  end,

  test_oversized_parsed_proposal_fails_without_asserting = function()
    local signals = { signal(11) }
    local proposal = assert(core.build_proposal(
      signals, session(), draft(signals, "A bounded canonical draft.", 1)))
    local body = assert(core.render_proposal(proposal))
      :gsub("\nsignal:[^\n]+", ""):gsub("\nevidence:[^\n]+", "")
    local lineage = {}
    local digests = {}
    local expanded_signals = {}
    local expanded_evidence = {}
    local long_repo = string.rep("o", 99) .. "/" .. string.rep("r", 100)
    for index = 10, 29 do
      local ref = long_repo .. "#issue/" .. tostring(index) .. string.rep("0", 17)
      local digest = "sha256:" .. string.rep("f", 64)
      lineage[#lineage + 1] = "signal: " .. ref .. " " .. digest
      lineage[#lineage + 1] = "evidence: " .. ref
      digests[#digests + 1] = digest
      expanded_signals[#expanded_signals + 1] = {
        source_ref = { kind = "external", ref = ref, reference = ref },
        signal_digest = digest,
      }
      expanded_evidence[#expanded_evidence + 1] = ref
    end
    proposal.signals = expanded_signals
    proposal.evidence_refs = expanded_evidence
    proposal.signal_set_digest = "sha256:" .. sha256.hex(table.concat(digests, "\n"))
    proposal.proposal_digest = assert(proposal_identity.proposal_digest(proposal))
    body = assert(body:gsub("\n\ntweet%-text:",
      "\n" .. table.concat(lineage, "\n") .. "\n\ntweet-text:", 1))
    body = assert(body:gsub("signal%-set%-digest: sha256:[0-9a-f]+",
      "signal-set-digest: " .. proposal.signal_set_digest, 1))
    body = assert(body:gsub("proposal%-digest: sha256:[0-9a-f]+",
      "proposal-digest: " .. proposal.proposal_digest, 1))
    t.is_true(#body > 11000 and #body < 32000)
    t.eq(#assert(core.parse_proposal(body)).signals, 20)
    local latest, why = core.latest_proposal({
      body = body .. "\n<!-- fkst:github-proxy:issue-create:"
        .. proposal.group_key .. "/create/cycle-1 -->",
      author_login = "fkst-test-bot",
      comments = {},
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(why, "malformed-bot-proposal-root:proposal-body-too-large")
  end,

  test_large_revision_gap_fails_without_range_iteration = function()
    local signals = { signal(11) }
    local root = assert(core.build_proposal(
      signals, session(), draft(signals, "The root revision.", 1)))
    local far = assert(core.build_proposal(
      signals, session(), draft(signals, "A discontinuous revision.", 2147483647), {
        proposal_id = root.proposal_id,
        content_id = root.content_id,
        content_revision = 2147483647,
      }))
    local latest, why = core.latest_proposal({
      body = proposal_root_body(root), author_login = "fkst-test-bot",
      comments = { { author_login = "fkst-test-bot", body = proposal_revision_body(far) } },
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(why, "discontinuous-bot-proposal-revision")
  end,

  test_request_changes_and_reject_require_a_reason = function()
    local signals = { signal(11) }
    local proposal = assert(core.build_proposal(signals, session(), draft(signals, "A reviewed update.")))
    local body = proposal_root_body(proposal)
    local issue = {
      body = body,
      author_login = "fkst-test-bot",
      comments = {
        { id = 1, author_login = "test-operator", body = review_command("request-changes", proposal) },
      },
    }
    local decision, why = core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "review-reason-required")
    issue.comments[1].body = review_command(
      "request-changes", proposal, "Include the release link.")
    decision = assert(core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.command, "request-changes")
    t.eq(decision.reason, "Include the release link.")

    issue.comments = {
      { id = 2, author_login = "test-operator", body = review_command("approve", proposal) },
      { id = 3, author_login = "test-operator",
        body = review_command("request-changes", proposal, "Too late.") },
    }
    decision = assert(core.review_decision(issue, {
      bot_login = "app/fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.command, "approve")
    t.eq(decision.comment_id, 2)

    issue.comments = {
      { id = 4, author_login = "test-operator",
        body = review_command("reject", proposal, string.rep("x", 513)) },
    }
    decision, why = core.review_decision(issue, {
      bot_login = "fkst-test-bot[bot]",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "invalid-review-reason")
  end,

  test_failed_request_changes_comment_yields_to_next_authorized_command = function()
    local signals = { signal(11) }
    local proposal = assert(core.build_proposal(signals, session(), draft(signals, "The first draft.")))
    local first_command = {
      id = 31,
      author_login = "test-operator",
      body = review_command("request-changes", proposal, "Add evidence."),
    }
    local decision = assert(core.review_decision({
      body = proposal_root_body(proposal),
      author_login = "fkst-test-bot",
      comments = { first_command },
    }, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    local failure_status = assert(core.review_failure_status(
      decision, "draft-correction-exhausted:invalid-x-text:text too long")
    )
    local failure_request = core.status_comment({
      account = "test_primary",
      source_ref = source_ref(91),
      trace_id = "test-review-failure",
    }, failure_status)
    local failure_comment = failure_request.body
      .. "\n<!-- fkst:github-proxy:comment:" .. failure_request.dedup_key .. " -->"
    local issue = {
      body = proposal_root_body(proposal),
      author_login = "fkst-test-bot",
      source_ref = source_ref(91),
      comments = {
        first_command,
        { id = 32, author_login = "fkst-test-bot", body = failure_request.body },
        { id = 33, author_login = "test-operator",
          body = review_command("request-changes", proposal, "Use the shorter release URL.") },
      },
    }

    decision = assert(core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.comment_id, 31)

    issue.comments[2].body = failure_comment
    decision = assert(core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.comment_id, 33)
    t.eq(decision.reason, "Use the shorter release URL.")

    local multiline = assert(core.review_failure_status(
      decision, "semantic-conflict:first line\nsecond line"))
    t.is_true(multiline:find("semantic-conflict:first line second line", 1, true) ~= nil)

    issue.comments[3] = nil
    local absent, why = core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(absent)
    t.eq(why, "no-review-command")

    issue.comments = {
      first_command,
      {
        id = 34,
        author_login = "fkst-test-bot",
        body = failure_status,
      },
    }
    decision = assert(core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.comment_id, 31)

    issue.comments = {
      first_command,
      {
        id = 35,
        author_login = "attacker",
        body = failure_comment,
      },
    }
    decision = assert(core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.comment_id, 31)

    issue.comments = {
      first_command,
      {
        id = 36,
        author_login = "fkst-test-bot",
        body = failure_comment .. "\n<!-- fkst:github-proxy:comment:"
          .. failure_request.dedup_key .. " -->",
      },
    }
    decision = assert(core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.comment_id, 31)

    issue.comments = {
      first_command,
      {
        id = 37,
        author_login = "fkst-test-bot",
        body = failure_request.body .. "\n<!-- fkst:github-proxy:comment:"
          .. failure_request.dedup_key .. "_forged -->",
      },
    }
    decision = assert(core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.comment_id, 31)
  end,

  test_old_revision_approval_is_stale_after_request_changes_revision = function()
    local signals = { signal(11) }
    local first = assert(core.build_proposal(
      signals, session(), draft(signals, "The first reviewed update.", 1)))
    local second = assert(core.build_proposal(
      signals, session(), draft(signals, "The requested replacement update.", 2), {
        proposal_id = first.proposal_id,
        content_id = first.content_id,
        content_revision = 2,
      }))
    local issue = {
      body = proposal_root_body(first),
      author_login = "fkst-test-bot",
      comments = {
        { id = 1, author_login = "fkst-test-bot", body = proposal_revision_body(second) },
        { id = 2, author_login = "test-operator", body = review_command("approve", first) },
      },
    }
    local decision, why = core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "stale-proposal-revision")
  end,

  test_malformed_or_discontinuous_bot_revision_invalidates_prior_approval = function()
    local signals = { signal(11) }
    local first = assert(core.build_proposal(
      signals, session(), draft(signals, "The first reviewed update.", 1)))
    local second = assert(core.build_proposal(
      signals, session(), draft(signals, "The requested replacement update.", 2), {
        proposal_id = first.proposal_id,
        content_id = first.content_id,
        content_revision = 2,
      }))
    local approval = { id = 2, author_login = "test-operator", body = review_command("approve", first) }
    local malformed = proposal_revision_body(second):gsub(
      "content%-digest: sha256:[0-9a-f]+", "content-digest: damaged", 1)
    local issue = {
      body = proposal_root_body(first),
      author_login = "fkst-test-bot",
      comments = {
        { id = 1, author_login = "fkst-test-bot", body = malformed },
        approval,
      },
    }
    local decision, why = core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.is_true(tostring(why):find("malformed-bot-proposal", 1, true) ~= nil)

    local third = assert(core.build_proposal(
      signals, session(), draft(signals, "A skipped replacement update.", 3), {
        proposal_id = first.proposal_id,
        content_id = first.content_id,
        content_revision = 3,
      }))
    local latest, lineage_why = core.latest_proposal({
      body = proposal_root_body(first),
      author_login = "fkst-test-bot",
      comments = { { id = 3, author_login = "fkst-test-bot", body = proposal_revision_body(third) } },
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(lineage_why, "discontinuous-bot-proposal-revision")

    local conflicting = assert(core.build_proposal(
      signals, session(), draft(signals, "A foreign replacement update.", 2), {
        proposal_id = "proposal-foreign",
        content_id = first.content_id,
        content_revision = 2,
      }))
    latest, lineage_why = core.latest_proposal({
      body = proposal_root_body(first),
      author_login = "fkst-test-bot",
      comments = { {
        id = 4, author_login = "fkst-test-bot", body = proposal_revision_body(conflicting),
      } },
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(lineage_why, "conflicting-bot-proposal-lineage")

    local revision_issue = {
      source_ref = source_ref(99),
    }
    local revision_request = core.proposal_revision_comment_request(revision_issue, second)
    local malformed_with_marker = assert(core.render_proposal(second))
      :gsub("contract: marketing%-radar%.weekly%-plan%-change%.v2", "contract: broken", 1)
    malformed_with_marker = malformed_with_marker .. "\n<!-- fkst:github-proxy:comment:"
      .. revision_request.dedup_key .. " -->"
    latest, lineage_why = core.latest_proposal({
      body = proposal_root_body(first),
      author_login = "fkst-test-bot",
      comments = { { id = 5, author_login = "fkst-test-bot", body = malformed_with_marker } },
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.is_true(tostring(lineage_why):find("malformed-bot-proposal-revision", 1, true) ~= nil)

    local mismatched_marker = assert(core.render_proposal(second))
      .. "\n<!-- fkst:github-proxy:comment:marketing-radar/other/revision-group/2026-W33/topic/add/none/weekly-plan-change/revision/2/"
      .. second.signal_set_digest .. " -->"
    latest, lineage_why = core.latest_proposal({
      body = proposal_root_body(first),
      author_login = "fkst-test-bot",
      comments = { { id = 6, author_login = "fkst-test-bot", body = mismatched_marker } },
    }, "fkst-test-bot")
    t.is_nil(latest)
    t.eq(lineage_why, "conflicting-bot-proposal-provenance")
  end,

  test_same_revision_with_different_signal_set_is_conflicting_even_when_content_matches = function()
    local first_signals = { signal(11) }
    local union_signals = { signal(11), signal(12) }
    local first = assert(core.build_proposal(
      first_signals, session(), draft(first_signals, "The same reviewed update.", 1)))
    local union = assert(core.build_proposal(
      union_signals, session(), draft(union_signals, "The same reviewed update.", 1), {
        proposal_id = first.proposal_id,
        content_id = first.content_id,
        content_revision = first.content_revision,
      }))
    t.eq(first.content_digest, union.content_digest)
    t.is_true(first.signal_set_digest ~= union.signal_set_digest)

    local latest, why = core.latest_proposal({
      body = proposal_root_body(first),
      author_login = "fkst-test-bot",
      comments = {
        { id = 1, author_login = "fkst-test-bot", body = proposal_revision_body(union) },
      },
    }, "fkst-test-bot")

    t.is_nil(latest)
    t.eq(why, "conflicting-bot-proposal-revision")
  end,

  test_terminal_status_dedup_binds_review_decision_and_content_identity = function()
    local item = signal(11)
    local digest_a = "sha256:" .. string.rep("a", 64)
    local digest_b = "sha256:" .. string.rep("b", 64)
    local digest_c = "sha256:" .. string.rep("c", 64)
    local function request(values)
      local decision = {
        command = "approve",
        comment_id = values.comment_id or 91,
        proposal = {
          proposal_id = values.proposal_id or "proposal-terminal-a",
          revision = values.revision or 1,
          proposal_digest = values.proposal_digest or digest_c,
          content_digest = values.content_digest or digest_a,
          review_source_ref = source_ref(values.review_number or 21),
        },
      }
      return core.status_comment(
        item,
        "approved; immutable weekly-content requested",
        core.close_handoff(item, "radar-signal", decision)
      )
    end
    local requests = {
      request({}),
      request({ review_number = 22 }),
      request({ proposal_id = "proposal-terminal-b" }),
      request({ revision = 2 }),
      request({ comment_id = 92 }),
      request({ proposal_digest = digest_b }),
      request({ content_digest = digest_b }),
    }
    local seen = {}
    for _, value in ipairs(requests) do
      t.is_true(#value.dedup_key <= proposal_identity.DEDUP_KEY_LIMIT)
      t.is_nil(seen[value.dedup_key])
      seen[value.dedup_key] = true
    end
  end,

  test_comment_ack_must_match_terminal_handoff_exactly = function()
    local item = signal(11)
    local handoff = core.close_handoff(item, "radar-signal", {
      command = "approve",
      comment_id = 91,
      proposal = {
        proposal_id = "proposal-terminal-ack",
        revision = 1,
        proposal_digest = "sha256:" .. string.rep("b", 64),
        content_digest = "sha256:" .. string.rep("c", 64),
        review_source_ref = source_ref(21),
      },
    })
    local request = core.status_comment(item, "approved", handoff)
    t.is_true(request.body:find("publish_attempted: false", 1, true) ~= nil)
    local payload = {
      schema = "github-proxy.comment-written.v1",
      target = "issue",
      repo = "owner/repo",
      issue_number = 11,
      comment_id = "91",
      request_dedup_key = request.dedup_key,
      dedup_key = request.dedup_key .. "/written/91",
      source_ref = source_ref(11),
      handoff = request.handoff,
    }
    local context = assert(core.close_ack_context(payload))
    t.eq(context.business_digest, item.signal_digest)
    payload.request_dedup_key = "mismatch"
    local invalid, why = core.close_ack_context(payload)
    t.is_nil(invalid)
    t.eq(why, "invalid-close-correlation")
  end,
}
