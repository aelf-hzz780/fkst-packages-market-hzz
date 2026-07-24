-- social-metrics/collect - the metrics read seam. It emits zero-value preview metrics until a
-- host-pinned egress skill supplies real platform observations.
local collect_caps = require("collect_caps")
local saga = require("workflow.saga")

local spec = {
  consumes = { "metrics_request", "metrics_tick" },
  -- metrics_request is the package's public entry point (a host composer produces it);
  -- metrics_tick is produced internally by the metrics_poll raiser, so it is not a seam.
  published_seam = { "metrics_request" },
  produces = { "social_metric" },
  stall_window = "15m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local metric = collect_caps.preview_metric(payload)
  log.info("social-metrics dept=collect tag=PREVIEW platform=" .. metric.platform
    .. " post_uri=" .. metric.post_uri .. " value=" .. tostring(metric.value))
  raise("social_metric", metric)
end

local M = saga.department(spec, { done = done, act = act, name = "collect" })
M.pipeline = _G.pipeline
return M
