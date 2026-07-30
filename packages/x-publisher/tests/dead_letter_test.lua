local t = fkst.test

local function capture_logs(fn)
  local captured = {}
  local old_log = log
  log = {
    warn = function(message)
      table.insert(captured, tostring(message))
    end,
    info = function(message)
      table.insert(captured, tostring(message))
    end,
    error = function(message)
      table.insert(captured, tostring(message))
    end,
  }

  local ok, result = pcall(fn)
  log = old_log
  if not ok then
    error(result)
  end
  return captured
end

local function event(payload)
  return {
    queue = "dead_letter",
    payload = payload,
  }
end

local function dead_payload()
  return {
    delivery_id = "delivery/v1/raised/queue/x-publisher.x_publish_request/dept/x-publisher.publish_x/01HY",
    queue = "x-publisher.x_publish_request",
    dept = "x-publisher.publish_x",
    error_class = "publish-failed",
    source_ref = {
      kind = "external",
      ref = "owner/repo#issue/43",
    },
    dedup_key = "auto-twitter-marketing/chronoai/2026-W31/schedule/publish",
    attempt = 2,
    error = "publish failed\nwhile posting to X",
  }
end

return {
  test_dead_letter_delivery_logs_l2_triage_fact = function()
    local result = t.run_department("departments/dead_letter/main.lua", event(dead_payload()))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)

    local module = require("departments.dead_letter.main")
    local logs = capture_logs(function()
      module.pipeline(event(dead_payload()))
    end)

    t.eq(#logs, 1)
    t.is_true(logs[1]:find("x-publisher dept=dead_letter tag=DEAD_LETTER", 1, true) ~= nil)
    t.is_true(logs[1]:find("source_ref=external:owner/repo#issue/43", 1, true) ~= nil)
    t.is_true(logs[1]:find("dedup_key=auto-twitter-marketing/chronoai/2026-W31/schedule/publish", 1, true) ~= nil)
  end,
}
