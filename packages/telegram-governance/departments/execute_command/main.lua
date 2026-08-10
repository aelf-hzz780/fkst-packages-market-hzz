local core = require("core")
local env = require("workflow.env")
local nyxid_adapter = require("nyxid_adapter")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")
local strings = require("contract.strings")

local spec = {
  consumes = { "telegram_command_request" },
  published_seam = { "telegram_command_request" },
  produces = { "telegram_command_receipt" },
  stall_window = "10m",
  retry = false,
}

local VALUE_ENV = {
  FKST_GITHUB_AUTHORIZED_LOGINS = true,
  FKST_GITHUB_BOT_LOGIN = true,
  FKST_DEVLOOP_MANAGED_BOT_LOGINS = true,
  TELEGRAM_GOVERNANCE_APPROVER_LOGINS = true,
  TELEGRAM_GOVERNANCE_DESTRUCTIVE_SERVICE_SLUG = true,
  TELEGRAM_GOVERNANCE_DESTRUCTIVE_WRITE = true,
  TELEGRAM_GOVERNANCE_DRY_RUN = true,
  TELEGRAM_GOVERNANCE_NYXID_MAX_ATTEMPTS = true,
  TELEGRAM_GOVERNANCE_NYXID_RETRY_BASE_SECONDS = true,
  TELEGRAM_GOVERNANCE_NYXID_RETRY_MAX_SECONDS = true,
  TELEGRAM_GOVERNANCE_SERVICE_SLUG = true,
  TELEGRAM_GOVERNANCE_TRUSTED_AUTHOR_LOGINS = true,
  TELEGRAM_GOVERNANCE_WRITE = true,
}

local function done(_event)
  return false
end

