local adapter = require("nyxid_adapter")
local t = fkst.test

local function fake_runner(responses)
  local calls = {}
  return function(request)
    table.insert(calls, request)
    return table.remove(responses, 1)
  end, calls
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
}
