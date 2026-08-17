local session_authority = require("session_authority")
local session_route = require("contract.session_route")
local strings = require("contract.strings")

local M = {}

local ACCOUNT_CONFIGURATION_REASONS = {
  ["conflicting-session-accounts"] = true,
  ["invalid-session-account"] = true,
  ["missing-session-account"] = true,
}

local function target(payload)
  local source_ref = type(payload) == "table" and payload.source_ref or nil
  local ref = type(source_ref) == "table" and (source_ref.ref or source_ref.reference) or nil
  local repo, raw_number
  if type(ref) == "string" then
    repo, raw_number = ref:match("^([^#]+)#issue/(%d+)$")
  end
  if repo == nil and type(payload) == "table" then
    repo = payload.repo
    raw_number = payload.number
    ref = tostring(repo or "") .. "#issue/" .. tostring(raw_number or "")
  end
  local number = tonumber(raw_number)
  if tostring(repo):match("^[%w_.-]+/[%w_.-]+$") == nil or number == nil or number < 1 then
    return nil
  end
  return repo, number, { kind = "external", ref = ref, reference = ref }
end

function M.comment(payload, issue, route_value, reason, declared_account)
  if not ACCOUNT_CONFIGURATION_REASONS[reason] then
    return nil
  end
  local route = session_authority.normalize_route(route_value)
  if route == nil or not session_route.has_label(issue and issue.labels, route.effective_work_label) then
    return nil
  end
  local assignee = session_route.single_assignee(issue.assignees)
  if not session_authority.login_matches(assignee, route.creator) then
    return nil
  end
  local repo, issue_number, source_ref = target(payload)
  if repo == nil then
    return nil
  end
  local account = session_route.normalize_account(declared_account) or "unbound"
  local safe_reason = strings.runtime_safe_segment(reason)
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
    body = table.concat({
      "Marketing radar v0.3.0: blocked/unrouted",
      "",
      "reason: " .. reason,
      "account: " .. account,
      "publish_attempted: false",
      "trace-id: github:marketing-radar:" .. source_ref.ref,
    }, "\n"),
    dedup_key = "marketing-radar/v2/ingress/" .. strings.runtime_safe_segment(source_ref.ref)
      .. "/blocked/" .. safe_reason,
    source_ref = source_ref,
  }
end

return M
