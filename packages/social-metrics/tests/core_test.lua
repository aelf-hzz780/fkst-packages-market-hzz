local core = require("core")
local t = fkst.test

return {
  test_persistence_class_is_stateless_adapter = function()
    t.eq(core.persistence_class(), "stateless_adapter")
  end,
  test_normalize_common_shape = function()
    local m = core.normalize("x", {
      post_uri = "https://x.com/p/1",
      metric = "likes",
      value = 42,
      artifact_id = "artifact-1",
      campaign_id = "campaign-1",
      observed_at = "2026-06-24T12:00:00Z",
      trace_id = "trace-1",
    })
    t.eq(m.platform, "x")
    t.eq(m.post_uri, "https://x.com/p/1")
    t.eq(m.metric, "likes")
    t.eq(m.value, 42)
    t.eq(m.artifact_id, "artifact-1")
    t.eq(m.campaign_id, "campaign-1")
    t.eq(m.observed_at, "2026-06-24T12:00:00Z")
    t.eq(m.trace_id, "trace-1")
  end,
  test_normalize_is_fail_closed = function()
    local m = core.normalize(nil, nil)
    t.eq(m.platform, "unknown")
    t.eq(m.post_uri, "unknown")
    t.eq(m.metric, "engagement")
    t.eq(m.value, 0)
  end,
  test_normalize_garbage_value_is_zero = function()
    t.eq(core.normalize("reddit", { value = "not-a-number" }).value, 0)
  end,
  test_normalize_negative_value_is_zero = function()
    t.eq(core.normalize("x", { value = -3 }).value, 0)
  end,
  test_normalize_standard_metric_aliases = function()
    t.eq(core.normalize("x", { metric = "retweets", value = 1 }).metric, "reposts")
    t.eq(core.normalize("x", { metric = "profile clicks", value = 1 }).metric, "profile_clicks")
    t.eq(core.normalize("x", { metric = "link-clicks", value = 1 }).metric, "url_clicks")
  end,
  test_normalize_unknown_metric_is_preserved = function()
    t.eq(core.normalize("x", { metric = "video_completions", value = 7 }).metric, "video_completions")
  end,
  test_preview_metric_shape_is_zero_value = function()
    local m = core.preview_metric({
      platform = "x",
      post_uri = "https://x.com/p/1",
      metric = "impressions",
      artifact_id = "artifact-1",
      campaign_id = "campaign-1",
      observed_at = "2026-06-24T12:00:00Z",
      trace_id = "trace-1",
    })
    t.eq(m.platform, "x")
    t.eq(m.post_uri, "https://x.com/p/1")
    t.eq(m.metric, "impressions")
    t.eq(m.value, 0)
    t.eq(m.artifact_id, "artifact-1")
    t.eq(m.campaign_id, "campaign-1")
    t.eq(m.observed_at, "2026-06-24T12:00:00Z")
    t.eq(m.trace_id, "trace-1")
  end,
}
