local conformance = require("testkit.namespaced_dispatch_conformance")
local github_fake = require("forge.github_fake")
local t = fkst.test
local account = "test_primary"
local logical_label = "auto-x-test-primary"
local effective_label = "auto-x-test-primary-example-fkst"
local creator = "test-owner"
local digest = "sha256:" .. string.rep("a", 64)

local function mock_import_env()
  local values = {
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_SESSION_CREATOR = creator,
    FKST_SESSION_WORK_LABEL = effective_label,
    FKST_SESSION_WORK_LABEL_MAP_JSON = '{"' .. logical_label .. '":"' .. effective_label .. '"}',
    FKST_X_PUBLISH_EXPECTED_USERNAME = "",
    X_PUBLISH_EXPECTED_USERNAME = account,
  }
  for _ = 1, 2 do
    for name, value in pairs(values) do
      t.mock_command('printf %s "$' .. name .. '"', {
        stdout = value,
        stderr = "",
        exit_code = 0,
      })
    end
  end
  for _ = 1, 2 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = values.FKST_GITHUB_BOT_LOGIN,
      stderr = "",
      exit_code = 0,
    })
  end
end

local function source_ref()
  local reference = "owner/repo#issue/42"
  return {
    kind = "external",
    ref = reference,
    reference = reference,
  }
end

local function event_payload()
  return {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    title = "Auto Twitter marketing",
    state = "OPEN",
    labels = { effective_label },
    assignees = { creator },
    updated_at = "2026-07-24T09:00:00Z",
    source_ref = source_ref(),
    dedup_key = "owner/repo#issue#42@2026-07-24T09:00:00Z",
  }
end

local function github()
  local model = github_fake.model({
    issues = {
      ["owner/repo#issue/42"] = {
        number = 42,
        title = "Auto Twitter marketing",
        body = "type: strategy\nproject: chronoai\naccount: " .. account
          .. "\nwork-label: " .. logical_label .. "\n",
        updatedAt = "2026-07-24T09:00:00Z",
        state = "OPEN",
        labels = { effective_label },
        assignees = { creator },
        comments = {},
        author = { login = "fkst-test-bot" },
      },
    },
  })
  return github_fake.new(model)
end

local function load_department()
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  return {
    path = "departments/import_issue/main.lua",
    module = module.make_department({
      github = github(),
      session_authority = function()
        return {
          effective_work_label = effective_label,
          logical_work_label = logical_label,
          creator = creator,
          account = account,
        }
      end,
      live_options = function() return {} end,
      once = function(_key, fn) fn() return true end,
    }),
  }
end

local function load_sink_department(name)
  local module = require("departments." .. name .. ".main")
  return {
    path = "departments/" .. name .. "/main.lua",
    module = module,
  }
end

local function load_terminalizer_department()
  local old_pipeline = pipeline
  local module = require("departments.one_shot_terminalizer.main")
  pipeline = old_pipeline
  return {
    path = "departments/one_shot_terminalizer/main.lua",
    module = module.make_department({
      github = github(),
      github_write_enabled = function()
        return false
      end,
      session_authority = function()
        return {
          effective_work_label = effective_label,
          logical_work_label = logical_label,
          creator = creator,
          account = account,
        }
      end,
      with_lock = function(_key, fn)
        return fn()
      end,
    }),
  }
end

local departments = conformance.loaded_departments({
  load_department(),
  load_sink_department("optional_receipt_sink"),
  load_terminalizer_department(),
  load_sink_department("strategy_import_sink"),
  load_sink_department("weekly_content_sink"),
})

local function contains(values, needle)
  for _, value in ipairs(values or {}) do
    if value == needle then
      return true
    end
  end
  return false
end

local function payload_for_queue(_path, queue)
  if queue == "github-proxy.github_comment_written" then
    return {
      schema = "github-proxy.comment-written.v1",
      comment_id = "comment-1",
      source_ref = source_ref(),
      dedup_key = "github-comment-written/1",
    }
  end
  if queue == "x-publisher.x_published" then
    return {
      schema = "x-publisher.publish-receipt.v2",
      artifact_id = "auto-twitter-marketing/test_primary/chronoai/2026-W33/schedule",
      status = "published",
      account = account,
      authenticated_account = account,
      work_label = logical_label,
      content_digest = digest,
      approval_id = "proposal-w33@1",
      source_ref = source_ref(),
      dedup_key = "x-published/1",
    }
  end
  if queue == "strategy_imported" or queue == "github-auto-twitter-marketing.strategy_imported" then
    return {
      schema = "auto-twitter-marketing.strategy-imported.v2",
      artifact_id = "auto-twitter-marketing/test_primary/chronoai/strategy",
      project = "chronoai",
      account = account,
      work_label = logical_label,
      source_ref = source_ref(),
      dedup_key = "owner/repo#issue#42@2026-07-24T09:00:00Z",
    }
  end
  if queue == "weekly_content_imported" or queue == "github-auto-twitter-marketing.weekly_content_imported" then
    return {
      schema = "auto-twitter-marketing.weekly-content-imported.v2",
      artifact_id = "auto-twitter-marketing/test_primary/chronoai/2026-W33/weekly-content/content-1",
      project = "chronoai",
      account = account,
      work_label = logical_label,
      week = "2026-W33",
      content_id = "content-1",
      content_revision = 1,
      content_digest = digest,
      approval_id = "proposal-w33@1",
      trace_id = "trace-content-1",
      source_ref = source_ref(),
      dedup_key = "owner/repo#issue#43@2026-07-24T09:00:00Z",
    }
  end
  if queue ~= "github-proxy.github_issue_changed" and queue ~= "github-proxy.github_issue_observed" then
    error("github-auto-twitter-marketing: no fixture for queue " .. tostring(queue))
  end
  local payload = event_payload()
  if queue == "github-proxy.github_issue_observed" then
    payload.schema = "github-proxy.issue-observed.v1"
    payload.labels = nil
    payload.title = nil
  end
  return payload
end

return {
  test_import_issue_declares_observed_resync_as_fanout = function()
    local import_issue = departments["departments/import_issue/main.lua"]
    t.is_true(contains(import_issue.spec.fanout, "github-proxy.github_issue_changed"))
    t.is_true(contains(import_issue.spec.fanout, "github-proxy.github_issue_observed"))
  end,

  test_terminalizer_declares_comment_ack_as_fanout = function()
    local terminalizer = departments["departments/one_shot_terminalizer/main.lua"]
    t.is_true(contains(terminalizer.spec.fanout, "github-proxy.github_comment_written"))
  end,

  test_all_departments_accept_production_namespaced_consumed_queues = function()
    mock_import_env()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "github-auto-twitter-marketing",
      package_root = "packages/github-auto-twitter-marketing",
      departments = departments,
      payload_for_queue = payload_for_queue,
    })
  end,
}
