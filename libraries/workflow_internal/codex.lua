local workflow_env = require("workflow_internal.env")

local M = {}

local role_timeout_defaults = {
  consensus = 3600,
}

local role_timeout_env = {
  consensus = "FKST_CODEX_TIMEOUT_CONSENSUS",
}

local function timeout_env_command(name)
  if name ~= "FKST_CODEX_TIMEOUT_CONSENSUS" then
    error("workflow_internal.codex: invalid-env-name: env name is not allowed")
  end
  return 'printf %s "$' .. name .. '"'
end

local read_timeout_env = workflow_env.read_env(timeout_env_command)

local function copy_opts(opts)
  local out = {}
  for key, value in pairs(type(opts) == "table" and opts or {}) do
    out[key] = value
  end
  return out
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parse_timeout_seconds(env_name, raw)
  local value = trim(raw)
  if value == "" or value:find("[^0-9]") ~= nil then
    error("workflow_internal.codex: invalid " .. env_name .. ": expected positive integer seconds")
  end
  local parsed = tonumber(value)
  if parsed == nil or parsed <= 0 then
    error("workflow_internal.codex: invalid " .. env_name .. ": expected positive integer seconds")
  end
  return parsed
end

local function resolved_role_timeout(role, dispatch_opts)
  if dispatch_opts.timeout ~= nil then
    return dispatch_opts.timeout
  end
  local default = role_timeout_defaults[role]
  if default == nil then
    return nil
  end
  local env_name = role_timeout_env[role]
  local raw = env_name and read_timeout_env(env_name, exec_sync) or nil
  if raw ~= nil then
    return parse_timeout_seconds(env_name, raw)
  end
  return default
end

function M.judgment_codex_opts(prompt, worktree)
  return {
    prompt = prompt,
    worktree = worktree,
    sandbox = "read-only",
  }
end

function M.unrestricted_codex_opts(prompt, worktree)
  return {
    prompt = prompt,
    worktree = worktree,
  }
end

local function identity_parts(identity_or_role, proposal_id, dedup_key)
  if type(identity_or_role) == "table" then
    return identity_or_role.role, identity_or_role.proposal_id, identity_or_role.dedup_key
  end
  return identity_or_role, proposal_id, dedup_key
end

local function run_lease_expired(run)
  -- A running record whose lease deadline is already past is NOT live: it is a
  -- dead/hung run awaiting reap, and a redrive must reactivate it (start a
  -- replacement), never defer to it. lease_expires_at_ms is data on the run
  -- record (milliseconds), not a magic constant; now() is seconds.
  local lease = run.lease_expires_at_ms
  if type(lease) ~= "number" or type(now) ~= "function" then
    return false
  end
  return lease < now() * 1000
end

local function run_matches(run, role, proposal_id, dedup_key)
  return type(run) == "table"
    and tostring(run.role or "") == tostring(role or "")
    and tostring(run.proposal_id or "") == tostring(proposal_id or "")
    and tostring(run.dedup_key or "") == tostring(dedup_key or "")
    and tostring(run.status or "") == "running"
    and not run_lease_expired(run)
end

function M.live_run_active(identity_or_role, proposal_id, dedup_key)
  local role
  role, proposal_id, dedup_key = identity_parts(identity_or_role, proposal_id, dedup_key)
  if role == nil or proposal_id == nil or dedup_key == nil then
    return false
  end
  -- Observational precheck only: concurrent first dispatches can race here. The
  -- atomic one-live-run invariant belongs to the substrate live_run_key admission
  -- follow-on; this wrapper closes redrive/redelivery forks by using one identity
  -- for both the guard and the spawn opts.
  if type(fkst) ~= "table" or type(fkst.codex_runs) ~= "function" then
    return false
  end
  local ok, status = pcall(fkst.codex_runs)
  if not ok or type(status) ~= "table" or type(status.running) ~= "table" then
    return false
  end
  for _, run in ipairs(status.running) do
    if run_matches(run, role, proposal_id, dedup_key) then
      return true
    end
  end
  return false
end

function M.dispatch(identity, opts)
  if type(identity) ~= "table" then
    error("workflow_internal.codex: dispatch identity must be a convergence identity")
  end
  local role, proposal_id, dedup_key = identity_parts(identity)
  if role == nil or proposal_id == nil or dedup_key == nil then
    error("workflow_internal.codex: dispatch identity is incomplete")
  end
  if M.live_run_active(identity) then
    return {
      deferred = true,
      reason = "live-run-active",
      identity = identity,
    }
  end
  local dispatch_opts = copy_opts(opts)
  dispatch_opts.timeout = resolved_role_timeout(role, dispatch_opts)
  local sync = dispatch_opts.sync == true
  dispatch_opts.sync = nil
  dispatch_opts.role = role
  dispatch_opts.proposal_id = proposal_id
  dispatch_opts.dedup_key = dedup_key
  if sync then
    return spawn_codex_sync(dispatch_opts)
  end
  return spawn_codex(dispatch_opts)
end

return M
