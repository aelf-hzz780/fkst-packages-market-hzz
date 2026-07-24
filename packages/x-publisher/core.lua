-- x-publisher/core.lua - pure, side-effect-free publish contract helpers. Payloads carry only
-- small control fields and a source_ref pointer; post content is re-fetched by the host seam.
local M = {}

local TOP_LEVEL_FIELDS = {
  artifact_id = true,
  source_ref = true,
  platform = true,
  channel = true,
  dedup_key = true,
  trace_id = true,
  approval_id = true,
  scheduled_at = true,
  metadata = true,
}

local SENSITIVE_PATTERNS = {
  "token",
  "bearer",
  "oauth",
  "secret",
  "credential",
  "password",
  "api_key",
  "apikey",
  "authorization",
  "provider_response",
  "raw_response",
}

local CONTENT_FIELDS = {
  tweet = true,
  body = true,
  text = true,
  message = true,
  media_bytes = true,
  media = true,
  raw = true,
  raw_provider_response = true,
  provider_raw_response = true,
  provider_response = true,
}

local SOURCE_REF_FIELDS = {
  kind = true,
  ref = true,
  reference = true,
  uri = true,
  version = true,
}

local METADATA_FIELDS = {
  campaign_id = true,
  content_type = true,
  locale = true,
  owner = true,
  tag = true,
  variant = true,
}

local SCALAR_TYPES = {
  boolean = true,
  number = true,
  string = true,
}

function M.persistence_class()
  return "stateless_adapter"
end

local function is_scalar(value)
  return SCALAR_TYPES[type(value)] == true
end

local function is_small_scalar(value)
  local value_type = type(value)
  if not SCALAR_TYPES[value_type] then
    return false
  end
  if value_type == "string" and #value > 512 then
    return false
  end
  return true
end

local function has_denylisted_name(key)
  local normalized = tostring(key or ""):lower()
  if CONTENT_FIELDS[normalized] then
    return true
  end
  for _, pattern in ipairs(SENSITIVE_PATTERNS) do
    if normalized:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function validate_small_table(value, allowed_fields, label)
  if type(value) ~= "table" then
    return false, "invalid " .. label
  end
  local count = 0
  for key, item in pairs(value) do
    count = count + 1
    local key_type = type(key)
    if key_type ~= "string" or allowed_fields[key] ~= true then
      return false, "unsupported " .. label .. " field"
    end
    if has_denylisted_name(key) then
      return false, "unsafe " .. label .. " field"
    end
    if not is_small_scalar(item) then
      return false, "unsafe " .. label .. " value"
    end
    if count > 12 then
      return false, label .. " too large"
    end
  end
  return true, nil
end

local function copy_allowed_scalars(source, allowed_fields)
  local safe = {}
  if type(source) ~= "table" then
    return safe
  end
  for key, value in pairs(source) do
    local allowed = allowed_fields[key] == true
    if allowed and is_small_scalar(value) then
      safe[key] = value
    end
  end
  return safe
end

local function source_ref_reference(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  local reference = source_ref.ref or source_ref.reference
  if type(reference) ~= "string" or reference == "" then
    return nil
  end
  return reference
end

local function normalized_platform(platform)
  if platform == nil or platform == "" then
    return "x"
  end
  local value = tostring(platform):lower()
  if value == "x" or value == "twitter" then
    return "x"
  end
  return nil
end

-- A publish request is usable only if it carries an artifact_id and a safe source_ref pointer.
-- Fail-closed: unsupported fields, content fields, or sensitive field names are rejected.
function M.validate_publish_request(payload)
  payload = payload or {}
  if type(payload) ~= "table" then
    return false, "invalid payload"
  end
  for key, _ in pairs(payload) do
    if type(key) ~= "string" or not TOP_LEVEL_FIELDS[key] then
      return false, "unsupported field"
    end
    if has_denylisted_name(key) then
      return false, "unsafe field"
    end
  end
  if type(payload.artifact_id) ~= "string" or payload.artifact_id == "" then
    return false, "missing artifact_id"
  end
  if source_ref_reference(payload.source_ref) == nil then
    return false, "missing source_ref"
  end
  local platform = normalized_platform(payload.platform)
  if not platform then
    return false, "unsupported platform"
  end
  local source_ok, source_why = validate_small_table(payload.source_ref, SOURCE_REF_FIELDS, "source_ref")
  if not source_ok then
    return false, source_why
  end
  if payload.metadata ~= nil then
    local metadata_ok, metadata_why = validate_small_table(payload.metadata, METADATA_FIELDS, "metadata")
    if not metadata_ok then
      return false, metadata_why
    end
  end
  for _, field in ipairs({ "channel", "dedup_key", "trace_id", "approval_id", "scheduled_at" }) do
    if payload[field] ~= nil and not is_small_scalar(payload[field]) then
      return false, "invalid " .. field
    end
  end
  return true, nil
end

function M.is_usable_request(payload)
  return M.validate_publish_request(payload)
end

function M.preview_receipt(payload, status)
  if type(payload) ~= "table" then
    payload = {}
  end
  local source_ref = copy_allowed_scalars(payload.source_ref, SOURCE_REF_FIELDS)
  if source_ref.ref == nil and source_ref.reference ~= nil then
    source_ref.ref = source_ref.reference
  end
  if source_ref.reference == nil and source_ref.ref ~= nil then
    source_ref.reference = source_ref.ref
  end
  return {
    artifact_id = payload.artifact_id,
    platform = "x",
    status = status or "preview",
    post_uri = nil,
    source_ref = source_ref,
    channel = payload.channel,
    dedup_key = payload.dedup_key,
    trace_id = payload.trace_id,
    approval_id = payload.approval_id,
    scheduled_at = payload.scheduled_at,
    metadata = copy_allowed_scalars(payload.metadata, METADATA_FIELDS),
  }
end

return M
