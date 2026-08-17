local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {
  CONTRACT = "auto-twitter-marketing.schedule-publish.v2",
}

local FIELDS = {
  account = "account",
  ["approval-id"] = "approval_id",
  contract = "contract",
  ["content-digest"] = "content_digest",
  ["content-ref"] = "content_ref",
  ["interval-minutes"] = "interval_minutes",
  mode = "mode",
  project = "project",
  recurrence = "recurrence",
  ["scheduled-at"] = "scheduled_at",
  time = "time",
  timezone = "timezone",
  type = "type",
  week = "week",
  ["work-label"] = "work_label",
}

local CANONICAL_FIELDS = {
  "contract",
  "type",
  "project",
  "account",
  "work_label",
  "week",
  "content_ref",
  "content_digest",
  "approval_id",
  "mode",
  "recurrence",
  "scheduled_at",
  "interval_minutes",
  "time",
  "timezone",
}

local function bounded(value, limit)
  return type(value) == "string"
    and value ~= ""
    and value == strings.trim(value)
    and #value <= limit
    and value:find("[%z\1-\31\127]") == nil
end

local function parse_positive_integer(value)
  if value == nil or value == "" then
    return nil
  end
  local number = tonumber(value)
  if number == nil or number < 1 or number > 1440 or number ~= math.floor(number) then
    return false
  end
  return number
end

local function append_canonical(parts, name, value)
  local text = tostring(value or "")
  parts[#parts + 1] = name
  parts[#parts + 1] = tostring(#text)
  parts[#parts + 1] = text
end

local function canonical_digest(fields)
  local parts = {}
  for _, name in ipairs(CANONICAL_FIELDS) do
    append_canonical(parts, name, fields[name])
  end
  return sha256.tagged(table.concat(parts, "\n"))
end

function M.parse(body)
  if type(body) ~= "string" or #body > 32000 then
    return nil, "invalid schedule body"
  end
  local fields = {}
  local in_fence = false
  local text = body:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"
  for line in text:gmatch("(.-)\n") do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      local key, value = line:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
      if key ~= nil then
        local normalized = key:lower():gsub("_", "-")
        local target = FIELDS[normalized]
        if target == nil then
          return nil, "unsupported schedule field"
        end
        if fields[target] ~= nil then
          return nil, "duplicate schedule field"
        end
        fields[target] = strings.trim(value)
      end
    end
  end
  if in_fence then
    return nil, "unterminated schedule fence"
  end

  local account = session_route.normalize_account(fields.account)
  if fields.contract ~= M.CONTRACT then
    return nil, "unsupported schedule contract"
  end
  if fields.type ~= "schedule-publish" and fields.type ~= "recurring-schedule-publish" then
    return nil, "invalid schedule type"
  end
  if account == nil or account ~= fields.account then
    return nil, "invalid schedule account"
  end
  if not bounded(fields.project, 120) or not bounded(fields.work_label, 80)
      or fields.week == nil or fields.week:match("^%d%d%d%d%-W%d%d$") == nil
      or not bounded(fields.content_ref, 512) or not sha256.is_tagged(fields.content_digest)
      or not bounded(fields.approval_id, 256) then
    return nil, "invalid schedule identity"
  end
  local mode = strings.trim(fields.mode):lower()
  if mode ~= "shadow" and mode ~= "live" then
    return nil, "invalid schedule mode"
  end
  local recurrence = strings.trim(fields.recurrence):lower()
  if fields.type == "schedule-publish" then
    if recurrence ~= "" or fields.interval_minutes ~= nil or fields.time ~= nil
        or fields.timezone ~= nil or not bounded(fields.scheduled_at, 128) then
      return nil, "invalid one-shot schedule"
    end
  elseif recurrence == "daily" then
    if fields.scheduled_at ~= nil or fields.interval_minutes ~= nil
        or not bounded(fields.time, 32) or not bounded(fields.timezone, 80) then
      return nil, "invalid daily schedule"
    end
  elseif recurrence == "every-minutes" then
    local interval = parse_positive_integer(fields.interval_minutes)
    if fields.time ~= nil or fields.timezone ~= nil or interval == nil or interval == false
        or not bounded(fields.scheduled_at, 128) then
      return nil, "invalid interval schedule"
    end
    fields.interval_minutes = interval
  else
    return nil, "unsupported recurrence"
  end
  fields.account = account
  fields.mode = mode
  fields.recurrence = recurrence ~= "" and recurrence or nil
  fields.schedule_digest = canonical_digest(fields)
  return fields, nil
end

function M.digest(body)
  local schedule, why = M.parse(body)
  if schedule == nil then
    return nil, why
  end
  return schedule.schedule_digest, nil
end

return M
