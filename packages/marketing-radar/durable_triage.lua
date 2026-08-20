local session_authority = require("session_authority")
local sha256 = require("contract.sha256")
local status_contract = require("status_contract")

local M = {}

local FAILURES = {
  { reason = "semantic-conflict" },
  { reason = "draft-correction-exhausted" },
}

local function source_ref(value)
  local ref = type(value) == "table" and value.source_ref or nil
  if type(ref) ~= "table" or type(ref.ref) ~= "string" or ref.ref == "" then
    return nil
  end
  return ref.ref
end

local function failure_for(reason)
  local value = status_contract.canonical_line(reason)
  for _, failure in ipairs(FAILURES) do
    if value:sub(1, #failure.reason + 1) == failure.reason .. ":"
        and #value > #failure.reason + 1 then
      return failure
    end
  end
  return nil
end

local function canonical_failure_reason(reason)
  local value = status_contract.canonical_line(reason)
  return failure_for(value) and value or nil
end

local function marker_keys(body)
  local keys = {}
  for key in tostring(body or ""):gmatch(
      "<!%-%- fkst:github%-proxy:comment:([%w%._%-%/#]+) %-%->") do
    keys[#keys + 1] = key
  end
  return keys
end

local function identity_values(identity)
  if type(identity) ~= "table" or type(identity.group_key) ~= "string"
      or identity.group_key == "" or #identity.group_key > 2048
      or not sha256.is_tagged(identity.signal_set_digest)
      or type(identity.first) ~= "table" then
    return nil, "invalid-signal-set-identity"
  end
  local anchor_ref = source_ref(identity.first)
  if anchor_ref == nil then
    return nil, "invalid-signal-set-anchor"
  end
  return {
    anchor = identity.first,
    anchor_ref = anchor_ref,
    group_hash = sha256.hex(identity.group_key),
    set_hash = identity.signal_set_digest:sub(8),
  }, nil
end

local function member(identity, signal)
  if type(signal) ~= "table" then
    return nil
  end
  local target_ref = source_ref(signal)
  if target_ref == nil or not sha256.is_tagged(signal.signal_digest) then
    return nil
  end
  for _, candidate in ipairs(identity.signals or {}) do
    if source_ref(candidate) == target_ref and candidate.signal_digest == signal.signal_digest then
      return target_ref
    end
  end
  return nil
end

local function marker_root(identity, signal)
  local values, why = identity_values(identity)
  if values == nil then
    return nil, why
  end
  local target_ref = member(identity, signal)
  if target_ref == nil then
    return nil, "signal-not-in-current-set"
  end
  return table.concat({
    "marketing-radar/v2/triage",
    "group-" .. values.group_hash,
    "set-" .. values.set_hash,
    "anchor-" .. sha256.hex(values.anchor_ref),
    "target-" .. sha256.hex(target_ref),
  }, "/"), nil
end

local function matching_failure(issue, signal, identity, bot_login, expected_reason)
  if type(issue) ~= "table" or session_authority.normalize_login(bot_login) == nil then
    return nil
  end
  if source_ref(issue) ~= source_ref(signal) then
    return nil
  end
  local root = marker_root(identity, signal)
  if root == nil then
    return nil
  end
  for _, comment in ipairs(issue.comments or {}) do
    if type(comment) == "table"
        and session_authority.login_matches(comment.author_login, bot_login) then
      local body = tostring(comment.body or "")
      local keys = marker_keys(body)
      if #keys == 1 then
        local status = status_contract.status_from_body(body)
        local prefix = "needs-triage: "
        local reason = status and status:sub(1, #prefix) == prefix
          and canonical_failure_reason(status:sub(#prefix + 1)) or nil
        local expected = status and root .. "/status/" .. status_contract.segment(status) or nil
        if reason ~= nil and (expected_reason == nil or reason == expected_reason)
            and keys[1] == expected then
          return reason
        end
      end
    end
  end
  return nil
end

function M.anchor(identity)
  local values, why = identity_values(identity)
  return values and values.anchor or nil, why
end

function M.status_item(signal, identity)
  local root, why = marker_root(identity, signal)
  if root == nil then
    return nil, why
  end
  local item = {}
  for key, value in pairs(signal) do
    item[key] = value
  end
  item.dedup_key = root
  return item, nil
end

function M.persisted_failure(issue, identity, bot_login)
  local anchor, why = M.anchor(identity)
  if anchor == nil then
    return nil, why
  end
  if type(issue) ~= "table" or source_ref(issue) ~= source_ref(anchor) then
    return nil, "durable-triage-anchor-mismatch"
  end
  return matching_failure(issue, anchor, identity, bot_login), nil
end

function M.failure_reason(reason)
  return canonical_failure_reason(reason)
end

function M.has_failure(issue, signal, identity, reason, bot_login)
  local expected_reason = canonical_failure_reason(reason)
  if expected_reason == nil then
    return false
  end
  return matching_failure(issue, signal, identity, bot_login, expected_reason) ~= nil
end

return M
