local core = require("core")
local t = fkst.test

local function issue(overrides)
  local value = {
    number = 42,
    body = '{"command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}},"mode":"preview"}',
    labels = { "telegram-governance" },
    author_login = "alice",
    comments = {},
    source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
      reference = "owner/repo#issue/42",
    },
  }
  for key, field in pairs(overrides or {}) do
    value[key] = field
  end
  return value
end

local function destructive_issue(overrides)
  local value = issue({
    body = '{"mode":"live","command":{"account_ref":"telegram-primary","operation":"moderation.user.restore","payload":{"group_id":-1001,"user_id":42,"restriction_audit_id":73}}}',
    comments = {
      {
        id = 99,
        body = '{"account_ref":"telegram-primary","mode":"live","operation":"moderation.user.restore","payload":{"group_id":-1001,"restriction_audit_id":73,"user_id":42}}',
        author_login = "bob",
        created_at = "2026-08-03T02:00:00Z",
      },
    },
  })
  for key, field in pairs(overrides or {}) do
    value[key] = field
  end
  return value
end

local function live_options(overrides)
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

local function capabilities()
  local metadata = core.operation_catalog()
  local operations = {}
  local values = {}
  for _, row in ipairs(metadata) do
    table.insert(operations, row.operation)
    table.insert(values, row)
  end
  return {
    contract_version = "automation.v1",
    account_ref = "telegram-primary",
    operations = operations,
    operation_capabilities = values,
    modes = { "shadow", "live" },
    scopes = { "automation:read", "groups:write", "analysis:run", "knowledge:write", "policy:write" },
    exclusions = {
      "group_creation",
      "arbitrary_proactive_messages",
      "caller_selected_moderation",
      "raw_telegram_rpc",
    },
    limits = { queue_max = 100, command_timeout_seconds = 60, result_max_bytes = 65536, read_limit = 100 },
  }
end

