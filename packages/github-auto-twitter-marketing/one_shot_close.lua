local core = require("core")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}

local HANDOFF_SCHEMA = "auto-twitter-marketing.one-shot-close.v2"
local HANDOFF_KIND = "published-one-shot"
local COMMENT_SUFFIX = "/status/x-publish-published"
local CONTENT_ANCHOR_PREFIX = "auto-twitter-marketing/v2/content-published/"
local MAX_DEDUP_KEY_BYTES = 512
local MAX_CONTROL_BYTES = 512
local MAX_X_POST_ID_BYTES = 32

local function bounded_string(value, limit)
  return type(value) == "string"
    and strings.trim(value) == value
    and value ~= ""
    and #value <= limit
    and value:find("[%z\1-\31\127]") == nil
end

local function canonical_dedup_key(value)
  return bounded_string(value, MAX_DEDUP_KEY_BYTES)
end

local function optional_bounded_string(value, limit)
  return value == nil or bounded_string(value, limit)
end

local function canonical_x_post_evidence(platform, platform_post_id, post_uri)
  if platform ~= "x"
      or not bounded_string(platform_post_id, MAX_X_POST_ID_BYTES)
      or platform_post_id:match("^%d+$") == nil then
    return nil
  end
  local canonical_uri = "https://x.com/i/web/status/" .. platform_post_id
  if post_uri ~= canonical_uri then
    return nil
  end
  return {
    platform = "x",
    platform_post_id = platform_post_id,
    post_uri = canonical_uri,
  }
end

local function source_ref_value(source_ref)
  if type(source_ref) ~= "table" or source_ref.kind ~= "external" then
    return nil
  end
  if source_ref.ref ~= nil and source_ref.reference ~= nil
      and source_ref.ref ~= source_ref.reference then
    return nil
  end
  local ref = source_ref.ref or source_ref.reference
  if not bounded_string(ref, MAX_CONTROL_BYTES) then
    return nil
  end
  return ref
end

local function issue_target(source_ref)
  local ref = source_ref_value(source_ref)
  if ref == nil then
    return nil
  end
  local repo, issue_number = ref:match("^([^#]+)#issue/(%d+)$")
  local number = tonumber(issue_number)
  if repo == nil or repo == "" or number == nil or number < 1 then
    return nil
  end
  return repo, number, ref
end

local function copy_source_ref(source_ref)
  local ref = source_ref_value(source_ref)
  if ref == nil then
    return nil
  end
  return {
    kind = "external",
    ref = ref,
    reference = ref,
  }
end

local function content_source_ref(schedule_source_ref, content_ref)
  local schedule_repo = select(1, issue_target(schedule_source_ref))
  local raw = strings.trim(content_ref)
  if schedule_repo == nil or raw == "" or #raw > MAX_CONTROL_BYTES then
    return nil
  end
  local repo, number = raw:match("^([^#]+)#issue/(%d+)$")
  if repo == nil then
    repo, number = raw:match("^https://github%.com/([^/]+/[^/]+)/issues/(%d+)")
  end
  if repo == nil then
    number = raw:match("^#(%d+)$") or raw:match("^(%d+)$")
    repo = number and schedule_repo or nil
  end
  local numeric = tonumber(number)
  if repo == nil or repo:match("^[%w_.-]+/[%w_.-]+$") == nil
      or numeric == nil or numeric < 1 or numeric ~= math.floor(numeric) then
    return nil
  end
  local ref = repo .. "#issue/" .. string.format("%.0f", numeric)
  return { kind = "external", ref = ref, reference = ref }
end

function M.content_anchor_source_ref(payload)
  if type(payload) ~= "table" then
    return nil
  end
  return content_source_ref(payload.source_ref, payload.content_ref)
end

function M.content_anchor_dedup_key(payload, anchor_source_ref)
  if type(payload) ~= "table" or not canonical_dedup_key(payload.dedup_key)
      or not sha256.is_tagged(payload.content_digest)
      or not bounded_string(payload.approval_id, MAX_CONTROL_BYTES) then
    return nil
  end
  local expected_anchor = content_source_ref(payload.source_ref, payload.content_ref)
  local supplied_anchor = copy_source_ref(anchor_source_ref or expected_anchor)
  if expected_anchor == nil or supplied_anchor == nil
      or supplied_anchor.ref ~= expected_anchor.ref then
    return nil
  end
  return CONTENT_ANCHOR_PREFIX .. sha256.hex(table.concat({
    payload.dedup_key,
    expected_anchor.ref,
    payload.content_digest,
    payload.approval_id,
  }, "\n"))
end

local function safe_log_value(value)
  local text = tostring(value or ""):gsub("[%z\1-\31\127]", " ")
  text = strings.trim(text)
  if #text > 256 then
    return text:sub(1, 256)
  end
  return text
end

