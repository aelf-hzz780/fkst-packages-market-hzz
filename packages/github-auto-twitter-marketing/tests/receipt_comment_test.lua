local t = fkst.test

local scheduled_at = "2026-07-25T09:00:00Z"

local function one_shot_publish_key(number)
  return "auto-twitter-marketing/chronoai/2026-W31/schedule/owner/repo#issue/"
    .. tostring(number) .. "/2026-07-25T09-00-00Z/x-publish"
end

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

local function capture_logs(fn)
  local captured = {}
  local old_log = log
  log = {
    warn = function(message)
      table.insert(captured, tostring(message))
    end,
    info = function(message)
      table.insert(captured, tostring(message))
    end,
    error = function(message)
      table.insert(captured, tostring(message))
    end,
  }

  local ok, result = pcall(fn)
  log = old_log
  if not ok then
    error(result)
  end
  return captured
end

return {
  test_published_receipt_comments_back_to_schedule_issue = function()
    local result = run_receipt({
      schema = "x-publisher.x-published.v1",
      artifact_id = "auto-twitter-marketing/chronoai/2026-W31/schedule",
      status = "published",
      platform = "x",
      platform_post_id = "1234567890",
      post_uri = "https://x.com/i/web/status/1234567890",
      dedup_key = one_shot_publish_key(62),
      content_ref = "#61",
      channel = "live",
      trace_id = "trace-published-one-shot",
      scheduled_at = scheduled_at,
      metadata = { schedule_type = "one-shot" },
      source_ref = source_ref(62),
    })

    t.eq(#result.raises, 1)
    local raised = result.raises[1]
    t.eq(raised.queue, "github-proxy.github_issue_comment_request")
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.issue_number, 62)
    t.is_true(raised.payload.body:find("X published", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("https://x.com/i/web/status/1234567890", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("platform_post_id: 1234567890", 1, true) ~= nil)
    t.eq(raised.payload.handoff.schema, "auto-twitter-marketing.one-shot-close.v1")
    t.eq(raised.payload.handoff.kind, "published-one-shot")
    t.eq(raised.payload.handoff.status, "published")
    t.eq(raised.payload.handoff.schedule_type, "one-shot")
    t.eq(raised.payload.handoff.scheduled_at, scheduled_at)
    t.eq(raised.payload.handoff.artifact_id, "auto-twitter-marketing/chronoai/2026-W31/schedule")
    t.eq(raised.payload.handoff.content_ref, "#61")
    t.eq(raised.payload.handoff.channel, "live")
    t.eq(raised.payload.handoff.platform, "x")
    t.eq(raised.payload.handoff.platform_post_id, "1234567890")
    t.eq(raised.payload.handoff.post_uri, "https://x.com/i/web/status/1234567890")
    t.eq(raised.payload.handoff.source_ref.ref, "owner/repo#issue/62")
    t.eq(raised.payload.handoff.receipt_dedup_key, one_shot_publish_key(62))
    t.eq(raised.payload.handoff.comment_dedup_key, raised.payload.dedup_key)
    t.eq(raised.payload.handoff.trace_id, "trace-published-one-shot")
  end,

  test_receipt_handoff_requires_published_explicit_one_shot = function()
    for index, fixture in ipairs({
      { status = "blocked", schedule_type = "one-shot" },
      { status = "preview", schedule_type = "one-shot" },
      { status = "skipped", schedule_type = "one-shot" },
      { status = "published", schedule_type = "daily" },
      { status = "published", schedule_type = "every-minutes" },
      { status = "published", schedule_type = nil },
      { status = "published", schedule_type = "one-shot" },
    }) do
      local result = run_receipt({
        schema = "x-publisher.x-published.v1",
        artifact_id = "receipt-no-close-" .. tostring(index),
        status = fixture.status,
        post_uri = "https://x.com/i/web/status/" .. tostring(index),
        dedup_key = "receipt-no-close-" .. tostring(index) .. "/x-publish",
        metadata = { schedule_type = fixture.schedule_type },
        source_ref = source_ref(70 + index),
      })

      t.eq(#result.raises, 1)
      t.is_nil(result.raises[1].payload.handoff)
    end
  end,

  test_receipt_handoff_requires_canonical_x_post_evidence = function()
    local cases = {
      { platform = nil, platform_post_id = "123", post_uri = "https://x.com/i/web/status/123" },
      { platform = "twitter", platform_post_id = "123", post_uri = "https://x.com/i/web/status/123" },
      { platform = "x", platform_post_id = nil, post_uri = "https://x.com/i/web/status/123" },
      { platform = "x", platform_post_id = "abc", post_uri = "https://x.com/i/web/status/abc" },
      { platform = "x", platform_post_id = "123", post_uri = nil },
      { platform = "x", platform_post_id = "123", post_uri = "https://x.com/i/web/status/456" },
      { platform = "x", platform_post_id = "123", post_uri = "https://twitter.com/example/status/123" },
    }
    for index, evidence in ipairs(cases) do
      local result = run_receipt({
        schema = "x-publisher.x-published.v1",
        artifact_id = "auto-twitter-marketing/chronoai/2026-W31/schedule",
        status = "published",
        platform = evidence.platform,
        platform_post_id = evidence.platform_post_id,
        post_uri = evidence.post_uri,
        dedup_key = one_shot_publish_key(80 + index),
        content_ref = "#61",
        channel = "live",
        trace_id = "trace-invalid-post-evidence-" .. tostring(index),
        scheduled_at = scheduled_at,
        metadata = { schedule_type = "one-shot" },
        source_ref = source_ref(80 + index),
      })

      t.eq(#result.raises, 1)
      t.is_nil(result.raises[1].payload.handoff)
    end
  end,

  test_published_receipt_preserves_512_byte_dedup_key_for_replay = function()
    local ending = "/x-publish"
    local dedup_key = string.rep("k", 512 - #ending) .. ending
    local post_id = "2087115967956839247"
    local result = run_receipt({
      schema = "x-publisher.x-published.v1",
      artifact_id = "long-dedup-receipt",
      status = "published",
      post_uri = "https://x.com/i/web/status/" .. post_id,
      dedup_key = dedup_key,
      source_ref = source_ref(65),
    })

    t.eq(#result.raises, 1)
    local raised = result.raises[1]
    local comment_key = dedup_key .. "/status/x-publish-published"
    local marker = "<!-- fkst:github-proxy:comment:" .. comment_key .. " -->"
    t.eq(raised.payload.dedup_key, comment_key)
    t.is_true(raised.payload.body:find("dedup_key: " .. dedup_key .. "\n", 1, true) ~= nil)
    t.is_true(raised.payload.body:find(marker, 1, true) ~= nil)

  end,

  test_receipt_does_not_rewrite_invalid_dedup_key = function()
    local function raises_for(dedup_key)
      return run_receipt({
        schema = "x-publisher.x-published.v1",
        artifact_id = "invalid-dedup-receipt",
        status = "published",
        post_uri = "https://x.com/i/web/status/123",
        dedup_key = dedup_key,
        source_ref = source_ref(66),
      }).raises
    end

    for _, dedup_key in ipairs({
      42,
      "",
      " leading-space",
      "trailing-space ",
      "line\nbreak",
      "control\1byte",
      string.rep("x", 513),
    }) do
      t.eq(#raises_for(dedup_key), 0)
    end
  end,

  test_receipt_without_dedup_key_uses_artifact_fallback = function()
    for index, status in ipairs({ "blocked", "preview" }) do
      local artifact_id = "receipt-without-dedup-" .. tostring(index)
      local result = run_receipt({
        schema = "x-publisher.x-published.v1",
        artifact_id = artifact_id,
        status = status,
        source_ref = source_ref(66 + index),
      })

      t.eq(#result.raises, 1)
      local raised = result.raises[1]
      local comment_key = artifact_id .. "/status/x-publish-" .. status
      t.eq(raised.payload.dedup_key, comment_key)
      t.is_true(raised.payload.body:find("dedup_key: \n", 1, true) ~= nil)
      t.is_true(raised.payload.body:find(
        "<!-- fkst:github-proxy:comment:" .. comment_key .. " -->",
        1,
        true
      ) ~= nil)
    end
  end,

  test_invalid_dedup_key_is_skipped_with_safe_reason = function()
    local invalid_key = "secret\nkey"
    local event = {
      queue = "x-publisher.x_published",
      payload = {
        schema = "x-publisher.x-published.v1",
        artifact_id = "invalid-dedup-receipt",
        status = "published",
        dedup_key = invalid_key,
        source_ref = source_ref(66),
      },
    }
    local module = require("departments.optional_receipt_sink.main")
    local logs = capture_logs(function()
      module.pipeline(event)
    end)

    t.eq(#logs, 2)
    t.is_true(logs[2]:find("tag=SKIP why=invalid-dedup-key", 1, true) ~= nil)
    t.is_true(logs[2]:find(invalid_key, 1, true) == nil)
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

  test_receipt_sink_owns_only_x_published_input = function()
    local department = require("departments.optional_receipt_sink.main")
    t.eq(#department.spec.consumes, 1)
    t.eq(department.spec.consumes[1], "x-publisher.x_published")
  end,
}
