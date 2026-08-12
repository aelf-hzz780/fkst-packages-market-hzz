local core = require("core")
local t = fkst.test

return {
  test_persistence_class_is_saga = function()
    t.eq(core.persistence_class(), "saga")
    t.eq(#core.saga_conformance_errors(), 0)
  end,
  test_usable_request_accepts_complete_payload = function()
    local ok, why = core.is_usable_request({
      artifact_id = "cmp_1:twitter:3",
      source_ref = { kind = "draft", ref = "ref-1" },
      content_ref = "#42",
      platform = "twitter",
      channel = "main",
      dedup_key = "dedup-1",
      trace_id = "trace-1",
      approval_id = "approval-1",
      scheduled_at = "2026-06-24T12:00:00Z",
      metadata = {
        campaign_id = "camp-1",
        interval_minutes = 10,
        locale = "en-US",
        occurrence_id = "2026-07-28T11:10:00+08:00",
        schedule_type = "daily",
        variant = "a",
      },
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
  test_usable_request_defaults_empty_platform_to_x = function()
    local ok, why = core.is_usable_request({
      artifact_id = "cmp_1:twitter:3",
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
      platform = "",
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
  test_usable_request_rejects_invalid_payload_and_nested_control_fields = function()
    local ok, why

    ok, why = core.validate_publish_request("bad")
    t.eq(ok, false)
    t.eq(why, "invalid payload")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43" },
      platform = "mastodon",
    })
    t.eq(ok, false)
    t.eq(why, "unsupported platform")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43", unsupported = "x" },
    })
    t.eq(ok, false)
    t.eq(why, "unsupported source_ref field")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43", uri = {} },
    })
    t.eq(ok, false)
    t.eq(why, "unsafe source_ref value")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43" },
      metadata = "bad",
    })
    t.eq(ok, false)
    t.eq(why, "invalid metadata")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43" },
      metadata = { extra = "bad" },
    })
    t.eq(ok, false)
    t.eq(why, "unsupported metadata field")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43" },
      metadata = { campaign_id = string.rep("x", 513) },
    })
    t.eq(ok, false)
    t.eq(why, "unsafe metadata value")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43" },
      channel = {},
    })
    t.eq(ok, false)
    t.eq(why, "invalid channel")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43" },
      content_ref = {},
    })
    t.eq(ok, false)
    t.eq(why, "invalid content_ref")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "" },
    })
    t.eq(ok, false)
    t.eq(why, "missing source_ref")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43" },
      scheduled_at = {},
    })
    t.eq(ok, false)
    t.eq(why, "invalid scheduled_at")
    ok, why = core.validate_publish_request({
      artifact_id = "artifact-1",
      source_ref = { [1] = "owner/repo#issue/43" },
    })
    t.eq(ok, false)
    t.eq(why, "missing source_ref")
  end,
  test_usable_request_rejects_noncanonical_dedup_keys = function()
    local base = {
      artifact_id = "artifact-1",
      source_ref = { ref = "owner/repo#issue/43" },
    }
    for _, dedup_key in ipairs({
      42,
      "",
      " leading-space",
      "trailing-space ",
      "line\nbreak",
      "carriage\rreturn",
      "control\1byte",
      string.rep("x", 513),
    }) do
      base.dedup_key = dedup_key
      local ok, why = core.validate_publish_request(base)
      t.eq(ok, false)
      t.eq(why, "invalid dedup_key")
    end

    base.dedup_key = string.rep("x", 512)
    t.eq(core.validate_publish_request(base), true)
  end,
  test_preview_receipt_shape_is_safe = function()
    local receipt = core.preview_receipt({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "ref-1" },
      content_ref = "#42",
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
    t.eq(receipt.content_ref, "#42")
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
  test_preview_receipt_normalizes_reference_source_ref_and_bad_payload = function()
    local fallback = core.preview_receipt("bad")
    local receipt = core.preview_receipt({
      artifact_id = "artifact-1",
      source_ref = {
        reference = "owner/repo#issue/43",
        uri = string.rep("x", 513),
      },
      metadata = {
        owner = "content-owner",
        raw_response = "must not leak",
      },
    })

    t.eq(fallback.status, "preview")
    t.eq(fallback.platform, "x")
    t.eq(receipt.source_ref.ref, "owner/repo#issue/43")
    t.eq(receipt.source_ref.reference, "owner/repo#issue/43")
    t.is_nil(receipt.source_ref.uri)
    t.eq(receipt.metadata.owner, "content-owner")
    t.is_nil(receipt.metadata.raw_response)
  end,
  test_live_gate_requires_live_channel_write_flag_and_service_slug = function()
    local payload = {
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
      content_ref = "#42",
      channel = "live",
    }

    t.eq(core.live_gate(payload, { live_write_enabled = true, nyxid_x_service = "api-twitter-2-media" }), true)
    t.eq(core.live_gate(payload, { live_write_enabled = false, nyxid_x_service = "api-twitter-2-media" }), false)
    t.eq(core.live_gate(payload, { live_write_enabled = true, nyxid_x_service = "" }), false)
    t.eq(core.live_gate({ channel = "shadow" }, { live_write_enabled = true, nyxid_x_service = "api-twitter-2-media" }), false)
    t.eq(core.live_gate("bad", { live_write_enabled = true, nyxid_x_service = "api-twitter-2-media" }), false)
    t.eq(core.live_gate({
      metadata = { variant = "live" },
    }, { live_write_enabled = true, nyxid_x_service = "api-twitter-2-media" }), true)
    t.eq(core.live_gate(payload, { live_write_enabled = true, nyxid_x_service = "secret://x" }), false)
    t.eq(core.live_gate(payload, { live_write_enabled = true, nyxid_x_service = "bad slug" }), false)
  end,
  test_publish_once_key_is_runtime_safe = function()
    local key = core.publish_once_key({
      dedup_key = "auto-twitter-marketing/chronoai/2026-W31/schedule/owner/repo#issue/43/2026-07-28T11:10:00+08:00/x-publish",
    })

    t.is_true(key:find("^x%-publisher/publish/") ~= nil)
    t.is_true(key:find("#", 1, true) == nil)
    t.is_true(key:find(":", 1, true) == nil)
    t.is_true(key:find("+", 1, true) == nil)
  end,
  test_trusted_published_receipt_requires_author_key_marker_and_valid_status_uri = function()
    local dedup_key = "auto-twitter-marketing/chronoai/2026-W31/schedule/owner/repo#issue/43/occurrence/x-publish"
    local marker = "<!-- fkst:github-proxy:comment:" .. dedup_key
      .. "/status/x-publish-published -->"
    local evidence, why = core.trusted_published_receipt({
      {
        author_login = "fkst-test-bot[bot]",
        body = "Auto Twitter marketing: X published\n\n"
          .. "status: published\n"
          .. "post_uri: https://x.com/example_user/status/2087115957424840733\n"
          .. "dedup_key: " .. dedup_key .. "\n\n"
          .. marker .. "\n" .. marker,
      },
    }, dedup_key, function(login)
      return login == "fkst-test-bot[bot]"
    end)

    t.eq(why, nil)
    t.eq(evidence.post_id, "2087115957424840733")
    t.eq(evidence.post_uri, "https://x.com/example_user/status/2087115957424840733")
  end,
  test_trusted_published_receipt_rejects_noncanonical_expected_keys = function()
    local authorize = function()
      return true
    end
    for _, dedup_key in ipairs({
      " leading-space",
      "trailing-space ",
      "line\nbreak",
      "control\1byte",
      string.rep("x", 513),
    }) do
      local evidence, why = core.trusted_published_receipt({}, dedup_key, authorize)
      t.is_nil(evidence)
      t.eq(why, "published receipt validation unavailable")
    end
  end,
  test_trusted_published_receipt_ignores_forged_wrong_key_and_blocked_only_comments = function()
    local dedup_key = "stable/x-publish"
    local function published_comment(author, key, post_id)
      return {
        author_login = author,
        body = "Auto Twitter marketing: X published\n\n"
          .. "status: published\n"
          .. "post_uri: https://x.com/i/web/status/" .. post_id .. "\n"
          .. "dedup_key: " .. key .. "\n\n"
          .. "<!-- fkst:github-proxy:comment:" .. key
          .. "/status/x-publish-published -->",
      }
    end
    local comments = {
      published_comment("untrusted-user", dedup_key, "111"),
      published_comment("fkst-test-bot", "other/x-publish", "222"),
      {
        author_login = "fkst-test-bot",
        body = "Auto Twitter marketing: X published\n\n"
          .. "status: published\n"
          .. "post_uri: https://x.com/i/web/status/333",
      },
      {
        author_login = "fkst-test-bot",
        body = "Auto Twitter marketing: X publish blocked\n\n"
          .. "status: blocked\n"
          .. "dedup_key: " .. dedup_key .. "\n\n"
          .. "<!-- fkst:github-proxy:comment:" .. dedup_key
          .. "/status/x-publish-blocked -->",
      },
    }

    local evidence, why = core.trusted_published_receipt(comments, dedup_key, function(login)
      return login == "fkst-test-bot"
    end)

    t.is_nil(evidence)
    t.eq(why, nil)
  end,
  test_trusted_published_receipt_survives_later_blocked_receipt = function()
    local dedup_key = "stable/x-publish"
    local evidence, why = core.trusted_published_receipt({
      {
        author_login = "fkst-test-bot",
        body = "Auto Twitter marketing: X published\n\n"
          .. "status: published\n"
          .. "post_uri: https://twitter.com/example/status/1234567890\n"
          .. "dedup_key: " .. dedup_key .. "\n\n"
          .. "<!-- fkst:github-proxy:comment:" .. dedup_key
          .. "/status/x-publish-published -->",
      },
      {
        author_login = "fkst-test-bot",
        body = "Auto Twitter marketing: X publish blocked\n\n"
          .. "status: blocked\n"
          .. "dedup_key: " .. dedup_key,
      },
    }, dedup_key, function()
      return true
    end)

    t.eq(why, nil)
    t.eq(evidence.post_id, "1234567890")
  end,
  test_trusted_published_receipt_fails_closed_on_corruption_or_conflict = function()
    local dedup_key = "stable/x-publish"
    local function comment(post_uri, platform_post_id, legacy_post_id)
      return {
        author_login = "fkst-test-bot",
        body = "Auto Twitter marketing: X published\n\n"
          .. "status: published\n"
          .. "post_uri: " .. post_uri .. "\n"
          .. (platform_post_id and ("platform_post_id: " .. platform_post_id .. "\n") or "")
          .. (legacy_post_id and ("post_id: " .. legacy_post_id .. "\n") or "")
          .. "dedup_key: " .. dedup_key .. "\n\n"
          .. "<!-- fkst:github-proxy:comment:" .. dedup_key
          .. "/status/x-publish-published -->",
      }
    end
    local authorize = function()
      return true
    end

    local malformed, malformed_why = core.trusted_published_receipt({
      comment("https://example.com/example/status/123", nil),
    }, dedup_key, authorize)
    local mismatched, mismatched_why = core.trusted_published_receipt({
      comment("https://x.com/example/status/123", "456"),
    }, dedup_key, authorize)
    local alias_conflict, alias_conflict_why = core.trusted_published_receipt({
      comment("https://x.com/example/status/123", "123", "456"),
    }, dedup_key, authorize)
    local matching_key_without_marker, missing_marker_why = core.trusted_published_receipt({
      {
        author_login = "fkst-test-bot",
        body = "Auto Twitter marketing: X published\n\n"
          .. "status: published\n"
          .. "post_uri: https://x.com/example/status/123\n"
          .. "dedup_key: " .. dedup_key,
      },
    }, dedup_key, authorize)
    local wrong_title, wrong_title_why = core.trusted_published_receipt({
      {
        author_login = "fkst-test-bot",
        body = "Damaged receipt title\n\n"
          .. "status: published\n"
          .. "post_uri: https://x.com/example/status/123\n"
          .. "dedup_key: " .. dedup_key,
      },
    }, dedup_key, authorize)
    local conflict, conflict_why = core.trusted_published_receipt({
      comment("https://x.com/example/status/123", nil),
      comment("https://x.com/example/status/456", nil),
    }, dedup_key, authorize)

    t.is_nil(malformed)
    t.eq(malformed_why, "corrupt published receipt marker")
    t.is_nil(mismatched)
    t.eq(mismatched_why, "corrupt published receipt marker")
    t.is_nil(alias_conflict)
    t.eq(alias_conflict_why, "corrupt published receipt marker")
    t.is_nil(matching_key_without_marker)
    t.eq(missing_marker_why, "corrupt published receipt marker")
    t.is_nil(wrong_title)
    t.eq(wrong_title_why, "corrupt published receipt marker")
    t.is_nil(conflict)
    t.eq(conflict_why, "conflicting published receipt markers")
  end,
  test_calendar_issue_ref_resolves_against_schedule_issue_repo = function()
    local ref, why = core.content_source_ref({
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
      content_ref = "#42",
    })

    t.eq(why, nil)
    t.eq(ref.kind, "external")
    t.eq(ref.ref, "owner/repo#issue/42")
  end,
  test_content_source_ref_accepts_direct_url_and_metadata_tag_refs = function()
    local direct = core.content_source_ref({
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
      content_ref = "another/repo#issue/99",
    })
    local url = core.content_source_ref({
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
      content_ref = "https://github.com/owner/content/issues/100",
    })
    local metadata = core.content_source_ref({
      source_ref = { kind = "external", reference = "owner/repo#issue/43" },
      metadata = { tag = "calendar:#44" },
    })
    local invalid_payload, invalid_payload_why = core.content_source_ref("bad")
    local missing, missing_why = core.content_source_ref({
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
    })
    local no_repo, no_repo_why = core.content_source_ref({
      source_ref = { kind = "external", ref = "not-an-issue-ref" },
      content_ref = "#44",
    })
    local no_source_repo, no_source_repo_why = core.content_source_ref({
      source_ref = {},
      content_ref = "#44",
    })
    local unsupported, unsupported_why = core.content_source_ref({
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
      content_ref = "issue:44",
    })

    t.eq(direct.ref, "another/repo#issue/99")
    t.eq(url.ref, "owner/content#issue/100")
    t.eq(metadata.ref, "owner/repo#issue/44")
    t.is_nil(invalid_payload)
    t.eq(invalid_payload_why, "invalid payload")
    t.is_nil(missing)
    t.eq(missing_why, "missing content_ref")
    t.is_nil(no_repo)
    t.eq(no_repo_why, "content_ref requires issue source_ref repo")
    t.is_nil(no_source_repo)
    t.eq(no_source_repo_why, "content_ref requires issue source_ref repo")
    t.is_nil(unsupported)
    t.eq(unsupported_why, "unsupported content_ref")
  end,
  test_extract_tweet_text_prefers_explicit_fenced_tweet_text = function()
    local text, why = core.extract_tweet_text([[
type: weekly-content
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
]])

    t.eq(why, nil)
    t.eq(text, "FKST live publish verification for example_user via NyxID. Test post.")
  end,
  test_extract_tweet_text_renders_schedule_placeholders = function()
    local text, why = core.extract_tweet_text([[
type: weekly-content
week: 2026-W31

tweet-text:
```
FKST interval recurring verification for example_user. occurrence={{occurrence_id}}, scheduled={{scheduled_at}}, interval={{interval_minutes}}m.
```
]], {
      scheduled_at = "2026-07-29T11:35:00+08:00",
      metadata = {
        interval_minutes = 10,
        occurrence_id = "2026-07-29T11:35:00+08:00",
      },
    })

    t.eq(why, nil)
    t.eq(text, "FKST interval recurring verification for example_user. occurrence=2026-07-29T11:35:00+08:00, scheduled=2026-07-29T11:35:00+08:00, interval=10m.")
  end,
  test_extract_tweet_text_renders_schedule_type_placeholder = function()
    local text, why = core.extract_tweet_text("tweet: schedule={{schedule_type}}", {
      metadata = {
        schedule_type = "daily",
      },
    })

    t.eq(why, nil)
    t.eq(text, "schedule=daily")
  end,
  test_extract_tweet_text_fails_closed_when_placeholder_value_missing = function()
    local text, why = core.extract_tweet_text("tweet: FKST interval {{occurrence_id}}")

    t.is_nil(text)
    t.eq(why, "missing tweet placeholder value")
  end,
  test_extract_tweet_text_rejects_oversized_text = function()
    local text, why = core.extract_tweet_text("tweet: " .. string.rep("x", 281))

    t.is_nil(text)
    t.eq(why, "tweet text too long")
  end,
  test_extract_tweet_text_rejects_empty_fenced_text = function()
    local text, why = core.extract_tweet_text("tweet:\n```\n   \n```")

    t.is_nil(text)
    t.eq(why, "missing tweet text")
  end,
  test_extract_tweet_text_handles_inline_markers_and_template_failures = function()
    local inline = core.extract_tweet_text("x-post: Inline X post")
    local crlf = core.extract_tweet_text("post: Line one\r\n")
    local empty, empty_why = core.extract_tweet_text("tweet:   ")
    local unsupported, unsupported_why = core.extract_tweet_text("tweet: Unsupported {{unknown}}")

    t.eq(inline, "Inline X post")
    t.eq(crlf, "Line one")
    t.is_nil(empty)
    t.eq(empty_why, "missing tweet text")
    t.is_nil(unsupported)
    t.eq(unsupported_why, "unsupported tweet placeholder")
  end,
  test_extract_publish_intent_keeps_legacy_post_compatible = function()
    local intent, why = core.extract_publish_intent("tweet: Existing post contract")

    t.eq(why, nil)
    t.eq(intent.operation, "post")
    t.eq(intent.text, "Existing post contract")
    t.eq(intent.publish_text, "Existing post contract")
    t.is_nil(intent.quote_post)
  end,
  test_extract_publish_intent_normalizes_native_quote_target = function()
    local intent, why = core.extract_publish_intent([[
operation: quote
quote-mode: native
quote-url: https://twitter.com/Example_User/status/2084047583316758780?ref_src=twsrc%5Etfw

tweet-text:
```
Commentary text
```
]])

    t.eq(why, nil)
    t.eq(intent.operation, "quote")
    t.eq(intent.text, "Commentary text")
    t.eq(intent.publish_text, "Commentary text")
    t.eq(intent.quote_post.mode, "native")
    t.eq(intent.quote_post.provider_post_id, "2084047583316758780")
    t.eq(intent.quote_post.author_handle, "example_user")
    t.eq(intent.quote_post.url, "https://x.com/example_user/status/2084047583316758780")
  end,
  test_extract_publish_intent_builds_link_quote_text_once = function()
    local intent, why = core.extract_publish_intent([[
operation: quote
quote-mode: link
quote-url: https://x.com/i/web/status/2084047583316758780
tweet: Commentary text
]])

    t.eq(why, nil)
    t.eq(intent.operation, "quote")
    t.eq(intent.publish_text,
      "Commentary text\n\nhttps://x.com/i/web/status/2084047583316758780")
    t.eq(intent.quote_post.mode, "link")
    t.is_nil(intent.quote_post.author_handle)
  end,
  test_extract_publish_intent_rejects_invalid_or_incomplete_quote_contracts = function()
    local cases = {
      { "operation: quote\nquote-mode: native\ntweet: text", "missing quote url" },
      { "operation: quote\nquote-url: https://x.com/a/status/1\ntweet: text", "missing quote mode" },
      { "operation: quote\nquote-mode: fallback\nquote-url: https://x.com/a/status/1\ntweet: text", "unsupported quote mode" },
      { "operation: quote\nquote-mode: native\nquote-url: http://x.com/a/status/1\ntweet: text", "invalid quote url" },
      { "operation: quote\nquote-mode: native\nquote-url: https://user@x.com/a/status/1\ntweet: text", "invalid quote url" },
      { "operation: quote\nquote-mode: native\nquote-url: https://x.com:443/a/status/1\ntweet: text", "invalid quote url" },
      { "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/1#fragment\ntweet: text", "invalid quote url" },
      { "operation: quote\nquote-mode: native\nquote-url: https://example.com/a/status/1\ntweet: text", "invalid quote url" },
      { "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/home/1\ntweet: text", "invalid quote url" },
      { "operation: post\nquote-mode: native\nquote-url: https://x.com/a/status/1\ntweet: text", "quote fields require quote operation" },
      { "operation: thread\ntweet: text", "unsupported operation" },
    }

    for _, case in ipairs(cases) do
      local intent, why = core.extract_publish_intent(case[1])
      t.is_nil(intent)
      t.eq(why, case[2])
    end
  end,
  test_extract_publish_intent_rejects_duplicate_quote_control_fields = function()
    local cases = {
      "operation: quote\noperation: post\nquote-mode: native\nquote-url: https://x.com/a/status/1\ntweet: text",
      "operation: quote\nquote-mode: native\nquote_mode: link\nquote-url: https://x.com/a/status/1\ntweet: text",
      "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/1\nquote-url: https://x.com/b/status/2\ntweet: text",
    }

    for _, body in ipairs(cases) do
      local intent, why = core.extract_publish_intent(body)
      t.is_nil(intent)
      t.eq(why, "duplicate quote control field")
    end
  end,
  test_weighted_length_matches_quote_boundary_vectors = function()
    local native = core.extract_publish_intent("operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/1\ntweet: "
      .. string.rep("中", 140))
    local native_too_long, native_why = core.extract_publish_intent(
      "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/1\ntweet: "
        .. string.rep("中", 141))
    local link = core.extract_publish_intent("operation: quote\nquote-mode: link\nquote-url: https://x.com/a/status/1\ntweet: "
      .. string.rep("x", 255))
    local link_too_long, link_why = core.extract_publish_intent(
      "operation: quote\nquote-mode: link\nquote-url: https://x.com/a/status/1\ntweet: "
        .. string.rep("x", 256))

    t.eq(native.weighted_length, 280)
    t.eq(link.weighted_length, 280)
    t.is_nil(native_too_long)
    t.eq(native_why, "tweet text too long")
    t.is_nil(link_too_long)
    t.eq(link_why, "tweet text too long")
  end,
  test_weighted_length_counts_emoji_cluster_as_two = function()
    local intent = assert(core.extract_publish_intent(
      "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/1\ntweet: "
        .. string.rep("👨‍👩‍👧‍👦", 140)))
    local too_long, why = core.extract_publish_intent(
      "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/1\ntweet: "
        .. string.rep("👨‍👩‍👧‍👦", 141))

    t.eq(intent.weighted_length, 280)
    t.is_nil(too_long)
    t.eq(why, "tweet text too long")
  end,
  test_tweet_body_json_escapes_control_characters = function()
    local body = core.tweet_body_json("quote \" slash \\ newline\n tab\t carriage\r")

    t.eq(body, '{"text":"quote \\" slash \\\\ newline\\n tab\\t carriage\\r"}')
  end,
  test_tweet_body_json_maps_native_and_link_quote_intents = function()
    local native = assert(core.extract_publish_intent(
      "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/123\ntweet: Native commentary"))
    local link = assert(core.extract_publish_intent(
      "operation: quote\nquote-mode: link\nquote-url: https://x.com/a/status/123\ntweet: Link commentary"))

    t.eq(core.publish_body_json(native),
      '{"text":"Native commentary","quote_tweet_id":"123"}')
    t.eq(core.publish_body_json(link),
      '{"text":"Link commentary\\n\\nhttps://x.com/a/status/123"}')
    t.is_true(core.publish_body_json(link):find("quote_tweet_id", 1, true) == nil)
  end,
  test_nyxid_response_parsers_fail_closed = function()
    t.eq(core.parse_nyxid_username('{"data":{"username":"example_user"}}'), "example_user")
    t.eq(core.parse_nyxid_tweet_id('{"data":{"id":"123"}}'), "123")
    t.is_nil(core.parse_nyxid_username("not-json"))
    t.is_nil(core.parse_nyxid_username("123"))
    t.is_nil(core.parse_nyxid_username('{"data":{}}'))
    t.is_nil(core.parse_nyxid_tweet_id('{"data":{}}'))
    t.is_nil(core.parse_nyxid_tweet_id('{"data":{"id":""}}'))
  end,
  test_live_receipt_shape_contains_x_uri_without_raw_response = function()
    local receipt = core.live_receipt({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
      content_ref = "#42",
      trace_id = "trace-1",
    }, {
      id = "1234567890123456789",
      username = "example_user",
      nyxid_x_service = "api-twitter-2-media",
    })

    t.eq(receipt.status, "published")
    t.eq(receipt.platform_post_id, "1234567890123456789")
    t.eq(receipt.post_uri, "https://x.com/i/web/status/1234567890123456789")
    t.eq(receipt.account_username, "example_user")
    t.eq(receipt.nyxid_x_service, "api-twitter-2-media")
    t.is_nil(receipt.provider_response)
  end,
  test_receipt_carries_safe_quote_evidence = function()
    local intent = assert(core.extract_publish_intent(
      "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/123\ntweet: Commentary"))
    local receipt = core.live_receipt({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
    }, {
      id = "456",
      intent = intent,
    })

    t.eq(receipt.operation, "quote")
    t.eq(receipt.quote_mode, "native")
    t.eq(receipt.quote_target_uri, "https://x.com/a/status/123")
    t.eq(receipt.quote_target_post_id, "123")
    t.is_nil(receipt.text)
  end,
}
