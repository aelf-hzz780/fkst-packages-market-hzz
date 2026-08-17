local saga = require("workflow.saga")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")
local one_shot_close = require("one_shot_close")

local MAX_DEDUP_KEY_BYTES = 512

local function is_canonical_dedup_key(value)
  return strings.is_bounded_string(value, MAX_DEDUP_KEY_BYTES)
    and strings.trim(value) == value
    and value:find("[%z\1-\31\127]") == nil
end

local function receipt_key_values(payload)
  if not is_canonical_dedup_key(payload.dedup_key) then
    return nil, nil, "invalid-dedup-key"
  end
  return payload.dedup_key, payload.dedup_key, nil
end

local spec = {
  consumes = {
    "x-publisher.x_published",
  },
  produces = {
    "github-proxy.github_issue_comment_request",
  },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function issue_target(source_ref)
  local ref = type(source_ref) == "table" and (source_ref.ref or source_ref.reference) or nil
  if type(ref) ~= "string" then
    return nil
  end
  local repo, number = ref:match("^([^#]+)#issue/(%d+)$")
  if repo == nil then
    return nil
  end
  return repo, tonumber(number)
end

local function safe_line(value, limit)
  local text = tostring(value or ""):gsub("[\r\n]", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if limit ~= nil and #text > limit then
    return text:sub(1, limit)
  end
  return text
end

local function comment_title(status)
  if status == "published" then
    return "X published"
  end
  if status == "blocked" then
    return "X publish blocked"
  end
  if status == "skipped" then
    return "X publish skipped"
  end
  if status == "preview" then
    return "X publish preview"
  end
  return "X publish receipt"
end

local function canonical_published_evidence(payload)
  local post_id = type(payload) == "table" and tostring(payload.platform_post_id or "") or ""
  return type(payload) == "table"
    and payload.status == "published"
    and payload.platform == "x"
    and payload.channel == "live"
    and post_id:match("^%d+$") ~= nil
    and #post_id <= 32
    and payload.post_uri == "https://x.com/i/web/status/" .. post_id
    and session_route.normalize_account(payload.authenticated_account) == payload.account
end

local function receipt_comments(payload)
  if type(payload) ~= "table" or payload.schema ~= "x-publisher.publish-receipt.v2" then
    return nil, "unsupported-receipt-schema"
  end
  if not session_route.is_canonical_account(payload.account)
      or not strings.is_bounded_string(payload.work_label, 80)
      or not sha256.is_tagged(payload.content_digest)
      or not strings.is_bounded_string(payload.approval_id, 256) then
    return nil, "invalid-receipt-correlation"
  end
  local comment_key_base, receipt_dedup_key, key_why = receipt_key_values(payload)
  if comment_key_base == nil then
    return nil, key_why
  end
  local repo, issue_number = issue_target(payload.source_ref)
  if repo == nil or issue_number == nil then
    return nil
  end

  local status = safe_line(payload.status, 64)
  if status == "" then
    status = "unknown"
  end
  local body = "Auto Twitter marketing: " .. comment_title(status) .. "\n\n"
    .. "schema: x-publisher.publish-receipt.v2\n"
    .. "status: " .. status .. "\n"

  for _, field in ipairs({
    "account",
    "authenticated_account",
    "work_label",
    "content_digest",
    "schedule_digest",
    "approval_id",
  }) do
    local value = safe_line(payload[field], 512)
    if value ~= "" then
      body = body .. field .. ": " .. value .. "\n"
    end
  end

  local post_uri = safe_line(payload.post_uri, 256)
  if post_uri ~= "" then
    body = body .. "post_uri: " .. post_uri .. "\n"
  end

  local platform_post_id = safe_line(payload.platform_post_id, 64)
  if platform_post_id ~= "" then
    body = body .. "platform_post_id: " .. platform_post_id .. "\n"
  end

  local operation = safe_line(payload.operation, 32)
  if operation ~= "" then
    body = body .. "operation: " .. operation .. "\n"
  end

  local quote_mode = safe_line(payload.quote_mode, 32)
  if quote_mode ~= "" then
    body = body .. "quote_mode: " .. quote_mode .. "\n"
  end

  local quote_target_uri = safe_line(payload.quote_target_uri, 256)
  if quote_target_uri ~= "" then
    body = body .. "quote_target_uri: " .. quote_target_uri .. "\n"
  end

  local quote_target_post_id = safe_line(payload.quote_target_post_id, 64)
  if quote_target_post_id ~= "" then
    body = body .. "quote_target_post_id: " .. quote_target_post_id .. "\n"
  end

  local blocked_reason = safe_line(payload.blocked_reason, 256)
  if blocked_reason ~= "" then
    body = body .. "blocked_reason: " .. blocked_reason .. "\n"
  end

  local skipped_reason = safe_line(payload.skipped_reason, 256)
  if skipped_reason ~= "" then
    body = body .. "skipped_reason: " .. skipped_reason .. "\n"
  end

  if type(payload.publish_attempted) == "boolean" then
    body = body .. "publish_attempted: " .. tostring(payload.publish_attempted) .. "\n"
  end

  body = body
    .. "source_ref: " .. safe_line((payload.source_ref or {}).ref or (payload.source_ref or {}).reference, 256) .. "\n"
    .. "dedup_key: " .. receipt_dedup_key .. "\n"

  local comment_key = comment_key_base .. "/status/x-publish-" .. status
  body = body .. "\n<!-- fkst:github-proxy:comment:" .. comment_key .. " -->\n"

  local request = {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
    body = body,
    dedup_key = comment_key,
    source_ref = {
      kind = "external",
      ref = (payload.source_ref or {}).ref or (payload.source_ref or {}).reference,
      reference = (payload.source_ref or {}).reference or (payload.source_ref or {}).ref,
    },
  }
  local requests = { request }
  if canonical_published_evidence(payload) then
    local anchor_ref = one_shot_close.content_anchor_source_ref(payload)
    local anchor_key = one_shot_close.content_anchor_dedup_key(payload, anchor_ref)
    local anchor_repo, anchor_number = issue_target(anchor_ref)
    if anchor_key ~= nil and anchor_repo ~= nil and anchor_number ~= nil then
      requests[#requests + 1] = {
        schema = "github-proxy.v1",
        repo = anchor_repo,
        issue_number = anchor_number,
        body = body,
        dedup_key = anchor_key,
        source_ref = anchor_ref,
        handoff = one_shot_close.handoff_for_receipt(payload, anchor_key, anchor_ref),
      }
    end
  end
  return requests
end

local function act(event)
  local payload = event and event.payload or {}
  log.info("github-auto-twitter-marketing dept=optional_receipt_sink tag=ACK queue="
    .. tostring(event and event.queue)
    .. " artifact_id="
    .. tostring(payload.artifact_id or payload.comment_id))
  local comments, why = receipt_comments(payload)
  if comments ~= nil then
    for _, comment in ipairs(comments) do
      raise("github-proxy.github_issue_comment_request", comment)
    end
  elseif why ~= nil then
    log.warn("github-auto-twitter-marketing dept=optional_receipt_sink tag=SKIP why=" .. why)
  end
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "optional_receipt_sink",
})
