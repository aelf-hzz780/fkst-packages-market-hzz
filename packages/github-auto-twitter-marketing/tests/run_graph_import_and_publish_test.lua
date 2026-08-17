local graph = require("testkit.graph")
local marketing_content = require("contract.marketing_content")
local t = fkst.test

local repo = "owner/repo"
local account = "test_primary"
local logical_label = "auto-x-test-primary"
local effective_label = "auto-x-test-primary-ci"
local creator = "test-maintainer"
local scheduled_at = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(now()) - 60)

local function source_ref(number)
  local ref = repo .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function json_escape(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
end

local function issue_json(number, body, state)
  return string.format(
    '{"number":%d,"title":"Marketing %d","body":"%s","html_url":"https://github.example/%s/issues/%d",'
      .. '"updated_at":"2026-08-17T00:00:00Z","state":"%s",'
      .. '"labels":[{"name":"%s"}],"assignees":[{"login":"%s"}],'
      .. '"user":{"login":"fkst-test-bot"}}\n',
    number,
    number,
    json_escape(body),
    repo,
    number,
    state or "open",
    effective_label,
    creator
  )
end

local function mock_issue(number, body, state, count)
  for _ = 1, count or 1 do
    t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(number), {
      stdout = issue_json(number, body, state), stderr = "", exit_code = 0,
    })
    t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. tostring(number)
      .. "/comments?per_page=100'", {
      stdout = "[]\n", stderr = "", exit_code = 0,
    })
  end
end

local function mock_env(options)
  local opts = options or {}
  local values = {
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot",
    FKST_GITHUB_AUTHORIZED_LOGINS = "fkst-test-bot",
    FKST_MARKETING_COLLABORATOR_LOGINS = "",
    FKST_GITHUB_WRITE = opts.github_write and "1" or "",
    FKST_SESSION_CREATOR = creator,
    FKST_SESSION_WORK_LABEL = effective_label,
    FKST_SESSION_WORK_LABEL_MAP_JSON = '{"' .. logical_label .. '":"' .. effective_label .. '"}',
    X_PUBLISH_EXPECTED_USERNAME = account,
    FKST_X_PUBLISH_EXPECTED_USERNAME = "",
    X_PUBLISH_WRITE = opts.x_write and "1" or "",
    FKST_X_PUBLISH_WRITE = "",
    NYXID_X_SERVICE_SLUG = opts.nyxid_x_service or "",
    FKST_NYXID_X_SERVICE_SLUG = "",
    X_PUBLISH_NATIVE_QUOTE = "",
    FKST_X_PUBLISH_NATIVE_QUOTE = "",
  }
  for _ = 1, 24 do
    for name, value in pairs(values) do
      t.mock_command('printf %s "$' .. name .. '"', {
        stdout = value, stderr = "", exit_code = 0,
      })
    end
    t.mock_command('if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi', {
      stdout = opts.nyxid_access_token and "1" or "0", stderr = "", exit_code = 0,
    })
  end
end

local function approved_content()
  return marketing_content.render({
    project = "test-project",
    account = account,
    work_label = logical_label,
    week = "2026-W33",
    content_id = "test-primary-w33-content-1",
    content_revision = 1,
    proposal_id = "test-primary-w33-proposal",
    proposal_revision = 2,
    approval_id = "test-primary-w33-proposal@2",
    content_status = "approved",
    tweet_text = "A reviewed test post.",
  })
end

local function schedule_body(digest, mode, content_number)
  return table.concat({
    "contract: auto-twitter-marketing.schedule-publish.v2",
    "type: schedule-publish",
    "project: test-project",
    "account: " .. account,
    "work-label: " .. logical_label,
    "week: 2026-W33",
    "content-ref: #" .. tostring(content_number or 42),
    "content-digest: " .. digest,
    "approval-id: test-primary-w33-proposal@2",
    "mode: " .. tostring(mode or "shadow"),
    "scheduled-at: " .. scheduled_at,
  }, "\n")
end

local function issue_event(number)
  return {
    queue = "github-proxy.github_issue_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = number,
      state = "OPEN",
      labels = { effective_label },
      assignees = { creator },
      updated_at = "2026-08-17T00:00:00Z",
      source_ref = source_ref(number),
    },
    source_ref = source_ref(number),
  }
end

local function count_command(fragment)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    local rendered = tostring(call.rendered or call.command or call.cmd or "")
    if rendered:find(fragment, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

return {
  test_due_v2_schedule_crosses_x_queue_and_produces_preview_without_provider_write = function()
    local content_body, digest = approved_content()
    local body = schedule_body(digest)
    mock_env()
    mock_issue(43, body, "open", 8)
    mock_issue(42, content_body, "closed", 8)

    local covers = {
      "github-proxy.github_issue_changed -> github-auto-twitter-marketing.import_issue",
      "x-publisher.x_publish_request -> x-publisher.publish_x",
      "x-publisher.x_published -> github-auto-twitter-marketing.optional_receipt_sink",
    }
    local trace = graph.require_quiescent(graph.run(issue_event(43), {
      covers = covers,
      max_steps = 30,
    }))
    graph.assert_covers(trace, covers)
    local request = graph.require_raise(trace, "x-publisher.x_publish_request")
    t.eq(request.payload.schema, "x-publisher.publish-request.v2")
    t.eq(request.payload.account, account)
    t.eq(request.payload.content_digest, digest)
    local receipt = graph.require_raise(trace, "x-publisher.x_published")
    t.eq(receipt.payload.schema, "x-publisher.publish-receipt.v2")
    t.eq(receipt.payload.status, "preview")
    t.eq(count_command("/tweets"), 0)
  end,

  test_weekly_content_import_routes_through_sink_to_durable_comment_request = function()
    local body, digest = approved_content()
    mock_env()
    mock_issue(42, body, "open", 6)

    local covers = {
      "github-proxy.github_issue_changed -> github-auto-twitter-marketing.import_issue",
      "github-auto-twitter-marketing.weekly_content_imported -> github-auto-twitter-marketing.weekly_content_sink",
      "github-proxy.github_issue_comment_request -> github-proxy.github_comment",
    }
    local trace = graph.require_quiescent(graph.run(issue_event(42), {
      covers = covers,
      max_steps = 20,
    }))
    graph.assert_covers(trace, covers)
    local imported = graph.require_raise(trace, "github-auto-twitter-marketing.weekly_content_imported")
    t.eq(imported.payload.schema, "auto-twitter-marketing.weekly-content-imported.v2")
    t.eq(imported.payload.content_digest, digest)
    local comment = graph.require_raise(trace, "github-proxy.github_issue_comment_request", function(raised)
      return raised.payload.handoff ~= nil
    end)
    t.eq(comment.payload.handoff.schema, "auto-twitter-marketing.weekly-content-close.v2")
    t.eq(comment.payload.handoff.account, account)
  end,
}
