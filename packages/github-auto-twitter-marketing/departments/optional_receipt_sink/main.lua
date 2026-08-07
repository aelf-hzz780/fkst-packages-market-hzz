local saga = require("workflow.saga")

local spec = {
  consumes = {
    "github-proxy.github_comment_written",
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

local function receipt_comment(payload)
  if type(payload) ~= "table" then
    return nil
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
    .. "status: " .. status .. "\n"

  local post_uri = safe_line(payload.post_uri, 256)
  if post_uri ~= "" then
    body = body .. "post_uri: " .. post_uri .. "\n"
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

  body = body
    .. "source_ref: " .. safe_line((payload.source_ref or {}).ref or (payload.source_ref or {}).reference, 256) .. "\n"
    .. "dedup_key: " .. safe_line(payload.dedup_key, 256) .. "\n"

  local comment_key = tostring(payload.dedup_key or payload.artifact_id or "x-publish-receipt")
    .. "/status/x-publish-" .. status
  body = body .. "\n<!-- fkst:github-proxy:comment:" .. safe_line(comment_key, 256) .. " -->\n"

  return {
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
end

local function act(event)
  local payload = event and event.payload or {}
  log.info("github-auto-twitter-marketing dept=optional_receipt_sink tag=ACK queue="
    .. tostring(event and event.queue)
    .. " artifact_id="
    .. tostring(payload.artifact_id or payload.comment_id))
  if event and event.queue == "x-publisher.x_published" then
    local comment = receipt_comment(payload)
    if comment ~= nil then
      raise("github-proxy.github_issue_comment_request", comment)
    end
  end
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "optional_receipt_sink",
})
