local automation_contract = require("automation_contract")
local github_fake = require("forge.github_fake")
local strings = require("contract.strings")
local t = fkst.test

local function source_ref(number)
  local ref = "owner/repo#issue/" .. tostring(number or 42)
  return { kind = "external", ref = ref, reference = ref }
end

local function changed_event()
  return {
    queue = "github-proxy.github_issue_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = 42,
      labels = { "telegram-governance" },
      title = "Telegram command",
      updated_at = "2026-08-03T01:00:00Z",
      source_ref = source_ref(),
      dedup_key = "github/changed/42",
    },
  }
end

local function observed_event()
  local event = changed_event()
  event.queue = "github-proxy.github_issue_observed"
  event.payload.schema = "github-proxy.issue-observed.v1"
  event.payload.labels = nil
  return event
end

local function issue_fixture(body, comments)
  return {
    number = 42,
    title = "Telegram command",
    body = body,
    updatedAt = "2026-08-03T01:00:00Z",
    state = "OPEN",
    labels = { "telegram-governance" },
    comments = comments or {},
    author = { login = "alice" },
  }
end

local function github_for(body, comments)
  local model = github_fake.model({
    issues = { ["owner/repo#issue/42"] = issue_fixture(body, comments) },
  })
  return github_fake.new(model)
end

local function load_department(module_name, handles)
  local old_pipeline = pipeline
  local module = require(module_name)
  pipeline = old_pipeline
  return module.make_department(handles)
end

