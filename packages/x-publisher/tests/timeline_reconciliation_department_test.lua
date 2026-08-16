local t = fkst.test
local timeline = require("x_timeline_reconciliation")

local repo = "owner/repo"
local account_id = "100000000000000001"
local suite_now = math.floor(now())
local scheduled_at = os.date("!%Y-%m-%dT%H:%M:%SZ", suite_now - 3600)
local timeline_created_at = os.date("!%Y-%m-%dT%H:%M:%S.000Z", suite_now - 1800)
local first_path = assert(timeline.timeline_path(account_id, scheduled_at))
local run_counter = 0
local suite_id = tostring(now())

local function json_escape(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
end

local function issue_json(number, body)
  return string.format(
    '{"number":%d,"title":"Issue %d","body":"%s","html_url":"https://github.example/%s/issues/%d","updated_at":"2026-08-15T00:00:00Z","state":"open","labels":[{"name":"auto-twitter-marketing"}],"assignees":[],"user":{"login":"fkst-test-bot"}}\n',
    number,
    number,
    json_escape(body),
    repo,
    number
  )
end

local function mock_environment()
  local values = {
    X_PUBLISH_WRITE = "1",
    NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
    X_PUBLISH_EXPECTED_USERNAME = "example_user",
  }
  for _, name in ipairs({
    "X_PUBLISH_WRITE",
    "FKST_X_PUBLISH_WRITE",
    "NYXID_X_SERVICE_SLUG",
    "FKST_NYXID_X_SERVICE_SLUG",
    "X_PUBLISH_EXPECTED_USERNAME",
    "FKST_X_PUBLISH_EXPECTED_USERNAME",
    "X_PUBLISH_NATIVE_QUOTE",
    "FKST_X_PUBLISH_NATIVE_QUOTE",
    "FKST_SESSION_PACKAGE_ENV_JSON",
  }) do
    t.mock_command('printf %s "$' .. name .. '"', {
      stdout = values[name] or "",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command('if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi', {
    stdout = "1",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_MANAGED_BOT_LOGINS"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_AUTHORIZED_LOGINS"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_github(tweet_text)
  t.mock_command("gh api repos/" .. repo .. "/issues/43", {
    stdout = issue_json(43, "type: schedule-publish"),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/43/comments?per_page=100'", {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api repos/" .. repo .. "/issues/42", {
    stdout = issue_json(42, "tweet: " .. tweet_text),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/42/comments?per_page=100'", {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_account()
  t.mock_command("nyxid --version", {
    stdout = "nyxid 0.8.0\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
    stdout = '{"data":{"id":"' .. account_id
      .. '","name":"Example User","username":"example_user"}}',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_timeline(path, response, exit_code)
  t.mock_command("nyxid proxy request api-twitter-2-media '" .. path .. "' -m GET", {
    stdout = response or "",
    stderr = exit_code == 0 and "" or "timeline read failed",
    exit_code = exit_code,
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

local function payload(suffix)
  return {
    artifact_id = "artifact-reconcile-" .. suffix,
    source_ref = { kind = "external", ref = repo .. "#issue/43" },
    content_ref = "#42",
    platform = "x",
    channel = "live",
    dedup_key = "dedup-reconcile-" .. suffix,
    trace_id = "trace-reconcile-" .. suffix,
    scheduled_at = scheduled_at,
    metadata = { schedule_type = "one-shot" },
  }
end

local function run_publish(suffix, tweet_text)
  run_counter = run_counter + 1
  mock_environment()
  mock_github(tweet_text)
  mock_account()
  return t.run_department("departments/publish_x/main.lua", {
    queue = "x_publish_request",
    payload = payload(suffix),
  }, {
    env = {
      FKST_RUNTIME_ROOT = "/tmp/fkst-marketing-test/x-reconcile/runtime-"
        .. suite_id .. "-" .. run_counter,
      FKST_DURABLE_ROOT = "/tmp/fkst-marketing-test/x-reconcile/durable-"
        .. suite_id .. "-" .. run_counter,
    },
  })
end

local function timeline_post(id, text)
  return '{"id":"' .. id .. '","text":"' .. json_escape(text)
    .. '","created_at":"' .. timeline_created_at .. '"}'
end

return {
  test_unique_timeline_match_recovers_receipt_without_post = function()
    local text = "already published before receipt persistence"
    local post_id = "2088000000000000001"
    mock_timeline(first_path, '{"data":[' .. timeline_post(post_id, text)
      .. '],"meta":{"result_count":1}}', 0)

    local result = run_publish("unique", text)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.status, "published")
    t.eq(result.raises[1].payload.platform_post_id, post_id)
    t.eq(result.raises[1].payload.account_username, "example_user")
    t.eq(result.raises[1].payload.scheduled_at, scheduled_at)
    t.eq(result.raises[1].payload.metadata.schedule_type, "one-shot")
    t.eq(count_calls("/users/" .. account_id .. "/tweets"), 1)
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_empty_timeline_continues_to_single_provider_post = function()
    local text = "not published yet"
    local post_id = "2088000000000000002"
    mock_timeline(first_path, '{"meta":{"result_count":0}}', 0)
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"' .. post_id .. '"}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish("empty", text)

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "published")
    t.eq(result.raises[1].payload.platform_post_id, post_id)
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,

  test_ambiguous_timeline_matches_fail_closed = function()
    local text = "legitimately repeated text"
    mock_timeline(first_path, '{"data":['
      .. timeline_post("2088000000000000003", text) .. ','
      .. timeline_post("2088000000000000004", text)
      .. '],"meta":{"result_count":2}}', 0)

    local result = run_publish("ambiguous", text)

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "ambiguous X timeline publish match")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_timeline_read_failure_fails_closed = function()
    mock_timeline(first_path, "", 1)

    local result = run_publish("read-failed", "timeline must be available")

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid timeline reconciliation failed")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_problem_json_with_zero_exit_fails_closed = function()
    mock_timeline(first_path, '{"status":503,"title":"Service Unavailable"}', 0)

    local result = run_publish("problem-json", "provider problem must not trigger a post")

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "invalid X timeline reconciliation response")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_reconciliation_scans_all_pages_before_recovering = function()
    local text = "match on a paginated timeline"
    local post_id = "2088000000000000005"
    local second_path = assert(timeline.timeline_path(account_id, scheduled_at, "page-two"))
    mock_timeline(first_path, '{"data":[' .. timeline_post(post_id, text)
      .. '],"meta":{"result_count":1,"next_token":"page-two"}}', 0)
    mock_timeline(second_path, '{"meta":{"result_count":0}}', 0)

    local result = run_publish("paginated", text)

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "published")
    t.eq(result.raises[1].payload.platform_post_id, post_id)
    t.eq(count_calls("/users/" .. account_id .. "/tweets"), 2)
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,

  test_reconciliation_fails_closed_when_five_pages_are_not_terminal = function()
    local path = first_path
    for page = 1, timeline.max_timeline_pages() do
      local next_token = "page-" .. tostring(page + 1)
      mock_timeline(path, '{"meta":{"result_count":0,"next_token":"'
        .. next_token .. '"}}', 0)
      path = assert(timeline.timeline_path(account_id, scheduled_at, next_token))
    end

    local result = run_publish("page-limit", "must inspect a complete bounded timeline")

    t.eq(result.exit_code, 0)
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "incomplete X timeline reconciliation")
    t.eq(count_calls("/users/" .. account_id .. "/tweets"), timeline.max_timeline_pages())
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 0)
  end,
}
