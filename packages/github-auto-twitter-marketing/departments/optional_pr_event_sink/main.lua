local saga = require("workflow.saga")

local spec = {
  consumes = { "github-proxy.github_pr_changed" },
  produces = {},
  fanout = { "github-proxy.github_pr_changed" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event and event.payload or {}
  log.info("github-auto-twitter-marketing dept=optional_pr_event_sink tag=ACK queue="
    .. tostring(event and event.queue)
    .. " repo="
    .. tostring(payload.repo)
    .. " pr="
    .. tostring(payload.number))
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "optional_pr_event_sink",
})
