-- Pure v2 contracts for account-scoped marketing radar review workflows.
local marketing_content = require("contract.marketing_content")
local action_strategies = require("action_strategies")
local control_fields = require("control_fields")
local issue_close_contract = require("issue_close_contract")
local limits = require("limits")
local proposal_identity = require("proposal_identity")
local proposal_provenance = require("proposal_provenance")
local review_commands = require("review_commands")
local session_route = require("contract.session_route")
local session_authority = require("session_authority")
local sha256 = require("contract.sha256")
local source_identity = require("source_identity")
local strings = require("contract.strings")
local x_text = require("contract.x_text")

local M = {}

local ISSUE_BODY_LIMIT = 11000
local SIGNAL_SET_LIMIT = 20
local MAX_PROPOSAL_REVISION = proposal_identity.MAX_REVISION
local CONFIG_CONTRACT = "marketing-radar.radar-config.v2"
local PROPOSAL_CONTRACT = control_fields.PROPOSAL_CONTRACT
local SIGNAL_CONTRACT = "marketing-radar.radar-signal.v2"
local SIGNAL_SCHEMA = "marketing-radar.signal-imported.v2"

local function trim(value)
  return strings.trim(value or "")
end

local function normalized_key(value) return trim(value):lower():gsub("_", "-") end

local normalized_login = session_authority.normalize_login

local runtime_segment = proposal_identity.runtime_segment

local function line_iter(body)
  local text = tostring(body or "")
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local position = 1
  return function()
    if position > #text then
      return nil
    end
    local next_position = text:find("\n", position, true)
    local line = text:sub(position, next_position - 1):gsub("\r$", "")
    position = next_position + 1
    return line
  end
end

local function canonical_body(body)
  local text = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("[ \t]+\n", "\n")
  return trim(text)
end

