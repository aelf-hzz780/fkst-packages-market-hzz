local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "telegram_command_receipt" },
  produces = { "github-proxy.github_issue_comment_request" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local comment, why = core.receipt_comment(event and event.payload or {})
  if comment == nil then
    log.warn("telegram-governance dept=receipt_sink tag=SKIP reason=" .. tostring(why))
    return
  end
  raise("github-proxy.github_issue_comment_request", comment)
end

return saga.department(spec, { done = done, act = act, name = "receipt_sink" })
