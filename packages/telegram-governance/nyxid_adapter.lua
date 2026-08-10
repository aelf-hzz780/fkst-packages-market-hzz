-- Narrow NyxID CLI adapter for the Telegram Automation API service.
local M = {}

local ALLOWED_PATHS = {
  ["/capabilities"] = { GET = true },
  ["/commands"] = { POST = true },
}

local RETRYABLE_HTTP_STATUS = {
  [429] = true,
  [502] = true,
  [503] = true,
  [504] = true,
}

local DEFAULT_MAX_ATTEMPTS = 3
local DEFAULT_RETRY_BASE_SECONDS = 1
local DEFAULT_RETRY_MAX_SECONDS = 5

local function result(exit_code, stderr)
  return { exit_code = exit_code, stdout = "", stderr = stderr or "invalid NyxID request" }
end

local function bounded_number(value, default, minimum, maximum)
  local parsed = tonumber(value)
  if parsed == nil then
    return default
  end
  return math.max(minimum, math.min(maximum, parsed))
end

local function bounded_integer(value, default, minimum, maximum)
  return math.floor(bounded_number(value, default, minimum, maximum))
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

local function normalized_response(response)
  if type(response) ~= "table" then
    return result(1, "NyxID CLI returned an invalid result")
  end
  return {
    exit_code = tonumber(response.exit_code) or 1,
    stdout = tostring(response.stdout or ""),
    stderr = tostring(response.stderr or ""),
  }
end

local function http_status(text)
  local status = text:match("http%s+(%d%d%d)") or text:match("error code:%s*(%d%d%d)")
  return tonumber(status)
end

local function classify_failure(response)
  local text = (response.stdout .. "\n" .. response.stderr):lower()
  local status = http_status(text)
  if status ~= nil then
    return "http_" .. tostring(status), RETRYABLE_HTTP_STATUS[status] == true, text
  end
  if text:find("tls handshake eof", 1, true) ~= nil then
    return "tls_handshake", true, text
  end
  if text:find("operation timed out", 1, true) ~= nil
    or text:find("connection timed out", 1, true) ~= nil then
    return "connect_timeout", true, text
  end
  if text:find("connection reset", 1, true) ~= nil
    or text:find("connection refused", 1, true) ~= nil
    or text:find("error sending request", 1, true) ~= nil then
    return "connect_failure", true, text
  end
  if response.exit_code ~= 0 then
    return "cli_failure", false, text
  end
  return nil, false, text
end

local function retry_after_seconds(text, maximum)
  local value = tonumber(text:match("retry%-after:%s*(%d+)"))
  if value == nil then
    return nil
  end
  return math.max(0, math.min(maximum, value))
end

local function default_sleep(run, seconds)
  local response = run({
    argv = { "sleep", tostring(seconds) },
    timeout = math.max(2, math.ceil(seconds) + 1),
  })
  return type(response) == "table" and tonumber(response.exit_code) == 0
end

function M.new(run, options)
  assert(type(run) == "function", "nyxid_adapter.new requires an exec_argv-compatible runner")
  local settings = options or {}
  local max_attempts = bounded_integer(settings.max_attempts, DEFAULT_MAX_ATTEMPTS, 1, 5)
  local retry_base_seconds = bounded_number(
    settings.retry_base_seconds,
    DEFAULT_RETRY_BASE_SECONDS,
    0.1,
    10
  )
  local retry_max_seconds = bounded_number(
    settings.retry_max_seconds,
    DEFAULT_RETRY_MAX_SECONDS,
    retry_base_seconds,
    30
  )
  local sleep = settings.sleep
  if type(sleep) ~= "function" then
    sleep = function(seconds)
      return default_sleep(run, seconds)
    end
  end
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
    if headers ~= nil and type(headers) ~= "table" then
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
    local retry_allowed = verb == "GET"
      or (verb == "POST" and valid_idempotency_key(request_headers["Idempotency-Key"]))
    local last_retry_error_class = nil

    for attempt = 1, max_attempts do
      local response = normalized_response(run({
        argv = argv,
        timeout = verb == "POST" and 60 or 30,
      }))
      local error_class, retryable, response_text = classify_failure(response)
      response.attempt_count = attempt
      response.recovered_after_retry = error_class == nil and attempt > 1
      response.retry_exhausted = false
      if error_class == nil then
        response.last_retry_error_class = last_retry_error_class
        return response
      end

      response.error_class = error_class
      last_retry_error_class = error_class
      if response.exit_code == 0 then
        response.exit_code = 1
      end
      if not retryable or not retry_allowed then
        return response
      end
      if attempt >= max_attempts then
        response.retry_exhausted = true
        return response
      end

      local delay = math.min(retry_max_seconds, retry_base_seconds * (2 ^ (attempt - 1)))
      delay = retry_after_seconds(response_text, retry_max_seconds) or delay
      if sleep(delay) ~= true then
        response.retry_exhausted = true
        response.backoff_failed = true
        return response
      end
    end
    return result(1, "NyxID retry loop exited unexpectedly")
  end

  return client
end

return M
