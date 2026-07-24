local t = fkst.test

return {
  test_metrics_poll_cron_shape = function()
    local raiser = require("raisers.metrics_poll")
    t.eq(raiser.type, "cron")
    t.eq(raiser.interval, "6h")
    t.eq(raiser.produces, "metrics_tick")
  end,

  test_fire_raiser_metrics_poll_routes_tick_to_collect = function()
    local trace = t.fire_raiser("metrics_poll")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "metrics_poll")
    t.eq(trace.routed_to[1], "collect")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 1)
    t.eq(trace.raised[1].queue, "social_metric")
    t.eq(trace.raised[1].payload.platform, "unknown")
    t.eq(trace.raised[1].payload.metric, "engagement")
    t.eq(trace.raised[1].payload.value, 0)
  end,
}
