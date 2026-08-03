local graph = require("testkit.graph")
local t = fkst.test

local repo = "owner/repo"

local function ref()
  return {
    kind = "external",
    ref = repo .. "#issue/42",
    reference = repo .. "#issue/42",
  }
end

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  return text
end

local function mock_env()
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_DEVLOOP_MANAGED_BOT_LOGINS"', { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_AUTHORIZED_LOGINS"', { stdout = "alice", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$TELEGRAM_GOVERNANCE_TRUSTED_AUTHOR_LOGINS"', { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$TELEGRAM_GOVERNANCE_APPROVER_LOGINS"', { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
  end
end

local function mock_issue(body)
  local stdout = string.format(
    '{"number":42,"title":"Telegram governance","body":"%s","html_url":"https://github.com/%s/issues/42","updated_at":"2026-08-03T01:00:00Z","state":"open","labels":[{"name":"telegram-governance"}],"assignees":[],"user":{"login":"alice"}}',
    json_escape(body),
    repo
  )
  t.mock_command("gh api repos/" .. repo .. "/issues/42", { stdout = stdout, stderr = "", exit_code = 0 })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/42/comments?per_page=100'", {
    stdout = "[]",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_preview_issue_flows_through_pointer_seam_to_receipt_comment_without_nyxid = function()
    mock_env()
    mock_issue('{"mode":"preview","command":{"action":"group.sync","target":{"group_id":-1001},"parameters":{}}}')
    local event_ref = ref()
    local trace = graph.require_quiescent(graph.run({
      queue = "github-proxy.github_issue_changed",
      payload = {
        schema = "github-proxy.v1",
        type = "issue",
        repo = repo,
        number = 42,
        labels = { "telegram-governance" },
        updated_at = "2026-08-03T01:00:00Z",
        source_ref = event_ref,
        dedup_key = "github/changed/42",
      },
      source_ref = event_ref,
    }, { max_steps = 10 }))

    graph.assert_covers(trace, {
      "github-proxy.github_issue_changed -> telegram-governance.github_command_intake",
      "telegram-governance.telegram_command_request -> telegram-governance.execute_command",
      "telegram-governance.telegram_command_receipt -> telegram-governance.receipt_sink",
    })
    local request = graph.require_raise(trace, "telegram-governance.telegram_command_request")
    t.is_nil(request.payload.body)
    t.is_nil(request.payload.labels)
    local receipt = graph.require_raise(trace, "telegram-governance.telegram_command_receipt")
    t.eq(receipt.payload.status, "preview")
    local comment = graph.require_raise(trace, "github-proxy.github_issue_comment_request")
    t.eq(comment.payload.issue_number, 42)

    local nyxid_calls = 0
    for _, call in ipairs(t.command_calls()) do
      local rendered = tostring(call.rendered or call.command or call.cmd or "")
      if rendered:find("nyxid", 1, true) then
        nyxid_calls = nyxid_calls + 1
      end
    end
    t.eq(nyxid_calls, 0)
  end,
}
