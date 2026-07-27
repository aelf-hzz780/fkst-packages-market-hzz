local caps = require("import_issue_caps")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")
local env = require("workflow_internal.env")
local strings = require("contract.strings")

local spec = {
  consumes = { "github-proxy.github_entity_changed" },
  produces = {
    "strategy_imported",
    "weekly_content_imported",
    "github-proxy.github_issue_comment_request",
    "x-publisher.x_publish_request",
  },
  fanout = { "github-proxy.github_entity_changed" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function status_for(item)
  if item.kind == "strategy" then
    return "strategy imported"
  end
  if item.kind == "weekly-content" then
    return "weekly content imported"
  end
  if item.mode == "live" then
    return "schedule publish live requested"
  end
  return "schedule publish preview requested"
end

local function issue_source_ref(source_ref)
  local ref = type(source_ref) == "table" and (source_ref.ref or source_ref.reference) or nil
  if type(source_ref) ~= "table"
      or source_ref.kind ~= "external"
      or type(ref) ~= "string"
      or ref:match("^[^#]+#issue/%d+$") == nil then
    return nil
  end
  return {
    kind = "external",
    ref = ref,
    reference = ref,
  }
end

local function fetched_issue_body(github, payload)
  if type(payload) ~= "table" or payload.body ~= nil or payload.controls ~= nil then
    return nil
  end
  local source_ref = issue_source_ref(payload.source_ref)
  if source_ref == nil then
    return nil
  end
  local ok, issue = pcall(function()
    return github.read_issue(source_ref, {
      updated_at = payload.updated_at,
      consumer = "github-auto-twitter-marketing",
    })
  end)
  if not ok then
    log.warn("github-auto-twitter-marketing dept=import_issue tag=FETCH_SKIP reason=github issue read failed")
    return nil
  end
  return issue and issue.body or nil
end

local live_options

local function make_department(ports)
  local handles = ports or {}
  local github = handles.github

  local function act(event)
    local payload = event.payload or {}
    local issue_body = nil
    if github ~= nil then
      issue_body = fetched_issue_body(github, payload)
    end

    local item, why = caps.classify_issue(payload, { issue_body = issue_body })
    if item == nil then
      log.info("github-auto-twitter-marketing dept=import_issue tag=SKIP reason=" .. tostring(why))
      return
    end

    if item.kind == "strategy" then
      raise("strategy_imported", caps.strategy_imported(item))
    elseif item.kind == "weekly-content" then
      raise("weekly_content_imported", caps.weekly_content_imported(item))
    elseif item.kind == "schedule-publish" then
      raise("x-publisher.x_publish_request", caps.x_publish_request(item, live_options()))
    else
      error("github-auto-twitter-marketing: unknown-kind: " .. tostring(item.kind), 0)
    end

    raise("github-proxy.github_issue_comment_request", caps.status_comment(item, status_for(item)))
  end

  return saga.department(spec, {
    done = done,
    act = act,
    name = "import_issue",
  })
end

local function read_env_command(name)
  if name ~= "FKST_GITHUB_BOT_LOGIN"
    and name ~= "FKST_DEVLOOP_MANAGED_BOT_LOGINS"
    and name ~= "FKST_GITHUB_AUTHORIZED_LOGINS"
    and name ~= "FKST_NYXID_X_SERVICE_SLUG"
    and name ~= "FKST_X_PUBLISH_EXPECTED_USERNAME"
    and name ~= "FKST_X_PUBLISH_WRITE"
    and name ~= "NYXID_X_SERVICE_SLUG"
    and name ~= "X_PUBLISH_EXPECTED_USERNAME"
    and name ~= "X_PUBLISH_WRITE" then
    error("github-auto-twitter-marketing: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })
local function first_non_empty_env(names)
  for _, name in ipairs(names) do
    local value = strings.trim(read_env(name) or "")
    if value ~= "" then
      return value
    end
  end
  return ""
end

live_options = function()
  local write_gate = first_non_empty_env({ "X_PUBLISH_WRITE", "FKST_X_PUBLISH_WRITE" })
  return {
    live_write_enabled = write_gate == "1",
    nyxid_x_service = first_non_empty_env({ "NYXID_X_SERVICE_SLUG", "FKST_NYXID_X_SERVICE_SLUG" }),
    expected_username = first_non_empty_env({ "X_PUBLISH_EXPECTED_USERNAME", "FKST_X_PUBLISH_EXPECTED_USERNAME" }),
  }
end

local github_author_policy_env = {
  bot_login_env = "FKST_GITHUB_BOT_LOGIN",
  extra_login_envs = {
    "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
    "FKST_GITHUB_AUTHORIZED_LOGINS",
  },
}

return ports_lib.install(
  make_department,
  ports_lib.github_author_options(read_env, "github-auto-twitter-marketing", github_author_policy_env)
)
