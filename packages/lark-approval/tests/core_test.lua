local core = require("core")
local t = fkst.test

return {
  test_persistence_class_is_stateless_adapter = function()
    t.eq(core.persistence_class(), "stateless_adapter")
  end,
  test_approve_tokens = function()
    t.eq(core.decision_from_reply("approve"), "approve")
    t.eq(core.decision_from_reply("  Approved "), "approve")
    t.eq(core.decision_from_reply("YES"), "approve")
  end,
  test_deny_tokens = function()
    t.eq(core.decision_from_reply("deny"), "deny")
    t.eq(core.decision_from_reply("reject"), "deny")
    t.eq(core.decision_from_reply("no"), "deny")
  end,
  test_fail_closed_pending = function()
    t.eq(core.decision_from_reply(""), "pending")
    t.eq(core.decision_from_reply("maybe"), "pending")
    t.eq(core.decision_from_reply(nil), "pending")
    t.eq(core.decision_from_reply("approve later"), "pending") -- ambiguous => pending
    t.eq(core.decision_from_reply("approve deny"), "pending")
  end,
  test_approval_request_accepts_safe_payload = function()
    local ok, why = core.validate_approval_request({
      approval_id = "approval-1",
      subject = { title = "Publish draft", kind = "x-post", locale = "en-US" },
      source_ref = { kind = "draft", ref = "ref-1" },
      trace_id = "trace-1",
      dedup_key = "dedup-1",
    })
    t.eq(ok, true)
    t.is_nil(why)
  end,
  test_approval_request_derives_id_from_artifact = function()
    local payload = {
      artifact_id = "artifact-1",
      source_ref = { ref = "ref-1" },
    }
    local ok = core.validate_approval_request(payload)
    t.eq(ok, true)
    t.eq(core.approval_id_for(payload), "approval:artifact-1")
  end,
  test_approval_request_rejects_missing_source_ref = function()
    local ok = core.validate_approval_request({ approval_id = "approval-1" })
    t.eq(ok, false)
  end,
  test_approval_request_rejects_message_body = function()
    local ok = core.validate_approval_request({
      approval_id = "approval-1",
      source_ref = { ref = "ref-1" },
      message = "Lark body must stay behind the seam",
    })
    t.eq(ok, false)
  end,
  test_approval_request_rejects_sensitive_fields = function()
    local ok = core.validate_approval_request({
      approval_id = "approval-1",
      source_ref = { ref = "ref-1" },
      lark_token = true,
    })
    t.eq(ok, false)
  end,
  test_pending_decision_shape = function()
    local decision = core.pending_decision({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "ref-1" },
      trace_id = "trace-1",
      dedup_key = "dedup-1",
    })
    t.eq(decision.approval_id, "approval:artifact-1")
    t.eq(decision.artifact_id, "artifact-1")
    t.eq(decision.decision, "pending")
    t.eq(decision.source_ref.ref, "ref-1")
    t.eq(decision.trace_id, "trace-1")
    t.eq(decision.dedup_key, "dedup-1")
  end,
}
