local graph = require("testkit.graph")
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
  test_pr_changed_routes_to_side_effect_free_sink_and_quiesces = function()
    local covers = {
      "github-proxy.github_pr_changed -> github-auto-twitter-marketing.optional_pr_event_sink",
    }
    local before_commands = #t.command_calls()
    local trace = graph.require_quiescent(graph.run(pr_event(), {
      covers = covers,
      max_steps = 2,
    }))
    graph.assert_covers(trace, covers)
    local delivery = graph.require_delivery(trace, {
      queue = "github-proxy.github_pr_changed",
      consumer = "github-auto-twitter-marketing.optional_pr_event_sink",
    })
    t.eq(delivery.exit_code, 0)
    t.eq(#delivery.raises, 0)
    t.eq(#t.command_calls(), before_commands)
  end,
}
