local caps = require("import_issue_caps")
local draft_port = require("draft_generator")
local durable_triage = require("durable_triage")
local ingress_block = require("ingress_block")
local materialization = require("materialization")
local issue_catalog = require("issue_catalog")
local proposal_reviews = require("proposal_review_catalog")
local env = require("workflow.env")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")
local strings = require("contract.strings")
local supersession = require("supersession")
local terminal_recovery = require("terminal_recovery")

local spec = {
  consumes = { "github-proxy.github_issue_changed", "github-proxy.github_issue_observed" },
  produces = {
    "radar_config_imported",
    "radar_signal_imported",
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_create_request",
  },
  fanout = { "github-proxy.github_issue_changed", "github-proxy.github_issue_observed" },
  stall_window = "30s",
}

local ALLOWED_ENV = {
  FKST_DEVLOOP_MANAGED_BOT_LOGINS = true,
  FKST_GITHUB_AUTHORIZED_LOGINS = true,
  FKST_GITHUB_BOT_LOGIN = true,
  FKST_MARKETING_COLLABORATOR_LOGINS = true,
  FKST_SESSION_CREATOR = true,
  FKST_SESSION_WORK_LABEL = true,
  FKST_SESSION_WORK_LABEL_MAP_JSON = true,
  FKST_X_PUBLISH_EXPECTED_USERNAME = true,
  X_PUBLISH_EXPECTED_USERNAME = true,
}

local GITHUB_AUTHOR_LOGIN_ENVS = {
  "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
  "FKST_GITHUB_AUTHORIZED_LOGINS",
  "FKST_MARKETING_COLLABORATOR_LOGINS",
  "FKST_SESSION_CREATOR",
}

