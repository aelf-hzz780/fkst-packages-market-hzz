-- lark-approval/core.lua - pure approval contract helpers. No Lark message body or provider
-- response travels in payloads; the subject body is re-fetched from source_ref by the host seam.
local M = {}

local TOP_LEVEL_FIELDS = {
  approval_id = true,
  artifact_id = true,
  subject = true,
  source_ref = true,
  trace_id = true,
  dedup_key = true,
}

local SUBJECT_FIELDS = {
  title = true,
  summary = true,
  kind = true,
  locale = true,
}

local SOURCE_REF_FIELDS = {
  kind = true,
  ref = true,
  uri = true,
  version = true,
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

local BODY_FIELDS = {
  body = true,
  text = true,
  message = true,
  card = true,
  lark_body = true,
  raw_reply = true,
  raw = true,
  provider_response = true,
}

function M.persistence_class()
  return "stateless_adapter"
end

local function is_scalar(value)
  local value_type = type(value)
  return value_type == "string" or value_type == "number" or value_type == "boolean"
end

local function is_small_scalar(value)
  if not is_scalar(value) then
    return false
  end
  if type(value) == "string" and #value > 512 then
    return false
  end
  return true
end

local function has_denylisted_name(key)
  local normalized = tostring(key or ""):lower()
  if BODY_FIELDS[normalized] then
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
    if count > 12 then
      return false, label .. " too large"
    end
    if type(key) ~= "string" or not allowed_fields[key] then
      return false, "unsupported " .. label .. " field"
    end
    if has_denylisted_name(key) then
      return false, "unsafe " .. label .. " field"
    end
    if not is_small_scalar(item) then
      return false, "unsafe " .. label .. " value"
    end
  end
  return true, nil
end

local function copy_allowed_scalars(source, allowed_fields)
  local out = {}
  if type(source) ~= "table" then
    return out
  end
  for key, value in pairs(source) do
    if allowed_fields[key] and is_small_scalar(value) then
      out[key] = value
    end
  end
  return out
end

function M.approval_id_for(payload)
  if type(payload) ~= "table" then
    payload = {}
  end
  if type(payload.approval_id) == "string" and payload.approval_id ~= "" then
    return payload.approval_id
  end
  if type(payload.artifact_id) == "string" and payload.artifact_id ~= "" then
    return "approval:" .. payload.artifact_id
  end
  return nil
end

function M.validate_approval_request(payload)
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
  if not M.approval_id_for(payload) then
    return false, "missing approval_id"
  end
  if type(payload.source_ref) ~= "table" or type(payload.source_ref.ref) ~= "string"
      or payload.source_ref.ref == "" then
    return false, "missing source_ref"
  end
  local source_ok, source_why = validate_small_table(payload.source_ref, SOURCE_REF_FIELDS, "source_ref")
  if not source_ok then
    return false, source_why
  end
  if payload.subject ~= nil then
    local subject_ok, subject_why = validate_small_table(payload.subject, SUBJECT_FIELDS, "subject")
    if not subject_ok then
      return false, subject_why
    end
  end
  for _, field in ipairs({ "trace_id", "dedup_key" }) do
    if payload[field] ~= nil and not is_small_scalar(payload[field]) then
      return false, "invalid " .. field
    end
  end
  return true, nil
end

function M.pending_decision(payload)
  if type(payload) ~= "table" then
    payload = {}
  end
  return {
    approval_id = M.approval_id_for(payload),
    artifact_id = payload.artifact_id,
    decision = "pending",
    source_ref = copy_allowed_scalars(payload.source_ref, SOURCE_REF_FIELDS),
    trace_id = payload.trace_id,
    dedup_key = payload.dedup_key,
  }
end

-- Map a Lark reply token to a decision. Fail-closed: ONLY an exact, unambiguous "approve" or
-- "deny" counts; anything else (empty, unknown, mixed) stays "pending" - a missing or unclear
-- human reply is never an approval. Pure -> unit-tested.
function M.decision_from_reply(reply)
  local token = tostring(reply or ""):lower():match("^%s*(%a+)%s*$")
  if token == "approve" or token == "approved" or token == "yes" then
    return "approve"
  end
  if token == "deny" or token == "denied" or token == "reject" or token == "no" then
    return "deny"
  end
  return "pending"
end

return M
