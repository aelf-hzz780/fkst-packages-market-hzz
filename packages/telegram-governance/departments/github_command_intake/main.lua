local core = require("core")
local env = require("workflow.env")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "github-proxy.github_issue_changed", "github-proxy.github_issue_observed" },
  produces = { "telegram_command_request" },
  fanout = { "github-proxy.github_issue_changed", "github-proxy.github_issue_observed" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function is_observed(event)
  return event and event.queue == "github-proxy.github_issue_observed"
end

local function observed_has_label(github, payload)
  if github == nil or type(github.read_issue) ~= "function" then
    return false
  end
  local ok, current_issue = pcall(function()
    return github.read_issue(payload.source_ref, {
      updated_at = payload.updated_at,
      consumer = "telegram-governance-intake",
    })
  end)
  return ok and type(current_issue) == "table" and core.has_work_label(current_issue.labels)
end

local function make_department(ports)
  local github = (ports or {}).github
  local function act(event)
    local payload = event and event.payload or {}
    local observed = is_observed(event)
    if observed then
      if not observed_has_label(github, payload) then
        log.info("telegram-governance dept=github_command_intake tag=SKIP reason=observed issue outside work label")
        return
      end
    elseif not core.has_work_label(payload.labels) then
      log.info("telegram-governance dept=github_command_intake tag=SKIP reason=missing work label")
      return
    end
    local request, why = core.telegram_command_request(payload, observed and "observed" or "changed")
    if request == nil then
      log.warn("telegram-governance dept=github_command_intake tag=SKIP reason=" .. tostring(why))
      return
    end
    raise("telegram_command_request", request)
  end
  return saga.department(spec, { done = done, act = act, name = "github_command_intake" })
end

local ALLOWED_ENV = {
  FKST_GITHUB_AUTHORIZED_LOGINS = true,
  FKST_GITHUB_BOT_LOGIN = true,
  FKST_DEVLOOP_MANAGED_BOT_LOGINS = true,
}

local function read_env_command(name)
  if not ALLOWED_ENV[name] then
    error("telegram-governance intake: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

return ports_lib.install(
  make_department,
  ports_lib.github_author_options(read_env, "telegram-governance", {
    bot_login_env = "FKST_GITHUB_BOT_LOGIN",
    extra_login_envs = {
      "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
      "FKST_GITHUB_AUTHORIZED_LOGINS",
    },
  })
)