local function encode_fields(fields, keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local value = tostring(fields[key] or "")
    parts[#parts + 1] = key .. ":" .. tostring(#value) .. ":" .. value
  end
  return table.concat(parts, "\n")
end

local function tagged_digest(value)
  return "sha256:" .. sha256.hex(tostring(value or ""))
end

local signal_lineage_digest = proposal_identity.signal_set_digest

local function copy_source_ref(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  local ref = trim(source_ref.ref or source_ref.reference)
  if source_ref.kind ~= "external" or ref == "" or #ref > 240
      or ref:match("^[^#]+#issue/%d+$") == nil then
    return nil
  end
  if source_ref.ref ~= nil and source_ref.reference ~= nil and source_ref.ref ~= source_ref.reference then
    return nil
  end
  return { kind = "external", ref = ref, reference = ref }
end

local source_ref_for = source_identity.canonical_issue_source_ref

local function issue_values(payload, options)
  local opts = options or {}
  return opts.issue_body ~= nil and opts.issue_body or payload.body,
    opts.issue_labels ~= nil and opts.issue_labels or payload.labels,
    opts.issue_assignees ~= nil and opts.issue_assignees or payload.assignees
end

local normalized_session = session_authority.normalize
local login_matches = session_authority.login_matches
local authorized_login = session_authority.authorized

local function source_number(source_ref)
  return tonumber(source_ref and source_ref.ref and source_ref.ref:match("#issue/(%d+)$"))
end

local function append(lines, key, value)
  if value ~= nil and tostring(value) ~= "" then
    lines[#lines + 1] = tostring(key) .. ": " .. tostring(value)
  end
end

function M.resolve_session_authority(values)
  return session_authority.resolve(values)
end

function M.resolve_session_route(values)
  return session_authority.resolve_route(values)
end

M.parse_control_fields = control_fields.parse

function M.proposal_catalog_group(body)
  local fields, fields_why, intent, complete_identity = M.parse_control_fields(body)
  if not intent then
    return nil, false, fields_why or "not-weekly-plan-change-v2"
  end
  if fields_why ~= nil then
    return nil, true, fields_why
  end
  if not complete_identity then
    return nil, true, "incomplete-proposal-identity"
  end
  local project = strings.sanitize_key(trim(fields.project):lower(), 180)
  local account = session_route.normalize_account(fields.account)
  local action = normalized_key(fields.action)
  if trim(fields.project) == "" or project == "" or account == nil
      or trim(fields.week) == "" or action == "" then
    return nil, true, "incomplete-proposal-group"
  end
  return M.proposal_group_key({
    project = project,
    account = account,
    week = fields.week,
    topic = fields.topic,
    action = action,
    target_ref = fields["target-ref"],
  }), true, nil
end

function M.saga_conformance_errors()
  return {}
end

function M.classify_issue(payload, options)
  if type(payload) ~= "table" then
    return nil, "invalid-payload"
  end
  if payload.schema ~= "github-proxy.v1" and payload.schema ~= "github-proxy.issue-observed.v1" then
    return nil, "unsupported-schema"
  end
  if payload.type ~= "issue" then
    return nil, "not-issue"
  end
  local session, session_why = normalized_session(options and options.session)
  if session == nil then
    return nil, session_why
  end
  local body, labels, assignees = issue_values(payload, options)
  if not session_route.has_label(labels, session.effective_work_label) then
    return nil, "missing-session-work-label"
  end
  local route_why = nil
  local assignee = session_route.single_assignee(assignees)
  if assignee == nil then
    route_why = "requires-single-session-creator-assignee"
  elseif not login_matches(assignee, session.creator) then
    route_why = "session-creator-assignee-mismatch"
  end

  local fields, fields_why = M.parse_control_fields(body)
  local kind = normalized_key(fields.type)
  if kind ~= "radar-signal" and kind ~= "weekly-plan-change" and kind ~= "radar-config" then
    return nil, "unsupported-type"
  end
  local source_ref, source_why = source_ref_for(payload)
  if source_ref == nil then
    return nil, source_why or "missing-source-ref"
  end

  local account = session_route.normalize_account(fields.account)
  local item = {
    kind = kind,
    project = strings.sanitize_key(trim(fields.project):lower(), 180),
    account = account or session.account,
    declared_work_label = fields["work-label"],
    week = fields.week,
    action = fields.action and normalized_key(fields.action) or nil,
    target_ref = fields["target-ref"],
    topic = fields.topic,
    insight = fields.insight,
    source_url = fields["source-url"],
    proposal_id = fields["proposal-id"],
    proposal_revision = proposal_identity.revision(fields["proposal-revision"]),
    content_digest = fields["content-digest"],
    signal_set_digest = fields["signal-set-digest"],
    status = fields.status,
    issue_number = tonumber(payload.number) or source_number(source_ref),
    repo = payload.repo or source_ref.ref:match("^([^#]+)#"),
    source_ref = source_ref,
    session_work_label = session.effective_work_label,
    logical_work_label = session.logical_work_label,
    session_creator = session.creator,
    trace_id = "github:marketing-radar:" .. source_ref.ref,
  }

  local expected_contract = kind == "radar-signal" and SIGNAL_CONTRACT
    or kind == "radar-config" and CONFIG_CONTRACT or PROPOSAL_CONTRACT
  local identity_why = route_why or fields_why
  if identity_why ~= nil then
    -- The effective label routed this Issue to this Session, so malformed
    -- authority or controls are explicit triage instead of silent handoff.
  elseif fields.contract ~= expected_contract then
    identity_why = "invalid-v2-contract"
  elseif account == nil then
    identity_why = "missing-account"
  elseif account ~= session.account then
    identity_why = "account-session-mismatch"
  elseif fields["work-label"] == nil then
    identity_why = "missing-logical-work-label"
  elseif fields["work-label"] ~= session.logical_work_label then
    identity_why = "logical-work-label-mismatch"
  elseif fields.project == nil then
    identity_why = "missing-project"
  end

  if kind == "radar-signal" then
    local strategy, strategy_why = action_strategies.evaluate(item.action, item.target_ref)
    local issue_author = options and options.issue_author_login or payload.author_login
    local trusted_body = canonical_body(body)
    if identity_why ~= nil then
      item.status = "needs-triage"
      item.triage_reason = identity_why
    elseif item.week == nil or item.week:match("^%d%d%d%d%-W%d%d$") == nil then
      item.status = "needs-triage"
      item.triage_reason = "invalid-week"
    elseif options and options.authorized_signal_authors ~= nil
        and not authorized_login(options.authorized_signal_authors, issue_author) then
      item.status = "needs-triage"
      item.triage_reason = "unauthorized-signal-author"
    elseif #trusted_body > limits.TRUSTED_SIGNAL_BODY_BYTES then
      item.status = "needs-triage"
      item.triage_reason = "signal-body-too-large"
    elseif strategy == nil then
      item.status = "needs-triage"
      item.triage_reason = item.action == nil and "missing-action" or strategy_why
    else
      item.status = "awaiting-review"
      item.signal_authorized = options and options.authorized_signal_authors ~= nil and true or nil
      item.trusted_body_context = item.signal_authorized and trusted_body or nil
      item.change_scope = strategy.change_scope
      item.supersede_mode = strategy.supersede_mode
      item.target_ref = strategy.target_ref
    end
    local business = {
      project = item.project,
      account = item.account,
      week = item.week,
      action = item.action,
      target_ref = item.target_ref,
      topic = item.topic,
      source_url = item.source_url,
      insight = item.insight,
      source_ref = source_ref.ref,
      body = canonical_body(body),
    }
    item.signal_digest = tagged_digest(encode_fields(business, {
      "project", "account", "week", "action", "target_ref", "topic",
      "source_url", "insight", "source_ref", "body",
    }))
    local identity = table.concat({
      "marketing-radar", runtime_segment(item.project, 80), runtime_segment(item.account),
      runtime_segment(item.week), runtime_segment(source_ref.ref, 160), runtime_segment(item.signal_digest, 80),
    }, "/")
    item.artifact_id = identity .. "/signal"
    item.dedup_key = identity .. "/import"
  elseif kind == "weekly-plan-change" then
    if identity_why ~= nil or item.week == nil or item.proposal_id == nil or item.proposal_revision == nil then
      item.status = "needs-triage"
      item.triage_reason = identity_why or "invalid-proposal-reference"
    end
  elseif identity_why ~= nil then
    item.status = "needs-triage"
    item.triage_reason = identity_why
  end
  return item
end

M.proposal_group_key = proposal_identity.group_key

local function normalized_signal_set(input_signals, session)
  local by_source = {}
  local signals = {}
  for _, signal in ipairs(input_signals or {}) do
    if type(signal) ~= "table" or signal.kind ~= "radar-signal"
        or not sha256.is_tagged(signal.signal_digest) or copy_source_ref(signal.source_ref) == nil then
      return nil, "invalid-signal"
    end
    if signal.status == "needs-triage" then
      return nil, "signal-needs-triage"
    end
    local ref = signal.source_ref.ref
    local previous = by_source[ref]
    if previous ~= nil and previous.signal_digest ~= signal.signal_digest then
      return nil, "duplicate-signal-source-ref"
    end
    if previous == nil then
      by_source[ref] = signal
      signals[#signals + 1] = signal
    end
  end
  if #signals == 0 then
    return nil, "empty-signal-set"
  end
  if #signals > SIGNAL_SET_LIMIT then
    return nil, "signal-group-too-large"
  end
  table.sort(signals, function(left, right)
    if left.signal_digest == right.signal_digest then
      return left.source_ref.ref < right.source_ref.ref
    end
    return left.signal_digest < right.signal_digest
  end)
  local first = signals[1]
  local group_key = M.proposal_group_key(first)
  for _, signal in ipairs(signals) do
    if signal.project ~= first.project or signal.account ~= first.account or signal.week ~= first.week
        or trim(signal.topic) ~= trim(first.topic) then
      return nil, "mixed-proposal-group"
    end
    if signal.action ~= first.action or trim(signal.target_ref) ~= trim(first.target_ref) then
      return nil, "mixed-signal-actions"
    end
    if M.proposal_group_key(signal) ~= group_key then
      return nil, "mixed-proposal-group"
    end
    if signal.account ~= session.account then
      return nil, "account-session-mismatch"
    end
  end
  return {
    signals = signals,
    first = first,
    group_key = group_key,
    signal_set_digest = signal_lineage_digest(signals),
  }, nil
end

function M.signal_set_identity(input_signals, session_value)
  local session, why = normalized_session(session_value)
  if session == nil then
    return nil, why
  end
  local identity, set_why = normalized_signal_set(input_signals, session)
  if identity == nil then
    return nil, set_why
  end
  identity.proposal_id = "proposal-" .. sha256.hex(
    identity.group_key .. "\n" .. identity.signal_set_digest):sub(1, 24)
  return identity, nil
end

local function proposal_content_record(proposal)
  return {
    project = proposal.project,
    account = proposal.account,
    work_label = proposal.work_label,
    week = proposal.week,
    content_id = proposal.content_id,
    content_revision = proposal.content_revision,
    proposal_id = proposal.proposal_id,
    proposal_revision = proposal.revision,
    approval_id = proposal.proposal_id .. "@" .. tostring(proposal.revision),
    content_status = "approved",
    tweet_text = proposal.tweet_text,
  }
end

function M.build_proposal(input_signals, session_value, draft, lineage)
  local session, why = normalized_session(session_value)
  if session == nil then
    return nil, why
  end
  local identity, identity_why = M.signal_set_identity(input_signals, session)
  if identity == nil then
    return nil, identity_why
  end
  local signals, first = identity.signals, identity.first

  if type(draft) ~= "table" then
    return nil, "missing-reviewed-draft"
  end
  if draft.action ~= first.action or trim(draft.target_ref) ~= trim(first.target_ref) then
    return nil, "draft-action-scope-conflict"
  end
  local evidence_set = {}
  local evidence_count = 0
  for _, ref in ipairs(draft.evidence_refs or {}) do
    local value = trim(ref)
    if value == "" then
      return nil, "invalid-draft-evidence"
    end
    if evidence_set[value] then
      return nil, "duplicate-draft-evidence"
    end
    evidence_set[value] = true
    evidence_count = evidence_count + 1
  end
  for _, signal in ipairs(signals) do
    if not evidence_set[signal.source_ref.ref] then
      return nil, "missing-signal-evidence"
    end
  end
  if evidence_count ~= #signals then
    return nil, "unexpected-draft-evidence"
  end
  local evidence_refs = {}
  for ref, _ in pairs(evidence_set) do
    evidence_refs[#evidence_refs + 1] = ref
  end
  table.sort(evidence_refs)
  local text = trim(draft.tweet_text)
  local analysis = x_text.analyze(text)
  if not analysis.valid then
    return nil, "invalid-x-text:" .. tostring(analysis.reason)
  end
  local revision = draft and draft.revision ~= nil
    and proposal_identity.revision(draft.revision) or 1
  if revision == nil then
    return nil, "invalid-proposal-revision"
  end
  local lineage_values = lineage or {}
  local proposal_id = trim(lineage_values.proposal_id)
  if proposal_id == "" then
    proposal_id = identity.proposal_id
  end
  local content_id = trim(lineage_values.content_id)
  local content_revision = proposal_identity.revision(lineage_values.content_revision)
  if lineage_values.content_revision ~= nil and content_revision == nil then
    return nil, "invalid-content-lineage"
  end
  if first.action == "revise" and (content_id == "" or content_revision == nil) then
    return nil, "revision-lineage-required"
  end
  if content_id == "" then
    content_id = "content-" .. sha256.hex(proposal_id):sub(1, 24)
  end
  if content_revision == nil then
    content_revision = revision
  end
  if #proposal_id > 180 or #content_id > 180 or content_revision < 1
      or content_revision > MAX_PROPOSAL_REVISION
      or content_revision % 1 ~= 0
      or (first.action ~= "revise" and content_revision ~= revision) then
    return nil, "invalid-content-lineage"
  end
  local proposal = {
    contract = PROPOSAL_CONTRACT,
    status = "awaiting-review",
    project = first.project,
    account = first.account,
    work_label = session.logical_work_label,
    week = first.week,
    topic = first.topic,
    action = first.action,
    target_ref = first.target_ref,
    change_scope = first.change_scope,
    supersede_mode = first.supersede_mode,
    proposal_id = proposal_id,
    revision = revision,
    signal_set_digest = identity.signal_set_digest,
    signals = signals,
    evidence_refs = evidence_refs,
    tweet_text = text,
    weighted_length = analysis.weighted_length,
    source_ref = copy_source_ref(first.source_ref),
    group_key = identity.group_key,
    content_id = content_id,
    content_revision = content_revision,
  }
  proposal.content_digest = marketing_content.digest(proposal_content_record(proposal))
  if proposal.content_digest == nil then
    return nil, "content-contract-rejected"
  end
  proposal.proposal_digest = proposal_identity.proposal_digest(proposal)
  if proposal.proposal_digest == nil then
    return nil, "proposal-contract-rejected"
  end
  local rendered = M.render_proposal(proposal)
  if rendered == nil or #rendered > ISSUE_BODY_LIMIT then
    return nil, "proposal-body-too-large"
  end
  return proposal
end

function M.render_proposal(proposal)
  local lines = {}
  append(lines, "contract", PROPOSAL_CONTRACT)
  append(lines, "type", "weekly-plan-change")
  append(lines, "project", proposal.project)
  append(lines, "account", proposal.account)
  append(lines, "work-label", proposal.work_label)
  append(lines, "week", proposal.week)
  append(lines, "topic", proposal.topic)
  append(lines, "action", proposal.action)
  append(lines, "target-ref", proposal.target_ref)
  append(lines, "change-scope", proposal.change_scope)
  append(lines, "supersede-mode", proposal.supersede_mode)
  append(lines, "proposal-id", proposal.proposal_id)
  append(lines, "proposal-revision", proposal.revision)
  append(lines, "content-id", proposal.content_id)
  append(lines, "content-revision", proposal.content_revision)
  append(lines, "signal-set-digest", proposal.signal_set_digest)
  append(lines, "proposal-digest", proposal.proposal_digest)
  append(lines, "content-digest", proposal.content_digest)
  append(lines, "status", proposal.status)
  for _, signal in ipairs(proposal.signals or {}) do
    lines[#lines + 1] = "signal: " .. signal.source_ref.ref .. " " .. signal.signal_digest
  end
  for _, evidence_ref in ipairs(proposal.evidence_refs or {}) do
    lines[#lines + 1] = "evidence: " .. evidence_ref
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "tweet-text:"
  lines[#lines + 1] = control_fields.render_fenced(proposal.tweet_text)
  local body = table.concat(lines, "\n")
  if #body > ISSUE_BODY_LIMIT then
    return nil, "proposal-body-too-large"
  end
  return body, nil
end

function M.parse_proposal(body)
  local fields, fields_why = M.parse_control_fields(body)
  if fields_why ~= nil then
    return nil, fields_why
  end
  if fields.contract ~= PROPOSAL_CONTRACT or normalized_key(fields.type) ~= "weekly-plan-change" then
    return nil, "not-weekly-plan-change-v2"
  end
  local tweet_text, tweet_why = control_fields.fenced_field(body, "tweet-text")
  if tweet_text == nil then
    return nil, tweet_why
  end
  local proposal = {
    contract = fields.contract,
    status = normalized_key(fields.status),
    project = fields.project,
    account = session_route.normalize_account(fields.account),
    work_label = fields["work-label"],
    week = fields.week,
    topic = fields.topic,
    action = normalized_key(fields.action),
    target_ref = fields["target-ref"],
    change_scope = fields["change-scope"],
    supersede_mode = fields["supersede-mode"],
    proposal_id = fields["proposal-id"],
    revision = proposal_identity.revision(fields["proposal-revision"]),
    content_id = fields["content-id"],
    content_revision = proposal_identity.revision(fields["content-revision"]),
    signal_set_digest = fields["signal-set-digest"],
    proposal_digest = fields["proposal-digest"],
    content_digest = fields["content-digest"],
    tweet_text = tweet_text,
    signals = {},
    evidence_refs = {},
  }
  local unfenced_lines, lines_why = control_fields.unfenced_lines(body)
  if unfenced_lines == nil then
    return nil, lines_why
  end
  local signal_refs = {}
  for _, line in ipairs(unfenced_lines) do
    local ref, digest = line:match("^%s*signal:%s*([^%s]+)%s+(sha256:[0-9a-f]+)%s*$")
    if line:match("^%s*signal:") then
      local canonical_ref = copy_source_ref({ kind = "external", ref = ref, reference = ref })
      if canonical_ref == nil or not sha256.is_tagged(digest) or signal_refs[ref]
          or #proposal.signals >= SIGNAL_SET_LIMIT then
        return nil, "invalid-proposal-signal-lineage"
      end
      signal_refs[ref] = true
      proposal.signals[#proposal.signals + 1] = {
        source_ref = canonical_ref,
        signal_digest = digest,
      }
    end
    local evidence = line:match("^%s*evidence:%s*([^%s]+)%s*$")
    if line:match("^%s*evidence:") then
      if copy_source_ref({ kind = "external", ref = evidence, reference = evidence }) == nil then
        return nil, "invalid-proposal-evidence-lineage"
      end
      proposal.evidence_refs[#proposal.evidence_refs + 1] = evidence
    end
  end
  local analysis = x_text.analyze(proposal.tweet_text)
  local strategy = action_strategies.evaluate(proposal.action, proposal.target_ref)
  local evidence_set = {}
  local evidence_count = 0
  local duplicate_evidence = false
  for _, ref in ipairs(proposal.evidence_refs) do
    if evidence_set[ref] then
      duplicate_evidence = true
    else
      evidence_count = evidence_count + 1
    end
    evidence_set[ref] = true
  end
  local all_signals_cited = true
  for _, signal in ipairs(proposal.signals) do
    if not evidence_set[signal.source_ref.ref] then
      all_signals_cited = false
    end
  end
  if proposal.project == nil or proposal.account == nil or proposal.work_label == nil
      or proposal.status ~= "awaiting-review"
      or proposal.week == nil or proposal.proposal_id == nil or proposal.revision == nil
      or proposal.revision < 1 or proposal.revision > MAX_PROPOSAL_REVISION
      or proposal.revision % 1 ~= 0
      or trim(proposal.content_id) == "" or proposal.content_revision == nil
      or proposal.content_revision < 1
      or proposal.content_revision > MAX_PROPOSAL_REVISION
      or proposal.content_revision % 1 ~= 0
      or not sha256.is_tagged(proposal.signal_set_digest)
      or not sha256.is_tagged(proposal.proposal_digest)
      or not sha256.is_tagged(proposal.content_digest) or #proposal.signals == 0
      or #proposal.evidence_refs == 0 or duplicate_evidence or evidence_count ~= #proposal.signals
      or not all_signals_cited or not analysis.valid
      or strategy == nil or strategy.change_scope ~= proposal.change_scope
      or strategy.supersede_mode ~= proposal.supersede_mode
      or (proposal.action ~= "revise" and proposal.content_revision ~= proposal.revision) then
    return nil, "invalid-proposal-contract"
  end
  if signal_lineage_digest(proposal.signals) ~= proposal.signal_set_digest then
    return nil, "proposal-signal-set-digest-mismatch"
  end
  proposal.group_key = M.proposal_group_key(proposal)
  local expected = marketing_content.digest(proposal_content_record(proposal))
  if expected ~= proposal.content_digest then
    return nil, "proposal-content-digest-mismatch"
  end
  local proposal_digest = proposal_identity.proposal_digest(proposal)
  if proposal_digest ~= proposal.proposal_digest then
    return nil, "proposal-digest-mismatch"
  end
  return proposal
end

function M.latest_proposal(issue, bot_login)
  if type(issue) ~= "table" then
    return nil, "invalid-review-issue"
  end
  if not login_matches(issue.author_login, bot_login) then
    return nil, "review-author-mismatch"
  end

  local root, root_why = M.parse_proposal(issue.body)
  if root == nil then
    return nil, "malformed-bot-proposal-root:" .. tostring(root_why)
  end
  local root_marker, root_marker_why = proposal_provenance.issue_create(issue.body)
  if root_marker == nil then
    return nil, "malformed-bot-proposal-root:" .. tostring(root_marker_why)
  end
  if root_marker.group_key ~= root.group_key then
    return nil, "conflicting-bot-proposal-root-provenance"
  end
  if root.revision ~= 1 then
    return nil, "invalid-bot-proposal-root-revision"
  end

  local revisions = {}
  local canonicals = {}
  local highest = 0
  local revision_count = 0
  local function add_revision(proposal)
    local canonical, canonical_why = M.render_proposal(proposal)
    if canonical == nil then
      return nil, canonical_why
    end
    local previous = canonicals[proposal.revision]
    if previous ~= nil and previous ~= canonical then
      return nil, "conflicting-bot-proposal-revision"
    end
    if revisions[proposal.revision] == nil then
      revisions[proposal.revision] = proposal
      revision_count = revision_count + 1
    end
    canonicals[proposal.revision] = previous or canonical
    highest = math.max(highest, proposal.revision)
    return true, nil
  end
  local root_added, root_add_why = add_revision(root)
  if root_added == nil then
    return nil, "malformed-bot-proposal-root:" .. tostring(root_add_why)
  end

  for _, comment in ipairs(issue.comments or {}) do
    if login_matches(comment.author_login, bot_login) then
      local parsed, parsed_why = M.parse_proposal(comment.body)
      local marker, marker_why, marker_intent = proposal_provenance.revision_comment(comment.body)
      local fields = M.parse_control_fields(comment.body)
      local control_intent = fields.contract == PROPOSAL_CONTRACT
        or normalized_key(fields.type) == "weekly-plan-change"
      if parsed == nil and (control_intent or marker_intent) then
        return nil, "malformed-bot-proposal-revision:"
          .. tostring(marker_why or parsed_why)
      end
      if parsed ~= nil then
        if marker == nil then
          return nil, "malformed-bot-proposal-revision:"
            .. tostring(marker_why or "proposal-revision-provenance-missing")
        end
        if marker.group_key ~= parsed.group_key
            or marker.revision ~= parsed.revision
            or marker.signal_set_digest ~= parsed.signal_set_digest then
          return nil, "conflicting-bot-proposal-provenance"
        end
        local added, add_why = add_revision(parsed)
        if added == nil then
          if add_why == "conflicting-bot-proposal-revision" then
            return nil, add_why
          end
          return nil, "malformed-bot-proposal-revision:" .. tostring(add_why)
        end
      end
    end
  end

  if revision_count ~= highest then
    return nil, "discontinuous-bot-proposal-revision"
  end
  local fixed = {
    "proposal_id", "group_key", "account", "project", "week", "topic", "action",
    "target_ref", "work_label", "content_id",
  }
  for revision = 2, highest do
    local proposal = revisions[revision]
    for _, field in ipairs(fixed) do
      if tostring(proposal[field] or "") ~= tostring(root[field] or "") then
        return nil, "conflicting-bot-proposal-lineage"
      end
    end
    if proposal.action == "revise" and proposal.content_revision ~= root.content_revision then
      return nil, "conflicting-bot-proposal-lineage"
    end
  end
  return revisions[highest]
end

function M.review_failure_status(decision, failure_reason)
  return review_commands.failure_status(decision, failure_reason)
end

M.next_proposal_revision = proposal_identity.next_revision

function M.review_decision(issue, options)
  local opts = options or {}
  local proposal, proposal_why = M.latest_proposal(issue, opts.bot_login)
  if proposal == nil then
    return nil, proposal_why
  end
  local failure_dedup_root = type(issue.source_ref) == "table"
    and type(issue.source_ref.ref) == "string" and issue.source_ref.ref ~= ""
    and ("marketing-radar/" .. runtime_segment(issue.source_ref.ref, 180)) or nil
  return review_commands.decision(issue, proposal, opts, failure_dedup_root)
end

function M.weekly_plan_change_issue_request(proposal, session_value, cycle_value)
  local session = assert(normalized_session(session_value))
  local cycle = assert(proposal_identity.revision(cycle_value or 1),
    "marketing-radar: invalid proposal cycle")
  local body = assert(M.render_proposal(proposal))
  local dedup_key = assert(proposal_identity.dedup_key(
    proposal.group_key, "/create/cycle-" .. tostring(cycle)))
  return {
    schema = "github-proxy.issue-create.v1",
    repo = proposal.source_ref.ref:match("^([^#]+)#"),
    title = "Weekly plan change: " .. proposal.project .. " " .. proposal.account .. " " .. proposal.week,
    body = body,
    labels = { session.effective_work_label },
    assignees = { session.creator },
    dedup_key = dedup_key,
    source_ref = copy_source_ref(proposal.source_ref),
    parent_comment_target = {
      repo = proposal.source_ref.ref:match("^([^#]+)#"),
      issue_number = source_number(proposal.source_ref),
    },
  }
end

function M.proposal_revision_comment_request(review_issue, proposal)
  local body = assert(M.render_proposal(proposal))
  local dedup_key = assert(proposal_identity.dedup_key(
    proposal.group_key, "/revision/" .. tostring(proposal.revision)
      .. "/" .. proposal.signal_set_digest))
  return {
    schema = "github-proxy.v1",
    repo = review_issue.source_ref.ref:match("^([^#]+)#"),
    issue_number = source_number(review_issue.source_ref),
    body = body,
    dedup_key = dedup_key,
    source_ref = copy_source_ref(review_issue.source_ref),
  }
end

function M.approved_weekly_content_issue_request(proposal, session_value)
  local session = assert(normalized_session(session_value))
  local record = proposal_content_record(proposal)
  local body, digest = marketing_content.render(record)
  assert(body ~= nil and digest == proposal.content_digest, "marketing-radar: approved content digest drift")
  local source_ref = copy_source_ref(proposal.review_source_ref or proposal.source_ref)
  local dedup_key = assert(proposal_identity.dedup_key(
    proposal.group_key, "/approved-content/" .. runtime_segment(digest, 80)))
  return {
    schema = "github-proxy.issue-create.v1",
    repo = source_ref.ref:match("^([^#]+)#"),
    title = "Approved weekly content: " .. proposal.project .. " " .. proposal.account .. " " .. proposal.week,
    body = body,
    labels = { session.effective_work_label },
    assignees = { session.creator },
    dedup_key = dedup_key,
    source_ref = source_ref,
    parent_comment_target = {
      repo = source_ref.ref:match("^([^#]+)#"),
      issue_number = source_number(source_ref),
    },
  }
end

function M.radar_signal_imported(item)
  return {
    schema = SIGNAL_SCHEMA,
    artifact_id = item.artifact_id,
    project = item.project,
    account = item.account,
    work_label = item.logical_work_label,
    week = item.week,
    action = item.action,
    target_ref = item.target_ref,
    topic = item.topic,
    signal_digest = item.signal_digest,
    status = item.status,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.radar_config_imported(item)
  return {
    schema = "marketing-radar.config-imported.v2",
    project = item.project,
    account = item.account,
    work_label = item.logical_work_label,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = "marketing-radar/" .. runtime_segment(item.project) .. "/"
      .. runtime_segment(item.account) .. "/config/" .. runtime_segment(item.source_ref.ref, 180),
    trace_id = item.trace_id,
  }
end

M.status_comment = issue_close_contract.status_comment
M.close_handoff = issue_close_contract.close_handoff
M.close_ack_context = issue_close_contract.close_ack_context

function M.current_close_decision(issue, context, review_options, review_issue)
  if type(issue) ~= "table" then
    return "skip", "invalid-current-issue"
  end
  local state = tostring(issue.state or ""):upper()
  if state ~= "OPEN" and state ~= "CLOSED" then
    return "skip", "current-issue-not-open"
  end
  local item, why = M.classify_issue({
    schema = "github-proxy.v1",
    type = "issue",
    repo = context.repo,
    number = context.issue_number,
    labels = issue.labels,
    assignees = issue.assignees,
    body = issue.body,
    source_ref = context.source_ref,
  }, {
    session = context.session,
    issue_body = issue.body,
    issue_labels = issue.labels,
    issue_assignees = issue.assignees,
  })
  if item == nil or item.kind ~= context.kind or item.status == "needs-triage" then
    return "skip", "current-issue-invalid:" .. tostring(why)
  end
  if context.kind == "radar-signal" then
    if item.signal_digest ~= context.business_digest then
      return "skip", "signal-digest-changed"
    end
    local review_state = type(review_issue) == "table"
      and tostring(review_issue.state or ""):upper() or ""
    local review_ref = context.review_source_ref
    local review_item, review_why = M.classify_issue({
      schema = "github-proxy.v1",
      type = "issue",
      repo = review_ref.ref:match("^([^#]+)#"),
      number = source_number(review_ref),
      labels = review_issue and review_issue.labels,
      assignees = review_issue and review_issue.assignees,
      body = review_issue and review_issue.body,
      source_ref = review_ref,
    }, {
      session = context.session,
      issue_body = review_issue and review_issue.body,
      issue_labels = review_issue and review_issue.labels,
      issue_assignees = review_issue and review_issue.assignees,
    })
    if (review_state ~= "OPEN" and review_state ~= "CLOSED")
        or review_item == nil or review_item.kind ~= "weekly-plan-change"
        or review_item.status == "needs-triage" then
      return "skip", "review-issue-invalid:" .. tostring(review_why)
    end
  end
  local review_source = context.kind == "radar-signal" and review_issue or issue
  local decision, decision_why = M.review_decision(review_source, review_options)
  if decision == nil or decision.command ~= context.review_command
      or tostring(decision.comment_id) ~= tostring(context.review_comment_id)
      or decision.proposal.proposal_id ~= context.proposal_id
      or decision.proposal.revision ~= context.proposal_revision
      or decision.proposal.proposal_digest ~= context.proposal_digest
      or decision.proposal.content_digest ~= context.content_digest then
    return "skip", "review-decision-changed:" .. tostring(decision_why)
  end
  return state == "CLOSED" and "converged" or "close",
    state == "CLOSED" and "already-closed" or nil
end

M.close_lock_key = issue_close_contract.close_lock_key

M.PROPOSAL_CONTRACT = PROPOSAL_CONTRACT
M.SIGNAL_CONTRACT = SIGNAL_CONTRACT
M.TERMINAL_HANDOFF_SCHEMA = issue_close_contract.SCHEMA
M.runtime_segment = runtime_segment
M.normalized_login = normalized_login
M.action_strategy = action_strategies.evaluate
M.canonical_issue_source_ref = source_identity.canonical_issue_source_ref
M.proposal_create_provenance = proposal_provenance.issue_create

return M