local function read_env_command(name)
  if not VALUE_ENV[name] then
    error("telegram-governance execute: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

local function read_token_presence_command(name)
  if name ~= "NYXID_ACCESS_TOKEN" then
    error("telegram-governance execute: invalid-env-name: " .. tostring(name), 0)
  end
  return 'if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi'
end

local read_token_presence = env.read_env(read_token_presence_command, { propagate_exec_errors = true })

local function login_list(raw)
  local values = {}
  for value in tostring(raw or ""):gmatch("[^,%s]+") do
    table.insert(values, value)
  end
  return values
end

local function runtime_options()
  return {
    dry_run_enabled = strings.trim(read_env("TELEGRAM_GOVERNANCE_DRY_RUN") or "") == "1",
    write_enabled = strings.trim(read_env("TELEGRAM_GOVERNANCE_WRITE") or "") == "1",
    destructive_write_enabled = strings.trim(read_env("TELEGRAM_GOVERNANCE_DESTRUCTIVE_WRITE") or "") == "1",
    ordinary_service = strings.trim(read_env("TELEGRAM_GOVERNANCE_SERVICE_SLUG") or ""),
    destructive_service = strings.trim(read_env("TELEGRAM_GOVERNANCE_DESTRUCTIVE_SERVICE_SLUG") or ""),
    trusted_author_logins = login_list(read_env("TELEGRAM_GOVERNANCE_TRUSTED_AUTHOR_LOGINS")),
    approver_logins = login_list(read_env("TELEGRAM_GOVERNANCE_APPROVER_LOGINS")),
    nyxid_access_token_present = strings.trim(read_token_presence("NYXID_ACCESS_TOKEN") or "") == "1",
    nyxid_max_attempts = tonumber(strings.trim(read_env("TELEGRAM_GOVERNANCE_NYXID_MAX_ATTEMPTS") or "")),
    nyxid_retry_base_seconds = tonumber(strings.trim(read_env("TELEGRAM_GOVERNANCE_NYXID_RETRY_BASE_SECONDS") or "")),
    nyxid_retry_max_seconds = tonumber(strings.trim(read_env("TELEGRAM_GOVERNANCE_NYXID_RETRY_MAX_SECONDS") or "")),
  }
end

local function production_nyxid(options)
  local run = type(exec_argv) == "function" and exec_argv or function()
    return { exit_code = 127, stdout = "", stderr = "exec_argv unavailable" }
  end
  return nyxid_adapter.new(run, {
    max_attempts = options.nyxid_max_attempts,
    retry_base_seconds = options.nyxid_retry_base_seconds,
    retry_max_seconds = options.nyxid_retry_max_seconds,
  })
end

local function valid_request(payload)
  return type(payload) == "table"
    and payload.schema == "telegram-governance.command-request.v1"
    and type(payload.source_ref) == "table"
    and type(payload.dedup_key) == "string"
    and type(payload.trace_id) == "string"
end

local function read_current_issue(github, payload)
  if github == nil or type(github.read_issue) ~= "function" then
    return nil, nil, "GitHub issue reader unavailable"
  end
  local ok, current_issue = pcall(function()
    return github.read_issue(payload.source_ref, {
      updated_at = payload.updated_at,
      consumer = "telegram-governance-execute",
    })
  end)
  if not ok or type(current_issue) ~= "table" then
    return nil, nil, "GitHub issue read failed"
  end
  if not core.has_work_label(current_issue.labels) then
    return nil, nil, "GitHub issue no longer has work label"
  end
  local document, why = core.parse_issue_document(current_issue.body)
  if document == nil then
    return current_issue, nil, why
  end
  if document.mode == "preview" then
    return current_issue, document, nil
  end

  local fresh_ok, fresh_issue = pcall(function()
    return github.read_issue(payload.source_ref, {
      force_fresh = true,
      consumer = "telegram-governance-live-authority",
    })
  end)
  if not fresh_ok or type(fresh_issue) ~= "table" then
    return current_issue, nil, "force-fresh GitHub issue read failed"
  end
  if not core.has_work_label(fresh_issue.labels) then
    return fresh_issue, nil, "GitHub issue no longer has work label"
  end
  local fresh_document, fresh_why = core.parse_issue_document(fresh_issue.body)
  return fresh_issue, fresh_document, fresh_why
end

local function raise_blocked(document, current_issue, reason)
  local receipt = core.blocked_receipt(document, current_issue, reason)
  log.warn("telegram-governance dept=execute_command tag=BLOCKED reason=" .. tostring(reason)
    .. " operation=" .. tostring(document and document.operation or "unknown")
    .. " trace_id=" .. tostring(receipt.trace_id))
  raise("telegram_command_receipt", receipt)
end

local function log_nyxid_retry(document, trace_id, request_kind, response)
  local attempts = type(response) == "table" and tonumber(response.attempt_count) or nil
  if attempts == nil or attempts <= 1 then
    return
  end
  local error_class = response.error_class or response.last_retry_error_class or "unknown"
  log.warn("telegram-governance dept=execute_command tag=NYXID_RETRY"
    .. " request_kind=" .. tostring(request_kind)
    .. " attempt_count=" .. tostring(attempts)
    .. " recovered=" .. tostring(response.recovered_after_retry == true)
    .. " exhausted=" .. tostring(response.retry_exhausted == true)
    .. " error_class=" .. tostring(error_class)
    .. " operation=" .. tostring(document and document.operation or "unknown")
    .. " trace_id=" .. tostring(trace_id or "unknown"))
end

local function make_department(ports)
  local handles = ports or {}
  local github = handles.github
  local injected_nyxid = handles.nyxid

  local function options()
    if handles.options ~= nil then
      return handles.options
    end
    return runtime_options()
  end

  local function act(event)
    local payload = event and event.payload or {}
    if not valid_request(payload) then
      log.warn("telegram-governance dept=execute_command tag=SKIP reason=invalid command request")
      return
    end
    local current_issue, document, issue_why = read_current_issue(github, payload)
    if document == nil then
      raise_blocked(nil, current_issue or { source_ref = payload.source_ref }, issue_why)
      return
    end
    if document.mode == "preview" then
      local receipt, receipt_why = core.preview_receipt(document, current_issue)
      if receipt == nil then
        raise_blocked(document, current_issue, receipt_why)
        return
      end
      log.info("telegram-governance dept=execute_command tag=PREVIEW operation=" .. document.operation)
      raise("telegram_command_receipt", receipt)
      return
    end

    local dispatch_options = options()
    local authorization, authorization_why
    if document.mode == "dry-run" then
      authorization, authorization_why = core.authorize_dry_run(document, dispatch_options)
    else
      authorization, authorization_why = core.authorize_live(document, current_issue, dispatch_options)
    end
    if authorization == nil then
      raise_blocked(document, current_issue, authorization_why)
      return
    end
    local nyxid = injected_nyxid or production_nyxid(dispatch_options)
    if type(nyxid.available) ~= "function" or not nyxid.available() then
      raise_blocked(document, current_issue, "nyxid cli unavailable")
      return
    end

    local capabilities_result = nyxid.request(dispatch_options.ordinary_service, "/capabilities", "GET")
    log_nyxid_retry(document, payload.trace_id, "capabilities", capabilities_result)
    if type(capabilities_result) ~= "table" or capabilities_result.exit_code ~= 0 then
      raise_blocked(document, current_issue, "Automation API capabilities request failed")
      return
    end
    local capabilities, capabilities_why = core.decode_proxy_response(capabilities_result.stdout, "Machine capabilities")
    if capabilities == nil then
      raise_blocked(document, current_issue, capabilities_why)
      return
    end
    local capabilities_ok, preflight_why = core.validate_capabilities(capabilities, document.account_ref)
    if not capabilities_ok then
      raise_blocked(document, current_issue, preflight_why)
      return
    end

    local command, command_why = core.machine_command(document, current_issue, authorization.approval)
    if command == nil then
      raise_blocked(document, current_issue, command_why)
      return
    end
    local command_result = nyxid.request(authorization.service, "/commands", "POST", command.body_json, {
      ["Idempotency-Key"] = command.idempotency_key,
      ["X-Trace-ID"] = command.body.trace_id,
    })
    log_nyxid_retry(document, command.body.trace_id, "command", command_result)
    if type(command_result) ~= "table" or command_result.exit_code ~= 0 then
      raise_blocked(document, current_issue, "Automation API command request failed")
      return
    end
    local response, response_why = core.normalize_machine_response(command_result.stdout)
    if response == nil then
      raise_blocked(document, current_issue, response_why)
      return
    end
    local binding_ok, binding_why = core.validate_response_binding(response, command)
    if not binding_ok then
      raise_blocked(document, current_issue, binding_why)
      return
    end
    log.info("telegram-governance dept=execute_command tag=RECEIPT operation=" .. document.operation
      .. " command_id=" .. tostring(response.command_id)
      .. " status=" .. tostring(response.status)
      .. " trace_id=" .. tostring(response.trace_id))
    raise("telegram_command_receipt", core.response_receipt(document, current_issue, command, response))
  end

  return saga.department(spec, { done = done, act = act, name = "execute_command" })
end

return ports_lib.install(
  make_department,
  ports_lib.github_author_options(read_env, "telegram-governance", {
    bot_login_env = "FKST_GITHUB_BOT_LOGIN",
    extra_login_envs = {
      "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
      "FKST_GITHUB_AUTHORIZED_LOGINS",
      "TELEGRAM_GOVERNANCE_TRUSTED_AUTHOR_LOGINS",
      "TELEGRAM_GOVERNANCE_APPROVER_LOGINS",
    },
  })
)
