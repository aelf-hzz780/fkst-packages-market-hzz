local control_fields = require("control_fields")
local proposal_identity = require("proposal_identity")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}

local ISSUE_CREATE_PREFIX = "<!-- fkst:github-proxy:issue-create:"
local COMMENT_PREFIX = "<!-- fkst:github-proxy:comment:"
local MARKER_SUFFIX = " -->"
local ISSUE_CREATE_INTENT = "/weekly-plan-change/create"
local ISSUE_CREATE_NAMESPACE = ISSUE_CREATE_INTENT .. "/"
local REVISION_INTENT = "/weekly-plan-change/revision"
local REVISION_NAMESPACE = REVISION_INTENT .. "/"
local GROUP_KEY_LIMIT = proposal_identity.GROUP_KEY_LIMIT
local MAX_PROPOSAL_REVISION = proposal_identity.MAX_REVISION

local function trim(value)
  return strings.trim(value or "")
end

local function marker_values(body, prefix, intent_path)
  local raw = tostring(body or "")
  local raw_prefix = raw:find(prefix, 1, true)
  local raw_intent = raw_prefix ~= nil
    and raw:find(intent_path, raw_prefix + #prefix, true) ~= nil
  local lines, lines_why = control_fields.unfenced_lines(body)
  if lines == nil then
    return nil, lines_why, raw_intent
  end
  local values = {}
  local outside_intent = false
  for _, raw_line in ipairs(lines) do
    local line = trim(raw_line)
    local at = line:find(prefix, 1, true)
    if at ~= nil then
      local relevant = line:find(intent_path, at + #prefix, true) ~= nil
      outside_intent = outside_intent or relevant
      if at ~= 1 or line:sub(-#MARKER_SUFFIX) ~= MARKER_SUFFIX then
        if relevant then
          return nil, "malformed-proxy-provenance-marker", true
        end
      else
        local value = line:sub(#prefix + 1, #line - #MARKER_SUFFIX)
        if value == "" or value:find('[%z\1-\31\127<>"]') ~= nil then
          if relevant then
            return nil, "malformed-proxy-provenance-marker", true
          end
        else
          values[#values + 1] = value
        end
      end
    end
  end
  return values, nil, outside_intent
end

function M.issue_create(body)
  local values, why, intent = marker_values(body, ISSUE_CREATE_PREFIX, ISSUE_CREATE_INTENT)
  if values == nil then
    return nil, intent and "proposal-create-provenance-invalid:" .. tostring(why)
      or "proposal-create-provenance-missing", intent
  end
  local create_values = {}
  for _, value in ipairs(values) do
    if value:find(ISSUE_CREATE_NAMESPACE, 1, true) ~= nil then
      create_values[#create_values + 1] = value
    end
  end
  if #create_values == 0 then
    return nil, "proposal-create-provenance-missing", intent
  end
  if #values ~= 1 or #create_values ~= 1 then
    return nil, "proposal-create-provenance-duplicate", true
  end
  local group_key, digits = create_values[1]:match("^(.-)/create/cycle%-(%d+)$")
  local cycle = tonumber(digits)
  if group_key == nil or group_key == "" or #group_key > GROUP_KEY_LIMIT
      or group_key:sub(-#"/weekly-plan-change") ~= "/weekly-plan-change"
      or cycle == nil or cycle < 1 or cycle % 1 ~= 0
      or #digits > 10 or cycle > 2147483647 or tostring(cycle) ~= digits then
    return nil, "proposal-create-provenance-invalid:invalid-cycle-marker", true
  end
  return { group_key = group_key, cycle = cycle }, nil, true
end

function M.revision_comment(body)
  local values, why, revision_intent = marker_values(body, COMMENT_PREFIX, REVISION_INTENT)
  if values == nil then
    return nil, revision_intent and "proposal-revision-provenance-invalid:" .. tostring(why) or nil,
      revision_intent
  end
  local revision_values = {}
  for _, value in ipairs(values) do
    if value:find(REVISION_NAMESPACE, 1, true) ~= nil then
      revision_values[#revision_values + 1] = value
    end
  end
  if #revision_values == 0 then
    return nil, nil, false
  end
  if #values ~= 1 or #revision_values ~= 1 then
    return nil, "proposal-revision-provenance-duplicate", true
  end
  local group_key, digits, signal_set_digest = revision_values[1]:match(
    "^(.-)/revision/(%d+)/(sha256:[0-9a-f]+)$")
  local revision = tonumber(digits)
  if group_key == nil or group_key == "" or #group_key > GROUP_KEY_LIMIT
      or group_key:sub(-#"/weekly-plan-change") ~= "/weekly-plan-change"
      or revision == nil or revision < 1 or revision % 1 ~= 0
      or #digits > 10 or revision > MAX_PROPOSAL_REVISION
      or tostring(revision) ~= digits or not sha256.is_tagged(signal_set_digest) then
    return nil, "proposal-revision-provenance-invalid:invalid-revision-marker", true
  end
  return {
    group_key = group_key,
    revision = revision,
    signal_set_digest = signal_set_digest,
  }, nil, true
end

return M
