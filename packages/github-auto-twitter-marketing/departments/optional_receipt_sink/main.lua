local saga = require("workflow.saga")

local spec = {
  consumes = {
    "github-proxy.github_comment_written",
    "x-publisher.x_published",
    "lark-approval.approval_decided",
    "social-metrics.social_metric",
  },
  produces = {},
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event and event.payload or {}
  log.info("github-auto-twitter-marketing dept=optional_receipt_sink tag=ACK queue="
    .. tostring(event and event.queue)
    .. " artifact_id="
    .. tostring(payload.artifact_id or payload.metric_id or payload.decision_id or payload.comment_id))
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "optional_receipt_sink",
})
