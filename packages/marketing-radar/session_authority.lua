local forge_strings = require("forge.strings")
local session_route = require("contract.session_route")
local strings = require("contract.strings")

local M = {}

local function trim(value)
  return strings.trim(value or "")
end

function M.normalize_login(value)
  local login = forge_strings.strip_bot_login_suffix(trim(value):lower():gsub("^@", ""))
  if login == "" or #login > 80 or login:match("^[%w_.-]+$") == nil then
    return nil
  end
  return login
end

function M.normalize_route(value)
  if type(value) ~= "table" then
    return nil, "missing-session-authority"
  end
  local route = {
    effective_work_label = trim(value.effective_work_label or value.effective_label),
    logical_work_label = trim(value.logical_work_label or value.logical_label),
    creator = M.normalize_login(value.creator),
  }
  if route.effective_work_label == "" then
    return nil, "missing-effective-work-label"
  end
  if route.logical_work_label == "" then
    return nil, "missing-logical-work-label"
  end
  if route.creator == nil then
    return nil, "missing-session-creator"
  end
  return route, nil
end

function M.normalize(value)
  local authority, why = M.normalize_route(value)
  if authority == nil then
    return nil, why
  end
  authority.account = session_route.normalize_account(value.account)
  if authority.account == nil then
    return nil, "missing-session-account"
  end
  return authority, nil
end

function M.resolve_route(values)
  local env = values or {}
  local effective = trim(env.FKST_SESSION_WORK_LABEL)
  local route, why = session_route.resolve(effective, trim(env.FKST_SESSION_WORK_LABEL_MAP_JSON))
  if route == nil then
    local reasons = {
      ["invalid session work label"] = "invalid-session-work-label",
      ["work label map decoder unavailable"] = "work-label-map-decoder-unavailable",
      ["invalid session work label map"] = "invalid-session-work-label-map",
      ["ambiguous session work label map"] = "ambiguous-logical-work-label",
      ["session work label map mismatch"] = "session-work-label-map-mismatch",
    }
    return nil, reasons[why] or why
  end
  return M.normalize_route({
    effective_work_label = route.effective_label,
    logical_work_label = route.logical_label,
    creator = env.FKST_SESSION_CREATOR,
  })
end

function M.resolve(values)
  local env = values or {}
  local authority, route_why = M.resolve_route(env)
  if authority == nil then
    return nil, route_why
  end
  local primary_raw = trim(env.X_PUBLISH_EXPECTED_USERNAME)
  local fallback_raw = trim(env.FKST_X_PUBLISH_EXPECTED_USERNAME)
  local primary = primary_raw ~= "" and session_route.normalize_account(primary_raw) or nil
  local fallback = fallback_raw ~= "" and session_route.normalize_account(fallback_raw) or nil
  if primary_raw ~= "" and primary == nil or fallback_raw ~= "" and fallback == nil then
    return nil, "invalid-session-account"
  end
  if primary ~= nil and fallback ~= nil and primary ~= fallback then
    return nil, "conflicting-session-accounts"
  end
  authority.account = primary or fallback
  if authority.account == nil then
    return nil, "missing-session-account"
  end
  return authority, nil
end

function M.login_matches(left, right)
  local normalized_left = M.normalize_login(left)
  local normalized_right = M.normalize_login(right)
  return normalized_left ~= nil and normalized_left == normalized_right
end

function M.authorized(logins, login)
  local expected = M.normalize_login(login)
  if expected == nil then
    return false
  end
  for _, candidate in ipairs(logins or {}) do
    if M.normalize_login(candidate) == expected then
      return true
    end
  end
  return false
end

function M.login_set(logins)
  local out = {}
  for _, login in ipairs(logins or {}) do
    local normalized = M.normalize_login(login)
    if normalized ~= nil then
      out[normalized] = true
    end
  end
  return out
end

return M
