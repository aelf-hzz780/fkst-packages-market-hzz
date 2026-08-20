local core = require("core")
local graph = require("testkit.graph")
local t = fkst.test

local repo = "owner/repo"
local logical_label = "auto-x-test-primary"
local effective_label = "auto-x-test-primary-ci"
local creator = "test-operator"
local account = "test_primary"

local function source_ref(number)
  local ref = repo .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function session()
  return {
    effective_work_label = effective_label,
    logical_work_label = logical_label,
    creator = creator,
    account = account,
  }
end

local function json_escape(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
end

local function proposal_body()
  local signal_body = table.concat({
    "contract: marketing-radar.radar-signal.v2",
    "type: radar-signal",
    "project: chronoai",
    "account: " .. account,
    "work-label: " .. logical_label,
    "week: 2026-W33",
    "action: add",
    "topic: publishing-gap",
    "insight: Use the cited COO evidence in a reviewed draft.",
  }, "\n")
  local signal = assert(core.classify_issue({
    schema = "github-proxy.v1",
    type = "issue",
    repo = repo,
    number = 116,
    labels = { effective_label },
    assignees = { creator },
    source_ref = source_ref(116),
  }, {
    session = session(),
    issue_body = signal_body,
    issue_labels = { effective_label },
    issue_assignees = { creator },
    issue_author_login = creator,
    authorized_signal_authors = { creator },
  }))
  local proposal = assert(core.build_proposal({ signal }, session(), {
    revision = 1,
    action = "add",
    evidence_refs = { signal.source_ref.ref },
    tweet_text = "A reviewed weekly update is ready for explicit scheduling approval.",
  }))
  local request = assert(core.weekly_plan_change_issue_request(proposal, session(), 1))
  return request.body .. "\n\n<!-- fkst:github-proxy:issue-create:"
    .. request.dedup_key .. " -->"
end

local function issue_json(number, body)
  return string.format(
    '{"number":%d,"title":"Weekly plan review","body":"%s",'
      .. '"html_url":"https://github.example/%s/issues/%d",'
      .. '"updated_at":"2026-08-20T00:00:00Z","state":"open",'
      .. '"labels":[{"name":"%s"}],"assignees":[{"login":"%s"}],'
      .. '"user":{"login":"fkst-test-bot"}}\n',
    number, json_escape(body), repo, number, effective_label, creator)
end

local function mock_issue(number, body)
  for _ = 1, 16 do
    t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(number), {
      stdout = issue_json(number, body), stderr = "", exit_code = 0,
    })
    t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/"
      .. tostring(number) .. "/comments?per_page=100'", {
      stdout = "[]\n", stderr = "", exit_code = 0,
    })
  end
end

local function mock_env()
  local values = {
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot",
    FKST_GITHUB_AUTHORIZED_LOGINS = "fkst-test-bot",
    FKST_MARKETING_COLLABORATOR_LOGINS = "",
    FKST_GITHUB_WRITE = "",
    FKST_SESSION_CREATOR = creator,
    FKST_SESSION_WORK_LABEL = effective_label,
    FKST_SESSION_WORK_LABEL_MAP_JSON = '{"' .. logical_label .. '":"' .. effective_label .. '"}',
    X_PUBLISH_EXPECTED_USERNAME = account,
    FKST_X_PUBLISH_EXPECTED_USERNAME = "",
    X_PUBLISH_WRITE = "1",
    FKST_X_PUBLISH_WRITE = "",
    NYXID_X_SERVICE_SLUG = "test-x-service",
    FKST_NYXID_X_SERVICE_SLUG = "",
    X_PUBLISH_NATIVE_QUOTE = "",
    FKST_X_PUBLISH_NATIVE_QUOTE = "",
  }
  for _ = 1, 32 do
    for name, value in pairs(values) do
      t.mock_command('printf %s "$' .. name .. '"', {
        stdout = value, stderr = "", exit_code = 0,
      })
    end
    t.mock_command('if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi', {
      stdout = "1", stderr = "", exit_code = 0,
    })
  end
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
      source_ref = source_ref(number),
    },
    source_ref = source_ref(number),
  }
end

local function count_command(fragment)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    local rendered = tostring(call.rendered or call.command or call.cmd or "")
    if rendered:find(fragment, 1, true) ~= nil then count = count + 1 end
  end
  return count
end

return {
  test_materialized_review_is_quiescent_with_live_x_write_enabled = function()
    local number = 910
    mock_env()
    mock_issue(number, proposal_body())
    local trace = graph.require_quiescent(graph.run(issue_event(number), { max_steps = 30 }))

    graph.require_delivery(trace, {
      queue = "github-proxy.github_issue_changed",
      consumer = "marketing-radar.import_issue",
    })
    t.is_nil(graph.find_raise(trace, "x-publisher.x_publish_request"))
    t.is_nil(graph.find_raise(trace, "x-publisher.x_published"))
    t.eq(count_command("/tweets"), 0)
  end,
}
