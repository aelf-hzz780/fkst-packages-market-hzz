local core = require("core")
local env = require("workflow.env")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "github-proxy.github_comment_written" },
  fanout = { "github-proxy.github_comment_written" },
  stall_window = "30s",
}

local ALLOWED_ENV = {
  FKST_DEVLOOP_MANAGED_BOT_LOGINS = true,
  FKST_GITHUB_AUTHORIZED_LOGINS = true,
  FKST_GITHUB_BOT_LOGIN = true,
  FKST_GITHUB_WRITE = true,
  FKST_MARKETING_COLLABORATOR_LOGINS = true,
  FKST_SESSION_CREATOR = true,
  FKST_SESSION_WORK_LABEL = true,
  FKST_SESSION_WORK_LABEL_MAP_JSON = true,
  FKST_X_PUBLISH_EXPECTED_USERNAME = true,
  X_PUBLISH_EXPECTED_USERNAME = true,
}

local GITHUB_AUTHOR_LOGIN_ENVS = {
  "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
  "FKST_GITHUB_AUTHORIZED_LOGINS",
  "FKST_MARKETING_COLLABORATOR_LOGINS",
  "FKST_SESSION_CREATOR",
}

local function read_env_command(name)
  if not ALLOWED_ENV[name] then
    error("marketing-radar: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

local function environment_values()
  local values = {}
  for name, _ in pairs(ALLOWED_ENV) do
    values[name] = read_env(name)
  end
  return values
end

local function csv_values(value)
  local values = {}
  for item in tostring(value or ""):gmatch("[^,%s]+") do
    values[#values + 1] = item
  end
  return values
end

local function same_session(left, right)
  return left.account == right.account
    and left.creator == right.creator
    and left.effective_work_label == right.effective_work_label
    and left.logical_work_label == right.logical_work_label
end

local function close_ok(result)
  return type(result) == "table" and tonumber(result.exit_code) == 0
end

local function done(_event)
  return false
end

local function make_department(handles)
  local ports = handles or {}
  local github = ports.github
  local github_write_enabled = ports.github_write_enabled or function()
    return read_env("FKST_GITHUB_WRITE") == "1"
  end
  local session_authority = ports.session_authority or function()
    local session, why = core.resolve_session_authority(environment_values())
    if session == nil then
      error("marketing-radar: terminal session authority rejected: " .. tostring(why), 0)
    end
    return session
  end
  local review_options = ports.review_options or function()
    local values = environment_values()
    return {
      bot_login = values.FKST_GITHUB_BOT_LOGIN,
      authorized_reviewers = csv_values(values.FKST_GITHUB_AUTHORIZED_LOGINS),
    }
  end
  local run_with_lock = ports.with_lock or function(key, fn)
    return with_lock(key, fn)
  end

  local function fresh_issue(source_ref, consumer)
    if type(github) ~= "table" or type(github.read_issue) ~= "function" then
      error("marketing-radar: terminal GitHub read port unavailable", 0)
    end
    return github.read_issue(source_ref, {
      force_fresh = true,
      consumer = consumer,
    })
  end

  local function current_state(context)
    local current = fresh_issue(
      context.source_ref, "marketing-radar-v2-terminalizer-target")
    local review = nil
    if context.kind == "radar-signal" then
      review = fresh_issue(
        context.review_source_ref, "marketing-radar-v2-terminalizer-review")
    end
    return current, review
  end

  local function reconcile(context)
    local current, review = current_state(context)
    local decision, why = core.current_close_decision(
      current, context, review_options(), review)
    if decision == "converged" then
      log.info("marketing-radar dept=issue_terminalizer tag=CONVERGED reason=" .. tostring(why))
      return
    end
    if decision ~= "close" then
      log.warn("marketing-radar dept=issue_terminalizer tag=SKIP reason=" .. tostring(why))
      return
    end
    local ok, result_or_error = pcall(github.issue_close, context.repo, context.issue_number, 30)
    if ok and close_ok(result_or_error) then
      log.info("marketing-radar dept=issue_terminalizer tag=CLOSED trace_id=" .. tostring(context.trace_id))
      return
    end
    local reread_ok, reread, review_reread = pcall(current_state, context)
    if reread_ok then
      local after = core.current_close_decision(
        reread, context, review_options(), review_reread)
      if after == "converged" then
        log.info("marketing-radar dept=issue_terminalizer tag=CONVERGED reason=close-response-lost")
        return
      end
    end
    error("marketing-radar: issue close failed trace_id=" .. tostring(context.trace_id)
      .. " close_error=" .. tostring(result_or_error), 0)
  end

  local function act(event)
    local context, why = core.close_ack_context(event and event.payload)
    if context == nil then
      log.info("marketing-radar dept=issue_terminalizer tag=SKIP reason=" .. tostring(why))
      return
    end
    local active = session_authority()
    if not same_session(active, context.session) then
      log.warn("marketing-radar dept=issue_terminalizer tag=SKIP reason=session-authority-changed")
      return
    end
    if github_write_enabled() ~= true then
      log.info("marketing-radar dept=issue_terminalizer tag=DRY_RUN reason=FKST_GITHUB_WRITE!=1")
      return
    end
    return run_with_lock(core.close_lock_key(context), function()
      return reconcile(context)
    end)
  end

  return saga.department(spec, { done = done, act = act, name = "issue_terminalizer" })
end

local department = ports_lib.install(make_department, ports_lib.github_author_options(read_env, "marketing-radar terminalizer", {
  bot_login_env = "FKST_GITHUB_BOT_LOGIN",
  extra_login_envs = GITHUB_AUTHOR_LOGIN_ENVS,
}))
department.github_author_login_envs = GITHUB_AUTHOR_LOGIN_ENVS
return department
