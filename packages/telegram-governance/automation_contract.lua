-- Pinned adapter contract for Telethon Auto's canonical /api/automation/v1 API.
local M = {}

local OPERATIONS = {
  { operation = "group.monitor.add", required_scope = "groups:write", risk_tier = "R1", side_effect_class = "telegram" },
  { operation = "group.monitor.pause", required_scope = "groups:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "group.monitor.resume", required_scope = "groups:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "group.sync", required_scope = "groups:write", risk_tier = "R0", side_effect_class = "telegram" },
  { operation = "group.history.backfill", required_scope = "groups:write", risk_tier = "R1", side_effect_class = "telegram" },
  { operation = "group.policy.update", required_scope = "policy:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "group.knowledge_bindings.replace", required_scope = "policy:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "group.moderation_profile.replace", required_scope = "policy:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "group.actor_policy.upsert", required_scope = "policy:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "group.actor_policy.revoke", required_scope = "policy:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "group.actor_policy.sync_admins", required_scope = "policy:write", risk_tier = "R1", side_effect_class = "telegram" },
  { operation = "knowledge.collection.create", required_scope = "knowledge:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "knowledge.collection.update", required_scope = "knowledge:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "knowledge.collection.archive", required_scope = "knowledge:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "knowledge.faq.create", required_scope = "knowledge:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "knowledge.faq.update", required_scope = "knowledge:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "knowledge.faq.archive", required_scope = "knowledge:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "analysis.messages.run", required_scope = "analysis:run", risk_tier = "R0", side_effect_class = "local" },
  { operation = "moderation.messages.scan", required_scope = "analysis:run", risk_tier = "R0", side_effect_class = "local" },
  { operation = "reply.decision.execute", required_scope = "replies:execute", risk_tier = "R2", side_effect_class = "telegram" },
  { operation = "moderation.message.execute", required_scope = "moderation:execute", risk_tier = "R2", side_effect_class = "telegram" },
  { operation = "moderation.profile.scan", required_scope = "moderation:execute", risk_tier = "R2", side_effect_class = "telegram" },
  { operation = "moderation.feedback.record", required_scope = "policy:write", risk_tier = "R1", side_effect_class = "local" },
  { operation = "moderation.user.restore", required_scope = "moderation:execute", risk_tier = "R2", side_effect_class = "telegram" },
}

local OPERATION_BY_NAME = {}
for _, metadata in ipairs(OPERATIONS) do
  metadata.supported_modes = { "shadow", "live" }
  metadata.forced_shadow = false
  OPERATION_BY_NAME[metadata.operation] = metadata
end

local ORDINARY_SCOPES = {
  ["automation:read"] = true,
  ["groups:write"] = true,
  ["analysis:run"] = true,
  ["knowledge:write"] = true,
  ["policy:write"] = true,
}

local REQUIRED_EXCLUSIONS = {
  arbitrary_proactive_messages = true,
  caller_selected_moderation = true,
  group_creation = true,
  raw_telegram_rpc = true,
}

local COMMAND_STATUSES = {
  accepted = true,
  running = true,
  succeeded = true,
  blocked = true,
  failed = true,
}

local EXECUTION_OUTCOMES = {
  not_attempted = true,
  confirmed_effect = true,
  confirmed_no_effect = true,
  unknown = true,
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, field in pairs(value) do
    result[copy(key)] = copy(field)
  end
  return result
end

local function exact_string_set(values, expected)
  if type(values) ~= "table" then
    return false
  end
  local actual = {}
  local count = 0
  for _, value in ipairs(values) do
    if type(value) ~= "string" or actual[value] then
      return false
    end
    actual[value] = true
    count = count + 1
  end
  local expected_count = 0
  for value, _ in pairs(expected) do
    expected_count = expected_count + 1
    if not actual[value] then
      return false
    end
  end
  return count == expected_count
end

local function valid_limits(limits)
  if type(limits) ~= "table" then
    return false
  end
  for _, name in ipairs({ "queue_max", "command_timeout_seconds", "result_max_bytes", "read_limit" }) do
    local value = limits[name]
    if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
      return false
    end
  end
  return true
end

function M.catalog()
  return copy(OPERATIONS)
end

function M.metadata(operation)
  return OPERATION_BY_NAME[operation]
end

function M.is_command_status(status)
  return COMMAND_STATUSES[status] == true
end

function M.is_execution_outcome(outcome)
  return EXECUTION_OUTCOMES[outcome] == true
end

function M.validate_capabilities(value, expected_account_ref)
  if type(value) ~= "table" or value.contract_version ~= "automation.v1" then
    return false, "invalid Automation API capabilities"
  end
  if value.account_ref ~= expected_account_ref then
    return false, "Automation API account_ref mismatch"
  end
  if type(value.operations) ~= "table" or #value.operations ~= #OPERATIONS then
    return false, "Automation API operation catalog mismatch"
  end
  for index, expected in ipairs(OPERATIONS) do
    if value.operations[index] ~= expected.operation then
      return false, "Automation API operation catalog mismatch"
    end
  end
  if type(value.operation_capabilities) ~= "table" or #value.operation_capabilities ~= #OPERATIONS then
    return false, "Automation API operation catalog mismatch"
  end
  for index, expected in ipairs(OPERATIONS) do
    local actual = value.operation_capabilities[index]
    if type(actual) ~= "table" or actual.operation ~= expected.operation then
      return false, "Automation API operation catalog mismatch"
    end
    if actual.required_scope ~= expected.required_scope
      or actual.risk_tier ~= expected.risk_tier
      or actual.side_effect_class ~= expected.side_effect_class
      or actual.forced_shadow ~= false
      or type(actual.supported_modes) ~= "table"
      or #actual.supported_modes ~= 2
      or actual.supported_modes[1] ~= "shadow"
      or actual.supported_modes[2] ~= "live" then
      return false, "Automation API operation metadata mismatch"
    end
  end
  if not exact_string_set(value.modes, { shadow = true, live = true }) then
    return false, "Automation API mode matrix mismatch"
  end
  if not exact_string_set(value.scopes, ORDINARY_SCOPES) then
    return false, "Automation API ordinary scope matrix mismatch"
  end
  if not exact_string_set(value.exclusions, REQUIRED_EXCLUSIONS) then
    return false, "Automation API exclusions mismatch"
  end
  if not valid_limits(value.limits) then
    return false, "Automation API limits mismatch"
  end
  return true, nil
end

return M
