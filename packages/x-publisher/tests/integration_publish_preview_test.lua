local t = fkst.test

local function event(payload)
  return {
    queue = "x_publish_request",
    payload = payload,
  }
end

local function run_publish(payload)
  return t.run_department("departments/publish_x/main.lua", event(payload), {
    env = {
      FKST_RUNTIME_ROOT = "/tmp/fkst-marketing-test/x-publisher/preview",
      FKST_DURABLE_ROOT = "/tmp/fkst-marketing-test/x-publisher/durable",
    },
  })
end

return {
  test_publish_request_raises_preview_receipt = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "drafts/artifact-1" },
      platform = "x",
      channel = "main",
      dedup_key = "dedup-1",
      trace_id = "trace-1",
      approval_id = "approval-1",
      scheduled_at = "2026-06-24T12:00:00Z",
      metadata = { campaign_id = "campaign-1", locale = "en-US", variant = "a" },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)

    local raised = result.raises[1]
    t.eq(raised.queue, "x_published")
    t.eq(raised.payload.artifact_id, "artifact-1")
    t.eq(raised.payload.platform, "x")
    t.eq(raised.payload.status, "preview")
    t.is_nil(raised.payload.post_uri)
    t.eq(raised.payload.source_ref.ref, "drafts/artifact-1")
    t.eq(raised.payload.dedup_key, "dedup-1")
    t.eq(raised.payload.trace_id, "trace-1")
    t.eq(raised.payload.approval_id, "approval-1")
    t.eq(raised.payload.metadata.campaign_id, "campaign-1")
  end,

  test_publish_request_skips_invalid_content_payload = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "drafts/artifact-1" },
      text = "content must stay behind source_ref",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