local function read_env_command(name)
  if not ALLOWED_ENV[name] then
    error("marketing-radar: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

local function environment_values()
  local values = {}
  for name, _ in pairs(ALLOWED_ENV) do
    values[name] = read_env(name)
  end
  return values
end

local function csv_values(value)
  local values = {}
  for item in tostring(value or ""):gmatch("[^,%s]+") do
    values[#values + 1] = item
  end
  return values
end

local function done(_event)
  return false
end

local function issue_source_ref(repo, number)
  if strings.trim(repo) == "" or tonumber(number) == nil then
    return nil
  end
  local ref = tostring(repo) .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function fetched_issue(github, payload, force_fresh)
  if type(github) ~= "table" or type(github.read_issue) ~= "function" then
    error("marketing-radar: GitHub read port unavailable", 0)
  end
  local source_ref = caps.canonical_issue_source_ref(payload)
  if source_ref == nil then
    return nil
  end
  return github.read_issue(source_ref, {
    updated_at = force_fresh and nil or payload.updated_at,
    force_fresh = force_fresh == true,
    consumer = "marketing-radar-v2",
  })
end

local function classify(payload, issue, session, signal_authors)
  return caps.classify_issue(payload, {
    session = session,
    issue_body = issue and issue.body or payload.body,
    issue_labels = issue and issue.labels or payload.labels,
    issue_assignees = issue and issue.assignees or payload.assignees,
    issue_author_login = issue and issue.author_login or payload.author_login,
    authorized_signal_authors = signal_authors,
  })
end

local function catalog_rows(github, repo, state)
  local rows, why = issue_catalog.list(github, repo, state)
  if rows == nil then
    error("marketing-radar: " .. tostring(why), 0)
  end
  return rows
end

local row_author = issue_catalog.row_author
local row_labels = issue_catalog.row_labels
local row_assignees = issue_catalog.row_assignees

local function row_payload(repo, row)
  return {
    schema = "github-proxy.v1",
    type = "issue",
    repo = repo,
    number = tonumber(row.number),
    state = row.state or "OPEN",
    labels = row_labels(row),
    assignees = row_assignees(row),
    body = row.body,
    source_ref = issue_source_ref(repo, row.number),
  }
end

local function same_group(left, right)
  return caps.proposal_group_key(left) == caps.proposal_group_key(right)
end

local function signal_group(rows, repo, current, session, signal_authors)
  local signals = {}
  local seen = {}
  local function include(payload, issue)
    local item = classify(payload, issue, session, signal_authors)
    local ref = item and item.source_ref and item.source_ref.ref
    if item ~= nil and item.kind == "radar-signal" and item.status == "awaiting-review"
        and same_group(item, current) and not seen[ref] then
      seen[ref] = true
      signals[#signals + 1] = item
    end
  end
  include({
    schema = "github-proxy.v1",
    type = "issue",
    repo = current.repo,
    number = current.issue_number,
    labels = { current.session_work_label },
    assignees = { current.session_creator },
    author_login = current.raw_author_login,
    body = current.raw_body,
    source_ref = current.source_ref,
  }, {
    body = current.raw_body,
    labels = { current.session_work_label },
    assignees = { current.session_creator },
    author_login = current.raw_author_login,
  })
  for _, row in ipairs(rows) do
    include(row_payload(repo, row), {
      body = row.body,
      labels = row_labels(row),
      assignees = row_assignees(row),
      author_login = row_author(row),
    })
  end
  return signals
end

local function matching_review(
    github, rows, repo, identity, session, options, trigger_signal, include_terminal_history)
  return proposal_reviews.matching_review(
    github, rows, repo, identity, session, options, trigger_signal,
    include_terminal_history, classify)
end

local next_proposal_cycle = proposal_reviews.next_cycle
local terminal_item = terminal_recovery.signal_item
local terminal_review_item = terminal_recovery.review_item
local terminal_status = terminal_recovery.status
local trusted_terminal_status = terminal_recovery.trusted_status

local function raise_terminal_comments(item, decision, session, status)
  local review_terminal = terminal_review_item(item, decision, session)
  raise("github-proxy.github_issue_comment_request", caps.status_comment(
    review_terminal,
    status,
    caps.close_handoff(review_terminal, "weekly-plan-change", decision)
  ))
  for _, signal in ipairs(decision.proposal.signals) do
    local signal_terminal = terminal_item(signal, session)
    raise("github-proxy.github_issue_comment_request", caps.status_comment(
      signal_terminal,
      status,
      caps.close_handoff(signal_terminal, "radar-signal", decision)
    ))
  end
end

local function draft_failure_needs_triage(why)
  return durable_triage.failure_reason(why)
end

local function raise_signal_triage(signal, identity, reason)
  local item, why = durable_triage.status_item(signal, identity)
  if item == nil then
    error("marketing-radar: durable triage identity failed: " .. tostring(why), 0)
  end
  raise("github-proxy.github_issue_comment_request", caps.status_comment(
    item, "needs-triage: " .. tostring(reason)))
end

local function raise_signal_set_triage(identity, reason)
  local anchor, why = durable_triage.anchor(identity)
  if anchor == nil then
    error("marketing-radar: durable triage anchor failed: " .. tostring(why), 0)
  end
  for _, signal in ipairs(identity.signals or {}) do
    if signal.source_ref.ref ~= anchor.source_ref.ref then
      raise_signal_triage(signal, identity, reason)
    end
  end
  raise_signal_triage(anchor, identity, reason)
end

local function make_department(handles)
  local ports = handles or {}
  local github = ports.github
  local session_authority = ports.session_authority or function()
    return caps.resolve_session_authority(environment_values())
  end
  local route_authority = ports.route_authority or function()
    return caps.resolve_session_route(environment_values())
  end
  local review_options = ports.review_options or function()
    local values = environment_values()
    return {
      bot_login = values.FKST_GITHUB_BOT_LOGIN,
      authorized_reviewers = csv_values(values.FKST_GITHUB_AUTHORIZED_LOGINS),
    }
  end
  local signal_author_logins = ports.signal_author_logins or function(session)
    local values = environment_values()
    local logins = { session.creator }
    for _, login in ipairs(csv_values(values.FKST_MARKETING_COLLABORATOR_LOGINS)) do
      logins[#logins + 1] = login
    end
    for _, login in ipairs(csv_values(values.FKST_GITHUB_AUTHORIZED_LOGINS)) do
      logins[#logins + 1] = login
    end
    return logins
  end
  local draft_generator = ports.draft_generator or function(signals, revision, context)
    return draft_port.generate(signals, revision, ports.spawn_codex_sync, context)
  end

  local function reload_proposal_signals(proposal, session)
    local signals = {}
    local authors = signal_author_logins(session)
    for _, expected in ipairs(proposal.signals) do
      local issue = github.read_issue(expected.source_ref, {
        force_fresh = true,
        consumer = "marketing-radar-v2-request-changes",
      })
      if type(issue) ~= "table" or tostring(issue.state or ""):upper() ~= "OPEN" then
        return nil, "signal-not-open"
      end
      local payload = {
        schema = "github-proxy.v1",
        type = "issue",
        repo = expected.source_ref.ref:match("^([^#]+)#"),
        number = tonumber(expected.source_ref.ref:match("#issue/(%d+)$")),
        source_ref = expected.source_ref,
      }
      local signal, why = classify(payload, issue, session, authors)
      if signal == nil or signal.kind ~= "radar-signal" or signal.status == "needs-triage"
          or signal.signal_digest ~= expected.signal_digest then
        return nil, "signal-changed-during-review:" .. tostring(why or signal and signal.triage_reason)
      end
      signals[#signals + 1] = signal
    end
    return signals
  end

  local function current_proposal_signals(proposal, session, repo)
    local authors = signal_author_logins(session)
    local rows = catalog_rows(github, repo, "open")
    local by_ref = {}
    for _, row in ipairs(rows) do
      local signal = classify(row_payload(repo, row), {
        body = row.body,
        labels = row_labels(row),
        assignees = row_assignees(row),
        author_login = row_author(row),
      }, session, authors)
      if signal ~= nil and signal.kind == "radar-signal" and signal.status == "awaiting-review"
          and caps.proposal_group_key(signal) == proposal.group_key then
        by_ref[signal.source_ref.ref] = signal
      end
    end
    local fresh, why = reload_proposal_signals(proposal, session)
    if fresh == nil then
      return nil, why
    end
    for _, signal in ipairs(fresh) do
      by_ref[signal.source_ref.ref] = signal
    end
    local signals = {}
    for _, signal in pairs(by_ref) do
      signals[#signals + 1] = signal
    end
    local identity, identity_why = caps.signal_set_identity(signals, session)
    if identity == nil then
      return nil, identity_why
    end
    if identity.group_key ~= proposal.group_key
        or identity.signal_set_digest ~= proposal.signal_set_digest then
      return nil, "signal-set-changed-during-review"
    end
    return identity.signals, nil
  end

  local function proposal_lineage(signals, identity, session, existing, revision)
    local values = {}
    if existing ~= nil then
      values.proposal_id = existing.latest.proposal_id
    end
    if signals[1].action == "revise" then
      local rows = catalog_rows(github, signals[1].repo, "all")
      local revision_input = {
        action = signals[1].action,
        target_ref = signals[1].target_ref,
        project = signals[1].project,
        account = signals[1].account,
        work_label = session.logical_work_label,
        week = signals[1].week,
      }
      local resolved, why = supersession.resolve_revision_lineage(
        revision_input, signals[1].repo, rows,
        function(ref)
          return github.read_issue(ref, {
            force_fresh = true,
            consumer = "marketing-radar-v2-revision-lineage",
          })
        end,
        {
          effective_work_label = session.effective_work_label,
          logical_work_label = session.logical_work_label,
          creator = session.creator,
          account = session.account,
          bot_login = review_options().bot_login,
        },
        function(expected)
          return issue_catalog.receipt_issue_rows(github, signals[1].repo, expected)
        end
      )
      if resolved == nil then
        return nil, why
      end
      values.content_id = resolved.content_id
      values.content_revision = resolved.content_revision
    elseif existing ~= nil then
      values.content_id = existing.latest.content_id
      values.content_revision = revision
    end
    return values, nil
  end

  -- The catalog is an eventually-consistent discovery surface. Before any
  -- proposal lineage, AI draft, or create request is derived, re-read every
  -- member of the discovered set and use those classified values as the
  -- authoritative input. A single anchor check is insufficient when a
  -- sibling was edited, closed, or rerouted after catalog discovery.
  local function fresh_signal_set(identity, session)
    local issues = {}
    local signals = {}
    local authors = signal_author_logins(session)
    for _, expected in ipairs(identity.signals or {}) do
      local ref = expected.source_ref.ref
      local issue = github.read_issue(expected.source_ref, {
        force_fresh = true,
        consumer = "marketing-radar-v2-durable-triage-set",
      })
      if type(issue) ~= "table" or tostring(issue.state or ""):upper() ~= "OPEN" then
        return nil, "signal-not-open"
      end
      local payload = {
        schema = "github-proxy.v1",
        type = "issue",
        repo = ref:match("^([^#]+)#"),
        number = tonumber(ref:match("#issue/(%d+)$")),
        source_ref = expected.source_ref,
      }
      local current, why = classify(payload, issue, session, authors)
      if current == nil or current.kind ~= "radar-signal" or current.status ~= "awaiting-review"
          or current.signal_digest ~= expected.signal_digest
          or caps.proposal_group_key(current) ~= identity.group_key then
        local mismatch = why or current and current.triage_reason
        if mismatch == nil and current ~= nil then
          if current.kind ~= "radar-signal" then
            mismatch = "signal-kind-changed"
          elseif current.status ~= "awaiting-review" then
            mismatch = "signal-not-awaiting-review"
          elseif current.signal_digest ~= expected.signal_digest then
            mismatch = "signal-digest-mismatch"
          elseif caps.proposal_group_key(current) ~= identity.group_key then
            mismatch = "signal-group-mismatch"
          end
        end
        return nil, "signal-set-changed:" .. tostring(mismatch or "invalid-signal")
      end
      -- Keep the fresh authority visible to downstream adapters as well as in
      -- trusted_body_context, so lineage/draft callers cannot accidentally
      -- fall back to the stale catalog row.
      current.raw_body = issue.body
      current.raw_author_login = issue.author_login
      issues[ref] = issue
      signals[#signals + 1] = current
    end
    local fresh_identity, identity_why = caps.signal_set_identity(signals, session)
    if fresh_identity == nil then
      return nil, "signal-set-changed:" .. tostring(identity_why)
    end
    if fresh_identity.group_key ~= identity.group_key
        or fresh_identity.signal_set_digest ~= identity.signal_set_digest then
      return nil, "signal-set-changed:digest-or-group-mismatch"
    end
    return {
      identity = fresh_identity,
      signals = fresh_identity.signals,
      issues = issues,
    }, nil
  end

  local function handle_signal(item, current_issue, session)
    raise("radar_signal_imported", caps.radar_signal_imported(item))
    if item.status == "needs-triage" then
      raise("github-proxy.github_issue_comment_request", caps.status_comment(
        item, "needs-triage: " .. tostring(item.triage_reason)))
      return
    end
    local options = review_options()
    local rows = catalog_rows(github, item.repo, "open")
    item.raw_body = current_issue.body
    item.raw_author_login = current_issue.author_login
    local signals = signal_group(rows, item.repo, item, session, signal_author_logins(session))
    local identity, identity_why = caps.signal_set_identity(signals, session)
    if identity == nil then
      raise("github-proxy.github_issue_comment_request", caps.status_comment(
        item, "needs-triage: " .. tostring(identity_why)))
      return
    end
    local existing, existing_why = matching_review(
      github, rows, item.repo, identity, session, options, item, false)
    if existing_why ~= nil then
      raise("github-proxy.github_issue_comment_request", caps.status_comment(
        item, "needs-triage: " .. tostring(existing_why)))
      return
    end
    local all_rows
    local retired_rc2 = {}
    if existing == nil then
      all_rows = catalog_rows(github, item.repo, "all")
      existing, existing_why = matching_review(
        github, all_rows, item.repo, identity, session, options, item, true)
      if existing_why ~= nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(existing_why)))
        return
      end
      retired_rc2, existing_why = proposal_reviews.retired_rc2_history(
        github, all_rows, item.repo, identity, session, options)
      if retired_rc2 == nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(existing_why)))
        return
      end
    end
    if existing ~= nil and existing.terminal then
      local status = trusted_terminal_status(existing, item.repo, session, options.bot_login)
      if status == nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: terminal-review-status-missing"))
        return
      end
      local recoverable, recoverable_why = terminal_recovery.recoverable_signals(
        github, existing.decision.proposal, session, signal_author_logins(session), classify)
      if recoverable == nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(recoverable_why)))
        return
      end
      if not existing.closed then
        local review_terminal = terminal_review_item({
          source_ref = existing.decision.proposal.review_source_ref,
          repo = item.repo,
          issue_number = tonumber(existing.row.number),
          trace_id = "github:marketing-radar:"
            .. existing.decision.proposal.review_source_ref.ref,
        }, existing.decision, session)
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          review_terminal,
          status,
          caps.close_handoff(review_terminal, "weekly-plan-change", existing.decision)
        ))
      end
      for _, signal in ipairs(recoverable) do
        local signal_terminal = terminal_item(signal, session)
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          signal_terminal,
          status,
          caps.close_handoff(signal_terminal, "radar-signal", existing.decision)
        ))
      end
      if not proposal_reviews.proposal_contains_signal(existing.decision.proposal, item) then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "awaiting-prior-terminal-handoff"))
      end
      return
    end
    if existing ~= nil and existing.latest.signal_set_digest == identity.signal_set_digest then
      raise("github-proxy.github_issue_comment_request", caps.status_comment(item, "awaiting-review"))
      return
    end
    local fresh_set, fresh_set_why = fresh_signal_set(identity, session)
    if fresh_set == nil then
      log.info("marketing-radar dept=import_issue tag=SKIP reason=signal-set-changed-during-durable-check:"
        .. tostring(fresh_set_why))
      return
    end
    -- From this point onward all proposal inputs are the fresh classified set.
    identity = fresh_set.identity
    signals = fresh_set.signals
    local anchor, anchor_why = durable_triage.anchor(identity)
    if anchor == nil then
      error("marketing-radar: durable triage anchor failed: " .. tostring(anchor_why), 0)
    end
    local anchor_issue = fresh_set.issues[anchor.source_ref.ref]
    local persisted_failure, persisted_why = durable_triage.persisted_failure(
      anchor_issue, identity, options.bot_login)
    if persisted_why ~= nil then
      error("marketing-radar: durable triage lookup failed: " .. tostring(persisted_why), 0)
    end
    if persisted_failure ~= nil then
      for _, signal in ipairs(identity.signals) do
        if not durable_triage.has_failure(
            fresh_set.issues[signal.source_ref.ref], signal, identity,
            persisted_failure, options.bot_login) then
          raise_signal_triage(signal, identity, persisted_failure)
        end
      end
      log.info("marketing-radar dept=import_issue tag=SKIP reason=durable-triage-"
        .. persisted_failure)
      return
    end
    local revision = 1
    if existing ~= nil then
      local revision_why
      revision, revision_why = caps.next_proposal_revision(existing.latest.revision)
      if revision == nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(revision_why)))
        return
      end
    end
    local lineage, lineage_why = proposal_lineage(signals, identity, session, existing, revision)
    if lineage == nil then
      raise("github-proxy.github_issue_comment_request", caps.status_comment(
        item, "needs-triage: " .. tostring(lineage_why)))
      return
    end
    local generated, draft_why = draft_generator(signals, revision)
    if generated == nil then
      local durable_failure = draft_failure_needs_triage(draft_why)
      if durable_failure ~= nil then
        raise_signal_set_triage(identity, durable_failure)
        return
      end
      error("marketing-radar: read-only draft generation failed: " .. tostring(draft_why), 0)
    end
    local proposal, proposal_why = caps.build_proposal(signals, session, generated, lineage)
    if proposal == nil then
      if proposal_why == "signal-group-too-large" or proposal_why == "proposal-body-too-large" then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(proposal_why)))
        return
      end
      error("marketing-radar: proposal generation failed: " .. tostring(proposal_why), 0)
    end
    if existing == nil then
      local history_unchanged, history_why = proposal_reviews.revalidate_retired_rc2(
        github, item.repo, retired_rc2, session, options)
      if not history_unchanged then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(history_why)))
        return
      end
      all_rows = catalog_rows(github, item.repo, "all")
      local concurrent, concurrent_why = matching_review(
        github, all_rows, item.repo, identity, session, options, item, false)
      if concurrent_why ~= nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(concurrent_why)))
        return
      end
      local concurrent_terminal, terminal_why = matching_review(
        github, all_rows, item.repo, identity, session, options, item, true)
      if terminal_why ~= nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(terminal_why)))
        return
      end
      if concurrent ~= nil or concurrent_terminal ~= nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "awaiting-review"))
        return
      end
      local cycle, cycle_why = next_proposal_cycle(
        all_rows, identity.group_key, caps.proposal_rc2_group_key(identity.first), options.bot_login)
      if cycle == nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(cycle_why)))
        return
      end
      raise("github-proxy.github_issue_create_request",
        caps.weekly_plan_change_issue_request(proposal, session, cycle))
    else
      raise("github-proxy.github_issue_comment_request",
        caps.proposal_revision_comment_request(existing.issue, proposal))
    end
    raise("github-proxy.github_issue_comment_request", caps.status_comment(item, "awaiting-review"))
  end

  local function handle_review(item, current_issue, session)
    local decision, why = caps.review_decision(current_issue, review_options())
    if decision == nil then
      if why ~= "no-review-command" then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(item, "blocked: " .. tostring(why)))
      end
      return
    end
    decision.proposal.review_source_ref = item.source_ref
    if decision.command == "request-changes" then
      local signals, reload_why = current_proposal_signals(decision.proposal, session, item.repo)
      if signals == nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(reload_why)))
        return
      end
      local revision, revision_why = caps.next_proposal_revision(decision.proposal.revision)
      if revision == nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(revision_why)))
        return
      end
      local next_draft, draft_why = draft_generator(signals, revision, {
        change_request = decision.reason,
      })
      if next_draft == nil then
        local durable_failure = draft_failure_needs_triage(draft_why)
        if durable_failure ~= nil then
          local failure_status, failure_why = caps.review_failure_status(decision, durable_failure)
          if failure_status == nil then
            error("marketing-radar: review failure correlation failed: "
              .. tostring(failure_why), 0)
          end
          raise("github-proxy.github_issue_comment_request", caps.status_comment(
            item, failure_status))
          return
        end
        error("marketing-radar: requested revision generation failed: " .. tostring(draft_why), 0)
      end
      local next_lineage = {
        proposal_id = decision.proposal.proposal_id,
        content_id = decision.proposal.content_id,
        content_revision = decision.proposal.action == "revise"
          and decision.proposal.content_revision or revision,
      }
      local next_proposal, proposal_why = caps.build_proposal(signals, session, next_draft, next_lineage)
      if next_proposal == nil or next_proposal.proposal_id ~= decision.proposal.proposal_id then
        error("marketing-radar: requested revision contract failed: " .. tostring(proposal_why), 0)
      end
      raise("github-proxy.github_issue_comment_request",
        caps.proposal_revision_comment_request(current_issue, next_proposal))
      raise("github-proxy.github_issue_comment_request", caps.status_comment(
        item, "changes-requested; proposal revision " .. tostring(revision) .. " generated"))
      return
    end
    if decision.command == "approve" then
      local approved_signals, signals_why = current_proposal_signals(decision.proposal, session, item.repo)
      if approved_signals == nil then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(signals_why)))
        return
      end
      local supersede = {}
      if decision.proposal.action ~= "add" then
        local rows = catalog_rows(github, item.repo, "all")
        local supersede_why
        supersede, supersede_why = supersession.plan(
          decision.proposal,
          item.repo,
          rows,
          function(ref)
            return github.read_issue(ref, {
              force_fresh = true,
              consumer = "marketing-radar-v2-supersession",
            })
          end,
          {
            effective_work_label = session.effective_work_label,
            logical_work_label = session.logical_work_label,
            creator = session.creator,
            account = session.account,
            bot_login = review_options().bot_login,
          },
          function(expected)
            return issue_catalog.receipt_issue_rows(github, item.repo, expected)
          end
        )
        if supersede == nil then
          raise("github-proxy.github_issue_comment_request", caps.status_comment(
            item, "needs-triage: " .. tostring(supersede_why)))
          return
        end
      end
      local content_request = caps.approved_weekly_content_issue_request(decision.proposal, session)
      local options = review_options()
      local content_number = materialization.trusted_created_issue_number(
        current_issue.comments,
        content_request.dedup_key,
        options.bot_login
      )
      if content_number == nil then
        raise("github-proxy.github_issue_create_request", content_request)
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "awaiting-materialization: approved weekly-content requested"))
        return
      end
      local content_ref = issue_source_ref(item.repo, content_number)
      local content_issue = github.read_issue(content_ref, {
        force_fresh = true,
        consumer = "marketing-radar-v2-materialization",
      })
      local materialized, materialized_why = materialization.validate_content_issue(
        content_issue,
        decision.proposal,
        session,
        content_number,
        options.bot_login
      )
      if materialized == nil then
        if materialized_why == "materialized-content-not-immutable" then
          raise("github-proxy.github_issue_comment_request", caps.status_comment(
            item, "awaiting-content-import: weekly-content is not immutable yet"))
          return
        end
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(materialized_why)))
        return
      end
      local pending_supersession = false
      for _, candidate in ipairs(supersede) do
        local candidate_issue = github.read_issue(candidate.source_ref, {
          force_fresh = true,
          consumer = "marketing-radar-v2-supersession-ack",
        })
        local applied, applied_why = supersession.is_superseded(
          candidate_issue, candidate, decision.proposal, review_options().bot_login)
        if applied == nil then
          raise("github-proxy.github_issue_comment_request", caps.status_comment(
            item, "needs-triage: " .. tostring(applied_why)))
          return
        end
        if not applied then
          pending_supersession = true
          raise("github-proxy.github_issue_comment_request",
            supersession.comment_request(candidate, decision.proposal))
        end
      end
      if pending_supersession then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "awaiting-supersession: prior content markers requested"))
        return
      end
      raise_terminal_comments(item, decision, session, terminal_status(decision))
      return
    end
    local rejected_signals, signals_why = current_proposal_signals(
      decision.proposal, session, item.repo)
    if rejected_signals == nil then
      raise("github-proxy.github_issue_comment_request", caps.status_comment(
        item, "needs-triage: " .. tostring(signals_why)))
      return
    end
    decision.proposal.signals = rejected_signals
    raise_terminal_comments(item, decision, session, terminal_status(decision))
  end

  local function act(event)
    local payload = event.payload or {}
    local session, session_why = session_authority()
    if session == nil then
      local route = route_authority()
      local issue = fetched_issue(github, payload, true)
      local fields = type(issue) == "table" and caps.parse_control_fields(issue.body) or {}
      local request = ingress_block.comment(
        payload, issue, route, session_why, fields and fields.account)
      if request ~= nil and tostring(issue.state or ""):upper() == "OPEN" then
        raise("github-proxy.github_issue_comment_request", request)
      end
      log.warn("marketing-radar dept=import_issue tag=SKIP reason=session-authority-invalid: "
        .. tostring(session_why))
      return
    end
    local ok, current_or_error = pcall(fetched_issue, github, payload, true)
    if not ok then
      error("marketing-radar: current issue read failed: " .. tostring(current_or_error), 0)
    end
    if current_or_error == nil then
      log.info("marketing-radar dept=import_issue tag=SKIP reason=invalid-source-ref")
      return
    end
    if tostring(current_or_error.state or ""):upper() ~= "OPEN" then
      log.info("marketing-radar dept=import_issue tag=SKIP reason=issue-not-open")
      return
    end
    local item, why = classify(payload, current_or_error, session, signal_author_logins(session))
    if item == nil then
      log.info("marketing-radar dept=import_issue tag=SKIP reason=" .. tostring(why))
      return
    end
    if item.kind == "radar-signal" then
      handle_signal(item, current_or_error, session)
    elseif item.kind == "weekly-plan-change" then
      if item.status == "needs-triage" then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(item.triage_reason)))
        return
      end
      handle_review(item, current_or_error, session)
    elseif item.kind == "radar-config" then
      if item.status == "needs-triage" then
        raise("github-proxy.github_issue_comment_request", caps.status_comment(
          item, "needs-triage: " .. tostring(item.triage_reason)))
        return
      end
      raise("radar_config_imported", caps.radar_config_imported(item))
      raise("github-proxy.github_issue_comment_request", caps.status_comment(item, "radar-config active"))
    else
      error("marketing-radar: unsupported classified type", 0)
    end
  end

  return saga.department(spec, { done = done, act = act, name = "import_issue" })
end

local department = ports_lib.install(make_department, ports_lib.github_author_options(read_env, "marketing-radar", {
  bot_login_env = "FKST_GITHUB_BOT_LOGIN",
  extra_login_envs = GITHUB_AUTHOR_LOGIN_ENVS,
}))
department.github_author_login_envs = GITHUB_AUTHOR_LOGIN_ENVS
return department
