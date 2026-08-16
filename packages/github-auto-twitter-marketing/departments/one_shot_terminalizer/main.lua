local env = require("workflow.env")
local one_shot_close = require("one_shot_close")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "github-proxy.github_comment_written" },
  stall_window = "30s",
}

local ALLOWED_ENV = {
  FKST_DEVLOOP_MANAGED_BOT_LOGINS = true,
  FKST_GITHUB_AUTHORIZED_LOGINS = true,
  FKST_GITHUB_BOT_LOGIN = true,
  FKST_GITHUB_WRITE = true,
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
      .. " decision=" .. one_shot_close.safe_log_value(reason))
  end

  local function reconcile(context)
    local read_ok, current = pcall(fresh_issue, context)
    if not read_ok then
      error("github-auto-twitter-marketing: one-shot close fresh read failed trace_id="
        .. one_shot_close.safe_log_value(context.trace_id)
        .. " source_ref=" .. one_shot_close.safe_log_value(context.source_ref.ref)
        .. " dedup_key=" .. one_shot_close.safe_log_value(context.receipt_dedup_key)
        .. " read_error=" .. one_shot_close.safe_log_value(current), 0)
    end
    local decision, why = one_shot_close.current_issue_decision(current, context)
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
      log_decision("info", "CLOSED", context, "published-one-shot")
      return
    end

    local reread_ok, reread_or_error = pcall(fresh_issue, context)
    if reread_ok then
      local after_decision = one_shot_close.current_issue_decision(reread_or_error, context)
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
      log.info("github-auto-twitter-marketing dept=one_shot_terminalizer tag=SKIP decision="
        .. one_shot_close.safe_log_value(why))
      return
    end
    if github_write_enabled() ~= true then
      log_decision("info", "DRY_RUN", context, "FKST_GITHUB_WRITE!=1")
      return
    end
    return run_with_lock(one_shot_close.lock_key(context), function()
      return reconcile(context)
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