function M.handoff_for_receipt(payload, comment_dedup_key, receipt_anchor_ref)
  if type(payload) ~= "table"
      or payload.schema ~= "x-publisher.publish-receipt.v2"
      or payload.status ~= "published" then
    return nil
  end
  local metadata = type(payload.metadata) == "table" and payload.metadata or {}
  if metadata.schedule_type ~= "one-shot" then
    return nil
  end
  local post_evidence = canonical_x_post_evidence(
    payload.platform,
    payload.platform_post_id,
    payload.post_uri
  )
  local account = session_route.normalize_account(payload.account)
  local authenticated_account = session_route.normalize_account(payload.authenticated_account)
  local anchor_ref = copy_source_ref(receipt_anchor_ref)
  local expected_comment_key = anchor_ref ~= nil
    and M.content_anchor_dedup_key(payload, anchor_ref)
    or (payload.dedup_key .. COMMENT_SUFFIX)
  if not canonical_dedup_key(payload.dedup_key)
      or comment_dedup_key ~= expected_comment_key
      or not bounded_string(comment_dedup_key, MAX_DEDUP_KEY_BYTES + #COMMENT_SUFFIX)
      or not bounded_string(payload.artifact_id, MAX_CONTROL_BYTES)
      or not bounded_string(payload.content_ref, MAX_CONTROL_BYTES)
      or account == nil
      or authenticated_account ~= account
      or not bounded_string(payload.work_label, MAX_CONTROL_BYTES)
      or not sha256.is_tagged(payload.content_digest)
      or not bounded_string(payload.approval_id, MAX_CONTROL_BYTES)
      or payload.channel ~= "live"
      or not bounded_string(payload.trace_id, MAX_CONTROL_BYTES)
      or not bounded_string(payload.scheduled_at, MAX_CONTROL_BYTES)
      or not optional_bounded_string(metadata.locale, MAX_CONTROL_BYTES)
      or not optional_bounded_string(metadata.owner, MAX_CONTROL_BYTES)
      or core.parse_iso8601_seconds(payload.scheduled_at) == nil
      or post_evidence == nil then
    return nil
  end
  local source_ref = copy_source_ref(payload.source_ref)
  if source_ref == nil then
    return nil
  end
  return {
    schema = HANDOFF_SCHEMA,
    kind = HANDOFF_KIND,
    status = "published",
    schedule_type = "one-shot",
    scheduled_at = payload.scheduled_at,
    artifact_id = payload.artifact_id,
    content_ref = payload.content_ref,
    account = account,
    authenticated_account = authenticated_account,
    work_label = payload.work_label,
    content_digest = payload.content_digest,
    approval_id = payload.approval_id,
    channel = "live",
    platform = post_evidence.platform,
    platform_post_id = post_evidence.platform_post_id,
    post_uri = post_evidence.post_uri,
    locale = metadata.locale,
    owner = metadata.owner,
    receipt_dedup_key = payload.dedup_key,
    comment_dedup_key = comment_dedup_key,
    source_ref = source_ref,
    receipt_anchor_ref = anchor_ref,
    trace_id = payload.trace_id,
  }
end

function M.ack_context(payload)
  local comment_id = type(payload) == "table" and tostring(payload.comment_id or "") or ""
  if type(payload) ~= "table"
      or payload.schema ~= "github-proxy.comment-written.v1"
      or payload.target ~= "issue"
      or (type(payload.comment_id) ~= "string" and type(payload.comment_id) ~= "number")
      or not bounded_string(comment_id, MAX_CONTROL_BYTES) then
    return nil, "invalid-comment-ack"
  end

  local handoff = payload.handoff
  if type(handoff) ~= "table"
      or handoff.schema ~= HANDOFF_SCHEMA
      or handoff.kind ~= HANDOFF_KIND
      or handoff.status ~= "published"
      or handoff.schedule_type ~= "one-shot" then
    return nil, "invalid-close-handoff"
  end

  local repo, issue_number, ref = issue_target(handoff.source_ref)
  local receipt_anchor_ref = copy_source_ref(handoff.receipt_anchor_ref)
  local ack_source_ref = receipt_anchor_ref or copy_source_ref(handoff.source_ref)
  local payload_repo, payload_issue_number, payload_ref = issue_target(payload.source_ref)
  local ack_repo, ack_issue_number, ack_ref = issue_target(ack_source_ref)
  if repo == nil
      or ack_repo == nil
      or payload_repo ~= ack_repo
      or payload_issue_number ~= ack_issue_number
      or payload_ref ~= ack_ref
      or payload.repo ~= ack_repo
      or tonumber(payload.issue_number) ~= ack_issue_number then
    return nil, "close-target-mismatch"
  end

  local post_evidence = canonical_x_post_evidence(
    handoff.platform,
    handoff.platform_post_id,
    handoff.post_uri
  )
  local account = session_route.normalize_account(handoff.account)
  local authenticated_account = session_route.normalize_account(handoff.authenticated_account)

  local expected_comment_key = receipt_anchor_ref ~= nil
    and M.content_anchor_dedup_key({
      dedup_key = handoff.receipt_dedup_key,
      content_ref = handoff.content_ref,
      content_digest = handoff.content_digest,
      approval_id = handoff.approval_id,
      source_ref = handoff.source_ref,
    }, receipt_anchor_ref)
    or (tostring(handoff.receipt_dedup_key or "") .. COMMENT_SUFFIX)
  if not canonical_dedup_key(handoff.receipt_dedup_key)
      or handoff.comment_dedup_key ~= expected_comment_key
      or payload.request_dedup_key ~= handoff.comment_dedup_key
      or payload.dedup_key ~= handoff.comment_dedup_key .. "/written/" .. comment_id
      or not bounded_string(handoff.artifact_id, MAX_CONTROL_BYTES)
      or not bounded_string(handoff.content_ref, MAX_CONTROL_BYTES)
      or account == nil
      or authenticated_account ~= account
      or not bounded_string(handoff.work_label, MAX_CONTROL_BYTES)
      or not sha256.is_tagged(handoff.content_digest)
      or not bounded_string(handoff.approval_id, MAX_CONTROL_BYTES)
      or handoff.channel ~= "live"
      or not bounded_string(handoff.trace_id, MAX_CONTROL_BYTES)
      or not bounded_string(handoff.scheduled_at, MAX_CONTROL_BYTES)
      or not optional_bounded_string(handoff.locale, MAX_CONTROL_BYTES)
      or not optional_bounded_string(handoff.owner, MAX_CONTROL_BYTES)
      or core.parse_iso8601_seconds(handoff.scheduled_at) == nil
      or post_evidence == nil then
    return nil, "invalid-close-correlation"
  end

  return {
    kind = "one-shot",
    repo = repo,
    issue_number = issue_number,
    source_ref = copy_source_ref(handoff.source_ref),
    receipt_anchor_ref = receipt_anchor_ref,
    scheduled_at = handoff.scheduled_at,
    artifact_id = handoff.artifact_id,
    content_ref = handoff.content_ref,
    account = account,
    authenticated_account = authenticated_account,
    work_label = handoff.work_label,
    content_digest = handoff.content_digest,
    approval_id = handoff.approval_id,
    channel = handoff.channel,
    platform = post_evidence.platform,
    platform_post_id = post_evidence.platform_post_id,
    post_uri = post_evidence.post_uri,
    locale = handoff.locale,
    owner = handoff.owner,
    receipt_dedup_key = handoff.receipt_dedup_key,
    comment_dedup_key = handoff.comment_dedup_key,
    trace_id = handoff.trace_id,
  }
end

function M.current_issue_decision(issue, context, authority)
  if type(issue) ~= "table" then
    return "skip", "invalid-current-issue"
  end
  local state = tostring(issue.state or ""):upper()
  if state ~= "OPEN" and state ~= "CLOSED" then
    return "skip", "current-issue-not-open"
  end

  local repo, issue_number, ref = issue_target(issue.source_ref)
  if repo ~= context.repo or issue_number ~= context.issue_number
      or ref ~= context.source_ref.ref or tonumber(issue.number) ~= context.issue_number then
    return "skip", "current-issue-target-mismatch"
  end
  if type(authority) ~= "table"
      or authority.account ~= context.account
      or authority.logical_work_label ~= context.work_label then
    return "skip", "current-session-correlation-mismatch"
  end
  if not core.has_work_label(issue.labels, authority.effective_work_label) then
    return "skip", "current-issue-out-of-scope"
  end

  local item, why = core.classify_issue({
    schema = "github-proxy.v1",
    type = "issue",
    repo = context.repo,
    number = context.issue_number,
    state = state,
    labels = issue.labels,
    source_ref = issue.source_ref,
  }, {
    issue_body = issue.body,
    issue_labels = issue.labels,
    issue_assignees = issue.assignees,
    session = authority,
  })
  if item == nil then
    return "skip", "current-issue-invalid:" .. tostring(why)
  end
  if item.kind ~= "schedule-publish" or item.recurrence ~= nil then
    return "skip", "current-issue-not-one-shot"
  end
  if item.scheduled_at ~= context.scheduled_at then
    return "skip", "current-occurrence-mismatch"
  end
  if core.artifact_id(item) ~= context.artifact_id
      or item.content_ref ~= context.content_ref
      or item.account ~= context.account
      or item.work_label ~= context.work_label
      or item.content_digest ~= context.content_digest
      or item.approval_id ~= context.approval_id
      or item.mode ~= context.channel
      or item.locale ~= context.locale
      or item.owner ~= context.owner then
    return "skip", "current-schedule-correlation-mismatch"
  end
  local current_dedup_key = core.schedule_publish_dedup_key(item, {
    occurrence_id = item.scheduled_at,
  })
  if current_dedup_key ~= context.receipt_dedup_key then
    return "skip", "current-publish-correlation-mismatch"
  end
  return state == "CLOSED" and "converged" or "close",
    state == "CLOSED" and "already-closed" or nil
end

function M.lock_key(context)
  return "auto-twitter-marketing/one-shot-close/"
    .. core.runtime_key_segment(context and context.source_ref and context.source_ref.ref or "unknown", 180)
end

M.safe_log_value = safe_log_value

return M
