local core = require("core")
local t = fkst.test

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
    reference = "owner/repo#issue/42",
  }
end

return {
  test_receipt_comment_deduplicates_by_command_status_and_outcome = function()
    local comment = assert(core.receipt_comment({
      schema = "telegram-governance.command-receipt.v1",
      command_id = "11111111-1111-4111-8111-111111111111",
      operation = "group.sync",
      status = "succeeded",
      execution_outcome = "confirmed_effect",
      risk_tier = "R0",
      idempotency_key = "telegram-governance/key-1",
      trace_id = "trace-1",
      source_ref = source_ref(),
    }))

    t.eq(comment.repo, "owner/repo")
    t.eq(comment.issue_number, 42)
    t.eq(comment.dedup_key, "telegram-governance/receipt/11111111-1111-4111-8111-111111111111/succeeded/confirmed_effect")
    t.is_true(comment.body:find("status: succeeded", 1, true) ~= nil)
    t.is_true(comment.body:find("command_id: 11111111-1111-4111-8111-111111111111", 1, true) ~= nil)
  end,

  test_preview_receipt_deduplicates_by_idempotency_and_status = function()
    local comment = assert(core.receipt_comment({
      schema = "telegram-governance.command-receipt.v1",
      operation = "group.sync",
      status = "preview",
      execution_outcome = "not_attempted",
      risk_tier = "R0",
      idempotency_key = "telegram-governance/key-1",
      trace_id = "trace-1",
      source_ref = source_ref(),
    }))

    t.eq(comment.dedup_key, "telegram-governance/receipt/telegram-governance_key-1/preview/not_attempted")
  end,

  test_receipt_comment_never_includes_raw_provider_payload = function()
    local comment = assert(core.receipt_comment({
      schema = "telegram-governance.command-receipt.v1",
      operation = "moderation.message.execute",
      status = "failed",
      execution_outcome = "confirmed_no_effect",
      risk_tier = "R2",
      command_id = "11111111-1111-4111-8111-111111111111",
      idempotency_key = "telegram-governance/key-1",
      error_code = "permission_denied",
      error_message = "Permission denied\nAuthorization: must-not-leak",
      provider_response = "secret raw response",
      source_ref = source_ref(),
    }))

    t.is_true(comment.body:find("permission_denied", 1, true) ~= nil)
    t.is_true(comment.body:find("provider_response", 1, true) == nil)
    t.is_true(comment.body:find("secret raw response", 1, true) == nil)
    t.is_true(comment.body:find("Authorization", 1, true) == nil)
  end,

  test_receipt_comment_rejects_unknown_operation = function()
    local comment, why = core.receipt_comment({
      schema = "telegram-governance.command-receipt.v1",
      operation = "raw.telegram.rpc",
      status = "succeeded",
      execution_outcome = "confirmed_effect",
      risk_tier = "R2",
      command_id = "11111111-1111-4111-8111-111111111111",
      idempotency_key = "telegram-governance/key-1",
      trace_id = "trace-1",
      source_ref = source_ref(),
    })

    t.is_nil(comment)
    t.eq(why, "invalid Telegram governance operation")
  end,
}
