local t = fkst.test
local marketing_schedule = require("contract.marketing_schedule")
local v2 = require("tests.fixtures.v2_publish")

local integration = require("tests.fixtures.publish_integration")
local repo = integration.repo
local published_receipt_comment = integration.published_receipt_comment
local mock_nyxid_cli_available = integration.mock_nyxid_cli_available
local count_calls = integration.count_calls
local live_payload = integration.live_payload
local live_env = integration.live_env
local run_publish = integration.run_publish
local process_token = tostring({}):gsub("[^%w]", "")

return {
  test_publish_request_raises_preview_receipt = function()
    local payload = live_payload("preview", nil, {
      artifact_id = "artifact-1",
      channel = "shadow",
      dedup_key = "dedup-1",
      trace_id = "trace-1",
      metadata = { campaign_id = "campaign-1", locale = "en-US", variant = "a" },
    })
    local result = run_publish(payload)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)

    local raised = result.raises[1]
    t.eq(raised.queue, "x-publisher.x_published")
    t.eq(raised.payload.artifact_id, "artifact-1")
    t.eq(raised.payload.platform, "x")
    t.eq(raised.payload.status, "preview")
    t.is_nil(raised.payload.post_uri)
    t.eq(raised.payload.schema, "x-publisher.publish-receipt.v2")
    t.eq(raised.payload.account, v2.ACCOUNT)
    t.eq(raised.payload.source_ref.ref, repo .. "#issue/43")
    t.eq(raised.payload.dedup_key, "dedup-1")
    t.eq(raised.payload.trace_id, "trace-1")
    t.eq(raised.payload.approval_id, "test-primary-w33-proposal@2")
    t.eq(raised.payload.metadata.campaign_id, "campaign-1")
    t.eq(raised.payload.content_ref, "#42")
  end,

  test_publish_request_skips_invalid_content_payload = function()
    local payload = live_payload("invalid-content-field")
    payload.text = "content must stay behind source_ref"
    local result = run_publish(payload)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_live_publish_fails_closed_without_write_gate = function()
    local result = run_publish(live_payload("missing-gate"), {
      FKST_X_PUBLISH_WRITE = "",
      FKST_NYXID_X_SERVICE_SLUG = "test-x-service",
      FKST_X_PUBLISH_EXPECTED_USERNAME = "test_primary",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "x-publisher.x_published")
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "live gate disabled")
    t.eq(result.raises[1].payload.publish_attempted, false)
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_fails_closed_without_nyxid_access_token = function()
    local result = run_publish(live_payload("missing-token"), {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "test-x-service",
      X_PUBLISH_EXPECTED_USERNAME = "test_primary",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "x-publisher.x_published")
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid access token missing")
    t.eq(count_calls("nyxid --version"), 0)
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_fails_closed_without_nyxid_cli = function()
    t.mock_command("nyxid --version", {
      stdout = "",
      stderr = "nyxid: command not found",
      exit_code = 127,
    })

    local result = run_publish(live_payload("missing-cli"), {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "test-x-service",
      X_PUBLISH_EXPECTED_USERNAME = "test_primary",
      ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "x-publisher.x_published")
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid cli unavailable")
    t.eq(count_calls('printf %s "$NYXID_ACCESS_TOKEN"'), 0)
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_publish_request_skips_missing_dedup_key_without_post = function()
    local payload = live_payload("missing-dedup")
    payload.dedup_key = nil

    local result = run_publish(payload, live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("nyxid --version"), 0)
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_blocks_when_account_preflight_fails = function()
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = "",
      stderr = "preflight failed",
      exit_code = 1,
    })

    local result = run_publish(live_payload("preflight-failed"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid account preflight failed")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_account_preflight_returns_problem_json = function()
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"detail":"Service Unavailable","status":503,"title":"Service Unavailable","type":"about:blank"}',
      stderr = "Proxy request failed (HTTP 503 Service Unavailable)",
      exit_code = 0,
    })

    local result = run_publish(live_payload("preflight-problem-json"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid account preflight failed")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_account_is_unexpected = function()
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000002","name":"Test Secondary","username":"test_secondary"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("unexpected-account"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "blocked")
    t.eq(receipt.blocked_reason, "unexpected account")
    t.eq(receipt.account, v2.ACCOUNT)
    t.eq(receipt.authenticated_account, v2.SECONDARY_ACCOUNT)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_stale_content_digest_without_post = function()
    local payload = live_payload("stale-content-digest")
    payload.content_digest = "sha256:" .. string.rep("0", 64)
    payload.schedule_digest = assert(marketing_schedule.digest(v2.schedule_body(payload)))

    local result = run_publish(payload, live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "content request correlation mismatch")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_stale_schedule_revisions_without_post = function()
    local one_shot_time = "2026-08-17T00:00:00Z"
    local interval_start = "2026-08-17T00:00:00Z"
    local cases = {
      {
        name = "one-shot-time",
        payload = live_payload("stale-one-shot-time", nil, {
          scheduled_at = one_shot_time,
          metadata = { schedule_type = "one-shot" },
        }),
        fresh = { scheduled_at = "2026-08-17T01:00:00Z" },
      },
      {
        name = "daily-time",
        payload = live_payload("stale-daily-time"),
        fresh = { time = "17:00" },
      },
      {
        name = "daily-timezone",
        payload = live_payload("stale-daily-timezone"),
        fresh = { timezone = "Asia/Shanghai" },
      },
      {
        name = "daily-to-interval",
        payload = live_payload("stale-recurrence"),
        fresh = {
          recurrence = "every-minutes",
          interval_minutes = 10,
          scheduled_at = interval_start,
        },
      },
    }

    local interval_payload = live_payload("stale-interval", nil, {
      scheduled_at = interval_start,
      metadata = {
        schedule_type = "every-minutes",
        occurrence_id = interval_start,
        interval_minutes = 10,
      },
    })
    local interval_schedule = {
      type = "recurring-schedule-publish",
      recurrence = "every-minutes",
      interval_minutes = 10,
      scheduled_at = interval_start,
    }
    interval_payload.schedule_digest = assert(marketing_schedule.digest(
      v2.schedule_body(interval_payload, interval_schedule)
    ))
    cases[#cases + 1] = {
      name = "interval-minutes",
      payload = interval_payload,
      fresh = {
        type = "recurring-schedule-publish",
        recurrence = "every-minutes",
        interval_minutes = 15,
        scheduled_at = interval_start,
      },
    }

    for _, case in ipairs(cases) do
      local result = run_publish(case.payload, live_env(), {
        schedule_issue = { schedule = case.fresh },
      })
      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 1)
      t.eq(result.raises[1].payload.status, "blocked")
      t.eq(result.raises[1].payload.blocked_reason, "schedule digest mismatch")
      t.eq(result.raises[1].payload.publish_attempted, false)
      t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
    end
  end,

  test_live_publish_blocks_trusted_superseded_content_without_post = function()
    local payload = live_payload("superseded-content")
    local superseded_marker = '<!-- fkst:auto-twitter:content-superseded:v2 content_digest="'
      .. payload.content_digest .. '" -->'

    local result = run_publish(payload, live_env(), {
      content_issue = {
        comments = {
          { author_login = v2.BOT_LOGIN, body = superseded_marker },
        },
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "content revision superseded")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_open_content_issue_without_post = function()
    local result = run_publish(live_payload("open-content"), live_env(), {
      content_issue = { state = "open" },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "content issue is not immutable")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_manually_authored_content_without_post = function()
    local result = run_publish(live_payload("manual-content-author"), live_env(), {
      content_issue = { author_login = v2.CREATOR },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "content author mismatch")
    t.eq(result.raises[1].payload.publish_attempted, false)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_invalid_content_assignees_without_post = function()
    local cases = {
      { name = "missing", assignees = {} },
      { name = "multiple", assignees = { v2.CREATOR, "test-other-maintainer" } },
      { name = "wrong", assignees = { "test-other-maintainer" } },
    }
    for _, case in ipairs(cases) do
      local result = run_publish(live_payload("content-assignee-" .. case.name), live_env(), {
        content_issue = { assignees = case.assignees },
      })

      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 1)
      t.eq(result.raises[1].payload.status, "blocked")
      t.eq(result.raises[1].payload.blocked_reason, "content route mismatch")
    end
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_github_content_read_fails = function()
    local result = run_publish(live_payload("github-read-failed"), live_env(), {
      content_read_failure = true,
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "github issue read failed")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_publish_request_skips_missing_content_ref_without_post = function()
    local payload = live_payload("missing-content-ref")
    payload.content_ref = nil

    local result = run_publish(payload, live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_tweet_publish_fails = function()
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = "",
      stderr = "publish failed",
      exit_code = 1,
    })

    local result = run_publish(live_payload("publish-failed"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid tweet publish failed")
    t.eq(result.raises[1].payload.publish_attempted, true)
  end,

  test_live_publish_blocks_when_tweet_response_has_no_id = function()
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"data":{}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("invalid-response"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "invalid nyxid tweet response")
    t.eq(result.raises[1].payload.publish_attempted, true)
  end,

  test_live_publish_blocks_without_session_expected_account = function()
    local env_values = live_env()
    env_values.X_PUBLISH_EXPECTED_USERNAME = ""

    local result = run_publish(live_payload("no-expected-username"), env_values)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "missing or invalid expected account")
    t.eq(count_calls("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET"), 0)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_conflicting_expected_account_env_without_nyxid = function()
    local env_values = live_env()
    env_values.FKST_X_PUBLISH_EXPECTED_USERNAME = v2.SECONDARY_ACCOUNT

    local result = run_publish(live_payload("conflicting-expected-account"), env_values)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "blocked")
    t.eq(receipt.blocked_reason, "conflicting expected account")
    t.eq(receipt.account, v2.ACCOUNT)
    t.is_nil(receipt.authenticated_account)
    t.eq(count_calls("nyxid"), 0)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_request_account_mismatch_without_post = function()
    local payload = live_payload("request-account-mismatch")
    payload.account = v2.SECONDARY_ACCOUNT

    local result = run_publish(payload, live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "request account mismatch")
    t.eq(result.raises[1].payload.account, v2.SECONDARY_ACCOUNT)
    t.is_nil(result.raises[1].payload.authenticated_account)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_publish_accepts_non_reserved_environment_names = function()
    local payload = live_payload("non-reserved-env", {
      tweet_text = "FKST live publish verification for test_primary via NyxID. Test post.",
    })
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for test_primary via NyxID. Test post."}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(payload, {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "test-x-service",
      X_PUBLISH_EXPECTED_USERNAME = "test_primary",
      ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "published")
    t.eq(receipt.platform_post_id, "1234567890123456789")
    t.eq(receipt.account, v2.ACCOUNT)
    t.eq(receipt.authenticated_account, v2.ACCOUNT)
  end,

  test_live_publish_uses_nyxid_after_account_preflight_and_calendar_ref_resolution = function()
    local payload = live_payload("calendar", {
      tweet_text = "FKST live publish verification for test_primary via NyxID. Test post.",
    })
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for test_primary via NyxID. Test post."}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(payload, {
      FKST_X_PUBLISH_WRITE = "1",
      FKST_NYXID_X_SERVICE_SLUG = "test-x-service",
      FKST_X_PUBLISH_EXPECTED_USERNAME = "test_primary",
      ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "published")
    t.eq(receipt.platform_post_id, "1234567890123456789")
    t.eq(receipt.post_uri, "https://x.com/i/web/status/1234567890123456789")
    t.eq(receipt.account, v2.ACCOUNT)
    t.eq(receipt.authenticated_account, v2.ACCOUNT)
    t.eq(count_calls("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET"), 1)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 1)
  end,

  test_live_native_quote_requires_explicit_capability_gate = function()
    local payload = live_payload("native-quote-gate", {
      week = "2026-W32",
      operation = "quote",
      quote_mode = "native",
      quote_url = "https://x.com/example/status/1234567890123456789",
      tweet_text = "Native Quote capability check",
    })
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(payload, live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "native quote capability disabled")
    t.eq(result.raises[1].payload.authenticated_account, v2.ACCOUNT)
    t.eq(result.raises[1].payload.publish_attempted, false)
    t.eq(result.raises[1].payload.quote_target_post_id, "1234567890123456789")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 0)
  end,

  test_live_native_quote_publishes_exact_body_once = function()
    local env_values = live_env()
    env_values.FKST_SESSION_PACKAGE_ENV_JSON =
      '{"x-publisher":{"FKST_X_PUBLISH_NATIVE_QUOTE":"1"}}'
    local payload = live_payload("native-quote", {
      week = "2026-W32",
      operation = "quote",
      quote_mode = "native",
      quote_url = "https://twitter.com/Example/status/1234567890123456789?source=fkst",
      tweet_text = "Native Quote commentary",
    })
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"data":{"id":"2234567890123456789"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(payload, env_values)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "published")
    t.eq(receipt.operation, "quote")
    t.eq(receipt.quote_mode, "native")
    t.eq(receipt.quote_target_uri, "https://x.com/example/status/1234567890123456789")
    t.eq(count_calls('"quote_tweet_id":"1234567890123456789"'), 1)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 1)
  end,

  test_native_quote_provider_failure_does_not_fallback = function()
    local env_values = live_env()
    env_values.X_PUBLISH_NATIVE_QUOTE = "1"
    local payload = live_payload("native-quote-failure", {
      operation = "quote",
      quote_mode = "native",
      quote_url = "https://x.com/example/status/1234567890123456789",
      tweet_text = "No fallback commentary",
    })
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"status":403,"title":"Forbidden"}',
      stderr = "Proxy request failed",
      exit_code = 1,
    })

    local result = run_publish(payload, env_values)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid quote publish failed")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 1)
    t.eq(count_calls("https://x.com/example/status/1234567890123456789"), 0)
  end,

  test_live_link_quote_appends_canonical_url_without_native_field = function()
    local payload = live_payload("link-quote", {
      operation = "quote",
      quote_mode = "link",
      quote_url = "https://twitter.com/Example/status/1234567890123456789?source=fkst",
      tweet_text = "Link Quote commentary",
    })
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"data":{"id":"3234567890123456789"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(payload, live_env())

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "published")
    t.eq(result.raises[1].payload.quote_mode, "link")
    t.eq(count_calls('Link Quote commentary\\n\\nhttps://x.com/example/status/1234567890123456789'), 1)
    t.eq(count_calls("quote_tweet_id"), 0)
  end,

  test_live_publish_replays_trusted_receipt_across_two_fresh_runtime_roots_without_post = function()
    local payload = live_payload("historical-replay")
    local comments = {
      published_receipt_comment(payload.dedup_key, "2087115957424840733", "fkst-test-bot[bot]"),
      published_receipt_comment(payload.dedup_key, "2087115957424840733", "app/fkst-test-bot"),
      {
        author_login = "fkst-test-bot",
        body = "Auto Twitter marketing: X publish blocked\n\n"
          .. "status: blocked\n"
          .. "dedup_key: " .. payload.dedup_key,
      },
    }

    local first = run_publish(payload, live_env(), { schedule_comments = comments })
    local second = run_publish(payload, live_env(), { schedule_comments = comments })

    t.eq(first.exit_code, 0)
    t.eq(second.exit_code, 0)
    t.eq(first.raises[1].payload.status, "published")
    t.eq(second.raises[1].payload.status, "published")
    t.eq(first.raises[1].payload.platform_post_id, "2087115957424840733")
    t.eq(second.raises[1].payload.platform_post_id, "2087115957424840733")
    t.eq(count_calls("gh api repos/" .. repo .. "/issues/43"), 2)
    t.eq(count_calls("gh api repos/" .. repo .. "/issues/42"), 2)
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_replays_content_anchored_receipt_without_post = function()
    local payload = live_payload("content-anchored-replay")
    local post_id = "2087115957424840799"
    local result = run_publish(payload, live_env(), {
      content_issue = {
        comments = { published_receipt_comment(payload.dedup_key, post_id) },
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "published")
    t.eq(result.raises[1].payload.platform_post_id, post_id)
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_rejects_noncanonical_dedup_keys_without_post = function()
    for index, dedup_key in ipairs({ " leading-space", "line\nbreak" }) do
      local payload = live_payload("invalid-dedup-" .. tostring(index))
      payload.dedup_key = dedup_key

      local result = run_publish(payload, live_env())

      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 0)
    end
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_posts_once_then_fresh_runtime_replays_persisted_receipt = function()
    local payload = live_payload("fresh-runtime-sequence", {
      tweet_text = "Publish once before receipt persistence.",
    })
    local post_id = "2087115963800109098"
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"data":{"id":"' .. post_id .. '"}}',
      stderr = "",
      exit_code = 0,
    })

    local first = run_publish(payload, live_env())
    local second = run_publish(payload, live_env(), {
      schedule_comments = { published_receipt_comment(payload.dedup_key, post_id) },
    })

    t.eq(first.exit_code, 0)
    t.eq(second.exit_code, 0)
    t.eq(first.raises[1].payload.status, "published")
    t.eq(second.raises[1].payload.status, "published")
    t.eq(first.raises[1].payload.platform_post_id, post_id)
    t.eq(second.raises[1].payload.platform_post_id, post_id)
    t.eq(count_calls("gh api repos/" .. repo .. "/issues/43"), 2)
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 1)
  end,

  test_live_publish_fails_closed_when_schedule_comments_read_fails = function()
    local result = run_publish(live_payload("schedule-read-failed"), live_env(), {
      schedule_read_failure = true,
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "github issue read failed")
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_fails_closed_on_corrupt_trusted_receipt_marker = function()
    local payload = live_payload("corrupt-receipt")
    local result = run_publish(payload, live_env(), {
      schedule_comments = {
        published_receipt_comment(payload.dedup_key, "not-a-post-id"),
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "corrupt published receipt marker")
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_does_not_trust_forged_receipt_comment = function()
    local payload = live_payload("forged-receipt", {
      tweet_text = "A forged receipt must not suppress this post.",
    })
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"data":{"id":"2087115960297967885"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(payload, live_env(), {
      schedule_comments = {
        published_receipt_comment(payload.dedup_key, "111", "untrusted-user"),
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "published")
    t.eq(result.raises[1].payload.platform_post_id, "2087115960297967885")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 1)
  end,

  test_live_publish_does_not_trust_receipt_from_authorized_human = function()
    local payload = live_payload("authorized-human-forged-receipt", {
      tweet_text = "An authorized human receipt must not suppress this post.",
    })
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
      stdout = '{"data":{"id":"2087115965062597421"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(payload, live_env(), {
      authorized_logins = "fkst-test-bot,release-manager",
      schedule_comments = {
        published_receipt_comment(payload.dedup_key, "111", "release-manager"),
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "published")
    t.eq(result.raises[1].payload.platform_post_id, "2087115965062597421")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 1)
  end,

  test_live_publish_duplicate_dedup_key_skips_second_post = function()
    local suffix = process_token .. "-" .. tostring(now())
    local runtime_root = "/tmp/fkst-marketing-test/x-publisher/live-once-" .. suffix
    local durable_root = "/tmp/fkst-marketing-test/x-publisher/live-once-durable-" .. suffix
    local dedup_key = "dedup-live-once-" .. suffix
    local payload = live_payload("once-" .. suffix, {
      tweet_text = "Publish exactly once for the shared durable root.",
    }, {
      dedup_key = dedup_key,
    })
    local function run_once()
      mock_nyxid_cli_available()
      t.mock_command("nyxid proxy request test-x-service '/users/me?user.fields=id,name,username' -m GET", {
        stdout = '{"data":{"id":"100000000000000001","name":"Test Primary","username":"test_primary"}}',
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("nyxid proxy request test-x-service /tweets -m POST", {
        stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for test_primary via NyxID. Test post."}}',
        stderr = "",
        exit_code = 0,
      })
      return run_publish(payload, {
        FKST_X_PUBLISH_WRITE = "1",
        FKST_NYXID_X_SERVICE_SLUG = "test-x-service",
        FKST_X_PUBLISH_EXPECTED_USERNAME = "test_primary",
        ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
      }, {
        runtime_root = runtime_root,
        durable_root = durable_root,
      })
    end

    local first = run_once()
    local second = run_once()

    t.eq(first.exit_code, 0)
    t.eq(second.exit_code, 0)
    t.eq(first.raises[1].payload.status, "published")
    t.eq(second.raises[1].payload.status, "skipped")
    t.eq(count_calls("nyxid proxy request test-x-service /tweets -m POST"), 1)
  end,
}
