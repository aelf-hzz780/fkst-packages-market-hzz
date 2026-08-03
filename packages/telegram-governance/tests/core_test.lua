local core = require("core")
local t = fkst.test

local ACTIONS = {
  "actor_policy.upsert",
  "group.config.update",
  "group.profile_scan",
  "group.sync",
  "history.backfill",
  "knowledge.bindings.replace",
  "message.delete",
  "monitor.add",
  "monitor.pause",
  "monitor.resume",
  "reply.approve_send",
  "user.ban",
  "user.restrict",
  "user.restore",
}

local function issue(overrides)
  local value = {
    number = 42,
    body = '{"command":{"target":{"group_id":-1001},"parameters":{},"action":"group.sync"},"mode":"preview"}',
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
    body = '{"mode":"live","command":{"parameters":{"reason":"spam"},"target":{"group_id":-1001,"message_id":9},"action":"message.delete"}}',
    comments = {
      {
        id = 99,
        body = '{"action":"message.delete","parameters":{"reason":"spam"},"target":{"group_id":-1001,"message_id":9}}',
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
  local metadata = {
    ["group.sync"] = { "R0", "machine:operate", false },
    ["group.profile_scan"] = { "R0", "machine:operate", true },
    ["monitor.add"] = { "R1", "machine:operate", false },
    ["monitor.pause"] = { "R1", "machine:operate", false },
    ["monitor.resume"] = { "R1", "machine:operate", false },
    ["history.backfill"] = { "R1", "machine:operate", false },
    ["group.config.update"] = { "R1", "machine:configure", false },
    ["knowledge.bindings.replace"] = { "R1", "machine:configure", false },
    ["actor_policy.upsert"] = { "R1", "machine:configure", false },
    ["message.delete"] = { "R2", "machine:destructive", false },
    ["user.restrict"] = { "R2", "machine:destructive", false },
    ["user.ban"] = { "R2", "machine:destructive", false },
    ["user.restore"] = { "R2", "machine:destructive", false },
    ["reply.approve_send"] = { "R2", "machine:destructive", false },
  }
  local values = {}
  for _, action in ipairs(ACTIONS) do
    local row = metadata[action]
    table.insert(values, {
      action = action,
      risk_tier = row[1],
      required_scope = row[2],
      forced_dry_run = row[3],
    })
  end
  return {
    version = "v1",
    actions = values,
    exclusions = { "group_creation", "arbitrary_proactive_messages", "raw_telethon_rpc" },
  }
end

return {
  test_issue_contract_canonicalizes_command_and_classifies_risk = function()
    local document, why = core.parse_issue_document(issue().body)

    t.is_nil(why)
    t.eq(document.mode, "preview")
    t.eq(document.action, "group.sync")
    t.eq(document.risk_tier, "R0")
    t.eq(document.canonical_json, '{"action":"group.sync","parameters":{},"target":{"group_id":-1001}}')
    t.eq(#core.action_catalog(), 14)
  end,

  test_issue_contract_rejects_invalid_json_unknown_fields_and_invalid_mode = function()
    local invalid_json, invalid_why = core.parse_issue_document("not-json")
    local unknown, unknown_why = core.parse_issue_document('{"mode":"preview","command":{"action":"group.sync","target":{},"parameters":{}},"extra":1}')
    local invalid_mode, mode_why = core.parse_issue_document('{"mode":"later","command":{"action":"group.sync","target":{},"parameters":{}}}')

    t.is_nil(invalid_json)
    t.eq(invalid_why, "invalid issue JSON")
    t.is_nil(unknown)
    t.eq(unknown_why, "unknown envelope field: extra")
    t.is_nil(invalid_mode)
    t.eq(mode_why, "mode must be preview or live")
  end,

  test_issue_contract_rejects_unknown_action_sensitive_fields_and_oversized_values = function()
    local unknown, unknown_why = core.parse_issue_document('{"command":{"action":"raw.telethon","target":{},"parameters":{}}}')
    local sensitive, sensitive_why = core.parse_issue_document('{"command":{"action":"group.sync","target":{"api_token":"nope"},"parameters":{}}}')
    local oversized, oversized_why = core.parse_issue_document('{"command":{"action":"group.sync","target":{"note":"' .. string.rep("x", 4097) .. '"},"parameters":{}}}')

    t.is_nil(unknown)
    t.eq(unknown_why, "unsupported action")
    t.is_nil(sensitive)
    t.is_true(tostring(sensitive_why):find("sensitive field", 1, true) ~= nil)
    t.is_nil(oversized)
    t.is_true(tostring(oversized_why):find("value too large", 1, true) ~= nil)
  end,

  test_profile_scan_cannot_request_live_execution = function()
    local document, why = core.parse_issue_document('{"mode":"live","command":{"action":"group.profile_scan","target":{"group_id":-1001},"parameters":{"dry_run":false}}}')

    t.is_nil(document)
    t.eq(why, "group.profile_scan is always dry-run")
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
    local document = assert(core.parse_issue_document('{"mode":"live","command":{"action":"group.config.update","target":{"group_id":-1001},"parameters":{"enabled":true}}}'))
    local authorization, why = core.authorize_live(document, issue(), live_options())

    t.is_nil(why)
    t.eq(authorization.service, "telegram-machine-online")
    t.eq(authorization.approval, nil)
  end,

  test_live_gate_fails_closed_without_token_write_switch_or_service = function()
    local document = assert(core.parse_issue_document('{"mode":"live","command":{"action":"group.sync","target":{"group_id":-1001},"parameters":{}}}'))
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
    local ok, why = core.validate_capabilities(capabilities())
    t.eq(ok, true)
    t.is_nil(why)

    local missing = capabilities()
    table.remove(missing.actions)
    local missing_ok, missing_why = core.validate_capabilities(missing)
    t.eq(missing_ok, false)
    t.eq(missing_why, "Machine API action catalog mismatch")

    local wrong_scope = capabilities()
    wrong_scope.actions[1].required_scope = "machine:destructive"
    local scope_ok, scope_why = core.validate_capabilities(wrong_scope)
    t.eq(scope_ok, false)
    t.eq(scope_why, "Machine API action metadata mismatch")

    local exclusions = capabilities()
    exclusions.exclusions = { "group_creation", "raw_telethon_rpc" }
    local exclusions_ok, exclusions_why = core.validate_capabilities(exclusions)
    t.eq(exclusions_ok, false)
    t.eq(exclusions_why, "Machine API exclusions mismatch")
  end,

  test_command_request_contains_github_evidence_trace_and_stable_idempotency = function()
    local current_issue = destructive_issue()
    local document = assert(core.parse_issue_document(current_issue.body))
    local authorization = assert(core.authorize_live(document, current_issue, live_options()))
    local first = assert(core.machine_command(document, current_issue, authorization.approval))
    local second = assert(core.machine_command(document, current_issue, authorization.approval))

    t.eq(first.body.action, "message.delete")
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
      action = "group.sync",
      status = "running",
      risk_tier = "R0",
      trace_id = "trace-1",
      result = nil,
      error = nil,
    })
    t.is_nil(why)
    t.eq(response.status, "running")
    t.is_nil(response.result)

    local invalid, invalid_why = core.normalize_machine_response({ status = "maybe", command_id = "id" })
    t.is_nil(invalid)
    t.eq(invalid_why, "invalid Machine API status")
  end,

  test_machine_response_must_bind_to_submitted_action_client_and_trace = function()
    local current_issue = issue({
      body = '{"mode":"live","command":{"action":"group.sync","target":{"group_id":-1001},"parameters":{}}}',
    })
    local document = assert(core.parse_issue_document(current_issue.body))
    local command = assert(core.machine_command(document, current_issue))
    local response = {
      action = command.body.action,
      client_command_id = command.body.client_command_id,
      trace_id = command.body.trace_id,
    }

    local ok, why = core.validate_response_binding(response, command)
    t.eq(ok, true)
    t.is_nil(why)

    response.trace_id = "different-trace"
    local mismatch, mismatch_why = core.validate_response_binding(response, command)
    t.eq(mismatch, false)
    t.eq(mismatch_why, "Machine API response trace_id mismatch")
  end,
}
