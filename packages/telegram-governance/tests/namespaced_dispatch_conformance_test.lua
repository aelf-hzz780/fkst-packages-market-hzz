local conformance = require("testkit.namespaced_dispatch_conformance")
local t = fkst.test

local ref = {
  kind = "external",
  ref = "owner/repo#issue/42",
  reference = "owner/repo#issue/42",
}

local github = {
  read_issue = function()
    return {
      number = 42,
      body = '{"mode":"preview","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}',
      labels = { "telegram-governance" },
      author_login = "alice",
      comments = {},
      source_ref = ref,
    }
  end,
}

local nyxid = {
  available = function() return true end,
  request = function() error("preview must not call NyxID") end,
}

local function load_module(name)
  local old_pipeline = pipeline
  local module = require(name)
  pipeline = old_pipeline
  return module
end

local intake = load_module("departments.github_command_intake.main")
local execute = load_module("departments.execute_command.main")
local receipt = load_module("departments.receipt_sink.main")

local departments = conformance.loaded_departments({
  {
    path = "departments/github_command_intake/main.lua",
    module = intake.make_department({ github = github }),
  },
  {
    path = "departments/execute_command/main.lua",
    module = execute.make_department({ github = github, nyxid = nyxid, options = {} }),
  },
  {
    path = "departments/receipt_sink/main.lua",
    module = receipt,
  },
})

local function payload_for_queue(_path, queue)
  if queue == "github-proxy.github_issue_changed" then
    return {
      schema = "github-proxy.v1",
      type = "issue",
      labels = { "telegram-governance" },
      updated_at = "2026-08-03T01:00:00Z",
      source_ref = ref,
      dedup_key = "github/changed/42",
    }
  end
  if queue == "github-proxy.github_issue_observed" then
    return {
      schema = "github-proxy.issue-observed.v1",
      type = "issue",
      updated_at = "2026-08-03T01:00:00Z",
      source_ref = ref,
      dedup_key = "github/observed/42",
    }
  end
  if queue == "telegram_command_request" then
    return {
      schema = "telegram-governance.command-request.v1",
      trigger = "changed",
      updated_at = "2026-08-03T01:00:00Z",
      source_ref = ref,
      dedup_key = "telegram-governance/intake/42",
      trace_id = "trace-42",
    }
  end
  if queue == "telegram_command_receipt" then
    return {
      schema = "telegram-governance.command-receipt.v1",
      command_id = "11111111-1111-4111-8111-111111111111",
      operation = "group.sync",
      status = "succeeded",
      execution_outcome = "confirmed_effect",
      risk_tier = "R0",
      idempotency_key = "telegram-governance/key-1",
      trace_id = "trace-42",
      source_ref = ref,
    }
  end
  error("telegram-governance: no fixture for queue " .. tostring(queue))
end

return {
  test_execute_command_declares_published_entry_seam = function()
    local department = departments["departments/execute_command/main.lua"]
    t.eq(department.spec.published_seam[1], "telegram_command_request")
  end,

  test_all_departments_accept_production_namespaced_consumed_queues = function()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "telegram-governance",
      package_root = "packages/telegram-governance",
      departments = departments,
      payload_for_queue = payload_for_queue,
    })
  end,
}
