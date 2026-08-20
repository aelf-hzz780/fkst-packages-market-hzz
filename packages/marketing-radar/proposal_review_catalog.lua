local caps = require("import_issue_caps")
local issue_catalog = require("issue_catalog")
local session_route = require("contract.session_route")
local strings = require("contract.strings")

local M = {}

local row_author = issue_catalog.row_author
local row_labels = issue_catalog.row_labels
local row_assignees = issue_catalog.row_assignees

local function issue_source_ref(repo, number)
  if strings.trim(repo) == "" or tonumber(number) == nil then
    return nil
  end
  local ref = tostring(repo) .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

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

local function review_issue(github, repo, row)
  return github.read_issue(issue_source_ref(repo, row.number), {
    force_fresh = true,
    consumer = "marketing-radar-v2-review",
  })
end

local function routed_to_session(issue, session)
  local assignee = session_route.single_assignee(row_assignees(issue))
  return session_route.has_label(row_labels(issue), session.effective_work_label)
    and caps.normalized_login(assignee) == caps.normalized_login(session.creator)
end

local function proposal_contains_signal(proposal, signal)
  local expected_ref = signal and signal.source_ref and signal.source_ref.ref
  local expected_digest = signal and signal.signal_digest
  if type(expected_ref) ~= "string" or type(expected_digest) ~= "string" then
    return false
  end
  for _, member in ipairs(proposal and proposal.signals or {}) do
    if member.source_ref and member.source_ref.ref == expected_ref
        and member.signal_digest == expected_digest then
      return true
    end
  end
  return false
end

local function proposal_overlaps_identity(proposal, identity)
  local refs = {}
  for _, member in ipairs(proposal and proposal.signals or {}) do
    if member.source_ref and type(member.source_ref.ref) == "string" then
      refs[member.source_ref.ref] = true
    end
  end
  for _, signal in ipairs(identity and identity.signals or {}) do
    if signal.source_ref and refs[signal.source_ref.ref] then
      return true
    end
  end
  return false
end

local function has_authorized_terminal_command(issue, options)
  local authorized = {}
  for _, login in ipairs(options.authorized_reviewers or {}) do
    local normalized = caps.normalized_login(login)
    if normalized ~= nil then authorized[normalized] = true end
  end
  for _, comment in ipairs(issue.comments or {}) do
    local author = caps.normalized_login(comment.author_login)
    local command = strings.trim(comment.body or ""):match("^/marketing%s+([%a%-]+)%s+")
    if authorized[author] and (command == "approve" or command == "reject") then
      return true
    end
  end
  return false
end

local function fresh_candidate(
    github, repo, row, identity, session, options, catalog_group_matched,
    catalog_provenance, trigger_signal, terminal_history_only, classify)
  local issue = review_issue(github, repo, row)
  if type(issue) ~= "table" then
    return nil, "review-read-failed"
  end
  if caps.normalized_login(row_author(issue)) ~= caps.normalized_login(options.bot_login) then
    return nil, "review-author-mismatch"
  end
  local state = tostring(issue.state or ""):upper()
  if not routed_to_session(issue, session) then
    return nil, nil
  end
  if state ~= "OPEN" and state ~= "CLOSED" then
    return nil, "invalid-review-state"
  end
  if terminal_history_only then
    if state ~= "CLOSED" or not has_authorized_terminal_command(issue, options) then
      return nil, nil
    end
  elseif state == "CLOSED" then
    return nil, nil
  end
  local fresh_provenance, fresh_provenance_why = caps.proposal_create_provenance(issue.body)
  if fresh_provenance == nil then
    return nil, "active-review-invalid:" .. tostring(fresh_provenance_why)
  end
  if fresh_provenance.group_key ~= identity.group_key then
    return nil, "active-review-invalid:proposal-create-provenance-group-mismatch"
  end
  if catalog_provenance ~= nil
      and (fresh_provenance.group_key ~= catalog_provenance.group_key
        or fresh_provenance.cycle ~= catalog_provenance.cycle) then
    return nil, "active-review-invalid:proposal-create-provenance-changed"
  end
  local fresh_group, fresh_intent, inspect_why = caps.proposal_catalog_group(issue.body)
  if not fresh_intent then
    return nil, catalog_group_matched
      and "active-review-invalid:proposal-identity-disappeared" or nil
  end
  if fresh_group == nil then
    return nil, "active-review-invalid:" .. tostring(inspect_why)
  end
  if fresh_group ~= identity.group_key then
    return nil, catalog_group_matched
      and "active-review-invalid:proposal-group-changed" or nil
  end
  local classified, classified_why = classify(row_payload(repo, row), issue, session, {})
  if classified == nil or classified.kind ~= "weekly-plan-change"
      or classified.status == "needs-triage" then
    return nil, "active-review-invalid:"
      .. tostring(classified_why or classified and classified.triage_reason)
  end
  local latest, latest_why = caps.latest_proposal(issue, options.bot_login)
  if latest == nil then
    return nil, "active-review-invalid:" .. tostring(latest_why)
  end
  if latest.group_key ~= identity.group_key then
    return nil, "active-review-group-mismatch"
  end
  local decision = caps.review_decision(issue, options)
  local terminal = decision ~= nil
    and (decision.command == "approve" or decision.command == "reject")
  if state == "CLOSED" and not terminal then
    return nil, nil
  end
  if terminal and latest.signal_set_digest ~= identity.signal_set_digest
      and not proposal_contains_signal(latest, trigger_signal)
      and not proposal_overlaps_identity(latest, identity) then
    return nil, nil
  end
  local ref = issue_source_ref(repo, row.number)
  latest.review_source_ref = ref
  if decision ~= nil and type(decision.proposal) == "table" then
    decision.proposal.review_source_ref = ref
  end
  return {
    row = row,
    issue = issue,
    latest = latest,
    decision = decision,
    terminal = terminal,
    closed = state == "CLOSED",
  }, nil
