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
      content_ref = "#61",
      scheduled_at = "2026-07-31T09:55:00Z",
      tweet_text = "FKST receipt test: published text is visible on the schedule issue.",
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
    t.is_true(raised.payload.body:find("content_ref: #61", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("scheduled_at: 2026-07-31T09:55:00Z", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("tweet_text:", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("FKST receipt test: published text is visible", 1, true) ~= nil)
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
