local core = require("core")
local strings = require("contract.strings")

local M = {}

local HANDOFF_SCHEMA = "auto-twitter-marketing.one-shot-close.v1"
local HANDOFF_KIND = "published-one-shot"
local COMMENT_SUFFIX = "/status/x-publish-published"
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

local function safe_log_value(value)
  local text = tostring(value or ""):gsub("[%z\1-\31\127]", " ")
  text = strings.trim(text)
  if #text > 256 then
    return text:sub(1, 256)
  end
  return text
end

function M.handoff_for_receipt(payload, comment_dedup_key)
  if type(payload) ~= "table" or payload.status ~= "published" then
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
  if not canonical_dedup_key(payload.dedup_key)
      or comment_dedup_key ~= payload.dedup_key .. COMMENT_SUFFIX
      or not bounded_string(comment_dedup_key, MAX_DEDUP_KEY_BYTES + #COMMENT_SUFFIX)
      or not bounded_string(payload.artifact_id, MAX_CONTROL_BYTES)
      or not bounded_string(payload.content_ref, MAX_CONTROL_BYTES)
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
    channel = "live",
    platform = post_evidence.platform,
    platform_post_id = post_evidence.platform_post_id,
    post_uri = post_evidence.post_uri,
    locale = metadata.locale,
    owner = metadata.owner,
    receipt_dedup_key = payload.dedup_key,
    comment_dedup_key = comment_dedup_key,
    source_ref = source_ref,
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
  local payload_repo, payload_issue_number, payload_ref = issue_target(payload.source_ref)
  if repo == nil
      or payload_repo ~= repo
      or payload_issue_number ~= issue_number
      or payload_ref ~= ref
      or payload.repo ~= repo
      or tonumber(payload.issue_number) ~= issue_number then
    return nil, "close-target-mismatch"
  end

  local post_evidence = canonical_x_post_evidence(
    handoff.platform,
    handoff.platform_post_id,
    handoff.post_uri
  )

  if not canonical_dedup_key(handoff.receipt_dedup_key)
      or handoff.comment_dedup_key ~= handoff.receipt_dedup_key .. COMMENT_SUFFIX
      or payload.request_dedup_key ~= handoff.comment_dedup_key
      or payload.dedup_key ~= handoff.comment_dedup_key .. "/written/" .. comment_id
      or not bounded_string(handoff.artifact_id, MAX_CONTROL_BYTES)
      or not bounded_string(handoff.content_ref, MAX_CONTROL_BYTES)
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
    repo = repo,
    issue_number = issue_number,
    source_ref = copy_source_ref(handoff.source_ref),
    scheduled_at = handoff.scheduled_at,
    artifact_id = handoff.artifact_id,
    content_ref = handoff.content_ref,
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

function M.current_issue_decision(issue, context)
  if type(issue) ~= "table" then
    return "skip", "invalid-current-issue"
  end
  local state = tostring(issue.state or ""):upper()
  if state == "CLOSED" then
    return "converged", "already-closed"
  end
  if state ~= "OPEN" then
    return "skip", "current-issue-not-open"
  end

  local repo, issue_number, ref = issue_target(issue.source_ref)
  if repo ~= context.repo or issue_number ~= context.issue_number
      or ref ~= context.source_ref.ref or tonumber(issue.number) ~= context.issue_number then
    return "skip", "current-issue-target-mismatch"
  end
  if not core.has_work_label(issue.labels) then
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
      or item.calendar_ref ~= context.content_ref
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
  return "close", nil
end

function M.lock_key(context)
  return "auto-twitter-marketing/one-shot-close/"
    .. core.runtime_key_segment(context and context.source_ref and context.source_ref.ref or "unknown", 180)
end

M.safe_log_value = safe_log_value

return M
