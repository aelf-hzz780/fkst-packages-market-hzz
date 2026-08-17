local core = require("core")
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

  test_group_rejects_mixed_actions_and_targets = function()
    local signals = { signal(11, "add"), signal(12, "revise", "#8") }
    local proposal, why = core.build_proposal(signals, session(), draft(signals, "A reviewed update."))
    t.is_nil(proposal)
    t.eq(why, "mixed-signal-actions")
    t.is_true(core.proposal_group_key(signals[1]) ~= core.proposal_group_key(signals[2]))
    t.is_true(core.proposal_group_key(signal(13, "revise", "#8"))
      ~= core.proposal_group_key(signal(14, "revise", "#9")))
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
  end,

  test_request_changes_and_reject_require_a_reason = function()
    local signals = { signal(11) }
    local proposal = assert(core.build_proposal(signals, session(), draft(signals, "A reviewed update.")))
    local body = core.render_proposal(proposal)
    local issue = {
      body = body,
      author_login = "fkst-test-bot",
      comments = {
        { id = 1, author_login = "test-operator", body = "/marketing request-changes "
          .. proposal.proposal_id .. "@" .. proposal.revision },
      },
    }
    local decision, why = core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "review-reason-required")
    issue.comments[1].body = issue.comments[1].body .. " Include the release link."
    decision = assert(core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.command, "request-changes")
    t.eq(decision.reason, "Include the release link.")

    issue.comments = {
      { id = 2, author_login = "test-operator", body = "/marketing approve "
        .. proposal.proposal_id .. "@" .. proposal.revision },
      { id = 3, author_login = "test-operator", body = "/marketing request-changes "
        .. proposal.proposal_id .. "@" .. proposal.revision .. " Too late." },
    }
    decision = assert(core.review_decision(issue, {
      bot_login = "app/fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    }))
    t.eq(decision.command, "approve")
    t.eq(decision.comment_id, 2)

    issue.comments = {
      { id = 4, author_login = "test-operator", body = "/marketing reject "
        .. proposal.proposal_id .. "@" .. proposal.revision .. " " .. string.rep("x", 513) },
    }
    decision, why = core.review_decision(issue, {
      bot_login = "fkst-test-bot[bot]",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "invalid-review-reason")
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
      body = assert(core.render_proposal(first)),
      author_login = "fkst-test-bot",
      comments = {
        { id = 1, author_login = "fkst-test-bot", body = assert(core.render_proposal(second)) },
        { id = 2, author_login = "test-operator", body = "/marketing approve "
          .. first.proposal_id .. "@1" },
      },
    }
    local decision, why = core.review_decision(issue, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "stale-proposal-revision")
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
      body = assert(core.render_proposal(first)),
      author_login = "fkst-test-bot",
      comments = {
        { id = 1, author_login = "fkst-test-bot", body = assert(core.render_proposal(union)) },
      },
    }, "fkst-test-bot")

    t.is_nil(latest)
    t.eq(why, "conflicting-bot-proposal-revision")
  end,

  test_comment_ack_must_match_terminal_handoff_exactly = function()
    local item = signal(11)
    local handoff = core.close_handoff(item, "radar-signal")
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
