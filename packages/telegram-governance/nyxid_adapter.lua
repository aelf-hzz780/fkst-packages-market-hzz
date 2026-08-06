-- Narrow NyxID CLI adapter for the Telegram Automation API service.
local M = {}

local ALLOWED_PATHS = {
  ["/capabilities"] = { GET = true },
  ["/commands"] = { POST = true },
}

local function result(exit_code, stderr)
  return { exit_code = exit_code, stdout = "", stderr = stderr or "invalid NyxID request" }
end

local function valid_slug(value)
  return type(value) == "string"
    and #value >= 1
    and #value <= 120
    and value:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") ~= nil
end

local function path_methods(path)
  if ALLOWED_PATHS[path] ~= nil then
    return ALLOWED_PATHS[path]
  end
  if tostring(path):match("^/commands/[A-Fa-f0-9-]+$") ~= nil then
    return { GET = true }
  end
  return nil
end

local function valid_idempotency_key(value)
  return type(value) == "string"
    and #value >= 8
    and #value <= 200
    and value:match("^[A-Za-z0-9._:/-]+$") ~= nil
end

local function valid_trace_id(value)
  return type(value) == "string"
    and #value >= 1
    and #value <= 128
    and value:match("^[A-Za-z0-9._:/-]+$") ~= nil
end

function M.new(run)
  assert(type(run) == "function", "nyxid_adapter.new requires an exec_argv-compatible runner")
  local client = {}

  function client.available()
    local response = run({ argv = { "nyxid", "--version" }, timeout = 10 })
    return type(response) == "table" and response.exit_code == 0
  end

  function client.request(service, path, method, body, headers)
    local verb = tostring(method or "GET"):upper()
    local methods = path_methods(path)
    if not valid_slug(service) or methods == nil or not methods[verb] then
      return result(2)
    end
    if body ~= nil and (type(body) ~= "string" or #body > 65536) then
      return result(2)
    end
    local request_headers = headers or {}
    for name, value in pairs(request_headers) do
      local valid = (name == "Idempotency-Key" and valid_idempotency_key(value))
        or (name == "X-Trace-ID" and valid_trace_id(value))
      if not valid then
        return result(2)
      end
    end

    local argv = { "nyxid", "proxy", "request", service, path, "-m", verb }
    if body ~= nil then
      table.insert(argv, "-H")
      table.insert(argv, "Content-Type:application/json")
    end
    if request_headers["Idempotency-Key"] ~= nil then
      table.insert(argv, "-H")
      table.insert(argv, "Idempotency-Key:" .. request_headers["Idempotency-Key"])
    end
    if request_headers["X-Trace-ID"] ~= nil then
      table.insert(argv, "-H")
      table.insert(argv, "X-Trace-ID:" .. request_headers["X-Trace-ID"])
    end
    if body ~= nil then
      table.insert(argv, "-d")
      table.insert(argv, body)
    end
    table.insert(argv, "--output")
    table.insert(argv, "json")
    local response = run({ argv = argv, timeout = verb == "POST" and 60 or 30 })
    if type(response) ~= "table" then
      return result(1, "NyxID CLI returned an invalid result")
    end
    return {
      exit_code = tonumber(response.exit_code) or 1,
      stdout = tostring(response.stdout or ""),
      stderr = tostring(response.stderr or ""),
    }
  end

  return client
end

return M
