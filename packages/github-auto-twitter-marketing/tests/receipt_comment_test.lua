local t = fkst.test

local function source_ref(number)
  local ref = "owner/repo#issue/" .. tostring(number)
  return {
    kind = "external",
    ref = ref,
    reference = ref,
  }
end

local function run_receipt(payload)
  return t.run_department("departments/optional_receipt_sink/main.lua", {
    queue = "x-publisher.x_published",
    payload = payload,
    source_ref = payload.source_ref,
  })
end

return {
  test_published_receipt_comments_back_to_schedule_issue = function()
    local result = run_receipt({
      schema = "x-publisher.x-published.v1",
      artifact_id = "auto-twitter-marketing/chronoai/2026-W31/schedule",
      status = "published",
      post_uri = "https://x.com/i/web/status/1234567890",
      dedup_key = "auto-twitter-marketing/chronoai/2026-W31/schedule/x-publish",
      source_ref = source_ref(62),
    })

    t.eq(#result.raises, 1)
    local raised = result.raises[1]
    t.eq(raised.queue, "github-proxy.github_issue_comment_request")
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.issue_number, 62)
    t.is_true(raised.payload.body:find("X published", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("https://x.com/i/web/status/1234567890", 1, true) ~= nil)
  end,

  test_blocked_receipt_comments_reason_without_provider_payload = function()
    local result = run_receipt({
      schema = "x-publisher.x-published.v1",
      artifact_id = "auto-twitter-marketing/chronoai/2026-W31/schedule",
      status = "blocked",
      blocked_reason = "unexpected account",
      dedup_key = "auto-twitter-marketing/chronoai/2026-W31/schedule/x-publish",
      source_ref = source_ref(63),
    })

    t.eq(#result.raises, 1)
    local raised = result.raises[1]
    t.eq(raised.queue, "github-proxy.github_issue_comment_request")
    t.eq(raised.payload.issue_number, 63)
    t.is_true(raised.payload.body:find("X publish blocked", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("unexpected account", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("provider_response", 1, true) == nil)
  end,

  test_quote_receipt_comment_displays_mode_and_target = function()
    local result = run_receipt({
      schema = "x-publisher.x-published.v1",
      artifact_id = "auto-twitter-marketing/chronoai/2026-W32/schedule",
      status = "published",
      operation = "quote",
      quote_mode = "native",
      quote_target_uri = "https://x.com/example/status/123",
      quote_target_post_id = "123",
      post_uri = "https://x.com/i/web/status/456",
      dedup_key = "auto-twitter-marketing/chronoai/2026-W32/schedule/x-publish",
      source_ref = source_ref(64),
    })

    t.eq(#result.raises, 1)
    local body = result.raises[1].payload.body
    t.is_true(body:find("operation: quote", 1, true) ~= nil)
    t.is_true(body:find("quote_mode: native", 1, true) ~= nil)
    t.is_true(body:find("quote_target_uri: https://x.com/example/status/123", 1, true) ~= nil)
    t.is_true(body:find("quote_target_post_id: 123", 1, true) ~= nil)
  end,

  test_comment_written_receipts_do_not_loop = function()
    local result = t.run_department("departments/optional_receipt_sink/main.lua", {
      queue = "github-proxy.github_comment_written",
      payload = {
        schema = "github-proxy.comment-written.v1",
        comment_id = "comment-1",
      },
    })

    t.eq(#result.raises, 0)
  end,
}
