local testing = require("testkit.testing")
local t = fkst.test

local function pr_event()
  local reference = "owner/repo#pr/42"
  return {
    queue = "github-proxy.github_pr_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = "owner/repo",
      number = 42,
      title = "Unrelated pull request",
      state = "OPEN",
      updated_at = "2026-08-17T09:00:00Z",
      dedup_key = "owner/repo#pr#42@2026-08-17T09:00:00Z",
      source_ref = { kind = "external", ref = reference },
    },
    source_ref = { kind = "external", reference = reference },
  }
end

return {
  test_declares_only_namespaced_pr_changed_and_no_outputs = function()
    local sink = require("departments.optional_pr_event_sink.main")
    t.eq(#sink.spec.consumes, 1)
    t.eq(sink.spec.consumes[1], "github-proxy.github_pr_changed")
    t.eq(#sink.spec.produces, 0)
    t.eq(#sink.spec.fanout, 1)
    t.eq(sink.spec.fanout[1], "github-proxy.github_pr_changed")
  end,

  test_pr_snapshot_is_acked_without_commands_writes_or_raised_events = function()
    local before_commands = #t.command_calls()
    local result = testing.run_fake(require("departments.optional_pr_event_sink.main"), pr_event())
    t.eq(#result.raises, 0)
    t.eq(#result.writes, 0)
    t.eq(#t.command_calls(), before_commands)
  end,
}
