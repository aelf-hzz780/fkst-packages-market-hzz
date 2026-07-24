-- lark-approval/gate - the approval seam. Valid requests emit a fail-closed pending decision;
-- the real Lark card send and reply observation are supplied by a host-pinned egress skill.
local gate_caps = require("gate_caps")
local saga = require("workflow.saga")

local spec = {
  consumes = { "approval_request" },
  -- approval_request is the package's public entry point: a host composer produces it.
  published_seam = { "approval_request" },
  produces = { "approval_decided" },
  stall_window = "10m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local ok, why = gate_caps.validate_approval_request(payload)
  if not ok then
    log.warn("lark-approval dept=gate tag=SKIP why=" .. tostring(why))
    return
  end
  local decision = gate_caps.pending_decision(payload)
  log.info("lark-approval dept=gate tag=PREVIEW approval_id=" .. tostring(decision.approval_id)
    .. " decision=pending")
  raise("approval_decided", decision)
end

local M = saga.department(spec, { done = done, act = act, name = "gate" })
M.pipeline = _G.pipeline
return M
