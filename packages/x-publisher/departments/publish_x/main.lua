-- x-publisher/publish_x - the X release seam. This package validates a small publish contract
-- and emits a preview receipt; the real post is supplied by a host-pinned egress skill.
local publish_caps = require("publish_x_caps")
local saga = require("workflow.saga")

local spec = {
  consumes = { "x_publish_request" },
  -- x_publish_request is the package's public entry point: a host composer produces it.
  published_seam = { "x_publish_request" },
  produces = { "x_published" },
  stall_window = "10m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local ok, why = publish_caps.validate_publish_request(payload)
  if not ok then
    log.warn("x-publisher dept=publish_x tag=SKIP why=" .. tostring(why))
    return
  end
  local receipt = publish_caps.preview_receipt(payload, "preview")
  log.info("x-publisher dept=publish_x tag=PREVIEW artifact_id=" .. tostring(payload.artifact_id)
    .. " source_ref=" .. tostring((payload.source_ref or {}).ref))
  raise("x_published", receipt)
end

local M = saga.department(spec, { done = done, act = act, name = "publish_x" })
M.pipeline = _G.pipeline
return M
