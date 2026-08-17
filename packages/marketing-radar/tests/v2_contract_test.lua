local core = require("core")
local t = fkst.test

local function source_ref(number)
  local ref = "owner/repo#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function session(overrides)
  local values = {
    effective_work_label = "host-session-42",
    logical_work_label = "auto-x-test-primary",
    creator = "test-operator",
    account = "test_primary",
  }
  for key, value in pairs(overrides or {}) do
    values[key] = value
  end
  return values
end

local function signal_body(overrides)
  local values = {
    contract = "marketing-radar.radar-signal.v2",
    type = "radar-signal",
    project = "chronoai",
    account = "@TEST_PRIMARY",
    ["work-label"] = "auto-x-test-primary",
    week = "2026-W33",
    action = "add",
    topic = "FKST hosted automation",
    insight = "Use the cited release evidence when drafting the update.",
    ["source-url"] = "https://github.example/owner/repo/issues/11",
  }
  for key, value in pairs(overrides or {}) do
    values[key] = value
  end
  local keys = { "contract", "type", "project", "account", "work-label", "week", "action", "target-ref", "topic", "source-url", "insight" }
  local lines = {}
  for _, key in ipairs(keys) do
    if values[key] ~= nil then
      lines[#lines + 1] = key .. ": " .. values[key]
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

local function issue(number, body, overrides)
  local payload = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = number,
    state = "OPEN",
    labels = { "host-session-42" },
    assignees = { "test-operator" },
    body = body,
    source_ref = source_ref(number),
    updated_at = "2026-08-17T01:02:03Z",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

local function classify(number, body, overrides, session_overrides)
  return core.classify_issue(issue(number, body, overrides), {
    session = session(session_overrides),
    issue_body = body,
    issue_labels = overrides and overrides.labels,
    issue_assignees = overrides and overrides.assignees,
  })
end

local function draft(signals, tweet_text, revision)
  local evidence = {}
  local seen = {}
  for _, signal in ipairs(signals) do
    if not seen[signal.source_ref.ref] then
      evidence[#evidence + 1] = signal.source_ref.ref
      seen[signal.source_ref.ref] = true
    end
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
  test_session_authority_resolves_effective_and_reverse_mapped_logical_label = function()
    local authority = core.resolve_session_authority({
      FKST_SESSION_WORK_LABEL = "host-session-42",
      FKST_SESSION_WORK_LABEL_MAP_JSON = '{"auto-x-test-primary":"host-session-42"}',
      FKST_SESSION_CREATOR = "TEST-OPERATOR",
      X_PUBLISH_EXPECTED_USERNAME = "@TEST_PRIMARY",
    })

    t.eq(authority.effective_work_label, "host-session-42")
    t.eq(authority.logical_work_label, "auto-x-test-primary")
    t.eq(authority.creator, "test-operator")
    t.eq(authority.account, "test_primary")
  end,

  test_session_authority_fails_closed_on_ambiguous_reverse_mapping = function()
    local authority, why = core.resolve_session_authority({
      FKST_SESSION_WORK_LABEL = "host-session-42",
      FKST_SESSION_WORK_LABEL_MAP_JSON = '{"auto-x-one":"host-session-42","auto-x-two":"host-session-42"}',
      FKST_SESSION_CREATOR = "test-operator",
      FKST_X_PUBLISH_EXPECTED_USERNAME = "test_primary",
    })

    t.is_nil(authority)
    t.eq(why, "ambiguous-logical-work-label")
  end,

  test_session_authority_fails_closed_on_conflicting_expected_accounts = function()
    local authority, why = core.resolve_session_authority({
      FKST_SESSION_WORK_LABEL = "host-session-42",
      FKST_SESSION_CREATOR = "test-operator",
      X_PUBLISH_EXPECTED_USERNAME = "test_primary",
      FKST_X_PUBLISH_EXPECTED_USERNAME = "test_secondary",
    })
    t.is_nil(authority)
    t.eq(why, "conflicting-session-accounts")
  end,

  test_issue_source_ref_must_match_repo_and_number = function()
    local payload = issue(11, signal_body(), { source_ref = nil })
    local derived = assert(core.canonical_issue_source_ref(payload))
    t.eq(derived.ref, "owner/repo#issue/11")

    for _, invalid in ipairs({
      source_ref(12),
      { kind = "external", ref = source_ref(11).ref, reference = source_ref(12).ref },
      { kind = "internal", ref = source_ref(11).ref, reference = source_ref(11).ref },
    }) do
      local item, why = core.classify_issue(issue(11, signal_body(), {
        source_ref = invalid,
      }), { session = session() })
      t.is_nil(item)
      t.eq(why, "source-ref-issue-identity-mismatch")
    end
  end,

  test_signal_admission_requires_dynamic_label_creator_and_matching_account = function()
    local accepted = classify(11, signal_body())
    t.eq(accepted.account, "test_primary")
    t.eq(accepted.session_work_label, "host-session-42")
    t.eq(accepted.logical_work_label, "auto-x-test-primary")

    local _, label_why = classify(11, signal_body(), { labels = { "other" } })
    t.eq(label_why, "missing-session-work-label")
    local wrong_assignee = classify(11, signal_body(), { assignees = { "someone-else" } })
    t.eq(wrong_assignee.status, "needs-triage")
    t.eq(wrong_assignee.triage_reason, "session-creator-assignee-mismatch")
    local many_assignees = classify(11, signal_body(), {
      assignees = { "test-operator", "someone-else" },
    })
    t.eq(many_assignees.status, "needs-triage")
    t.eq(many_assignees.triage_reason, "requires-single-session-creator-assignee")
    local account_mismatch = classify(11, signal_body({ account = "test_secondary" }))
    t.eq(account_mismatch.status, "needs-triage")
    t.eq(account_mismatch.triage_reason, "account-session-mismatch")
  end,

  test_signal_admission_accepts_real_world_9kb_body_and_rejects_over_limit = function()
    local accepted = classify(11, signal_body() .. string.rep("n", 9000))
    t.eq(accepted.status, "awaiting-review")

    local oversized = classify(12, signal_body() .. string.rep("n", 12001))
    t.eq(oversized.status, "needs-triage")
    t.eq(oversized.triage_reason, "signal-body-too-large")
  end,

  test_signal_action_contract_marks_field_conflicts_for_triage = function()
    local add = classify(11, signal_body())
    local revise = classify(12, signal_body({ action = "revise", ["target-ref"] = "#99" }))
    local replan = classify(13, signal_body({ action = "replan" }))
    local add_conflict = classify(14, signal_body({ action = "add", ["target-ref"] = "#99" }))
    local revise_conflict = classify(15, signal_body({ action = "revise", ["target-ref"] = nil }))
    local missing_action = classify(16, signal_body({ action = "" }))
    local work_label_mismatch = classify(17, signal_body({ ["work-label"] = "auto-x-other" }))

    t.eq(add.action, "add")
    t.eq(revise.action, "revise")
    t.eq(revise.target_ref, "#99")
    t.eq(replan.action, "replan")
    t.eq(add_conflict.status, "needs-triage")
    t.eq(add_conflict.triage_reason, "add-forbids-target-ref")
    t.eq(revise_conflict.status, "needs-triage")
    t.eq(revise_conflict.triage_reason, "revise-requires-target-ref")
    t.eq(missing_action.status, "needs-triage")
    t.eq(missing_action.triage_reason, "missing-action")
    t.eq(work_label_mismatch.status, "needs-triage")
    t.eq(work_label_mismatch.triage_reason, "logical-work-label-mismatch")
  end,

  test_signal_digest_ignores_delivery_timestamp_but_changes_with_business_content = function()
    local first = classify(11, signal_body(), { updated_at = "2026-08-17T01:02:03Z" })
    local replay = classify(11, signal_body(), { updated_at = "2026-08-17T09:59:59Z" })
    local changed = classify(11, signal_body({ insight = "A materially different instruction." }))

    t.eq(first.signal_digest, replay.signal_digest)
    t.eq(first.dedup_key, replay.dedup_key)
    t.is_true(first.signal_digest ~= changed.signal_digest)
    t.is_true(first.artifact_id:find("/test_primary/2026-W33/", 1, true) ~= nil)
    local digest_hex = assert(first.signal_digest:match("^sha256:([0-9a-f]+)$"))
    t.eq(#digest_hex, 64)
    t.is_true(first.artifact_id:find(digest_hex, 1, true) ~= nil)
    t.is_nil(first.session_id)
  end,

  test_signal_set_groups_once_and_validates_generated_x_text = function()
    local one = classify(11, signal_body())
    local two = classify(12, signal_body({ ["source-url"] = "https://github.example/owner/repo/issues/12" }))
    local proposal_signals = { two, one, one }
    local replay_signals = { one, two }
    local proposal = core.build_proposal(proposal_signals, session(),
      draft(proposal_signals, "FKST workflows turn reviewed GitHub signals into auditable weekly updates."))
    local replay = core.build_proposal(replay_signals, session(),
      draft(replay_signals, "FKST workflows turn reviewed GitHub signals into auditable weekly updates."))

    t.eq(#proposal.signals, 2)
    t.eq(proposal.signal_set_digest, replay.signal_set_digest)
    t.eq(proposal.proposal_id, replay.proposal_id)
    t.eq(proposal.revision, replay.revision)
    t.eq(proposal.account, "test_primary")
    t.is_true(proposal.content_digest ~= nil)

    local invalid, why = core.build_proposal({ one }, session(), draft({ one }, string.rep("x", 281)))
    t.is_nil(invalid)
    t.eq(why, "invalid-x-text:text too long")

    local extra_evidence = draft({ one }, "A cited update.")
    extra_evidence.evidence_refs[#extra_evidence.evidence_refs + 1] = "owner/repo#issue/999"
    invalid, why = core.build_proposal({ one }, session(), extra_evidence)
    t.is_nil(invalid)
    t.eq(why, "unexpected-draft-evidence")
  end,

  test_generated_x_text_counts_ordinary_https_url_at_transformed_length = function()
    local one = classify(11, signal_body())
    local url = "https://example.com/releases/" .. string.rep("a", 512)
    local at_limit = string.rep("x", 256) .. " " .. url
    local proposal = assert(core.build_proposal(
      { one }, session(), draft({ one }, at_limit)))

    t.eq(proposal.weighted_length, 280)
    local parsed = assert(core.parse_proposal(assert(core.render_proposal(proposal))))
    t.eq(parsed.tweet_text, at_limit)

    local too_long, why = core.build_proposal(
      { one }, session(), draft({ one }, string.rep("x", 257) .. " " .. url))
    t.is_nil(too_long)
    t.eq(why, "invalid-x-text:text too long")
  end,

  test_signal_set_identity_is_cycle_scoped_and_bounded = function()
    local first = classify(11, signal_body())
    local next_cycle = classify(12, signal_body({
      insight = "A new approved input for the next add cycle.",
      ["source-url"] = "https://github.example/owner/repo/issues/12",
    }))
    local first_proposal = assert(core.build_proposal(
      { first }, session(), draft({ first }, "First reviewed cycle.")))
    local next_proposal = assert(core.build_proposal(
      { next_cycle }, session(), draft({ next_cycle }, "Next reviewed cycle.")))
    t.is_true(first_proposal.proposal_id ~= next_proposal.proposal_id)
    t.is_true(first_proposal.content_id ~= next_proposal.content_id)

    local too_many = {}
    for number = 1, 21 do
      too_many[#too_many + 1] = classify(number, signal_body({
        ["source-url"] = "https://github.example/owner/repo/issues/" .. tostring(number),
      }))
    end
    local identity, why = core.signal_set_identity(too_many, session())
    t.is_nil(identity)
    t.eq(why, "signal-group-too-large")
  end,

  test_review_accepts_only_authorized_command_for_current_revision = function()
    local one = classify(11, signal_body())
    local proposal = core.build_proposal({ one }, session(), draft({ one }, "A reviewed FKST weekly update."))
    local review = core.weekly_plan_change_issue_request(proposal, session())
    local current = {
      body = review.body,
      author_login = "fkst-test-bot",
      comments = {
        { id = 1, author_login = "outsider", body = "/marketing approve " .. proposal.proposal_id .. "@" .. proposal.revision },
      },
    }

    local decision, why = core.review_decision(current, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "unauthorized-review-command")

    current.comments[1].author_login = "test-operator"
    current.comments[1].body = "/marketing approve " .. proposal.proposal_id .. "@stale"
    decision, why = core.review_decision(current, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.is_nil(decision)
    t.eq(why, "stale-proposal-revision")

    current.comments[1].body = "/marketing approve " .. proposal.proposal_id .. "@" .. proposal.revision
    decision = core.review_decision(current, {
      bot_login = "fkst-test-bot",
      authorized_reviewers = { "test-operator" },
    })
    t.eq(decision.command, "approve")
    t.eq(decision.proposal.content_digest, proposal.content_digest)
  end,

  test_approval_creates_immutable_content_without_publish_request = function()
    local signal = classify(11, signal_body())
    local proposal = core.build_proposal({ signal }, session(), draft({ signal }, "A reviewed FKST weekly update."))
    local request = core.approved_weekly_content_issue_request(proposal, session())

    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.eq(request.labels[1], "host-session-42")
    t.eq(request.assignees[1], "test-operator")
    t.is_true(request.body:find("status: approved", 1, true) ~= nil)
    t.is_true(request.body:find("account: test_primary", 1, true) ~= nil)
    t.is_true(request.body:find("content-digest: " .. proposal.content_digest, 1, true) ~= nil)
    t.is_nil(request.operation)
    t.is_nil(request.publish_text)
  end,
}
