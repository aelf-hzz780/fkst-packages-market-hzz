local proposal_identity = require("proposal_identity")
local session_authority = require("session_authority")
local sha256 = require("contract.sha256")
local status_contract = require("status_contract")
local strings = require("contract.strings")

local M = {
  SCHEMA = "marketing-radar.issue-close.v2",
}

local function trim(value)
  return strings.trim(value or "")
end

local function copy_source_ref(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  local ref = trim(source_ref.ref or source_ref.reference)
  if source_ref.kind ~= "external" or ref == "" or #ref > 240
      or ref:match("^[^#]+#issue/%d+$") == nil then
    return nil
  end
  if source_ref.ref ~= nil and source_ref.reference ~= nil
      and source_ref.ref ~= source_ref.reference then
    return nil
  end
  return { kind = "external", ref = ref, reference = ref }
end

local function source_number(source_ref)
  return tonumber(source_ref and source_ref.ref and source_ref.ref:match("#issue/(%d+)$"))
end

local function encode_fields(fields, keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local value = tostring(fields[key] or "")
    parts[#parts + 1] = key .. ":" .. tostring(#value) .. ":" .. value
  end
  return table.concat(parts, "\n")
end

local function terminal_dedup_root(handoff)
  local target_ref = copy_source_ref(handoff.source_ref)
  local review_source_ref = copy_source_ref(handoff.review_source_ref)
  local proposal_revision = proposal_identity.revision(handoff.proposal_revision)
  local review_comment_id = tostring(handoff.review_comment_id or "")
  local proposal_id = trim(handoff.proposal_id)
  if handoff.schema ~= M.SCHEMA
      or (handoff.kind ~= "radar-signal" and handoff.kind ~= "weekly-plan-change")
      or target_ref == nil or review_source_ref == nil
      or proposal_id == "" or #proposal_id > 160
      or proposal_id:find("[%z\1-\31\127]") ~= nil
      or proposal_revision == nil or review_comment_id:match("^[1-9][0-9]*$") == nil
      or (handoff.review_command ~= "approve" and handoff.review_command ~= "reject")
      or not sha256.is_tagged(handoff.business_digest)
      or not sha256.is_tagged(handoff.proposal_digest)
      or not sha256.is_tagged(handoff.content_digest) then
    return nil
  end
  local identity = encode_fields({
    target_ref = target_ref.ref,
    review_source_ref = review_source_ref.ref,
    proposal_id = proposal_id,
    proposal_revision = proposal_revision,
    review_comment_id = review_comment_id,
    review_command = handoff.review_command,
    business_digest = handoff.business_digest,
    proposal_digest = handoff.proposal_digest,
    content_digest = handoff.content_digest,
  }, {
    "target_ref", "review_source_ref", "proposal_id", "proposal_revision",
    "review_comment_id", "review_command", "business_digest", "proposal_digest",
    "content_digest",
  })
  return "marketing-radar/v2/terminal-status/"
    .. proposal_identity.runtime_segment(target_ref.ref, 180)
    .. "/sha256-" .. sha256.hex(identity)
end

function M.status_comment(item, status, handoff)
  local dedup = item.dedup_key or item.group_key
    or ("marketing-radar/" .. proposal_identity.runtime_segment(item.source_ref.ref, 180))
  if handoff ~= nil then
    dedup = terminal_dedup_root(handoff)
    if dedup == nil then
      error("marketing-radar: invalid terminal handoff identity", 0)
    end
  end
  local request_dedup = assert(proposal_identity.dedup_key(
    dedup, "/status/" .. status_contract.segment(status)))
  local request = {
    schema = "github-proxy.v1",
    repo = item.repo or item.source_ref.ref:match("^([^#]+)#"),
    issue_number = item.issue_number or source_number(item.source_ref),
    body = status_contract.prefix(status)
      .. "\n\naccount: " .. tostring(item.account)
      .. "\npublish_attempted: false"
      .. "\ntrace-id: " .. tostring(item.trace_id or "n/a"),
    dedup_key = request_dedup,
    source_ref = copy_source_ref(item.source_ref),
  }
  if handoff ~= nil then
    handoff.comment_dedup_key = request.dedup_key
    request.handoff = handoff
  end
  return request
end

function M.close_handoff(item, terminal_kind, decision)
  local proposal = decision and decision.proposal or nil
  local review_source_ref = terminal_kind == "weekly-plan-change"
    and copy_source_ref(item.source_ref)
    or copy_source_ref(proposal and proposal.review_source_ref)
  return {
    schema = M.SCHEMA,
    kind = terminal_kind,
    account = item.account,
    effective_work_label = item.session_work_label,
    logical_work_label = item.logical_work_label,
    session_creator = item.session_creator,
    business_digest = item.signal_digest or item.content_digest,
    proposal_digest = proposal and proposal.proposal_digest or item.proposal_digest,
    content_digest = proposal and proposal.content_digest or item.content_digest,
    proposal_id = proposal and proposal.proposal_id or item.proposal_id,
    proposal_revision = proposal and proposal.revision or item.proposal_revision,
    review_command = decision and decision.command or nil,
    review_comment_id = decision and decision.comment_id or nil,
    review_source_ref = review_source_ref,
    source_ref = copy_source_ref(item.source_ref),
    trace_id = item.trace_id,
  }
end

function M.close_ack_context(payload)
  if type(payload) ~= "table" or payload.schema ~= "github-proxy.comment-written.v1"
      or payload.target ~= "issue" or payload.comment_id == nil
      or type(payload.handoff) ~= "table" then
    return nil, "invalid-comment-ack"
  end
  local handoff = payload.handoff
  local source_ref = copy_source_ref(handoff.source_ref)
  local review_source_ref = copy_source_ref(handoff.review_source_ref)
  local payload_ref = copy_source_ref(payload.source_ref)
  if handoff.schema ~= M.SCHEMA
      or (handoff.kind ~= "radar-signal" and handoff.kind ~= "weekly-plan-change")
      or source_ref == nil or payload_ref == nil or source_ref.ref ~= payload_ref.ref
      or payload.request_dedup_key ~= handoff.comment_dedup_key
      or payload.dedup_key ~= handoff.comment_dedup_key
        .. "/written/" .. tostring(payload.comment_id)
      or tonumber(payload.issue_number) ~= source_number(source_ref)
      or payload.repo ~= source_ref.ref:match("^([^#]+)#") then
    return nil, "invalid-close-correlation"
  end
  local session, why = session_authority.normalize({
    effective_work_label = handoff.effective_work_label,
    logical_work_label = handoff.logical_work_label,
    creator = handoff.session_creator,
    account = handoff.account,
  })
  if session == nil or review_source_ref == nil
      or not sha256.is_tagged(handoff.business_digest)
      or not sha256.is_tagged(handoff.proposal_digest)
      or not sha256.is_tagged(handoff.content_digest)
      or trim(handoff.proposal_id) == ""
      or proposal_identity.revision(handoff.proposal_revision) == nil
      or (handoff.review_command ~= "approve" and handoff.review_command ~= "reject")
      or tostring(handoff.review_comment_id or ""):match("^[1-9][0-9]*$") == nil then
    return nil, why or "invalid-business-digest"
  end
  return {
    kind = handoff.kind,
    repo = payload.repo,
    issue_number = tonumber(payload.issue_number),
    source_ref = source_ref,
    business_digest = handoff.business_digest,
    proposal_digest = handoff.proposal_digest,
    content_digest = handoff.content_digest,
    proposal_id = handoff.proposal_id,
    proposal_revision = tonumber(handoff.proposal_revision),
    review_command = handoff.review_command,
    review_comment_id = handoff.review_comment_id,
    review_source_ref = review_source_ref,
    trace_id = handoff.trace_id,
    session = session,
  }
end

function M.close_lock_key(context)
  return "marketing-radar/v2/close/"
    .. proposal_identity.runtime_segment(context.source_ref.ref, 180)
end

return M
