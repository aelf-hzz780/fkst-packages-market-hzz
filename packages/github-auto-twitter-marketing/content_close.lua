local marketing_content = require("contract.marketing_content")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}

local HANDOFF_SCHEMA = "auto-twitter-marketing.weekly-content-close.v2"
local IMPORT_SCHEMA = "auto-twitter-marketing.weekly-content-imported.v2"
local COMMENT_SUFFIX = "/status/weekly-content-imported"
local MAX_VALUE_BYTES = 512

local function bounded(value, limit)
  return type(value) == "string"
    and value ~= ""
    and value == strings.trim(value)
    and #value <= (limit or MAX_VALUE_BYTES)
    and value:find("[%z\1-\31\127]") == nil
end

local function canonical_login(value)
  local login = strings.trim(value):lower()
  if login == "" then
    return nil
  end
  return login
end

local function source_target(source_ref)
  if type(source_ref) ~= "table" or source_ref.kind ~= "external"
      or (source_ref.ref ~= nil and source_ref.reference ~= nil and source_ref.ref ~= source_ref.reference) then
    return nil
  end
  local ref = source_ref.ref or source_ref.reference
  local repo, raw_number
  if type(ref) == "string" then
    repo, raw_number = ref:match("^([^#]+)#issue/(%d+)$")
  end
  local number = tonumber(raw_number)
  if repo == nil or number == nil or number < 1 then
    return nil
  end
  return repo, number, ref
end

local function copy_source_ref(source_ref)
  local _repo, _number, ref = source_target(source_ref)
  if ref == nil then
    return nil
  end
  return { kind = "external", ref = ref, reference = ref }
end

function M.comment_request(payload)
  if type(payload) ~= "table" or payload.schema ~= IMPORT_SCHEMA
      or not bounded(payload.artifact_id)
      or not bounded(payload.account)
      or not bounded(payload.work_label)
      or not bounded(payload.content_id)
      or type(payload.content_revision) ~= "number"
      or not bounded(payload.approval_id)
      or not bounded(payload.content_digest)
      or not bounded(payload.dedup_key)
      or not bounded(payload.trace_id)
      or not session_route.is_canonical_account(payload.account)
      or not sha256.is_tagged(payload.content_digest) then
    return nil, "invalid weekly content import"
  end
  local repo, issue_number = source_target(payload.source_ref)
  if repo == nil then
    return nil, "invalid weekly content source"
  end
  local comment_key = payload.dedup_key .. COMMENT_SUFFIX
  if #comment_key > MAX_VALUE_BYTES + #COMMENT_SUFFIX then
    return nil, "invalid weekly content comment key"
  end
  local source_ref = copy_source_ref(payload.source_ref)
  local body = table.concat({
    "Auto Twitter marketing: weekly content imported",
    "",
    "account: " .. payload.account,
    "work_label: " .. payload.work_label,
    "content_id: " .. payload.content_id,
    "content_revision: " .. tostring(payload.content_revision),
    "content_digest: " .. payload.content_digest,
    "approval_id: " .. payload.approval_id,
    "source_ref: " .. source_ref.ref,
    "dedup_key: " .. payload.dedup_key,
    "",
    "<!-- fkst:github-proxy:comment:" .. comment_key .. " -->",
  }, "\n")
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
    body = body,
    dedup_key = comment_key,
    source_ref = source_ref,
    handoff = {
      schema = HANDOFF_SCHEMA,
      kind = "imported-weekly-content",
      artifact_id = payload.artifact_id,
      account = payload.account,
      work_label = payload.work_label,
      content_id = payload.content_id,
      content_revision = payload.content_revision,
      content_digest = payload.content_digest,
      approval_id = payload.approval_id,
      import_dedup_key = payload.dedup_key,
      comment_dedup_key = comment_key,
      source_ref = source_ref,
      trace_id = payload.trace_id,
    },
  }, nil
end

