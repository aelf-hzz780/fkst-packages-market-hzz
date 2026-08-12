local t = fkst.test

local repo = "owner/repo"
local run_counter = 0
local prepare_github_live_read

local function unique_root(label)
  run_counter = run_counter + 1
  return "/tmp/fkst-marketing-test/x-publisher/" .. tostring(label)
    .. "-" .. tostring(now()) .. "-" .. tostring(run_counter)
end

local function event(payload)
  return {
    queue = "x_publish_request",
    payload = payload,
  }
end

local function run_publish(payload, env, opts)
  local env_values = env or {}
  prepare_github_live_read(opts or {})
  t.mock_command('printf %s "$X_PUBLISH_WRITE"', {
    stdout = env_values.X_PUBLISH_WRITE or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_X_PUBLISH_WRITE"', {
    stdout = env_values.FKST_X_PUBLISH_WRITE or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$NYXID_X_SERVICE_SLUG"', {
    stdout = env_values.NYXID_X_SERVICE_SLUG or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_NYXID_X_SERVICE_SLUG"', {
    stdout = env_values.FKST_NYXID_X_SERVICE_SLUG or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$X_PUBLISH_EXPECTED_USERNAME"', {
    stdout = env_values.X_PUBLISH_EXPECTED_USERNAME or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_X_PUBLISH_EXPECTED_USERNAME"', {
    stdout = env_values.FKST_X_PUBLISH_EXPECTED_USERNAME or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$X_PUBLISH_NATIVE_QUOTE"', {
    stdout = env_values.X_PUBLISH_NATIVE_QUOTE or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_X_PUBLISH_NATIVE_QUOTE"', {
    stdout = env_values.FKST_X_PUBLISH_NATIVE_QUOTE or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_SESSION_PACKAGE_ENV_JSON"', {
    stdout = env_values.FKST_SESSION_PACKAGE_ENV_JSON or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi', {
    stdout = env_values.NYXID_ACCESS_TOKEN and "1" or "0",
    stderr = "",
    exit_code = 0,
  })
  return t.run_department("departments/publish_x/main.lua", event(payload), {
    env = {
      FKST_RUNTIME_ROOT = unique_root("preview-rt"),
      FKST_DURABLE_ROOT = unique_root("preview-durable"),
    },
  })
end

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  return text
end

local function issue_rest_json(issue_number, body, author_login)
  return string.format(
    '{"number":%d,"title":"Auto Twitter marketing content %d","body":"%s","html_url":"https://github.example/%s/issues/%d","updated_at":"2026-07-24T09:00:00Z","state":"open","labels":[{"name":"auto-twitter-marketing"}],"assignees":[],"user":{"login":"%s"}}\n',
    issue_number,
    issue_number,
    json_escape(body),
    repo,
    issue_number,
    json_escape(author_login or "fkst-test-bot")
  )
end

local function comments_rest_json(comments)
  local rows = {}
  for index, comment in ipairs(comments or {}) do
    rows[#rows + 1] = string.format(
      '{"id":%d,"body":"%s","created_at":"2026-07-24T09:%02d:00Z","user":{"login":"%s"}}',
      index,
      json_escape(comment.body),
      index,
      json_escape(comment.author_login or "fkst-test-bot")
    )
  end
  return "[" .. table.concat(rows, ",") .. "]\n"
end

