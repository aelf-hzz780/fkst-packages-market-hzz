local adapter = require("nyxid_adapter")
local t = fkst.test

local function fake_runner(responses)
  local calls = {}
  return function(request)
    table.insert(calls, request)
    return table.remove(responses, 1)
  end, calls
end

local function retry_options(sleeps)
  return {
    max_attempts = 3,
    retry_base_seconds = 1,
    retry_max_seconds = 5,
    sleep = function(seconds)
      table.insert(sleeps, seconds)
      return true
    end,
  }
end

return {
  test_adapter_uses_only_nyxid_cli_and_relative_machine_paths = function()
    local run, calls = fake_runner({
      { exit_code = 0, stdout = "nyxid 0.9.0", stderr = "" },
      { exit_code = 0, stdout = '{"version":"v1","actions":[],"exclusions":[]}', stderr = "" },
      { exit_code = 0, stdout = '{"command_id":"command-1","status":"queued"}', stderr = "" },
    })
    local client = adapter.new(run)

    local ready = client.available()
    local capabilities = client.request("telegram-machine", "/capabilities", "GET")
    local command = client.request("telegram-machine", "/commands", "POST", "{}", {
      ["Idempotency-Key"] = "telegram-governance/key-1",
      ["X-Trace-ID"] = "tg:issue-42:sync",
    })

    t.eq(ready, true)
    t.eq(capabilities.exit_code, 0)
    t.eq(command.exit_code, 0)
    t.eq(calls[1].argv[1], "nyxid")
    t.eq(calls[1].argv[2], "--version")
    t.eq(table.concat(calls[2].argv, " "), "nyxid proxy request telegram-machine /capabilities -m GET --output json")
    t.eq(table.concat(calls[3].argv, " "), "nyxid proxy request telegram-machine /commands -m POST -H Content-Type:application/json -H Idempotency-Key:telegram-governance/key-1 -H X-Trace-ID:tg:issue-42:sync -d {} --output json")
  end,

  test_adapter_rejects_invalid_service_path_method_and_header = function()
    local run, calls = fake_runner({})
    local client = adapter.new(run)

    local service = client.request("secret://bad", "/capabilities", "GET")
    local path = client.request("telegram-machine", "/api/machine/v1/commands", "GET")
    local method = client.request("telegram-machine", "/commands", "DELETE")
    local header = client.request("telegram-machine", "/commands", "POST", "{}", { Authorization = "nope" })
    local trace = client.request("telegram-machine", "/commands", "POST", "{}", { ["X-Trace-ID"] = "bad trace" })

    t.eq(service.exit_code, 2)
    t.eq(path.exit_code, 2)
    t.eq(method.exit_code, 2)
    t.eq(header.exit_code, 2)
    t.eq(trace.exit_code, 2)
    t.eq(#calls, 0)
  end,

  test_adapter_retries_post_with_identical_idempotent_request = function()
    local run, calls = fake_runner({
      { exit_code = 1, stdout = "", stderr = "client error (Connect): tls handshake eof" },
      { exit_code = 0, stdout = "Proxy request failed (HTTP 502 Bad Gateway)\nerror code: 502", stderr = "" },
      { exit_code = 0, stdout = '{"command_id":"command-1","status":"succeeded"}', stderr = "" },
    })
    local sleeps = {}
    local client = adapter.new(run, retry_options(sleeps))

    local response = client.request("telegram-machine", "/commands", "POST", "{}", {
      ["Idempotency-Key"] = "telegram-governance/key-1",
      ["X-Trace-ID"] = "tg:issue-42:sync",
    })

    t.eq(response.exit_code, 0)
    t.eq(response.attempt_count, 3)
    t.eq(response.recovered_after_retry, true)
    t.eq(response.last_retry_error_class, "http_502")
    t.eq(response.retry_exhausted, false)
    t.eq(#calls, 3)
    t.eq(table.concat(calls[1].argv, " "), table.concat(calls[2].argv, " "))
    t.eq(table.concat(calls[2].argv, " "), table.concat(calls[3].argv, " "))
    t.eq(#sleeps, 2)
    t.eq(sleeps[1], 1)
    t.eq(sleeps[2], 2)
  end,

  test_adapter_retries_connect_timeout_and_retryable_http_statuses = function()
    local failures = {
      "error sending request: client error (Connect): operation timed out",
      "Proxy request failed (HTTP 502 Bad Gateway)",
      "Proxy request failed (HTTP 503 Service Unavailable)",
      "Proxy request failed (HTTP 504 Gateway Timeout)",
    }
    for _, failure in ipairs(failures) do
      local run, calls = fake_runner({
        { exit_code = 1, stdout = "", stderr = failure },
        { exit_code = 0, stdout = '{"contract_version":"automation.v1"}', stderr = "" },
      })
      local sleeps = {}
      local response = adapter.new(run, retry_options(sleeps))
        .request("telegram-machine", "/capabilities", "GET")

      t.eq(response.exit_code, 0)
      t.eq(response.attempt_count, 2)
      t.eq(response.recovered_after_retry, true)
      t.eq(#calls, 2)
      t.eq(#sleeps, 1)
      t.eq(sleeps[1], 1)
    end
  end,

  test_adapter_honors_bounded_retry_after = function()
    local run, calls = fake_runner({
      { exit_code = 1, stdout = "", stderr = "Proxy request failed (HTTP 429 Too Many Requests)\nRetry-After: 30" },
      { exit_code = 0, stdout = '{"contract_version":"automation.v1"}', stderr = "" },
    })
    local sleeps = {}
    local response = adapter.new(run, retry_options(sleeps))
      .request("telegram-machine", "/capabilities", "GET")

    t.eq(response.exit_code, 0)
    t.eq(response.attempt_count, 2)
    t.eq(#calls, 2)
    t.eq(sleeps[1], 5)
  end,

  test_adapter_does_not_retry_authority_or_idempotency_failures = function()
    for _, status in ipairs({ 401, 403, 409 }) do
      local run, calls = fake_runner({
        { exit_code = 1, stdout = "", stderr = "Proxy request failed (HTTP " .. tostring(status) .. ")" },
      })
      local sleeps = {}
      local response = adapter.new(run, retry_options(sleeps))
        .request("telegram-machine", "/capabilities", "GET")

      t.eq(response.exit_code, 1)
      t.eq(response.attempt_count, 1)
      t.eq(response.retry_exhausted, false)
      t.eq(#calls, 1)
      t.eq(#sleeps, 0)
    end
  end,

  test_adapter_never_retries_post_without_idempotency_key = function()
    local run, calls = fake_runner({
      { exit_code = 1, stdout = "", stderr = "client error (Connect): tls handshake eof" },
    })
    local sleeps = {}
    local response = adapter.new(run, retry_options(sleeps))
      .request("telegram-machine", "/commands", "POST", "{}", {
        ["X-Trace-ID"] = "tg:issue-42:sync",
      })

    t.eq(response.exit_code, 1)
    t.eq(response.attempt_count, 1)
    t.eq(response.retry_exhausted, false)
    t.eq(#calls, 1)
    t.eq(#sleeps, 0)
  end,

  test_adapter_marks_retry_exhaustion_without_leaking_response = function()
    local run, calls = fake_runner({
      { exit_code = 1, stdout = "", stderr = "client error (Connect): tls handshake eof" },
      { exit_code = 1, stdout = "", stderr = "client error (Connect): tls handshake eof" },
      { exit_code = 1, stdout = "", stderr = "client error (Connect): tls handshake eof" },
    })
    local sleeps = {}
    local response = adapter.new(run, retry_options(sleeps))
      .request("telegram-machine", "/capabilities", "GET")

    t.eq(response.exit_code, 1)
    t.eq(response.stdout, "")
    t.eq(response.stderr, "client error (Connect): tls handshake eof")
    t.eq(response.attempt_count, 3)
    t.eq(response.error_class, "tls_handshake")
    t.eq(response.retry_exhausted, true)
    t.eq(#calls, 3)
    t.eq(#sleeps, 2)
  end,

  test_adapter_default_backoff_uses_only_local_sleep = function()
    local calls = {}
    local nyxid_attempt = 0
    local function run(request)
      table.insert(calls, request)
      if request.argv[1] == "sleep" then
        return { exit_code = 0, stdout = "", stderr = "" }
      end
      nyxid_attempt = nyxid_attempt + 1
      if nyxid_attempt == 1 then
        return { exit_code = 1, stdout = "", stderr = "operation timed out" }
      end
      return { exit_code = 0, stdout = '{"contract_version":"automation.v1"}', stderr = "" }
    end

    local response = adapter.new(run).request("telegram-machine", "/capabilities", "GET")

    t.eq(response.exit_code, 0)
    t.eq(response.attempt_count, 2)
    t.eq(#calls, 3)
    t.eq(table.concat(calls[1].argv, " "), "nyxid proxy request telegram-machine /capabilities -m GET --output json")
    t.eq(calls[2].argv[1], "sleep")
    t.eq(tonumber(calls[2].argv[2]), 1)
    t.eq(table.concat(calls[3].argv, " "), "nyxid proxy request telegram-machine /capabilities -m GET --output json")
  end,
}
