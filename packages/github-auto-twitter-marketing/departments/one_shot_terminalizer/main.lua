local env = require("workflow.env")
local core = require("core")
local content_close = require("content_close")
local one_shot_close = require("one_shot_close")
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
  FKST_SESSION_CREATOR = true,
  FKST_SESSION_WORK_LABEL = true,
  FKST_SESSION_WORK_LABEL_MAP_JSON = true,
  FKST_X_PUBLISH_EXPECTED_USERNAME = true,
  X_PUBLISH_EXPECTED_USERNAME = true,
}

local function read_env_command(name)
  if not ALLOWED_ENV[name] then
    error("github-auto-twitter-marketing: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

local function production_write_enabled()
  return read_env("FKST_GITHUB_WRITE") == "1"
end

local function production_session_authority()
  return core.resolve_session_authority({
    FKST_SESSION_CREATOR = read_env("FKST_SESSION_CREATOR"),
    FKST_SESSION_WORK_LABEL = read_env("FKST_SESSION_WORK_LABEL"),
    FKST_SESSION_WORK_LABEL_MAP_JSON = read_env("FKST_SESSION_WORK_LABEL_MAP_JSON"),
    X_PUBLISH_EXPECTED_USERNAME = read_env("X_PUBLISH_EXPECTED_USERNAME"),
    FKST_X_PUBLISH_EXPECTED_USERNAME = read_env("FKST_X_PUBLISH_EXPECTED_USERNAME"),
  })
end

local function done(_event)
  return false
end

local function close_result_ok(result)
  return type(result) == "table" and tonumber(result.exit_code) == 0
end

local function make_department(ports)
  local handles = ports or {}
  local github = handles.github
  local github_write_enabled = handles.github_write_enabled or production_write_enabled
  local session_authority = handles.session_authority or production_session_authority
  local run_with_lock = handles.with_lock or function(key, fn)
    return with_lock(key, fn)
  end

  local function fresh_issue(context)
    if type(github) ~= "table" or type(github.read_issue) ~= "function" then
      error("github-auto-twitter-marketing: one-shot close GitHub port unavailable", 0)
    end
    return github.read_issue(context.source_ref, {
      consumer = "github-auto-twitter-marketing-one-shot-terminalizer",
      force_fresh = true,
    })
  end

  local function log_decision(level, tag, context, reason)
    local logger = log[level] or log.info
    logger("github-auto-twitter-marketing dept=one_shot_terminalizer tag=" .. tostring(tag)
      .. " trace_id=" .. one_shot_close.safe_log_value(context and context.trace_id)
      .. " source_ref=" .. one_shot_close.safe_log_value(
        context and context.source_ref and context.source_ref.ref)
      .. " dedup_key=" .. one_shot_close.safe_log_value(context and context.receipt_dedup_key)
      .. " account=" .. one_shot_close.safe_log_value(context and context.account)
      .. " content_digest=" .. one_shot_close.safe_log_value(context and context.content_digest)
      .. " decision=" .. one_shot_close.safe_log_value(reason))
  end

  local function reconcile(context, authority)
    local read_ok, current = pcall(fresh_issue, context)
    if not read_ok then
      error("github-auto-twitter-marketing: one-shot close fresh read failed trace_id="
        .. one_shot_close.safe_log_value(context.trace_id)
        .. " source_ref=" .. one_shot_close.safe_log_value(context.source_ref.ref)
        .. " dedup_key=" .. one_shot_close.safe_log_value(context.receipt_dedup_key)
        .. " read_error=" .. one_shot_close.safe_log_value(current), 0)
    end
    local decision, why
    if context.kind == "weekly-content" then
      decision, why = content_close.current_issue_decision(current, context, authority)
    else
      decision, why = one_shot_close.current_issue_decision(current, context, authority)
    end
    if decision == "converged" then
      log_decision("info", "CONVERGED", context, why)
      return
    end
    if decision ~= "close" then
      log_decision("warn", "SKIP", context, why)
      return
    end

    local ok, result_or_error = pcall(function()
      local result = github.issue_close(context.repo, context.issue_number, 30)
      if not close_result_ok(result) then
        error("GitHub issue close returned non-zero", 0)
      end
      return result
    end)
    if ok then
      log_decision("info", "CLOSED", context,
        context.kind == "weekly-content" and "imported-weekly-content" or "published-one-shot")
      return
    end

    local reread_ok, reread_or_error = pcall(fresh_issue, context)
    if reread_ok then
      local after_decision
      if context.kind == "weekly-content" then
        after_decision = content_close.current_issue_decision(reread_or_error, context, authority)
      else
        after_decision = one_shot_close.current_issue_decision(reread_or_error, context, authority)
      end
      if after_decision == "converged" then
        log_decision("info", "CONVERGED", context, "close-response-lost")
        return
      end
    end

    error("github-auto-twitter-marketing: one-shot close failed trace_id="
      .. one_shot_close.safe_log_value(context.trace_id)
      .. " source_ref=" .. one_shot_close.safe_log_value(context.source_ref.ref)
      .. " dedup_key=" .. one_shot_close.safe_log_value(context.receipt_dedup_key)
      .. " close_error=" .. one_shot_close.safe_log_value(result_or_error)
      .. (reread_ok and "" or (" reread_error=" .. one_shot_close.safe_log_value(reread_or_error))), 0)
  end

  local function act(event)
    local context, why = one_shot_close.ack_context(event and event.payload)
    if context == nil then
      context, why = content_close.ack_context(event and event.payload)
      if context == nil then
        log.info("github-auto-twitter-marketing dept=one_shot_terminalizer tag=SKIP decision="
          .. one_shot_close.safe_log_value(why))
        return
      end
    end
    if github_write_enabled() ~= true then
      log_decision("info", "DRY_RUN", context, "FKST_GITHUB_WRITE!=1")
      return
    end
    local authority, authority_why = session_authority()
    if authority == nil then
      log_decision("warn", "SKIP", context, "invalid-session-authority:" .. tostring(authority_why))
      return
    end
    local lock_key = context.kind == "weekly-content"
      and content_close.lock_key(context)
      or one_shot_close.lock_key(context)
    return run_with_lock(lock_key, function()
      return reconcile(context, authority)
    end)
  end

  return saga.department(spec, {
    done = done,
    act = act,
    name = "one_shot_terminalizer",
  })
end

return ports_lib.install(
  make_department,
  ports_lib.github_author_options(read_env, "github-auto-twitter-marketing one-shot terminalizer", {
    bot_login_env = "FKST_GITHUB_BOT_LOGIN",
    extra_login_envs = {
      "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
      "FKST_GITHUB_AUTHORIZED_LOGINS",
    },
  })
)
