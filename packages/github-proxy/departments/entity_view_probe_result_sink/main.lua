local saga = require("workflow.saga")

local spec = {
  consumes = { "entity_view_probe_result" },
  produces = {},
  ephemeral = { "entity_view_probe_result" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  log.info("github-proxy dept=entity_view_probe_result_sink tag=ACK queue="
    .. tostring(event and event.queue))
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "entity_view_probe_result_sink",
})
