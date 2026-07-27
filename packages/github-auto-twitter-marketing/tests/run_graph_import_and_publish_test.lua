local graph = require("testkit.graph")
local t = fkst.test

local repo = "owner/repo"

local function source_ref(issue_number)
  local reference = repo .. "#issue/" .. tostring(issue_number)
  return {
    kind = "external",
    ref = reference,
    reference = reference,
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

local function issue_rest_json(issue_number, body)
  return string.format(
    '{"number":%d,"title":"Auto Twitter marketing %d","body":"%s","html_url":"https://github.example/%s/issues/%d","updated_at":"2026-07-24T09:00:00Z","state":"open","labels":[{"name":"auto-twitter-marketing"}],"assignees":[],"user":{"login":"fkst-test-bot"}}\n',
    issue_number,
    issue_number,
    json_escape(body),
    repo,
    issue_number
  )
end

local function mock_env(opts)
  local options = opts or {}
  local write_value = options.live == true and "1" or ""
  local service_value = options.live == true and "api-twitter-2-media" or ""
  local username_value = options.live == true and "hzz780" or ""
  for _ = 1, 8 do
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
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_X_PUBLISH_WRITE"', {
      stdout = write_value,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_NYXID_X_SERVICE_SLUG"', {
      stdout = service_value,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_X_PUBLISH_EXPECTED_USERNAME"', {
      stdout = username_value,
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_issue_read(issue_number, body)
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

local function issue_event(issue_number)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Auto Twitter marketing " .. tostring(issue_number),
      url = "https://github.example/" .. repo .. "/issues/" .. tostring(issue_number),
      state = "OPEN",
      labels = { "auto-twitter-marketing" },
      updated_at = "2026-07-24T09:00:0" .. tostring(issue_number % 10) .. "Z",
      source_ref = source_ref(issue_number),
      dedup_key = repo .. "#issue#" .. tostring(issue_number) .. "@2026-07-24T09:00:00Z",
    },
    source_ref = {
      kind = "external",
      reference = repo .. "#issue/" .. tostring(issue_number),
    },
  }
end

local function run_issue(issue_number, body)
  mock_env()
  mock_issue_read(issue_number, body)
  return graph.require_quiescent(graph.run(issue_event(issue_number), { max_steps = 8 }))
end

return {
  test_strategy_issue_imports_strategy_and_comments_receipt = function()
    local trace = run_issue(41, [[
type: strategy
project: chronoai
account: main
]])

    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> github-auto-twitter-marketing.import_issue",
    })

    local imported = graph.require_raise(trace, "github-auto-twitter-marketing.strategy_imported")
    t.eq(imported.payload.schema, "auto-twitter-marketing.strategy-imported.v1")
    t.eq(imported.payload.project, "chronoai")
    t.eq(imported.payload.account, "main")
    t.eq(imported.payload.source_ref.ref, repo .. "#issue/41")

    local comment = graph.require_raise(trace, "github-proxy.github_issue_comment_request")
    t.eq(comment.payload.issue_number, 41)
    t.is_true(comment.payload.body:find("strategy imported", 1, true) ~= nil)
  end,

  test_weekly_content_issue_imports_weekly_content = function()
    local trace = run_issue(42, [[
type: weekly-content
project: chronoai
week: 2026-W31
strategy-ref: #41
]])

    local imported = graph.require_raise(trace, "github-auto-twitter-marketing.weekly_content_imported")
    t.eq(imported.payload.schema, "auto-twitter-marketing.weekly-content-imported.v1")
    t.eq(imported.payload.project, "chronoai")
    t.eq(imported.payload.week, "2026-W31")
    t.eq(imported.payload.strategy_ref, "#41")
    t.eq(imported.payload.source_ref.ref, repo .. "#issue/42")
  end,

  test_schedule_publish_issue_flows_to_x_preview = function()
    local trace = run_issue(43, [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #42
mode: shadow
scheduled-at: 2026-07-25T09:00:00Z
]])

    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> github-auto-twitter-marketing.import_issue",
      "x-publisher.x_publish_request -> x-publisher.publish_x",
    })

    local request = graph.require_raise(trace, "x-publisher.x_publish_request")
    t.eq(request.payload.platform, "x")
    t.eq(request.payload.channel, "shadow")
    t.eq(request.payload.content_ref, "#42")
    t.eq(request.payload.source_ref.ref, repo .. "#issue/43")
    t.eq(request.payload.scheduled_at, "2026-07-25T09:00:00Z")

    local receipt = graph.require_raise(trace, "x-publisher.x_published")
    t.eq(receipt.payload.status, "preview")
    t.eq(receipt.payload.platform, "x")
    t.eq(receipt.payload.source_ref.ref, repo .. "#issue/43")
  end,

  test_live_schedule_publish_issue_flows_to_x_publisher_live_request = function()
    mock_env({ live = true })
    mock_issue_read(44, [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #42
mode: live
scheduled-at: 2026-07-25T09:00:00Z
]])
    mock_issue_read(42, [[
type: weekly-content
project: chronoai
week: 2026-W31

tweet-text:
```
FKST live publish verification for hzz780 via NyxID. Test post.
```
]])
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"955688313951698945","name":"黄宗哲","username":"hzz780"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"2071886153800929439","text":"FKST live publish verification for hzz780 via NyxID. Test post."}}',
      stderr = "",
      exit_code = 0,
    })

    local trace = graph.require_quiescent(graph.run(issue_event(44), { max_steps = 10 }))

    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> github-auto-twitter-marketing.import_issue",
      "x-publisher.x_publish_request -> x-publisher.publish_x",
    })

    local request = graph.require_raise(trace, "x-publisher.x_publish_request")
    t.eq(request.payload.channel, "live")
    t.eq(request.payload.content_ref, "#42")
    t.eq(request.payload.metadata.variant, "live")

    local receipt = graph.require_raise(trace, "x-publisher.x_published")
    t.eq(receipt.payload.status, "published")
    t.eq(receipt.payload.platform_post_id, "2071886153800929439")
    t.eq(receipt.payload.account_username, "hzz780")
  end,
}