end

function M.matching_review(
    github, rows, repo, identity, session, options, trigger_signal,
    terminal_history_only, classify)
  local expected_bot = caps.normalized_login(options.bot_login)
  if expected_bot == nil then
    return nil, "missing-bot-login"
  end
  local active = {}
  local terminal_same_set = {}
  for _, row in ipairs(rows) do
    local catalog_state = tostring(row.state or ""):upper()
    if caps.normalized_login(row_author(row)) == expected_bot
        and (not terminal_history_only or catalog_state == "CLOSED") then
      local catalog_provenance = caps.proposal_create_provenance(row.body)
      local group_key, intent = caps.proposal_catalog_group(row.body)
      local catalog_group_matched = group_key == identity.group_key
      local marker_group_matched = catalog_provenance ~= nil
        and catalog_provenance.group_key == identity.group_key
      if (catalog_group_matched or marker_group_matched)
          or (intent and group_key == nil) then
        local candidate, candidate_why = fresh_candidate(
          github, repo, row, identity, session, options,
          catalog_group_matched or marker_group_matched, catalog_provenance,
          trigger_signal, terminal_history_only, classify)
        if candidate_why ~= nil then
          return nil, candidate_why
        end
        if candidate ~= nil then
          if candidate.terminal then
            terminal_same_set[#terminal_same_set + 1] = candidate
          else
            active[#active + 1] = candidate
          end
        end
      end
    end
  end
  if #active > 1 or #terminal_same_set > 1
      or (#active == 1 and #terminal_same_set == 1) then
    return nil, "ambiguous-active-review"
  end
  return active[1] or terminal_same_set[1], nil
end

function M.next_cycle(rows, group_key, bot_login)
  local expected_bot = caps.normalized_login(bot_login)
  if expected_bot == nil then
    return nil, "missing-bot-login"
  end
  local seen = {}
  local cycles = {}
  local max_cycle = 0
  for _, row in ipairs(rows or {}) do
    local number = tonumber(row.number)
    if number ~= nil and not seen[number]
        and caps.normalized_login(row_author(row)) == expected_bot then
      seen[number] = true
      local provenance, provenance_why, provenance_intent = caps.proposal_create_provenance(row.body)
      local candidate_group, intent = caps.proposal_catalog_group(row.body)
      if provenance ~= nil then
        if provenance.group_key == group_key then
          if cycles[provenance.cycle] ~= nil and cycles[provenance.cycle] ~= number then
            return nil, "proposal-create-provenance-cycle-conflict"
          end
          cycles[provenance.cycle] = number
          max_cycle = math.max(max_cycle, provenance.cycle)
        elseif intent and candidate_group == group_key then
          return nil, "proposal-create-provenance-group-conflict"
        end
      elseif provenance_intent then
        return nil, provenance_why
      elseif intent and candidate_group == group_key then
        return nil, provenance_why
      end
    end
  end
  if max_cycle == 0 then
    return 1, nil
  end
  local next_cycle, next_why = caps.next_proposal_revision(max_cycle)
  if next_cycle == nil then
    return nil, next_why == "proposal-revision-exhausted"
      and "proposal-cycle-exhausted" or next_why
  end
  return next_cycle, nil
end

function M.proposal_contains_signal(proposal, signal)
  return proposal_contains_signal(proposal, signal)
end

return M
