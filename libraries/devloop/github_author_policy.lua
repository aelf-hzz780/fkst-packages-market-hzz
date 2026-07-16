local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local content_filter = require("forge.github.content_filter")

local M = {}

local function append_csv_logins(logins, raw)
  for login in tostring(raw or ""):gmatch("[^,%s]+") do
    table.insert(logins, login)
  end
end

local function append_login(logins, login)
  local value = strings.trim(login or "")
  if value ~= "" then
    table.insert(logins, value)
  end
end

local function repo_collaborator_authorization_enabled(exec)
  local ok, raw = pcall(devloop_base.read_env, "FKST_GITHUB_AUTHORIZE_REPO_COLLABORATORS", exec)
  return ok and strings.trim(raw or "") == "1"
end

local function configured_repo(exec)
  local ok, raw = pcall(devloop_base.read_env, "FKST_GITHUB_REPO", exec)
  if not ok then
    return nil
  end
  local repo = strings.trim(raw or "")
  if repo:match("^[^/%s]+/[^/%s]+$") == nil then
    return nil
  end
  return repo
end

local function has_write_permission(row)
  if type(row) ~= "table" then
    return false
  end
  local permissions = row.permissions
  if type(permissions) == "table" then
    if permissions.push == true or permissions.maintain == true or permissions.admin == true then
      return true
    end
    if permissions.pull == true or permissions.triage == true then
      return false
    end
  end
  local permission = strings.trim(row.permission or row.role_name or ""):lower()
  if permission == "push" or permission == "write" or permission == "maintain" or permission == "admin" then
    return true
  end
  if permission == "pull" or permission == "read" or permission == "triage" then
    return false
  end
  return permissions == nil and permission == ""
end

local function collect_collaborator_logins(rows, logins)
  if type(rows) ~= "table" then
    return
  end
  if rows.login ~= nil then
    if has_write_permission(rows) then
      append_login(logins, rows.login)
    end
    return
  end
  for _, row in ipairs(rows) do
    collect_collaborator_logins(row, logins)
  end
end

local function resolve_github_handle(github_handle)
  if type(github_handle) == "function" then
    local ok, resolved = pcall(github_handle)
    if ok then
      return resolved
    end
    return nil
  end
  return github_handle
end

local function append_repo_collaborator_logins(logins, exec, github_handle)
  if not repo_collaborator_authorization_enabled(exec) then
    return
  end
  local repo = configured_repo(exec)
  github_handle = resolve_github_handle(github_handle)
  if repo == nil or type(github_handle) ~= "table" or type(github_handle.api_paginate_slurp) ~= "function" then
    return
  end
  local ok_fetch, result = pcall(github_handle.api_paginate_slurp, "repos/" .. repo .. "/collaborators?permission=push&per_page=100")
  if not ok_fetch or type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return
  end
  local ok_decode, decoded = pcall(json.decode, result.stdout or "[]")
  if not ok_decode then
    return
  end
  collect_collaborator_logins(decoded, logins)
end

function M.from_logins(logins)
  return content_filter.author_policy_from_logins(logins or {})
end

function M.from_env(exec, github_handle)
  local bot_login = nil
  if type(devloop_base.configured_trusted_bot_login) == "function" then
    bot_login = devloop_base.configured_trusted_bot_login()
  end
  if bot_login == nil or tostring(bot_login or "") == "" then
    local ok_bot = true
    ok_bot, bot_login = pcall(devloop_base.read_env, "FKST_GITHUB_BOT_LOGIN", exec)
    bot_login = ok_bot and strings.trim(bot_login or "") or ""
  end
  if bot_login == "" then
    error("devloop.github_author_policy: FKST_GITHUB_BOT_LOGIN is required for authored GitHub reads")
  end
  local logins = { bot_login }
  for _, name in ipairs({ "FKST_DEVLOOP_MANAGED_BOT_LOGINS", "FKST_GITHUB_AUTHORIZED_LOGINS" }) do
    local ok, raw = pcall(devloop_base.read_env, name, exec)
    if ok then
      append_csv_logins(logins, raw)
    end
  end
  append_repo_collaborator_logins(logins, exec, github_handle)
  return M.from_logins(logins)
end

function M.is_authorized(policy, login)
  return content_filter.is_authorized(login, content_filter.policy_whitelist(policy))
end

function M.for_exec(exec, github_handle)
  return M.from_env(exec, github_handle)
end

function M.github_options(exec)
  local policy = nil
  return {
    trusted_author_policy = function(github_handle)
      if policy == nil then
        policy = M.for_exec(exec, github_handle)
      end
      return policy
    end,
  }
end

return M
