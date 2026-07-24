local core = require("core")
local t = fkst.test

return {
  test_persistence_class_is_stateless_adapter = function()
    t.eq(core.persistence_class(), "stateless_adapter")
  end,
  test_usable_request_accepts_complete_payload = function()
    local ok, why = core.is_usable_request({
      artifact_id = "cmp_1:twitter:3",
      source_ref = { kind = "draft", ref = "ref-1" },
      platform = "twitter",
      channel = "main",
      dedup_key = "dedup-1",
      trace_id = "trace-1",
      approval_id = "approval-1",
      scheduled_at = "2026-06-24T12:00:00Z",
      metadata = { campaign_id = "camp-1", locale = "en-US", variant = "a" },
    })
    t.eq(ok, true)
    t.is_nil(why)
  end,
  test_usable_request_accepts_event_reference_source_ref = function()
    local ok, why = core.is_usable_request({
      artifact_id = "cmp_1:twitter:3",
      source_ref = { kind = "external", reference = "owner/repo#issue/43" },
      platform = "x",
    })
    t.eq(ok, true)
    t.is_nil(why)
  end,
  test_usable_request_fails_closed_on_missing_artifact = function()
    local ok = core.is_usable_request({ source_ref = { ref = "ref-1" } })
    t.eq(ok, false)
  end,
  test_usable_request_fails_closed_on_missing_source_ref = function()
    local ok = core.is_usable_request({ artifact_id = "a" })
    t.eq(ok, false)
  end,
  test_usable_request_rejects_content_payload = function()
    local ok = core.is_usable_request({
      artifact_id = "a",
      source_ref = { ref = "ref-1" },
      text = "post body must stay behind source_ref",
    })
    t.eq(ok, false)
  end,
  test_usable_request_rejects_sensitive_fields = function()
    local ok = core.is_usable_request({
      artifact_id = "a",
      source_ref = { ref = "ref-1" },
      oauth_token = true,
    })
    t.eq(ok, false)
  end,
  test_preview_receipt_shape_is_safe = function()
    local receipt = core.preview_receipt({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "ref-1" },
      dedup_key = "dedup-1",
      trace_id = "trace-1",
      approval_id = "approval-1",
      metadata = { campaign_id = "camp-1" },
    })
    t.eq(receipt.artifact_id, "artifact-1")
    t.eq(receipt.platform, "x")
    t.eq(receipt.status, "preview")
    t.is_nil(receipt.post_uri)
    t.eq(receipt.source_ref.ref, "ref-1")
    t.eq(receipt.source_ref.reference, "ref-1")
    t.eq(receipt.dedup_key, "dedup-1")
    t.eq(receipt.trace_id, "trace-1")
    t.eq(receipt.approval_id, "approval-1")
    t.eq(receipt.metadata.campaign_id, "camp-1")
  end,
  test_skipped_receipt_shape = function()
    local receipt = core.preview_receipt({ artifact_id = "artifact-1" }, "skipped")
    t.eq(receipt.artifact_id, "artifact-1")
    t.eq(receipt.platform, "x")
    t.eq(receipt.status, "skipped")
    t.is_nil(receipt.post_uri)
  end,
}
