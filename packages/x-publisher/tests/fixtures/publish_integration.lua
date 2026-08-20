local t = fkst.test
local v2 = require("tests.fixtures.v2_publish")

local repo = "owner/repo"
local run_counter = 0
local process_token = tostring({}):gsub("[^%w]", "")
local prepare_github_live_read
local fixture_by_dedup_key = {}

local function unique_root(label)
  run_counter = run_counter + 1
  return "/tmp/fkst-marketing-test/x-publisher/" .. tostring(label)
    .. "-" .. process_token .. "-" .. tostring(now()) .. "-" .. tostring(run_counter)
end

local function event(payload)
  return {
    queue = "x_publish_request",
    payload = payload,
  }
end

local function mock_content_issue(issue_number, content, options)
  local opts = options or {}
  t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(issue_number), {
    stdout = v2.issue_rest_json(repo, issue_number, content.body, {
      state = opts.state or "closed",
      labels = opts.labels,
      assignees = opts.assignees,
      author_login = opts.author_login,
    }),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. tostring(issue_number) .. "/comments?per_page=100'", {
    stdout = v2.comments_rest_json(opts.comments or {}),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_schedule_issue(payload, comments, options, comments_read_failure)
  local opts = options or {}
  t.mock_command("gh api repos/" .. repo .. "/issues/43", {
    stdout = v2.issue_rest_json(repo, 43, v2.schedule_body(payload, opts.schedule), {
      state = opts.state or "open",
      labels = opts.labels,
      assignees = opts.assignees,
      author_login = opts.author_login,
    }),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/43/comments?per_page=100'", {
    stdout = comments_read_failure and "" or v2.comments_rest_json(comments),
    stderr = comments_read_failure and "schedule comments unavailable" or "",
    exit_code = comments_read_failure and 1 or 0,
  })
end

local function published_receipt_comment(dedup_key, post_id, author_login)
  local payload = assert(fixture_by_dedup_key[dedup_key] and fixture_by_dedup_key[dedup_key].payload)
  return v2.receipt_comment(payload, post_id, author_login)
end

prepare_github_live_read = function(opts, payload)
  v2.mock_author_env(t, opts)
  mock_schedule_issue(
    payload,
    opts.schedule_comments or {},
    opts.schedule_issue,
    opts.schedule_read_failure
  )
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

local function live_payload(suffix, content_options, payload_overrides)
  local content = v2.content(content_options)
  local payload = v2.payload("integration-" .. tostring(suffix), content, payload_overrides)
  fixture_by_dedup_key[payload.dedup_key] = { payload = payload, content = content }
  return payload
end

local function live_env()
  return {
    X_PUBLISH_WRITE = "1",
    NYXID_X_SERVICE_SLUG = v2.SERVICE_SLUG,
    X_PUBLISH_EXPECTED_USERNAME = v2.ACCOUNT,
    ["NYXID_ACCESS_TOKEN"] = "present",
  }
end

local function run_publish(payload, env, opts)
  local env_values = env or {}
  local options = opts or {}
  local fixture = fixture_by_dedup_key[payload.dedup_key]
  local content = fixture and fixture.content or options.content
  if payload.content_ref ~= nil and payload.content_digest ~= nil then
    prepare_github_live_read(options, payload)
    if content ~= nil and not options.content_read_failure then
      mock_content_issue(42, content, options.content_issue)
    end
  end
  local expected_username = env_values.X_PUBLISH_EXPECTED_USERNAME
  if expected_username == nil and env_values.FKST_X_PUBLISH_EXPECTED_USERNAME == nil then
    expected_username = v2.ACCOUNT
  end
  local values = {
    X_PUBLISH_WRITE = env_values.X_PUBLISH_WRITE,
    FKST_X_PUBLISH_WRITE = env_values.FKST_X_PUBLISH_WRITE,
    NYXID_X_SERVICE_SLUG = env_values.NYXID_X_SERVICE_SLUG,
    FKST_NYXID_X_SERVICE_SLUG = env_values.FKST_NYXID_X_SERVICE_SLUG,
    X_PUBLISH_EXPECTED_USERNAME = expected_username,
    FKST_X_PUBLISH_EXPECTED_USERNAME = env_values.FKST_X_PUBLISH_EXPECTED_USERNAME,
    X_PUBLISH_NATIVE_QUOTE = env_values.X_PUBLISH_NATIVE_QUOTE,
    FKST_X_PUBLISH_NATIVE_QUOTE = env_values.FKST_X_PUBLISH_NATIVE_QUOTE,
    FKST_SESSION_PACKAGE_ENV_JSON = env_values.FKST_SESSION_PACKAGE_ENV_JSON,
    FKST_SESSION_CREATOR = env_values.FKST_SESSION_CREATOR or v2.CREATOR,
    FKST_SESSION_WORK_LABEL = env_values.FKST_SESSION_WORK_LABEL or v2.EFFECTIVE_LABEL,
    FKST_SESSION_WORK_LABEL_MAP_JSON = env_values.FKST_SESSION_WORK_LABEL_MAP_JSON
      or v2.WORK_LABEL_MAP_JSON,
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
    "FKST_SESSION_CREATOR",
    "FKST_SESSION_WORK_LABEL",
    "FKST_SESSION_WORK_LABEL_MAP_JSON",
  }) do
    t.mock_command('printf %s "$' .. name .. '"', {
      stdout = values[name] or "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _, name in ipairs({
    "X_PUBLISH_EXPECTED_USERNAME",
    "FKST_X_PUBLISH_EXPECTED_USERNAME",
  }) do
    t.mock_command('printf %s "$' .. name .. '"', {
      stdout = values[name] or "",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command('if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi', {
    stdout = env_values.NYXID_ACCESS_TOKEN and "1" or "0",
    stderr = "",
    exit_code = 0,
  })
  return t.run_department("departments/publish_x/main.lua", event(payload), {
    env = {
      FKST_RUNTIME_ROOT = options.runtime_root or unique_root("preview-rt"),
      FKST_DURABLE_ROOT = options.durable_root or unique_root("preview-durable"),
    },
  })
end

return {
  repo = repo,
  published_receipt_comment = published_receipt_comment,
  mock_nyxid_cli_available = mock_nyxid_cli_available,
  count_calls = count_calls,
  live_payload = live_payload,
  live_env = live_env,
  run_publish = run_publish,
}
