local core = require("core")
local t = fkst.test

local OPERATIONS = {
  { "group.monitor.add", "groups:write", "R1", "telegram" },
  { "group.monitor.pause", "groups:write", "R1", "local" },
  { "group.monitor.resume", "groups:write", "R1", "local" },
  { "group.sync", "groups:write", "R0", "telegram" },
  { "group.history.backfill", "groups:write", "R1", "telegram" },
  { "group.policy.update", "policy:write", "R1", "local" },
  { "group.knowledge_bindings.replace", "policy:write", "R1", "local" },
  { "group.moderation_profile.replace", "policy:write", "R1", "local" },
  { "group.actor_policy.upsert", "policy:write", "R1", "local" },
  { "group.actor_policy.revoke", "policy:write", "R1", "local" },
  { "group.actor_policy.sync_admins", "policy:write", "R1", "telegram" },
  { "knowledge.collection.create", "knowledge:write", "R1", "local" },
  { "knowledge.collection.update", "knowledge:write", "R1", "local" },
  { "knowledge.collection.archive", "knowledge:write", "R1", "local" },
  { "knowledge.faq.create", "knowledge:write", "R1", "local" },
  { "knowledge.faq.update", "knowledge:write", "R1", "local" },
  { "knowledge.faq.archive", "knowledge:write", "R1", "local" },
  { "analysis.messages.run", "analysis:run", "R0", "local" },
  { "moderation.messages.scan", "analysis:run", "R0", "local" },
  { "reply.decision.execute", "replies:execute", "R2", "telegram" },
  { "moderation.message.execute", "moderation:execute", "R2", "telegram" },
  { "moderation.profile.scan", "moderation:execute", "R2", "telegram" },
  { "moderation.feedback.record", "policy:write", "R1", "local" },
  { "moderation.user.restore", "moderation:execute", "R2", "telegram" },
}

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
    reference = "owner/repo#issue/42",
  }
end

local function issue(body, comments)
  return {
    body = body,
    labels = { "telegram-governance" },
    comments = comments or {},
    author_login = "alice",
    source_ref = source_ref(),
  }
end

local function capabilities()
  local rows = {}
  local operations = {}
  for _, expected in ipairs(OPERATIONS) do
    table.insert(operations, expected[1])
    table.insert(rows, {
      operation = expected[1],
      required_scope = expected[2],
      risk_tier = expected[3],
      side_effect_class = expected[4],
      supported_modes = { "shadow", "live" },
      forced_shadow = false,
    })
  end
  return {
    contract_version = "automation.v1",
    account_ref = "telegram-primary",
    operations = operations,
    operation_capabilities = rows,
    modes = { "shadow", "live" },
    scopes = {
      "automation:read",
      "groups:write",
      "analysis:run",
      "knowledge:write",
      "policy:write",
    },
    exclusions = {
      "arbitrary_proactive_messages",
      "caller_selected_moderation",
      "group_creation",
      "raw_telegram_rpc",
    },
    limits = {
      queue_max = 100,
      command_timeout_seconds = 60,
      result_max_bytes = 65536,
      read_limit = 100,
    },
  }
end

