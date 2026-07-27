-- github-auto-twitter-marketing/core.lua - pure issue contract mapping helpers.
-- The durable payload carries only source_ref plus small control fields; strategy
-- and weekly content stay in the GitHub issue and are re-fetched through source_ref.
local M = {}
local strings = require("contract.strings")

local WORK_LABEL = "auto-twitter-marketing"
local CONTROL_VALUE_LIMIT = 512

local ALLOWED_CONTROL_FIELDS = {
  account = true,
  ["calendar-ref"] = true,
  channel = true,
  locale = true,
  mode = true,
  owner = true,
  project = true,
  ["scheduled-at"] = true,
  ["strategy-ref"] = true,
  type = true,
  week = true,
}

local SENSITIVE_PATTERNS = {
  "authorization",
  "api_key",
  "apikey",
  "bearer",
  "credential",
  "oauth",
  "password",
  "provider_response",
  "raw_response",
  "secret",
  "token",
}

local SOURCE_REF_FIELDS = {
  kind = true,
  ref = true,
  reference = true,
  uri = true,
  version = true,
}

local function is_small_scalar(value)
  local value_type = type(value)
  if value_type ~= "string" and value_type ~= "number" and value_type ~= "boolean" then
    return false
  end
  return #tostring(value) <= CONTROL_VALUE_LIMIT
end

local function normalized_key(key)
  return strings.trim(key):lower():gsub("_", "-")
end

local function has_sensitive_name(key)
  local normalized = normalized_key(key)
  for _, pattern in ipairs(SENSITIVE_PATTERNS) do
    if normalized:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function copy_source_ref(source_ref)
  local out = {}
  if type(source_ref) ~= "table" then
    return out
  end
  for key, value in pairs(source_ref) do
    if SOURCE_REF_FIELDS[key] and is_small_scalar(value) then
      out[key] = value
    end
  end
  if out.ref == nil and out.reference ~= nil then
    out.ref = out.reference
  end
  if out.reference == nil and out.ref ~= nil then
    out.reference = out.ref
  end
  return out
end

local function safe_id(value)
  local text = strings.trim(value):gsub("[^%w._#/-]", "-")
  text = text:gsub("-+", "-"):gsub("^[-/]+", ""):gsub("[-/]+$", "")
  if text == "" then
    return "unknown"
  end
  if #text > 180 then
    return text:sub(1, 180)
  end
  return text
end

function M.work_label()
  return WORK_LABEL
end

function M.has_work_label(labels)
  if type(labels) ~= "table" then
    return false
  end
  for _, label in ipairs(labels) do
    if tostring(label) == WORK_LABEL then
      return true
    end
  end
  return false
end

function M.parse_control_fields(body)
  local fields = {}
  if type(body) ~= "string" then
    return fields
  end
  for line in body:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
    if key ~= nil then
      local normalized = normalized_key(key)
      local cleaned = strings.trim(value)
      if ALLOWED_CONTROL_FIELDS[normalized] and not has_sensitive_name(normalized)
          and cleaned ~= "" and #cleaned <= CONTROL_VALUE_LIMIT then
        fields[normalized] = cleaned
      end
    end
  end
  return fields
end

local function control_fields(payload, opts)
  local options = opts or {}
  local fields = M.parse_control_fields(options.issue_body)
  if type(payload.controls) == "table" then
    for key, value in pairs(payload.controls) do
      local normalized = normalized_key(key)
      if ALLOWED_CONTROL_FIELDS[normalized] and not has_sensitive_name(normalized)
          and is_small_scalar(value) and tostring(value) ~= "" then
        fields[normalized] = tostring(value)
      end
    end
  end
  return fields
end

local function source_ref_for(payload)
  local source_ref = copy_source_ref(payload.source_ref)
  if source_ref.ref ~= nil and source_ref.ref ~= "" then
    return source_ref
  end
  if payload.repo ~= nil and payload.number ~= nil then
    local reference = tostring(payload.repo) .. "#issue/" .. tostring(payload.number)
    return {
      kind = "external",
      ref = reference,
      reference = reference,
    }
  end
  return nil
end

local function trace_id_for(source_ref)
  return "github:auto-twitter-marketing:" .. tostring(source_ref.ref)
end

local function dedup_key_for(kind, fields, payload, source_ref)
  local parts = {
    "auto-twitter-marketing",
    safe_id(kind),
    safe_id(fields.project),
    safe_id(fields.week or fields.account or "default"),
    safe_id(source_ref.ref),
    safe_id(payload.updated_at or payload.dedup_key or "unversioned"),
  }
  return table.concat(parts, "/")
end

