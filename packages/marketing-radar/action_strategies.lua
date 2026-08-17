-- Explicit signal actions own their impact scope; generated drafts cannot widen it.
local strings = require("contract.strings")

local M = {}

local function add(target_ref)
  if strings.trim(target_ref) ~= "" then
    return nil, "add-forbids-target-ref"
  end
  return { action = "add", change_scope = "append", supersede_mode = "none" }
end

local function revise(target_ref)
  local target = strings.trim(target_ref)
  if target == "" then
    return nil, "revise-requires-target-ref"
  end
  return {
    action = "revise",
    target_ref = target,
    change_scope = "target-only",
    supersede_mode = "target-unpublished",
  }
end

local function replan(target_ref)
  if strings.trim(target_ref) ~= "" then
    return nil, "replan-forbids-target-ref"
  end
  return {
    action = "replan",
    change_scope = "week-unpublished",
    supersede_mode = "all-unpublished",
  }
end

local HANDLERS = {
  add = add,
  revise = revise,
  replan = replan,
}

function M.evaluate(action, target_ref)
  local normalized = strings.trim(action):lower()
  local handler = HANDLERS[normalized]
  if handler == nil then
    return nil, "invalid-action"
  end
  return handler(target_ref)
end

return M
