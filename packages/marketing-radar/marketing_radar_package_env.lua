local env = require("workflow.env")
local strings = require("contract.strings")

local M = {}

local PACKAGE_ENV_VAR = "FKST_SESSION_PACKAGE_ENV_JSON"
local PACKAGE_NAME = "marketing-radar"
local AUTHOR_SETTABLE = {
  FKST_MARKETING_PAST_WEEK_MIGRATION_REFS = true,
}

local read_raw = env.read_env(function(name)
  if name ~= PACKAGE_ENV_VAR then
    error("marketing-radar package env: unexpected env name", 0)
  end
  return 'printf %s "$' .. name .. '"'
end, { propagate_exec_errors = true })

local function package_block(raw)
  local text = strings.trim(raw or "")
  if text == "" then
    return {}
  end
  if text:sub(1, 1) ~= "{" then
    error("marketing-radar package env: invalid JSON object", 0)
  end

  local ok, decoded = pcall(json.decode, text)
  if not ok or type(decoded) ~= "table" then
    error("marketing-radar package env: invalid JSON object", 0)
  end
  local block = decoded[PACKAGE_NAME]
  if block == nil then
    return {}
  end
  if type(block) ~= "table" then
    error("marketing-radar package env: invalid package block", 0)
  end
  return block
end

function M.get(name)
  if not AUTHOR_SETTABLE[name] then
    error("marketing-radar package env: unsupported key", 0)
  end
  local value = package_block(read_raw(PACKAGE_ENV_VAR))[name]
  if value == nil or value == "" then
    return nil
  end
  if type(value) ~= "string" then
    error("marketing-radar package env: configured value must be a string", 0)
  end
  return value
end

return M