return {
  test_operation_catalog_matches_canonical_automation_v1_registry = function()
    local actual = core.operation_catalog()
    t.eq(#actual, 24)
    for index, expected in ipairs(OPERATIONS) do
      t.eq(actual[index].operation, expected[1])
      t.eq(actual[index].required_scope, expected[2])
      t.eq(actual[index].risk_tier, expected[3])
      t.eq(actual[index].side_effect_class, expected[4])
      t.eq(actual[index].supported_modes[1], "shadow")
      t.eq(actual[index].supported_modes[2], "live")
      t.eq(actual[index].forced_shadow, false)
    end
  end,

  test_issue_contract_uses_account_operation_payload_and_rejects_legacy_actions = function()
    local document = assert(core.parse_issue_document(
      '{"mode":"live","command":{"account_ref":"telegram-primary","operation":"group.sync","payload":{"group_id":-1001}}}'
    ))
    t.eq(document.account_ref, "telegram-primary")
    t.eq(document.operation, "group.sync")
    t.eq(document.payload.group_id, -1001)
    t.eq(document.machine_mode, "live")

    local legacy, legacy_why = core.parse_issue_document(
      '{"mode":"live","command":{"action":"message.delete","target":{"message_id":9},"parameters":{}}}'
    )
    t.is_nil(legacy)
    t.is_true(legacy_why:find("unknown command field", 1, true) ~= nil)
  end,

  test_r2_approval_and_machine_body_use_tg_canonical_document = function()
    local canonical = '{"account_ref":"telegram-primary","mode":"live","operation":"moderation.user.restore","payload":{"group_id":-1001,"restriction_audit_id":73,"user_id":42}}'
    local body = '{"mode":"live","command":{"account_ref":"telegram-primary","operation":"moderation.user.restore","payload":{"group_id":-1001,"user_id":42,"restriction_audit_id":73}}}'
    local current_issue = issue(body, {
      {
        id = 99,
        body = canonical,
        author_login = "bob",
        created_at = "2026-08-03T02:00:00Z",
      },
    })
    local document = assert(core.parse_issue_document(body))
    local live = assert(core.authorize_live(document, current_issue, {
      write_enabled = true,
      destructive_write_enabled = true,
      nyxid_access_token_present = true,
      ordinary_service = "telegram-automation",
      destructive_service = "telegram-automation-destructive",
      trusted_author_logins = { "alice" },
      approver_logins = { "bob" },
    }))
    local command = assert(core.machine_command(document, current_issue, live.approval))
    local decoded = json.decode(command.body_json)

    t.eq(live.service, "telegram-automation-destructive")
    t.eq(decoded.account_ref, "telegram-primary")
    t.eq(decoded.operation, "moderation.user.restore")
    t.eq(decoded.mode, "live")
    t.eq(decoded.payload.restriction_audit_id, 73)
    t.eq(decoded.approval.canonical_json, canonical)
    t.is_nil(decoded.action)
    t.is_nil(decoded.target)
    t.is_nil(decoded.parameters)
  end,

  test_capabilities_require_exact_automation_v1_metadata_account_and_ordinary_scopes = function()
    local value = capabilities()
    t.is_true(core.validate_capabilities(value, "telegram-primary"))

    local wrong_account = capabilities()
    wrong_account.account_ref = "other-account"
    local ok, why = core.validate_capabilities(wrong_account, "telegram-primary")
    t.eq(ok, false)
    t.eq(why, "Automation API account_ref mismatch")

    local unsafe_ordinary = capabilities()
    table.insert(unsafe_ordinary.scopes, "moderation:execute")
    ok, why = core.validate_capabilities(unsafe_ordinary, "telegram-primary")
    t.eq(ok, false)
    t.eq(why, "Automation API ordinary scope matrix mismatch")
  end,

  test_response_and_receipt_preserve_execution_outcome = function()
    local response = assert(core.normalize_machine_response({
      command_id = "11111111-1111-4111-8111-111111111111",
      client_command_id = "fkst-telegram-1234",
      operation = "group.sync",
      status = "accepted",
      trace_id = "tg:1234:42",
      execution_outcome = "not_attempted",
      idempotent_replay = false,
    }))
    t.eq(response.operation, "group.sync")
    t.eq(response.status, "accepted")
    t.eq(response.execution_outcome, "not_attempted")

    local malformed, malformed_why = core.normalize_machine_response({
      command_id = "11111111-1111-4111-8111-111111111111",
      client_command_id = "fkst-telegram-1234",
      operation = "group.sync",
      status = "accepted",
      trace_id = "tg:1234:42",
      execution_outcome = "not_attempted",
      idempotent_replay = "false",
    })
    t.is_nil(malformed)
    t.eq(malformed_why, "invalid Automation API idempotent_replay")

    local current_issue = issue("{}")
    local command = { idempotency_key = "telegram-governance/key", body = { trace_id = "tg:1234:42" } }
    local receipt = core.response_receipt({ risk_tier = "R0" }, current_issue, command, response)
    t.eq(receipt.execution_outcome, "not_attempted")

    local comment = assert(core.receipt_comment(receipt))
    t.is_true(comment.dedup_key:find("/accepted/not_attempted", 1, true) ~= nil)
    t.is_true(comment.body:find("execution_outcome: not_attempted", 1, true) ~= nil)
  end,
}
