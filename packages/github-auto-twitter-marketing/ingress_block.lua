local core = require("core")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}

local ROUTING_REASONS = {
  ["invalid payload"] = true,
  ["unsupported schema"] = true,
  ["not issue"] = true,
  ["missing session authority"] = true,
  ["missing session work label"] = true,
  ["session creator must be sole assignee"] = true,
  ["missing source_ref"] = true,
}

local SCHEDULE_TYPES = {
  ["schedule-publish"] = true,
  ["schedule"] = true,
  ["recurring-schedule-publish"] = true,
  ["daily-schedule-publish"] = true,
}

local function canonical_login(value)
  local login = strings.trim(value):lower()
  if login == "" then
    return nil
  end
  return login
end

local function routed_issue(options, authority)
  if not core.has_work_label(options.issue_labels, authority.effective_work_label) then
    return false
  end
  local assignee = session_route.single_assignee(options.issue_assignees)
  return canonical_login(assignee) == canonical_login(authority.creator)
end

local function open_issue(options)
  local state = strings.trim(options.issue_state):upper()
  return state == "OPEN"
end

local function schedule_body(options)
  local fields = core.parse_control_fields(options.issue_body)
  local issue_type = strings.trim(fields.type):lower():gsub("_", "-")
  return SCHEDULE_TYPES[issue_type] == true
end

local function safe_reason(why)
  local reason = strings.trim(why):gsub("[%z\1-\31\127]", " ")
  if reason == "" or #reason > 256 or ROUTING_REASONS[reason] then
    return nil
  end
  return reason
end

function M.comment(payload, opts, why)
  local options = type(opts) == "table" and opts or {}
  local authority = type(options.session) == "table" and options.session or nil
  local reason = safe_reason(why)
  if type(payload) ~= "table" or authority == nil or reason == nil
      or payload.type ~= "issue" or not open_issue(options)
      or not routed_issue(options, authority) or not schedule_body(options) then
    return nil
  end
  local account = session_route.normalize_account(authority.account)
  local work_label = strings.trim(authority.logical_work_label)
  local source_ref = core.canonical_issue_source_ref(payload)
  if account == nil or work_label == "" or #work_label > 80
      or work_label:find("[%z\1-\31\127]") ~= nil or source_ref == nil then
    return nil
  end

  local body = table.concat({
    "Auto Twitter marketing: schedule publish blocked at ingress",
    "",
    "reason: " .. reason,
    "expected_account: " .. account,
    "expected_work_label: " .. work_label,
    "source_ref: " .. source_ref.ref,
    "publish_attempted: false",
  }, "\n")
  local digest = sha256.hex(table.concat({
    account,
    work_label,
    source_ref.ref,
    reason,
  }, "\n"))
  return {
    schema = "github-proxy.v1",
    repo = payload.repo,
    issue_number = payload.number,
    body = body,
    dedup_key = "auto-twitter-marketing/" .. account .. "/schedule-ingress/" .. digest .. "/blocked",
    source_ref = source_ref,
  }
end

return M