return {
  test_issue_contract_canonicalizes_command_and_classifies_risk = function()
    local document, why = core.parse_issue_document(issue().body)

    t.is_nil(why)
    t.eq(document.mode, "preview")
    t.eq(document.machine_mode, "shadow")
    t.eq(document.operation, "group.sync")
    t.eq(document.risk_tier, "R0")
    t.eq(document.canonical_json, '{"account_ref":"telegram-primary","mode":"shadow","operation":"group.sync","payload":{"group_id":-1001}}')
    t.eq(#core.operation_catalog(), 24)
  end,

  test_issue_contract_rejects_invalid_json_unknown_fields_and_invalid_mode = function()
    local invalid_json, invalid_why = core.parse_issue_document("not-json")
    local unknown, unknown_why = core.parse_issue_document('{"mode":"preview","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{}},"extra":1}')
    local invalid_mode, mode_why = core.parse_issue_document('{"mode":"later","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{}}}')

    t.is_nil(invalid_json)
    t.eq(invalid_why, "invalid issue JSON")
    t.is_nil(unknown)
    t.eq(unknown_why, "unknown envelope field: extra")
    t.is_nil(invalid_mode)
    t.eq(mode_why, "mode must be preview or live")
  end,

  test_issue_contract_rejects_unknown_operation_sensitive_fields_and_oversized_values = function()
    local unknown, unknown_why = core.parse_issue_document('{"command":{"account_ref":"telegram-primary","operation":"raw.telethon","payload":{}}}')
    local sensitive, sensitive_why = core.parse_issue_document('{"command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"api_token":"nope"}}}')
    local oversized, oversized_why = core.parse_issue_document('{"command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"note":"' .. string.rep("x", 4097) .. '"}}}')

    t.is_nil(unknown)
    t.eq(unknown_why, "unsupported operation")
    t.is_nil(sensitive)
    t.is_true(tostring(sensitive_why):find("sensitive field", 1, true) ~= nil)
    t.is_nil(oversized)
    t.is_true(tostring(oversized_why):find("value too large", 1, true) ~= nil)
  end,

  test_caller_selected_destructive_action_is_not_supported = function()
    local document, why = core.parse_issue_document('{"mode":"live","command":{"account_ref":"telegram-primary","operation":"message.delete","payload":{"message_id":9}}}')

    t.is_nil(document)
    t.eq(why, "unsupported operation")
  end,

  test_intake_event_is_pointer_only = function()
    local request, why = core.telegram_command_request({
      schema = "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = 42,
      title = string.rep("large", 1000),
      labels = { "telegram-governance" },
      body = "must-not-cross-the-seam",
      updated_at = "2026-08-03T01:00:00Z",
      dedup_key = "github/changed/42",
      source_ref = issue().source_ref,
    }, "changed")

    t.is_nil(why)
    t.eq(request.schema, "telegram-governance.command-request.v1")
    t.eq(request.trigger, "changed")
    t.eq(request.source_ref.ref, "owner/repo#issue/42")
    t.is_nil(request.repo)
    t.is_nil(request.number)
    t.is_nil(request.title)
    t.is_nil(request.body)
    t.is_nil(request.labels)
    t.is_true(#request.dedup_key <= 200)
  end,

  test_live_gate_selects_ordinary_service_for_r0_and_r1 = function()
    local document = assert(core.parse_issue_document('{"mode":"live","command":{"account_ref":"telegram-primary","operation":"group.policy.update","payload":{"group_id":-1001,"expected_policy_version":1,"patch":{"auto_reply_enabled":true}}}}'))
    local authorization, why = core.authorize_live(document, issue(), live_options())

    t.is_nil(why)
    t.eq(authorization.service, "telegram-machine-online")
    t.eq(authorization.approval, nil)
  end,

  test_live_gate_fails_closed_without_token_write_switch_or_service = function()
    local document = assert(core.parse_issue_document('{"mode":"live","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}'))
    local cases = {
      { options = live_options({ nyxid_access_token_present = false }), why = "nyxid access token missing" },
      { options = live_options({ write_enabled = false }), why = "ordinary write switch disabled" },
      { options = live_options({ ordinary_service = "" }), why = "ordinary NyxID service missing" },
      { options = live_options({ ordinary_service = "secret://bad" }), why = "invalid ordinary NyxID service slug" },
    }

    for _, case in ipairs(cases) do
      local authorization, why = core.authorize_live(document, issue(), case.options)
      t.is_nil(authorization)
      t.eq(why, case.why)
    end
  end,

  test_r2_requires_trusted_author_distinct_allowed_approver_and_exact_canonical_comment = function()
    local document = assert(core.parse_issue_document(destructive_issue().body))
    local cases = {
      {
        issue = destructive_issue({ author_login = "mallory" }),
        options = live_options(),
        why = "issue author is not trusted for destructive action",
      },
      {
        issue = destructive_issue({ comments = {
          { id = 1, body = document.canonical_json, author_login = "alice", created_at = "2026-08-03T02:00:00Z" },
        } }),
        options = live_options({ approver_logins = { "alice" } }),
        why = "destructive approval missing",
      },
      {
        issue = destructive_issue({ comments = {
          { id = 1, body = document.canonical_json, author_login = "carol", created_at = "2026-08-03T02:00:00Z" },
        } }),
        options = live_options(),
        why = "destructive approval missing",
      },
      {
        issue = destructive_issue({ comments = {
          { id = 1, body = document.canonical_json .. "\n", author_login = "bob", created_at = "2026-08-03T02:00:00Z" },
        } }),
        options = live_options(),
        why = "destructive approval missing",
      },
      {
        issue = destructive_issue({ comments = {
          { id = 1, body = document.canonical_json, author_login = "bob" },
        } }),
        options = live_options(),
        why = "destructive approval missing",
      },
      {
        issue = destructive_issue({ comments = {
          { id = 1, body = document.canonical_json, author_login = "bob", created_at = "not-a-timestamp" },
        } }),
        options = live_options(),
        why = "destructive approval missing",
      },
    }

    for _, case in ipairs(cases) do
      local authorization, why = core.authorize_live(document, case.issue, case.options)
      t.is_nil(authorization)
      t.eq(why, case.why)
    end
  end,

  test_r2_requires_both_switches_and_uses_destructive_service = function()
    local current_issue = destructive_issue()
    local document = assert(core.parse_issue_document(current_issue.body))

    local no_ordinary, ordinary_why = core.authorize_live(document, current_issue, live_options({ write_enabled = false }))
    local no_destructive, destructive_why = core.authorize_live(document, current_issue, live_options({ destructive_write_enabled = false }))
    local no_service, service_why = core.authorize_live(document, current_issue, live_options({ destructive_service = "" }))
    local authorized, why = core.authorize_live(document, current_issue, live_options())

    t.is_nil(no_ordinary)
    t.eq(ordinary_why, "ordinary write switch disabled")
    t.is_nil(no_destructive)
    t.eq(destructive_why, "destructive write switch disabled")
    t.is_nil(no_service)
    t.eq(service_why, "destructive NyxID service missing")
    t.is_nil(why)
    t.eq(authorized.service, "telegram-machine-destructive-online")
    t.eq(authorized.approval.approved_by, "bob")
    t.eq(authorized.approval.canonical_json, document.canonical_json)
    t.eq(authorized.approval.comment_url, "https://github.com/owner/repo/issues/42#issuecomment-99")
  end,

  test_capabilities_preflight_requires_exact_catalog_scope_matrix_and_exclusions = function()
    local ok, why = core.validate_capabilities(capabilities(), "telegram-primary")
    t.eq(ok, true)
    t.is_nil(why)

    local missing = capabilities()
    table.remove(missing.operations)
    local missing_ok, missing_why = core.validate_capabilities(missing, "telegram-primary")
    t.eq(missing_ok, false)
    t.eq(missing_why, "Automation API operation catalog mismatch")

    local wrong_scope = capabilities()
    wrong_scope.operation_capabilities[1].required_scope = "moderation:execute"
    local scope_ok, scope_why = core.validate_capabilities(wrong_scope, "telegram-primary")
    t.eq(scope_ok, false)
    t.eq(scope_why, "Automation API operation metadata mismatch")

    local exclusions = capabilities()
    exclusions.exclusions = { "group_creation", "raw_telegram_rpc" }
    local exclusions_ok, exclusions_why = core.validate_capabilities(exclusions, "telegram-primary")
    t.eq(exclusions_ok, false)
    t.eq(exclusions_why, "Automation API exclusions mismatch")
  end,

  test_command_request_contains_github_evidence_trace_and_stable_idempotency = function()
    local current_issue = destructive_issue()
    local document = assert(core.parse_issue_document(current_issue.body))
    local authorization = assert(core.authorize_live(document, current_issue, live_options()))
    local first = assert(core.machine_command(document, current_issue, authorization.approval))
    local second = assert(core.machine_command(document, current_issue, authorization.approval))

    t.eq(first.body.account_ref, "telegram-primary")
    t.eq(first.body.operation, "moderation.user.restore")
    t.eq(first.body.mode, "live")
    t.eq(first.body.source.provider, "github")
    t.eq(first.body.source.repository, "owner/repo")
    t.eq(first.body.source.issue_number, 42)
    t.eq(first.body.source.source_ref, "github://owner/repo/issues/42")
    t.eq(first.body.actor.login, "alice")
    t.eq(first.body.approval.approved_by, "bob")
    t.eq(first.idempotency_key, second.idempotency_key)
    t.eq(first.body.client_command_id, second.body.client_command_id)
    t.is_true(#first.idempotency_key >= 8 and #first.idempotency_key <= 200)
    t.is_true(type(first.body.trace_id) == "string" and first.body.trace_id ~= "")
  end,

  test_machine_response_normalization_accepts_known_statuses_and_rejects_raw_or_invalid_data = function()
    local response, why = core.normalize_machine_response({
      command_id = "11111111-1111-4111-8111-111111111111",
      client_command_id = "fkst-client",
      operation = "group.sync",
      status = "running",
      execution_outcome = "not_attempted",
      idempotent_replay = false,
      trace_id = "trace-1",
      result = nil,
      error = nil,
    })
    t.is_nil(why)
    t.eq(response.status, "running")
    t.is_nil(response.result)

    local invalid, invalid_why = core.normalize_machine_response({ status = "maybe", command_id = "id" })
    t.is_nil(invalid)
    t.eq(invalid_why, "invalid Automation API status")
  end,

  test_machine_response_must_bind_to_submitted_operation_client_and_trace = function()
    local current_issue = issue({
      body = '{"mode":"live","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}',
    })
    local document = assert(core.parse_issue_document(current_issue.body))
    local command = assert(core.machine_command(document, current_issue))
    local response = {
      operation = command.body.operation,
      client_command_id = command.body.client_command_id,
      trace_id = command.body.trace_id,
    }

    local ok, why = core.validate_response_binding(response, command)
    t.eq(ok, true)
    t.is_nil(why)

    response.trace_id = "different-trace"
    local mismatch, mismatch_why = core.validate_response_binding(response, command)
    t.eq(mismatch, false)
    t.eq(mismatch_why, "Automation API response trace_id mismatch")
  end,
}