local function normalize_kind(value)
  local kind = normalized_key(value)
  if kind == "strategy" then
    return "strategy"
  end
  if kind == "weekly-content" or kind == "weekly" then
    return "weekly-content"
  end
  if kind == "schedule-publish" or kind == "schedule" then
    return "schedule-publish"
  end
  return nil
end

local function normalize_mode(value)
  local mode = normalized_key(value or "shadow")
  if mode == "live" then
    return "live"
  end
  return "shadow"
end

function M.classify_issue(payload, opts)
  if type(payload) ~= "table" then
    return nil, "invalid payload"
  end
  if payload.schema ~= "github-proxy.v1" and payload.schema ~= "github-proxy.issue-observed.v1" then
    return nil, "unsupported schema"
  end
  if payload.type ~= "issue" then
    return nil, "not issue"
  end
  if not M.has_work_label(payload.labels) then
    return nil, "missing work label"
  end

  local fields = control_fields(payload, opts)
  local kind = normalize_kind(fields.type)
  if kind == nil then
    return nil, "missing type"
  end
  if fields.project == nil then
    return nil, "missing project"
  end

  local source_ref = source_ref_for(payload)
  if source_ref == nil then
    return nil, "missing source_ref"
  end

  local out = {
    kind = kind,
    project = safe_id(fields.project),
    account = safe_id(fields.account or "main"),
    week = fields.week,
    strategy_ref = fields["strategy-ref"],
    calendar_ref = fields["calendar-ref"],
    mode = normalize_mode(fields.mode or fields.channel),
    scheduled_at = fields["scheduled-at"],
    locale = fields.locale,
    owner = fields.owner,
    issue_number = payload.number,
    repo = payload.repo,
    source_ref = source_ref,
    trace_id = trace_id_for(source_ref),
  }
  out.dedup_key = dedup_key_for(kind, fields, payload, source_ref)

  if kind == "weekly-content" and out.week == nil then
    return nil, "missing week"
  end
  if kind == "schedule-publish" and (out.week == nil or out.calendar_ref == nil or out.scheduled_at == nil) then
    return nil, "missing schedule fields"
  end
  return out
end

function M.artifact_id(item)
  if item.kind == "strategy" then
    return "auto-twitter-marketing/" .. item.project .. "/strategy"
  end
  if item.kind == "weekly-content" then
    return "auto-twitter-marketing/" .. item.project .. "/" .. tostring(item.week) .. "/weekly-content"
  end
  return "auto-twitter-marketing/" .. item.project .. "/" .. tostring(item.week) .. "/schedule"
end

function M.strategy_imported(item)
  return {
    schema = "auto-twitter-marketing.strategy-imported.v1",
    artifact_id = M.artifact_id(item),
    project = item.project,
    account = item.account,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.weekly_content_imported(item)
  return {
    schema = "auto-twitter-marketing.weekly-content-imported.v1",
    artifact_id = M.artifact_id(item),
    project = item.project,
    week = item.week,
    strategy_ref = item.strategy_ref,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.live_gate(item, opts)
  opts = opts or {}
  return item ~= nil
    and item.mode == "live"
    and type(opts.nyxid_x_service) == "string"
    and opts.nyxid_x_service ~= ""
    and opts.live_write_enabled == true
end

function M.x_publish_request(item, opts)
  local live = M.live_gate(item, opts)
  local metadata = {
    campaign_id = item.project,
    content_type = "weekly-content",
    tag = "calendar:" .. tostring(item.calendar_ref),
    variant = live and "live" or "preview",
  }
  if item.locale ~= nil then
    metadata.locale = item.locale
  end
  if item.owner ~= nil then
    metadata.owner = item.owner
  end
  return {
    artifact_id = M.artifact_id(item),
    source_ref = copy_source_ref(item.source_ref),
    content_ref = item.calendar_ref,
    platform = "x",
    channel = live and "live" or "shadow",
    dedup_key = item.dedup_key .. "/x-publish",
    trace_id = item.trace_id,
    scheduled_at = item.scheduled_at,
    metadata = metadata,
  }
end

function M.status_comment(item, status)
  local body = "Auto Twitter marketing: " .. tostring(status) .. "\n\n"
    .. "source_ref: " .. tostring((item.source_ref or {}).ref) .. "\n"
    .. "dedup_key: " .. tostring(item.dedup_key)
  return {
    schema = "github-proxy.v1",
    repo = item.repo,
    issue_number = item.issue_number,
    body = body,
    dedup_key = item.dedup_key .. "/status/" .. safe_id(status),
    source_ref = copy_source_ref(item.source_ref),
  }
end

return M
