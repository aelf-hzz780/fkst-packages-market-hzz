-- Pure v2 contracts for account-scoped marketing radar review workflows.
local marketing_content = require("contract.marketing_content")
local action_strategies = require("action_strategies")
local limits = require("limits")
local session_route = require("contract.session_route")
local session_authority = require("session_authority")
local sha256 = require("contract.sha256")
local source_identity = require("source_identity")
local strings = require("contract.strings")
local x_text = require("contract.x_text")

local M = {}

local CONTROL_VALUE_LIMIT = 512
local ISSUE_BODY_LIMIT = 11000
local SIGNAL_SET_LIMIT = 20
local CONFIG_CONTRACT = "marketing-radar.radar-config.v2"
local PROPOSAL_CONTRACT = "marketing-radar.weekly-plan-change.v2"
local SIGNAL_CONTRACT = "marketing-radar.radar-signal.v2"
local SIGNAL_SCHEMA = "marketing-radar.signal-imported.v2"
local TERMINAL_HANDOFF_SCHEMA = "marketing-radar.issue-close.v2"

local ALLOWED_FIELDS = {
  account = true,
  action = true,
  contract = true,
  ["content-digest"] = true,
  ["content-id"] = true,
  ["content-revision"] = true,
  ["content-status"] = true,
  ["change-scope"] = true,
  insight = true,
  project = true,
  ["proposal-id"] = true,
  ["proposal-revision"] = true,
  ["signal-set-digest"] = true,
  ["source-url"] = true,
  status = true,
  ["supersede-mode"] = true,
  ["target-ref"] = true,
  topic = true,
  type = true,
  week = true,
  ["work-label"] = true,
}

local function trim(value)
  return strings.trim(value or "")
end

local function normalized_key(value) return trim(value):lower():gsub("_", "-") end

local normalized_login = session_authority.normalize_login

