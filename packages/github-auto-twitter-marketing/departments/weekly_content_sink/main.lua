local saga = require("workflow.saga")
local content_close = require("content_close")

local spec = {
  consumes = { "weekly_content_imported" },
  produces = { "github-proxy.github_issue_comment_request" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event and event.payload or {}
  log.info("github-auto-twitter-marketing dept=weekly_content_sink tag=ACK artifact_id="
    .. tostring(payload.artifact_id))
  local request, why = content_close.comment_request(payload)
  if request == nil then
    log.warn("github-auto-twitter-marketing dept=weekly_content_sink tag=SKIP reason=" .. tostring(why))
    return
  end
  raise("github-proxy.github_issue_comment_request", request)
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "weekly_content_sink",
})