local function mock_author_env(opts)
  local options = opts or {}
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = options.bot_login or "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_MANAGED_BOT_LOGINS"', {
    stdout = options.managed_bot_logins or "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_AUTHORIZED_LOGINS"', {
    stdout = options.authorized_logins or "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_content_issue(issue_number, body)
  t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(issue_number), {
    stdout = issue_rest_json(issue_number, body),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. tostring(issue_number) .. "/comments?per_page=100'", {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_schedule_issue(comments)
  t.mock_command("gh api repos/" .. repo .. "/issues/43", {
    stdout = issue_rest_json(43, "type: schedule-publish"),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/43/comments?per_page=100'", {
    stdout = comments_rest_json(comments),
    stderr = "",
    exit_code = 0,
  })
end

local function published_receipt_comment(dedup_key, post_id, author_login)
  return {
    author_login = author_login or "fkst-test-bot",
    body = "Auto Twitter marketing: X published\n\n"
      .. "status: published\n"
      .. "post_uri: https://x.com/i/web/status/" .. tostring(post_id) .. "\n"
      .. "source_ref: " .. repo .. "#issue/43\n"
      .. "dedup_key: " .. dedup_key .. "\n\n"
      .. "<!-- fkst:github-proxy:comment:" .. dedup_key
      .. "/status/x-publish-published -->",
  }
end

prepare_github_live_read = function(opts)
  mock_author_env(opts)
  if opts.schedule_read_failure then
    t.mock_command("gh api repos/" .. repo .. "/issues/43", {
      stdout = "",
      stderr = "schedule issue unavailable",
      exit_code = 1,
    })
    return
  end
  mock_schedule_issue(opts.schedule_comments or {})
end

local function mock_nyxid_cli_available()
  t.mock_command("nyxid --version", {
    stdout = "nyxid 0.8.0\n",
    stderr = "",
    exit_code = 0,
  })
end

local function count_calls(needle)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    local rendered = tostring(call.rendered or call.command or call.cmd or "")
    if rendered == "" and type(call.argv) == "table" then
      rendered = table.concat(call.argv, " ")
    end
    if rendered:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

local function live_payload(suffix)
  return {
    artifact_id = "artifact-" .. tostring(suffix),
    source_ref = { kind = "external", ref = repo .. "#issue/43" },
    content_ref = "#42",
    platform = "x",
    channel = "live",
    dedup_key = "dedup-live-" .. tostring(suffix),
    trace_id = "trace-" .. tostring(suffix),
  }
end

local function live_env()
  return {
    X_PUBLISH_WRITE = "1",
    NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
    X_PUBLISH_EXPECTED_USERNAME = "example_user",
    ["NYXID_ACCESS_TOKEN"] = "present",
  }
end

return {
  test_publish_request_raises_preview_receipt = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "drafts/artifact-1" },
      content_ref = "#42",
      platform = "x",
      channel = "main",
      dedup_key = "dedup-1",
      trace_id = "trace-1",
      approval_id = "approval-1",
      scheduled_at = "2026-06-24T12:00:00Z",
      metadata = { campaign_id = "campaign-1", locale = "en-US", variant = "a" },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)

    local raised = result.raises[1]
    t.eq(raised.queue, "x-publisher.x_published")
    t.eq(raised.payload.artifact_id, "artifact-1")
    t.eq(raised.payload.platform, "x")
    t.eq(raised.payload.status, "preview")
    t.is_nil(raised.payload.post_uri)
    t.eq(raised.payload.source_ref.ref, "drafts/artifact-1")
    t.eq(raised.payload.dedup_key, "dedup-1")
    t.eq(raised.payload.trace_id, "trace-1")
    t.eq(raised.payload.approval_id, "approval-1")
    t.eq(raised.payload.metadata.campaign_id, "campaign-1")
    t.eq(raised.payload.content_ref, "#42")
  end,

  test_publish_request_skips_invalid_content_payload = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "drafts/artifact-1" },
      text = "content must stay behind source_ref",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_live_publish_fails_closed_without_write_gate = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-missing-gate",
      trace_id = "trace-1",
    }, {
      FKST_X_PUBLISH_WRITE = "",
      FKST_NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      FKST_X_PUBLISH_EXPECTED_USERNAME = "example_user",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "x-publisher.x_published")
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "live gate disabled")
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_fails_closed_without_nyxid_access_token = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-missing-token",
      trace_id = "trace-1",
    }, {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      X_PUBLISH_EXPECTED_USERNAME = "example_user",
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

    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-missing-cli",
      trace_id = "trace-1",
    }, {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      X_PUBLISH_EXPECTED_USERNAME = "example_user",
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

  test_live_publish_fails_closed_without_dedup_key = function()
    local payload = live_payload("missing-dedup")
    payload.dedup_key = nil

    local result = run_publish(payload, live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "missing dedup_key")
    t.eq(count_calls("nyxid --version"), 0)
  end,

  test_live_publish_blocks_when_account_preflight_fails = function()
    mock_author_env()
    mock_content_issue(42, "tweet: account preflight failure")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = "",
      stderr = "preflight failed",
      exit_code = 1,
    })

    local result = run_publish(live_payload("preflight-failed"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid account preflight failed")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_account_preflight_returns_problem_json = function()
    mock_author_env()
    mock_content_issue(42, "tweet: account preflight problem response")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"detail":"Service Unavailable","status":503,"title":"Service Unavailable","type":"about:blank"}',
      stderr = "Proxy request failed (HTTP 503 Service Unavailable)",
      exit_code = 0,
    })

    local result = run_publish(live_payload("preflight-problem-json"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid account preflight failed")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_account_is_unexpected = function()
    mock_author_env()
    mock_content_issue(42, "tweet: unexpected account")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000002","name":"Other User","username":"other_user"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("unexpected-account"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "unexpected account")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_github_content_read_fails = function()
    mock_author_env()
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("github-read-failed"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "github content read failed")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_content_ref_is_missing_after_preflight = function()
    local payload = live_payload("missing-content-ref")
    payload.content_ref = nil
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(payload, live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "missing content_ref")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_live_publish_blocks_when_tweet_publish_fails = function()
    mock_author_env()
    mock_content_issue(42, "tweet: publish failure branch")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = "",
      stderr = "publish failed",
      exit_code = 1,
    })

    local result = run_publish(live_payload("publish-failed"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid tweet publish failed")
  end,

  test_live_publish_blocks_when_tweet_response_has_no_id = function()
    mock_author_env()
    mock_content_issue(42, "tweet: invalid response branch")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("invalid-response"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "invalid nyxid tweet response")
  end,

  test_live_publish_skips_account_preflight_without_expected_username = function()
    local env_values = live_env()
    env_values.X_PUBLISH_EXPECTED_USERNAME = ""
    mock_author_env()
    mock_content_issue(42, "tweet: no expected username branch")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"2234567890123456789","text":"no expected username branch"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("no-expected-username"), env_values)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "published")
    t.is_nil(result.raises[1].payload.account_username)
    t.eq(count_calls("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET"), 0)
  end,

  test_live_publish_accepts_non_reserved_environment_names = function()
    mock_author_env()
    mock_content_issue(42, [[
type: weekly-content
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
]])
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for example_user via NyxID. Test post."}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-env",
      trace_id = "trace-1",
    }, {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      X_PUBLISH_EXPECTED_USERNAME = "example_user",
      ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "published")
    t.eq(receipt.platform_post_id, "1234567890123456789")
    t.eq(receipt.account_username, "example_user")
  end,

  test_live_publish_uses_nyxid_after_account_preflight_and_calendar_ref_resolution = function()
    mock_author_env()
    mock_content_issue(42, [[
type: weekly-content
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
]])
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for example_user via NyxID. Test post."}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-calendar",
      trace_id = "trace-1",
    }, {
      FKST_X_PUBLISH_WRITE = "1",
      FKST_NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      FKST_X_PUBLISH_EXPECTED_USERNAME = "example_user",
      ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "published")
    t.eq(receipt.platform_post_id, "1234567890123456789")
    t.eq(receipt.post_uri, "https://x.com/i/web/status/1234567890123456789")
    t.eq(receipt.account_username, "example_user")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET"), 1)
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,

  test_live_native_quote_requires_explicit_capability_gate = function()
    mock_author_env()
    mock_content_issue(42, [[
type: weekly-content
week: 2026-W32
operation: quote
quote-mode: native
quote-url: https://x.com/example/status/1234567890123456789
tweet: Native Quote capability check
]])
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("native-quote-gate"), live_env())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "native quote capability disabled")
    t.eq(result.raises[1].payload.quote_target_post_id, "1234567890123456789")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_live_native_quote_publishes_exact_body_once = function()
    local env_values = live_env()
    env_values.FKST_SESSION_PACKAGE_ENV_JSON =
      '{"x-publisher":{"FKST_X_PUBLISH_NATIVE_QUOTE":"1"}}'
    mock_author_env()
    mock_content_issue(42, [[
type: weekly-content
week: 2026-W32
operation: quote
quote-mode: native
quote-url: https://twitter.com/Example/status/1234567890123456789?source=fkst
tweet: Native Quote commentary
]])
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"2234567890123456789"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("native-quote"), env_values)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "published")
    t.eq(receipt.operation, "quote")
    t.eq(receipt.quote_mode, "native")
    t.eq(receipt.quote_target_uri, "https://x.com/example/status/1234567890123456789")
    t.eq(count_calls('"quote_tweet_id":"1234567890123456789"'), 1)
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,

  test_native_quote_provider_failure_does_not_fallback = function()
    local env_values = live_env()
    env_values.X_PUBLISH_NATIVE_QUOTE = "1"
    mock_author_env()
    mock_content_issue(42, [[
operation: quote
quote-mode: native
quote-url: https://x.com/example/status/1234567890123456789
tweet: No fallback commentary
]])
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"status":403,"title":"Forbidden"}',
      stderr = "Proxy request failed",
      exit_code = 1,
    })

    local result = run_publish(live_payload("native-quote-failure"), env_values)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid quote publish failed")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
    t.eq(count_calls("https://x.com/example/status/1234567890123456789"), 0)
  end,

  test_live_link_quote_appends_canonical_url_without_native_field = function()
    mock_author_env()
    mock_content_issue(42, [[
operation: quote
quote-mode: link
quote-url: https://twitter.com/Example/status/1234567890123456789?source=fkst
tweet: Link Quote commentary
]])
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"3234567890123456789"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish(live_payload("link-quote"), live_env())

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
    t.eq(count_calls("gh api repos/" .. repo .. "/issues/42"), 0)
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
    local payload = live_payload("fresh-runtime-sequence")
    local post_id = "2087115963800109098"
    mock_content_issue(42, "tweet: publish once before receipt persistence")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
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
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,

  test_live_publish_fails_closed_when_schedule_receipt_read_fails = function()
    local result = run_publish(live_payload("schedule-read-failed"), live_env(), {
      schedule_read_failure = true,
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "github publish receipt read failed")
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
    local payload = live_payload("forged-receipt")
    mock_content_issue(42, "tweet: forged receipt must not suppress this post")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
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
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,

  test_live_publish_does_not_trust_receipt_from_authorized_human = function()
    local payload = live_payload("authorized-human-forged-receipt")
    mock_content_issue(42, "tweet: an authorized human receipt must not suppress this post")
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
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
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,

  test_live_publish_duplicate_dedup_key_skips_second_post = function()
    local suffix = tostring(now())
    local runtime_root = "/tmp/fkst-marketing-test/x-publisher/live-once-" .. suffix
    local durable_root = "/tmp/fkst-marketing-test/x-publisher/live-once-durable-" .. suffix
    local dedup_key = "dedup-live-once-" .. suffix
    local function run_once()
      mock_author_env()
      mock_schedule_issue({})
      mock_content_issue(42, [[
type: weekly-content
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
]])
      mock_nyxid_cli_available()
      t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
        stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
        stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for example_user via NyxID. Test post."}}',
        stderr = "",
        exit_code = 0,
      })
      local env_values = {
        FKST_X_PUBLISH_WRITE = "1",
        FKST_NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
        FKST_X_PUBLISH_EXPECTED_USERNAME = "example_user",
        ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
      }
      t.mock_command('printf %s "$X_PUBLISH_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$FKST_X_PUBLISH_WRITE"', { stdout = env_values.FKST_X_PUBLISH_WRITE, stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$NYXID_X_SERVICE_SLUG"', { stdout = "", stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$FKST_NYXID_X_SERVICE_SLUG"', { stdout = env_values.FKST_NYXID_X_SERVICE_SLUG, stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$X_PUBLISH_EXPECTED_USERNAME"', { stdout = "", stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$FKST_X_PUBLISH_EXPECTED_USERNAME"', { stdout = env_values.FKST_X_PUBLISH_EXPECTED_USERNAME, stderr = "", exit_code = 0 })
      t.mock_command('if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi', { stdout = "1", stderr = "", exit_code = 0 })
      return t.run_department("departments/publish_x/main.lua", event({
        artifact_id = "artifact-once",
        source_ref = { kind = "external", ref = repo .. "#issue/43" },
        content_ref = "#42",
        platform = "x",
        channel = "live",
        dedup_key = dedup_key,
        trace_id = "trace-once",
      }), {
        env = {
          FKST_RUNTIME_ROOT = runtime_root,
          FKST_DURABLE_ROOT = durable_root,
        },
      })
    end

    local first = run_once()
    local second = run_once()

    t.eq(first.exit_code, 0)
    t.eq(second.exit_code, 0)
    t.eq(first.raises[1].payload.status, "published")
    t.eq(second.raises[1].payload.status, "skipped")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,
}