local function runtime_segment(value, limit)
  local raw = tostring(value or "")
  local safe = strings.runtime_safe_segment(raw)
  local max_len = tonumber(limit) or 120
  if #safe <= max_len then
    return safe
  end
  local suffix = "_" .. strings.decimal_checksum(raw)
  return safe:sub(1, math.max(1, max_len - #suffix)) .. suffix
end

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

local function fenced_field(body, field)
  local target = normalized_key(field)
  local waiting = false
  local collecting = false
  local lines = {}
  for line in line_iter(body) do
    if collecting then
      if line:match("^%s*```") then
        return trim(table.concat(lines, "\n"))
      end
      lines[#lines + 1] = line
    elseif waiting then
      if line:match("^%s*```") then
        collecting = true
      elseif trim(line) ~= "" then
        return trim(line)
      end
    else
      local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
      if key ~= nil and normalized_key(key) == target then
        local inline = trim(value)
        if inline ~= "" and inline ~= "|" and inline ~= ">" then
          return inline
        end
        waiting = true
      end
    end
  end
  if collecting then
    return trim(table.concat(lines, "\n"))
  end
  return nil
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

local function copy_source_ref(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  local ref = trim(source_ref.ref or source_ref.reference)
  if source_ref.kind ~= "external" or ref == "" or ref:match("^[^#]+#issue/%d+$") == nil then
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

function M.parse_control_fields(body)
  local fields = {}
  if type(body) ~= "string" then
    return fields, "invalid-control-body"
  end
  if #body > 32000 then
    return fields, "control-body-too-large"
  end
  local in_fence = false
  for line in line_iter(body) do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
      local normalized = normalized_key(key)
      local cleaned = trim(value)
      if ALLOWED_FIELDS[normalized] and cleaned ~= "" then
        if fields[normalized] ~= nil then
          return fields, "duplicate-control-field:" .. normalized
        end
        if #cleaned > CONTROL_VALUE_LIMIT then
          return fields, "control-field-too-large:" .. normalized
        end
        fields[normalized] = cleaned
      end
    end
  end
  if in_fence then
    return fields, "unterminated-control-fence"
  end
  return fields, nil
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
    proposal_revision = tonumber(fields["proposal-revision"]),
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
      "marketing-radar", runtime_segment(item.project), runtime_segment(item.account),
      runtime_segment(item.week), runtime_segment(source_ref.ref, 180), runtime_segment(item.signal_digest, 80),
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

function M.proposal_group_key(signal)
  return table.concat({
    "marketing-radar", runtime_segment(signal.project), runtime_segment(signal.account),
    runtime_segment(signal.week), runtime_segment(signal.topic or "general"),
    runtime_segment(signal.action or "unknown"), runtime_segment(signal.target_ref or "none", 180),
    "weekly-plan-change",
  }, "/")
end

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
  local digests = {}
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
    digests[#digests + 1] = signal.signal_digest
  end
  return {
    signals = signals,
    first = first,
    digests = digests,
    group_key = group_key,
    signal_set_digest = tagged_digest(table.concat(digests, "\n")),
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
  local revision = tonumber(draft and draft.revision) or 1
  if revision < 1 or revision % 1 ~= 0 then
    return nil, "invalid-proposal-revision"
  end
  local lineage_values = lineage or {}
  local proposal_id = trim(lineage_values.proposal_id)
  if proposal_id == "" then
    proposal_id = identity.proposal_id
  end
  local content_id = trim(lineage_values.content_id)
  local content_revision = tonumber(lineage_values.content_revision)
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
      or content_revision % 1 ~= 0 then
    return nil, "invalid-content-lineage"
  end
  local proposal = {
    contract = PROPOSAL_CONTRACT,
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
  append(lines, "content-digest", proposal.content_digest)
  append(lines, "status", "awaiting-review")
  for _, signal in ipairs(proposal.signals or {}) do
    lines[#lines + 1] = "signal: " .. signal.source_ref.ref .. " " .. signal.signal_digest
  end
  for _, evidence_ref in ipairs(proposal.evidence_refs or {}) do
    lines[#lines + 1] = "evidence: " .. evidence_ref
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "tweet-text:"
  lines[#lines + 1] = "```"
  lines[#lines + 1] = proposal.tweet_text
  lines[#lines + 1] = "```"
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
  local proposal = {
    contract = fields.contract,
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
    revision = tonumber(fields["proposal-revision"]),
    content_id = fields["content-id"],
    content_revision = tonumber(fields["content-revision"]),
    signal_set_digest = fields["signal-set-digest"],
    content_digest = fields["content-digest"],
    tweet_text = fenced_field(body, "tweet-text"),
    signals = {},
    evidence_refs = {},
  }
  for line in line_iter(body) do
    local ref, digest = line:match("^%s*signal:%s*([^%s]+)%s+(sha256:[0-9a-f]+)%s*$")
    if ref ~= nil and digest ~= nil then
      proposal.signals[#proposal.signals + 1] = {
        source_ref = { kind = "external", ref = ref, reference = ref },
        signal_digest = digest,
      }
    end
    local evidence = line:match("^%s*evidence:%s*([^%s]+)%s*$")
    if evidence ~= nil then
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
      or proposal.week == nil or proposal.proposal_id == nil or proposal.revision == nil
      or trim(proposal.content_id) == "" or proposal.content_revision == nil
      or proposal.content_revision < 1 or proposal.content_revision % 1 ~= 0
      or not sha256.is_tagged(proposal.signal_set_digest)
      or not sha256.is_tagged(proposal.content_digest) or #proposal.signals == 0
      or #proposal.evidence_refs == 0 or duplicate_evidence or evidence_count ~= #proposal.signals
      or not all_signals_cited or not analysis.valid
      or strategy == nil or strategy.change_scope ~= proposal.change_scope
      or strategy.supersede_mode ~= proposal.supersede_mode then
    return nil, "invalid-proposal-contract"
  end
  proposal.group_key = M.proposal_group_key(proposal)
  local expected = marketing_content.digest(proposal_content_record(proposal))
  if expected ~= proposal.content_digest then
    return nil, "proposal-content-digest-mismatch"
  end
  return proposal
end

function M.latest_proposal(issue, bot_login)
  if type(issue) ~= "table" then
    return nil, "invalid-review-issue"
  end
  local latest = nil
  local latest_canonical = nil
  local conflict = false
  local function consider(body, author_login)
    if not login_matches(author_login, bot_login) then
      return
    end
    local parsed = M.parse_proposal(body)
    if parsed ~= nil then
      local canonical = M.render_proposal(parsed)
      if latest ~= nil and parsed.revision == latest.revision
          and canonical ~= latest_canonical then
        conflict = true
        return
      end
      if latest == nil or parsed.revision > latest.revision then
        latest = parsed
        latest_canonical = canonical
      end
    end
  end
  consider(issue.body, issue.author_login)
  for _, comment in ipairs(issue.comments or {}) do
    consider(comment.body, comment.author_login)
  end
  if conflict then
    return nil, "conflicting-bot-proposal-revision"
  end
  if latest == nil then
    return nil, "missing-bot-proposal"
  end
  return latest
end

function M.review_decision(issue, options)
  local opts = options or {}
  local proposal, proposal_why = M.latest_proposal(issue, opts.bot_login)
  if proposal == nil then
    return nil, proposal_why
  end
  local authorized = session_authority.login_set(opts.authorized_reviewers)
  local saw_unauthorized = false
  local saw_stale = false
  for index = 1, #(issue.comments or {}) do
    local comment = issue.comments[index]
    local command, id, revision, reason = tostring(comment.body or ""):match(
      "^%s*/marketing%s+([%w-]+)%s+([^@%s]+)@([^%s]+)%s*(.-)%s*$"
    )
    if command == "approve" or command == "request-changes" or command == "reject" then
      local author = normalized_login(comment.author_login)
      if id ~= proposal.proposal_id or tostring(revision) ~= tostring(proposal.revision) then
        saw_stale = true
      elseif author == nil or not authorized[author] then
        saw_unauthorized = true
      else
        if command ~= "approve" and trim(reason) == "" then
          return nil, "review-reason-required"
        end
        if #trim(reason) > CONTROL_VALUE_LIMIT
            or trim(reason):find("[%z\1-\31\127]") ~= nil then
          return nil, "invalid-review-reason"
        end
        return {
          command = command,
          reason = trim(reason) ~= "" and trim(reason) or nil,
          reviewer = author,
          comment_id = comment.id,
          approval_id = proposal.proposal_id .. "@" .. tostring(proposal.revision),
          proposal = proposal,
        }
      end
    end
  end
  if saw_unauthorized then
    return nil, "unauthorized-review-command"
  end
  if saw_stale then
    return nil, "stale-proposal-revision"
  end
  return nil, "no-review-command"
end

function M.weekly_plan_change_issue_request(proposal, session_value, cycle_value)
  local session = assert(normalized_session(session_value))
  local cycle = tonumber(cycle_value) or 1
  assert(cycle >= 1 and cycle % 1 == 0, "marketing-radar: invalid proposal cycle")
  local body = assert(M.render_proposal(proposal))
  return {
    schema = "github-proxy.issue-create.v1",
    repo = proposal.source_ref.ref:match("^([^#]+)#"),
    title = "Weekly plan change: " .. proposal.project .. " " .. proposal.account .. " " .. proposal.week,
    body = body,
    labels = { session.effective_work_label },
    assignees = { session.creator },
    dedup_key = proposal.group_key .. "/create/cycle-" .. tostring(cycle),
    source_ref = copy_source_ref(proposal.source_ref),
    parent_comment_target = {
      repo = proposal.source_ref.ref:match("^([^#]+)#"),
      issue_number = source_number(proposal.source_ref),
    },
  }
end

function M.proposal_revision_comment_request(review_issue, proposal)
  local body = assert(M.render_proposal(proposal))
  return {
    schema = "github-proxy.v1",
    repo = review_issue.source_ref.ref:match("^([^#]+)#"),
    issue_number = source_number(review_issue.source_ref),
    body = body,
    dedup_key = proposal.group_key .. "/revision/" .. tostring(proposal.revision)
      .. "/" .. runtime_segment(proposal.signal_set_digest, 80),
    source_ref = copy_source_ref(review_issue.source_ref),
  }
end

function M.approved_weekly_content_issue_request(proposal, session_value)
  local session = assert(normalized_session(session_value))
  local record = proposal_content_record(proposal)
  local body, digest = marketing_content.render(record)
  assert(body ~= nil and digest == proposal.content_digest, "marketing-radar: approved content digest drift")
  local source_ref = copy_source_ref(proposal.review_source_ref or proposal.source_ref)
  return {
    schema = "github-proxy.issue-create.v1",
    repo = source_ref.ref:match("^([^#]+)#"),
    title = "Approved weekly content: " .. proposal.project .. " " .. proposal.account .. " " .. proposal.week,
    body = body,
    labels = { session.effective_work_label },
    assignees = { session.creator },
    dedup_key = proposal.group_key .. "/approved-content/" .. runtime_segment(digest, 80),
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

function M.status_comment(item, status, handoff)
  local dedup = item.dedup_key or item.group_key or ("marketing-radar/" .. runtime_segment(item.source_ref.ref, 180))
  local request = {
    schema = "github-proxy.v1",
    repo = item.repo or item.source_ref.ref:match("^([^#]+)#"),
    issue_number = item.issue_number or source_number(item.source_ref),
    body = "Marketing radar v0.3.0: " .. tostring(status)
      .. "\n\naccount: " .. tostring(item.account)
      .. "\npublish_attempted: false"
      .. "\ntrace-id: " .. tostring(item.trace_id or "n/a"),
    dedup_key = dedup .. "/status/" .. runtime_segment(status, 100),
    source_ref = copy_source_ref(item.source_ref),
  }
  if handoff ~= nil then
    handoff.comment_dedup_key = request.dedup_key
    request.handoff = handoff
  end
  return request
end

function M.close_handoff(item, terminal_kind, decision)
  local business_digest = item.signal_digest or item.content_digest
  return {
    schema = TERMINAL_HANDOFF_SCHEMA,
    kind = terminal_kind,
    account = item.account,
    effective_work_label = item.session_work_label,
    logical_work_label = item.logical_work_label,
    session_creator = item.session_creator,
    business_digest = business_digest,
    proposal_id = decision and decision.proposal and decision.proposal.proposal_id or item.proposal_id,
    proposal_revision = decision and decision.proposal and decision.proposal.revision or item.proposal_revision,
    review_command = decision and decision.command or nil,
    review_comment_id = decision and decision.comment_id or nil,
    source_ref = copy_source_ref(item.source_ref),
    trace_id = item.trace_id,
  }
end

function M.close_ack_context(payload)
  if type(payload) ~= "table" or payload.schema ~= "github-proxy.comment-written.v1"
      or payload.target ~= "issue" or payload.comment_id == nil or type(payload.handoff) ~= "table" then
    return nil, "invalid-comment-ack"
  end
  local handoff = payload.handoff
  local source_ref = copy_source_ref(handoff.source_ref)
  local payload_ref = copy_source_ref(payload.source_ref)
  if handoff.schema ~= TERMINAL_HANDOFF_SCHEMA
      or (handoff.kind ~= "radar-signal" and handoff.kind ~= "weekly-plan-change")
      or source_ref == nil or payload_ref == nil or source_ref.ref ~= payload_ref.ref
      or payload.request_dedup_key ~= handoff.comment_dedup_key
      or payload.dedup_key ~= handoff.comment_dedup_key .. "/written/" .. tostring(payload.comment_id)
      or tonumber(payload.issue_number) ~= source_number(source_ref)
      or payload.repo ~= source_ref.ref:match("^([^#]+)#") then
    return nil, "invalid-close-correlation"
  end
  local session, why = normalized_session({
    effective_work_label = handoff.effective_work_label,
    logical_work_label = handoff.logical_work_label,
    creator = handoff.session_creator,
    account = handoff.account,
  })
  if session == nil or not sha256.is_tagged(handoff.business_digest) then
    return nil, why or "invalid-business-digest"
  end
  return {
    kind = handoff.kind,
    repo = payload.repo,
    issue_number = tonumber(payload.issue_number),
    source_ref = source_ref,
    business_digest = handoff.business_digest,
    proposal_id = handoff.proposal_id,
    proposal_revision = tonumber(handoff.proposal_revision),
    review_command = handoff.review_command,
    review_comment_id = handoff.review_comment_id,
    trace_id = handoff.trace_id,
    session = session,
  }
end

function M.current_close_decision(issue, context, review_options)
  if type(issue) ~= "table" then
    return "skip", "invalid-current-issue"
  end
  if tostring(issue.state or ""):upper() == "CLOSED" then
    return "converged", "already-closed"
  end
  if tostring(issue.state or ""):upper() ~= "OPEN" then
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
  if item == nil or item.kind ~= context.kind then
    return "skip", "current-issue-invalid:" .. tostring(why)
  end
  if context.kind == "radar-signal" then
    return item.signal_digest == context.business_digest and "close" or "skip",
      item.signal_digest == context.business_digest and nil or "signal-digest-changed"
  end
  local decision, decision_why = M.review_decision(issue, review_options)
  if decision == nil or decision.command ~= context.review_command
      or tostring(decision.comment_id) ~= tostring(context.review_comment_id)
      or decision.proposal.proposal_id ~= context.proposal_id
      or decision.proposal.revision ~= context.proposal_revision
      or decision.proposal.content_digest ~= context.business_digest then
    return "skip", "review-decision-changed:" .. tostring(decision_why)
  end
  return "close"
end

function M.close_lock_key(context)
  return "marketing-radar/v2/close/" .. runtime_segment(context.source_ref.ref, 180)
end

M.PROPOSAL_CONTRACT = PROPOSAL_CONTRACT
M.SIGNAL_CONTRACT = SIGNAL_CONTRACT
M.TERMINAL_HANDOFF_SCHEMA = TERMINAL_HANDOFF_SCHEMA
M.runtime_segment = runtime_segment
M.normalized_login = normalized_login
M.action_strategy = action_strategies.evaluate
M.canonical_issue_source_ref = source_identity.canonical_issue_source_ref

return M
