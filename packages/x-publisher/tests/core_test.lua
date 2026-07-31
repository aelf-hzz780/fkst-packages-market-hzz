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
  test_tweet_body_json_escapes_control_characters = function()
    local body = core.tweet_body_json("quote \" slash \\ newline\n tab\t carriage\r")

    t.eq(body, '{"text":"quote \\" slash \\\\ newline\\n tab\\t carriage\\r"}')
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
      tweet_text = "FKST live receipt text.",
    })

    t.eq(receipt.status, "published")
    t.eq(receipt.platform_post_id, "1234567890123456789")
    t.eq(receipt.post_uri, "https://x.com/i/web/status/1234567890123456789")
    t.eq(receipt.account_username, "example_user")
    t.eq(receipt.nyxid_x_service, "api-twitter-2-media")
    t.eq(receipt.tweet_text, "FKST live receipt text.")
    t.is_nil(receipt.provider_response)
  end,
}
