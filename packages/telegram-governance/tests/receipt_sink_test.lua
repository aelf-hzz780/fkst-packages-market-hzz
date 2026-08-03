local t = fkst.test

return {
  test_receipt_sink_raises_github_comment_request = function()
    local result = t.run_department("departments/receipt_sink/main.lua", {
      queue = "telegram_command_receipt",
      payload = {
        schema = "telegram-governance.command-receipt.v1",
        command_id = "11111111-1111-4111-8111-111111111111",
        action = "group.sync",
        status = "succeeded",
        risk_tier = "R0",
        idempotency_key = "telegram-governance/key-1",
        trace_id = "trace-1",
        source_ref = {
          kind = "external",
          ref = "owner/repo#issue/42",
          reference = "owner/repo#issue/42",
        },
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github-proxy.github_issue_comment_request")
    t.eq(result.raises[1].payload.issue_number, 42)
  end,

  test_receipt_sink_skips_invalid_receipt_without_throwing = function()
    local result = t.run_department("departments/receipt_sink/main.lua", {
      queue = "telegram_command_receipt",
      payload = { status = "succeeded" },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
