local strings = require("contract.strings")

local M = {}

local function valid_label(value)
  return type(value) == "string"
    and value ~= ""
    and value == strings.trim(value)
    and #value <= 80
    and value:find(",", 1, true) == nil
    and value:find("[%z\1-\31\127]") == nil
end

function M.normalize_account(value)
  local account = strings.trim(value):lower():gsub("^@", "")
  if #account < 1 or #account > 15 or account:match("^[a-z0-9_]+$") == nil then
    return nil
  end
  return account
end

function M.is_canonical_account(value)
  return type(value) == "string" and M.normalize_account(value) == value
end

function M.resolve(effective_label, map_json)
  if not valid_label(effective_label) then
    return nil, "invalid session work label"
  end
  local raw = strings.trim(map_json)
  if raw == "" then
    return {
      effective_label = effective_label,
      logical_label = effective_label,
    }, nil
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return nil, "work label map decoder unavailable"
  end
  local ok, mapping = pcall(json.decode, raw)
  if not ok or type(mapping) ~= "table" then
    return nil, "invalid session work label map"
  end
  local logical = nil
  for candidate, effective in pairs(mapping) do
    if not valid_label(candidate) or not valid_label(effective) then
      return nil, "invalid session work label map"
    end
    if effective == effective_label then
      if logical ~= nil and logical ~= candidate then
        return nil, "ambiguous session work label map"
      end
      logical = candidate
    end
  end
  if logical == nil then
    return nil, "session work label map mismatch"
  end
  return {
    effective_label = effective_label,
    logical_label = logical,
  }, nil
end

function M.has_label(labels, expected)
  if type(labels) ~= "table" or not valid_label(expected) then
    return false
  end
  for _, label in ipairs(labels) do
    local value = type(label) == "table" and (label.name or label.label) or label
    if value == expected then
      return true
    end
  end
  return false
end

function M.single_assignee(assignees)
  if type(assignees) ~= "table" or #assignees ~= 1 then
    return nil
  end
  local candidate = assignees[1]
  local login = type(candidate) == "table" and candidate.login or candidate
  login = strings.trim(login):lower()
  if login == "" or #login > 80 or login:match("^[%w%-%[%]_.]+$") == nil then
    return nil
  end
  return login
end

return M