local function fake_nyxid(responses)
  local client = { calls = {} }
  function client.available()
    return true
  end
  function client.request(service, path, method, body, headers)
    table.insert(client.calls, {
      service = service,
      path = path,
      method = method,
      body = body,
      headers = headers,
    })
    local response = table.remove(responses, 1)
    if type(response) == "function" then
      return response(client.calls[#client.calls])
    end
    return response
  end
  return client
end

local function command_response(status, command_id)
  return function(call)
    local request = json.decode(call.body)
    return {
      exit_code = 0,
      stdout = "{"
        .. '"command_id":' .. strings.json_string(command_id)
        .. ',"client_command_id":' .. strings.json_string(request.client_command_id)
        .. ',"operation":' .. strings.json_string(request.operation)
        .. ',"status":' .. strings.json_string(status)
        .. ',"execution_outcome":"not_attempted"'
        .. ',"idempotent_replay":false'
        .. ',"trace_id":' .. strings.json_string(request.trace_id)
        .. "}",
      stderr = "",
    }
  end
end

local function capabilities_stdout()
  local operations = {}
  local metadata = {}
  for _, item in ipairs(automation_contract.catalog()) do
    table.insert(operations, strings.json_string(item.operation))
    table.insert(metadata, "{"
      .. '"operation":' .. strings.json_string(item.operation)
      .. ',"required_scope":' .. strings.json_string(item.required_scope)
      .. ',"risk_tier":' .. strings.json_string(item.risk_tier)
      .. ',"side_effect_class":' .. strings.json_string(item.side_effect_class)
      .. ',"supported_modes":["shadow","live"]'
      .. ',"forced_shadow":false}')
  end
  return '{"contract_version":"automation.v1","account_ref":"telegram-primary","operations":['
    .. table.concat(operations, ",")
    .. '],"operation_capabilities":[' .. table.concat(metadata, ",")
    .. '],"modes":["shadow","live"],"scopes":["automation:read","groups:write","analysis:run","knowledge:write","policy:write"]'
    .. ',"exclusions":["arbitrary_proactive_messages","caller_selected_moderation","group_creation","raw_telegram_rpc"]'
    .. ',"limits":{"queue_max":100,"command_timeout_seconds":60,"result_max_bytes":65536,"read_limit":100}}'
end

local function options(overrides)
  local value = {
    write_enabled = true,
    destructive_write_enabled = true,
    nyxid_access_token_present = true,
    ordinary_service = "telegram-machine-online",
    destructive_service = "telegram-machine-destructive-online",
    trusted_author_logins = { "alice" },
    approver_logins = { "bob" },
  }
  for key, field in pairs(overrides or {}) do
    value[key] = field
  end
  return value
end

return {
  test_changed_intake_emits_pointer_only_command_request = function()
    local department = load_department("departments.github_command_intake.main", { github = github_for("{}") })
    local raises = {}
    local old_raise = raise
    raise = function(queue, payload)
      table.insert(raises, { queue = queue, payload = payload })
    end
    department.pipeline(changed_event())
    raise = old_raise

    t.eq(#raises, 1)
    t.eq(raises[1].queue, "telegram_command_request")
    t.eq(raises[1].payload.source_ref.ref, "owner/repo#issue/42")
    t.is_nil(raises[1].payload.title)
    t.is_nil(raises[1].payload.labels)
    t.is_nil(raises[1].payload.body)
  end,

  test_observed_intake_rechecks_work_label_before_replay = function()
    local allowed = load_department("departments.github_command_intake.main", {
      github = github_for('{"command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}'),
    })
    local raises = {}
    local old_raise = raise
    raise = function(queue, payload)
      table.insert(raises, { queue = queue, payload = payload })
    end
    allowed.pipeline(observed_event())
    raise = old_raise

    t.eq(#raises, 1)
    t.eq(raises[1].payload.trigger, "observed")
  end,

  test_preview_reads_issue_without_calling_nyxid = function()
    local client = fake_nyxid({})
    local github = github_for('{"mode":"preview","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}')
    local department = load_department("departments.execute_command.main", {
      github = github,
      nyxid = client,
      options = options(),
    })
    local raises = {}
    local old_raise = raise
    raise = function(queue, payload)
      table.insert(raises, { queue = queue, payload = payload })
    end
    department.pipeline({
      queue = "telegram_command_request",
      payload = {
        schema = "telegram-governance.command-request.v1",
        trigger = "changed",
        source_ref = source_ref(),
        dedup_key = "telegram-governance/intake/42",
        trace_id = "trace-42",
      },
    })
    raise = old_raise

    t.eq(#client.calls, 0)
    t.eq(#raises, 1)
    t.eq(raises[1].queue, "telegram_command_receipt")
    t.eq(raises[1].payload.status, "preview")
  end,

  test_live_force_fresh_preflights_then_posts_with_stable_idempotency = function()
    local read_options = nil
    local fixture = issue_fixture('{"mode":"live","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}')
    local github = {
      read_issue = function(_source_ref, received)
        read_options = received
        return {
          number = fixture.number,
          body = fixture.body,
          labels = fixture.labels,
          comments = fixture.comments,
          author_login = fixture.author.login,
          source_ref = source_ref(),
        }
      end,
    }
    local client = fake_nyxid({
      { exit_code = 0, stdout = capabilities_stdout(), stderr = "" },
      command_response("accepted", "11111111-1111-4111-8111-111111111111"),
    })
    local department = load_department("departments.execute_command.main", {
      github = github,
      nyxid = client,
      options = options(),
    })
    local raises = {}
    local old_raise = raise
    raise = function(queue, payload)
      table.insert(raises, { queue = queue, payload = payload })
    end
    department.pipeline({
      queue = "telegram_command_request",
      payload = {
        schema = "telegram-governance.command-request.v1",
        trigger = "observed",
        source_ref = source_ref(),
        dedup_key = "telegram-governance/intake/42",
        trace_id = "trace-42",
      },
    })
    raise = old_raise

    t.eq(read_options.force_fresh, true)
    t.eq(#client.calls, 2)
    t.eq(client.calls[1].service, "telegram-machine-online")
    t.eq(client.calls[1].path, "/capabilities")
    t.eq(client.calls[2].path, "/commands")
    t.eq(client.calls[2].headers["Idempotency-Key"]:find("telegram-governance/", 1, true), 1)
    t.eq(raises[1].payload.status, "accepted")
    t.eq(raises[1].payload.command_id, "11111111-1111-4111-8111-111111111111")
  end,

  test_nyxid_or_preflight_failure_emits_blocked_receipt_without_post = function()
    local document = '{"mode":"live","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}'
    local cases = {
      {
        client = setmetatable({ calls = {} }, {
          __index = {
            available = function() return false end,
            request = function() error("must not call") end,
          },
        }),
        why = "nyxid cli unavailable",
      },
      {
        client = fake_nyxid({ { exit_code = 1, stdout = "", stderr = "service unavailable" } }),
        why = "Automation API capabilities request failed",
      },
    }
    for _, case in ipairs(cases) do
      local department = load_department("departments.execute_command.main", {
        github = github_for(document),
        nyxid = case.client,
        options = options(),
      })
      local raises = {}
      local old_raise = raise
      raise = function(queue, payload)
        table.insert(raises, { queue = queue, payload = payload })
      end
      department.pipeline({
        queue = "telegram_command_request",
        payload = {
          schema = "telegram-governance.command-request.v1",
          trigger = "changed",
          source_ref = source_ref(),
          dedup_key = "telegram-governance/intake/42",
          trace_id = "trace-42",
        },
      })
      raise = old_raise
      t.eq(#raises, 1)
      t.eq(raises[1].payload.status, "blocked")
      t.eq(raises[1].payload.blocked_reason, case.why)
    end
  end,

  test_r2_force_fresh_approval_posts_only_through_destructive_service = function()
    local canonical = '{"account_ref":"telegram-primary","mode":"live","operation":"moderation.user.restore","payload":{"group_id":-1001,"restriction_audit_id":73,"user_id":42}}'
    local body = '{"mode":"live","command":{"account_ref":"telegram-primary","operation":"moderation.user.restore","payload":{"group_id":-1001,"user_id":42,"restriction_audit_id":73}}}'
    local comments = {
      {
        id = 99,
        body = canonical,
        author = { login = "bob" },
        createdAt = "2026-08-03T02:00:00Z",
      },
    }
    local client = fake_nyxid({
      { exit_code = 0, stdout = capabilities_stdout(), stderr = "" },
      command_response("accepted", "22222222-2222-4222-8222-222222222222"),
    })
    local department = load_department("departments.execute_command.main", {
      github = github_for(body, comments),
      nyxid = client,
      options = options(),
    })
    local raises = {}
    local old_raise = raise
    raise = function(queue, payload)
      table.insert(raises, { queue = queue, payload = payload })
    end
    department.pipeline({
      queue = "telegram_command_request",
      payload = {
        schema = "telegram-governance.command-request.v1",
        trigger = "changed",
        source_ref = source_ref(),
        dedup_key = "telegram-governance/intake/42",
        trace_id = "trace-42",
      },
    })
    raise = old_raise

    t.eq(client.calls[1].service, "telegram-machine-online")
    t.eq(client.calls[1].path, "/capabilities")
    t.eq(client.calls[2].service, "telegram-machine-destructive-online")
    t.eq(client.calls[2].path, "/commands")
    t.is_true(client.calls[2].body:find('"approved_by":"bob"', 1, true) ~= nil)
    t.is_true(client.calls[2].body:find('"canonical_json":"{\\"account_ref\\":\\"telegram-primary\\"', 1, true) ~= nil)
    t.eq(raises[1].payload.status, "accepted")
    t.eq(raises[1].payload.risk_tier, "R2")
  end,

  test_observed_replay_posts_identical_payload_and_idempotency_for_latest_status = function()
    local body = '{"mode":"live","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}'
    local client = fake_nyxid({
      { exit_code = 0, stdout = capabilities_stdout(), stderr = "" },
      command_response("running", "33333333-3333-4333-8333-333333333333"),
      { exit_code = 0, stdout = capabilities_stdout(), stderr = "" },
      command_response("succeeded", "33333333-3333-4333-8333-333333333333"),
    })
    local department = load_department("departments.execute_command.main", {
      github = github_for(body),
      nyxid = client,
      options = options(),
    })
    local receipts = {}
    local old_raise = raise
    raise = function(_queue, payload)
      table.insert(receipts, payload)
    end
    local event = {
      queue = "telegram_command_request",
      payload = {
        schema = "telegram-governance.command-request.v1",
        trigger = "observed",
        source_ref = source_ref(),
        dedup_key = "telegram-governance/intake/42",
        trace_id = "trace-42",
      },
    }
    department.pipeline(event)
    department.pipeline(event)
    raise = old_raise

    t.eq(client.calls[2].headers["Idempotency-Key"], client.calls[4].headers["Idempotency-Key"])
    t.eq(client.calls[2].body, client.calls[4].body)
    t.eq(receipts[1].command_id, receipts[2].command_id)
    t.eq(receipts[1].status, "running")
    t.eq(receipts[2].status, "succeeded")
  end,
}