function M.ack_context(payload)
  local comment_id = type(payload) == "table" and tostring(payload.comment_id or "") or ""
  local handoff = type(payload) == "table" and payload.handoff or nil
  if type(payload) ~= "table" or payload.schema ~= "github-proxy.comment-written.v1"
      or payload.target ~= "issue" or not bounded(comment_id)
      or type(handoff) ~= "table" or handoff.schema ~= HANDOFF_SCHEMA
      or handoff.kind ~= "imported-weekly-content" then
    return nil, "invalid-content-close-ack"
  end
  local repo, issue_number, ref = source_target(handoff.source_ref)
  local payload_repo, payload_number, payload_ref = source_target(payload.source_ref)
  if repo == nil or payload_repo ~= repo or payload_number ~= issue_number or payload_ref ~= ref
      or payload.repo ~= repo or tonumber(payload.issue_number) ~= issue_number then
    return nil, "content-close-target-mismatch"
  end
  if not bounded(handoff.artifact_id) or not bounded(handoff.account)
      or not bounded(handoff.work_label) or not bounded(handoff.content_id)
      or type(handoff.content_revision) ~= "number" or not bounded(handoff.content_digest)
      or not bounded(handoff.approval_id) or not bounded(handoff.import_dedup_key)
      or handoff.comment_dedup_key ~= handoff.import_dedup_key .. COMMENT_SUFFIX
      or payload.request_dedup_key ~= handoff.comment_dedup_key
      or payload.dedup_key ~= handoff.comment_dedup_key .. "/written/" .. comment_id
      or not bounded(handoff.trace_id)
      or not session_route.is_canonical_account(handoff.account)
      or not sha256.is_tagged(handoff.content_digest) then
    return nil, "invalid-content-close-correlation"
  end
  return {
    kind = "weekly-content",
    repo = repo,
    issue_number = issue_number,
    source_ref = copy_source_ref(handoff.source_ref),
    artifact_id = handoff.artifact_id,
    account = handoff.account,
    work_label = handoff.work_label,
    content_id = handoff.content_id,
    content_revision = handoff.content_revision,
    content_digest = handoff.content_digest,
    approval_id = handoff.approval_id,
    receipt_dedup_key = handoff.import_dedup_key,
    comment_dedup_key = handoff.comment_dedup_key,
    trace_id = handoff.trace_id,
  }, nil
end

function M.current_issue_decision(issue, context, authority)
  if type(issue) ~= "table" then
    return "skip", "invalid-current-content"
  end
  local state = tostring(issue.state or ""):upper()
  if state == "CLOSED" then
    return "converged", "already-closed"
  end
  if state ~= "OPEN" then
    return "skip", "current-content-not-open"
  end
  local repo, issue_number, ref = source_target(issue.source_ref)
  if repo ~= context.repo or issue_number ~= context.issue_number or ref ~= context.source_ref.ref
      or tonumber(issue.number) ~= context.issue_number then
    return "skip", "current-content-target-mismatch"
  end
  if type(authority) ~= "table" or authority.account ~= context.account
      or authority.logical_work_label ~= context.work_label
      or not session_route.has_label(issue.labels, authority.effective_work_label) then
    return "skip", "current-content-route-mismatch"
  end
  if canonical_login(session_route.single_assignee(issue.assignees)) ~= canonical_login(authority.creator) then
    return "skip", "current-content-assignee-mismatch"
  end
  local content, why = marketing_content.parse(issue.body)
  if content == nil then
    return "skip", "current-content-invalid:" .. tostring(why)
  end
  if content.account ~= context.account or content.work_label ~= context.work_label
      or content.content_id ~= context.content_id
      or content.content_revision ~= context.content_revision
      or content.content_digest ~= context.content_digest
      or content.approval_id ~= context.approval_id then
    return "skip", "current-content-correlation-mismatch"
  end
  return "close", nil
end

function M.lock_key(context)
  return "auto-twitter-marketing/weekly-content-close/"
    .. strings.runtime_safe_segment(context and context.source_ref and context.source_ref.ref or "unknown")
end

return M
