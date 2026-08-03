-- Pure contracts and policy for GitHub-driven Telegram Machine API commands.
local M = {}
local strings = require("contract.strings")

local WORK_LABEL = "telegram-governance"
local MAX_DOCUMENT_BYTES = 32768
local MAX_STRING_BYTES = 4096
local MAX_KEY_BYTES = 128
local MAX_DEPTH = 8
local MAX_NODES = 1000

local ACTIONS = {
  { action = "actor_policy.upsert", risk_tier = "R1", required_scope = "machine:configure", forced_dry_run = false },
  { action = "group.config.update", risk_tier = "R1", required_scope = "machine:configure", forced_dry_run = false },
  { action = "group.profile_scan", risk_tier = "R0", required_scope = "machine:operate", forced_dry_run = true },
  { action = "group.sync", risk_tier = "R0", required_scope = "machine:operate", forced_dry_run = false },
  { action = "history.backfill", risk_tier = "R1", required_scope = "machine:operate", forced_dry_run = false },
  { action = "knowledge.bindings.replace", risk_tier = "R1", required_scope = "machine:configure", forced_dry_run = false },
  { action = "message.delete", risk_tier = "R2", required_scope = "machine:destructive", forced_dry_run = false },
  { action = "monitor.add", risk_tier = "R1", required_scope = "machine:operate", forced_dry_run = false },
  { action = "monitor.pause", risk_tier = "R1", required_scope = "machine:operate", forced_dry_run = false },
  { action = "monitor.resume", risk_tier = "R1", required_scope = "machine:operate", forced_dry_run = false },
  { action = "reply.approve_send", risk_tier = "R2", required_scope = "machine:destructive", forced_dry_run = false },
  { action = "user.ban", risk_tier = "R2", required_scope = "machine:destructive", forced_dry_run = false },
  { action = "user.restrict", risk_tier = "R2", required_scope = "machine:destructive", forced_dry_run = false },
  { action = "user.restore", risk_tier = "R2", required_scope = "machine:destructive", forced_dry_run = false },
}

local ACTION_BY_NAME = {}
for _, metadata in ipairs(ACTIONS) do
  ACTION_BY_NAME[metadata.action] = metadata
end

local COMMAND_STATUSES = {
  queued = true,
  running = true,
  succeeded = true,
  failed = true,
  indeterminate = true,
  cancelled = true,
}

local RECEIPT_STATUSES = {
  preview = true,
  blocked = true,
  queued = true,
  running = true,
  succeeded = true,
  failed = true,
  indeterminate = true,
  cancelled = true,
}

local SENSITIVE_KEY_PARTS = {
  "authorization",
  "bearer",
  "cookie",
  "credential",
  "apikey",
  "oauth",
  "password",
  "providerresponse",
  "rawresponse",
  "secret",
  "session",
  "token",
}

local REQUIRED_EXCLUSIONS = {
  arbitrary_proactive_messages = true,
  group_creation = true,
  raw_telethon_rpc = true,
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

local function exact_fields(value, allowed, label)
  if type(value) ~= "table" then
    return false, label .. " must be an object"
  end
  for key, _ in pairs(value) do
    if type(key) ~= "string" or not allowed[key] then
      return false, "unknown " .. label .. " field: " .. tostring(key)
    end
  end
  return true, nil
end

local function normalized_key(value)
  return tostring(value or ""):lower():gsub("[^a-z0-9]", "")
end

local function sensitive_key(value)
  local normalized = normalized_key(value)
  for _, part in ipairs(SENSITIVE_KEY_PARTS) do
    if normalized:find(part, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function table_shape(value)
  local has_string = false
  local numeric_count = 0
  local max_numeric = 0
  for key, _ in pairs(value) do
    if type(key) == "string" then
      has_string = true
    elseif type(key) == "number" and key >= 1 and key == math.floor(key) then
      numeric_count = numeric_count + 1
      max_numeric = math.max(max_numeric, key)
    else
      return nil, "invalid JSON object key"
    end
  end
  if has_string and numeric_count > 0 then
    return nil, "mixed JSON table shape"
  end
  if numeric_count > 0 then
    if max_numeric ~= numeric_count then
      return nil, "sparse JSON array"
    end
    return "array", nil
  end
  return "object", nil
end

local function validate_json_value(value, state, depth, path)
  state.nodes = state.nodes + 1
  if state.nodes > MAX_NODES then
    return false, "command JSON has too many values"
  end
  if depth > MAX_DEPTH then
    return false, "command JSON is too deeply nested"
  end

  local kind = type(value)
  if kind == "string" then
    if #value > MAX_STRING_BYTES then
      return false, "value too large at " .. path
    end
    return true, nil
  end
  if kind == "boolean" then
    return true, nil
  end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return false, "non-finite number at " .. path
    end
    return true, nil
  end
  if kind ~= "table" then
    return false, "unsupported JSON value at " .. path
  end

  local shape, shape_why = table_shape(value)
  if shape == nil then
    return false, shape_why
  end
  if shape == "array" then
    for index, field in ipairs(value) do
      local ok, why = validate_json_value(field, state, depth + 1, path .. "[" .. tostring(index) .. "]")
      if not ok then
        return false, why
      end
    end
    return true, nil
  end

  for key, field in pairs(value) do
    if #key > MAX_KEY_BYTES then
      return false, "field name too large at " .. path
    end
    if sensitive_key(key) then
      return false, "sensitive field is not allowed at " .. path .. "." .. key
    end
    local ok, why = validate_json_value(field, state, depth + 1, path .. "." .. key)
    if not ok then
      return false, why
    end
  end
  return true, nil
end

local function canonical_json(value)
  local kind = type(value)
  if kind == "string" then
    return strings.json_string(value)
  end
  if kind == "boolean" then
    return value and "true" or "false"
  end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, "non-finite number"
    end
    return tostring(value), nil
  end
  if kind ~= "table" then
    return nil, "unsupported JSON value"
  end

  local shape, shape_why = table_shape(value)
  if shape == nil then
    return nil, shape_why
  end
  local parts = {}
  if shape == "array" then
    for _, field in ipairs(value) do
      local encoded, why = canonical_json(field)
      if encoded == nil then
        return nil, why
      end
      table.insert(parts, encoded)
    end
    return "[" .. table.concat(parts, ",") .. "]", nil
  end

  local keys = {}
  for key, _ in pairs(value) do
    table.insert(keys, key)
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local encoded, why = canonical_json(value[key])
    if encoded == nil then
      return nil, why
    end
    table.insert(parts, strings.json_string(key) .. ":" .. encoded)
  end
  return "{" .. table.concat(parts, ",") .. "}", nil
end

local function decode_json(text, label)
  if type(text) ~= "string" or text == "" then
    return nil, "invalid " .. label .. " JSON"
  end
  local ok, decoded = pcall(function()
    return json.decode(text)
  end)
  if not ok or type(decoded) ~= "table" then
    return nil, "invalid " .. label .. " JSON"
  end
  return decoded, nil
end

local function decode_proxy_stdout(stdout, label)
  local decoded, why = decode_json(stdout, label)
  if decoded == nil then
    return nil, why
  end
  if decoded.body ~= nil and (decoded.status ~= nil or decoded.status_code ~= nil) then
    if type(decoded.body) == "table" then
      return decoded.body, nil
    end
    if type(decoded.body) == "string" then
      return decode_json(decoded.body, label)
    end
  end
  return decoded, nil
end

local function source_ref(value)
  if type(value) ~= "table" or value.kind ~= "external" then
    return nil, "source_ref must point to a GitHub issue"
  end
  local ref = value.ref or value.reference
  local repo, number = tostring(ref or ""):match("^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#issue/(%d+)$")
  number = tonumber(number)
  if repo == nil or number == nil or number < 1 then
    return nil, "source_ref must point to a GitHub issue"
  end
  return {
    kind = "external",
    ref = repo .. "#issue/" .. tostring(number),
    reference = repo .. "#issue/" .. tostring(number),
    repo = repo,
    issue_number = number,
  }, nil
end

local function safe_segment(value, limit)
  local safe = strings.runtime_safe_segment(value)
  local max_len = limit or 120
  if #safe > max_len then
    local suffix = "_" .. strings.decimal_checksum(value)
    safe = safe:sub(1, math.max(1, max_len - #suffix)) .. suffix
  end
  return safe
end

local function digest(value)
  local text = tostring(value or "")
  return strings.decimal_checksum(text) .. strings.decimal_checksum(text:reverse())
end

local function has_login(logins, candidate)
  local wanted = tostring(candidate or ""):lower()
  if wanted == "" then
    return false
  end
  for _, login in ipairs(logins or {}) do
    if tostring(login):lower() == wanted then
      return true
    end
  end
  return false
end

local function valid_slug(value)
  return type(value) == "string"
    and #value >= 1
    and #value <= 120
    and value:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") ~= nil
end

local function command_identity(document, issue_ref)
  local key_digest = digest(issue_ref.ref .. "\n" .. document.canonical_json)
  return {
    client_command_id = "fkst-telegram-" .. key_digest,
    idempotency_key = table.concat({
      "telegram-governance",
      safe_segment(issue_ref.repo, 80),
      "issue-" .. tostring(issue_ref.issue_number),
      key_digest,
    }, "/"),
    trace_id = "tg:" .. key_digest .. ":" .. tostring(issue_ref.issue_number),
  }
end

local function command_body_json(body, approval)
  local action = assert(canonical_json(body.action))
  local actor = assert(canonical_json(body.actor))
  local approval_json = approval == nil and "null" or assert(canonical_json(approval))
  local client_command_id = assert(canonical_json(body.client_command_id))
  local parameters = assert(canonical_json(body.parameters))
  local source = assert(canonical_json(body.source))
  local target = assert(canonical_json(body.target))
  local trace_id = assert(canonical_json(body.trace_id))
  return "{"
    .. '"action":' .. action
    .. ',"actor":' .. actor
    .. ',"approval":' .. approval_json
    .. ',"client_command_id":' .. client_command_id
    .. ',"parameters":' .. parameters
    .. ',"source":' .. source
    .. ',"target":' .. target
    .. ',"trace_id":' .. trace_id
    .. "}"
end

local function safe_line(value, limit)
  local first = tostring(value or ""):match("^([^\r\n]*)") or ""
  first = strings.trim(first)
  local normalized = first:lower()
  for _, part in ipairs(SENSITIVE_KEY_PARTS) do
    if normalized:find(part, 1, true) ~= nil then
      return "Machine API request failed"
    end
  end
  local max_len = limit or 256
  if #first > max_len then
    return first:sub(1, max_len)
  end
  return first
end

function M.saga_conformance_errors()
  return {}
end

function M.work_label()
  return WORK_LABEL
end

function M.has_work_label(labels)
  for _, label in ipairs(type(labels) == "table" and labels or {}) do
    if tostring(label) == WORK_LABEL then
      return true
    end
  end
  return false
end

function M.action_catalog()
  return copy(ACTIONS)
end

function M.is_valid_service_slug(value)
  return valid_slug(value)
end

function M.parse_issue_document(body)
  if type(body) ~= "string" or body == "" or #body > MAX_DOCUMENT_BYTES then
    return nil, "invalid issue JSON"
  end
  local envelope, why = decode_json(body, "issue")
  if envelope == nil then
    return nil, why
  end
  local exact, exact_why = exact_fields(envelope, { mode = true, command = true }, "envelope")
  if not exact then
    return nil, exact_why
  end
  local mode = envelope.mode or "preview"
  if mode ~= "preview" and mode ~= "live" then
    return nil, "mode must be preview or live"
  end
  local command = envelope.command
  local command_exact, command_why = exact_fields(command, {
    action = true,
    target = true,
    parameters = true,
  }, "command")
  if not command_exact then
    return nil, command_why
  end
  if type(command.action) ~= "string" or ACTION_BY_NAME[command.action] == nil then
    return nil, "unsupported action"
  end
  if type(command.target) ~= "table" or table_shape(command.target) ~= "object" then
    return nil, "target must be an object"
  end
  if type(command.parameters) ~= "table" or table_shape(command.parameters) ~= "object" then
    return nil, "parameters must be an object"
  end
  local valid, valid_why = validate_json_value(command, { nodes = 0 }, 0, "$.command")
  if not valid then
    return nil, valid_why
  end
  if command.action == "group.profile_scan" and command.parameters.dry_run == false then
    return nil, "group.profile_scan is always dry-run"
  end
  local canonical, canonical_why = canonical_json(command)
  if canonical == nil then
    return nil, canonical_why
  end
  return {
    mode = mode,
    action = command.action,
    target = copy(command.target),
    parameters = copy(command.parameters),
    canonical_json = canonical,
    risk_tier = ACTION_BY_NAME[command.action].risk_tier,
    required_scope = ACTION_BY_NAME[command.action].required_scope,
    forced_dry_run = ACTION_BY_NAME[command.action].forced_dry_run,
  }, nil
end

function M.telegram_command_request(payload, trigger)
  if type(payload) ~= "table" or payload.type ~= "issue" then
    return nil, "not a GitHub issue event"
  end
  if payload.schema ~= "github-proxy.v1" and payload.schema ~= "github-proxy.issue-observed.v1" then
    return nil, "unsupported GitHub event schema"
  end
  local pointer, why = source_ref(payload.source_ref)
  if pointer == nil then
    return nil, why
  end
  local event_trigger = trigger == "observed" and "observed" or "changed"
  local version = safe_segment(payload.updated_at or payload.dedup_key or "unversioned", 80)
  local pointer_key = safe_segment(pointer.ref, 100)
  return {
    schema = "telegram-governance.command-request.v1",
    trigger = event_trigger,
    updated_at = tostring(payload.updated_at or ""),
    source_ref = {
      kind = pointer.kind,
      ref = pointer.ref,
      reference = pointer.reference,
    },
    dedup_key = "telegram-governance/intake/" .. pointer_key .. "/" .. version,
    trace_id = "tg-intake:" .. digest(pointer.ref),
  }, nil
end

local function approval_evidence(document, current_issue, opts)
  local options = opts or {}
  local author = tostring(current_issue.author_login or "")
  if not has_login(options.trusted_author_logins, author) then
    return nil, "issue author is not trusted for destructive action"
  end
  local pointer = source_ref(current_issue.source_ref)
  if pointer == nil then
    return nil, "destructive approval missing"
  end
  local selected = nil
  for _, comment in ipairs(current_issue.comments or {}) do
    local approver = tostring(comment.author_login or "")
    local comment_id = tostring(comment.id or "")
    local approved_at = tostring(comment.created_at or "")
    if approver ~= ""
      and approver:lower() ~= author:lower()
      and has_login(options.approver_logins, approver)
      and tostring(comment.body or "") == document.canonical_json
      and approved_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%d%.]*Z$") ~= nil
      and comment_id:match("^[A-Za-z0-9_-]+$") ~= nil then
      selected = {
        approved_by = approver,
        approved_at = approved_at,
        canonical_json = document.canonical_json,
        comment_url = "https://github.com/" .. pointer.repo .. "/issues/"
          .. tostring(pointer.issue_number) .. "#issuecomment-" .. comment_id,
      }
    end
  end
  if selected == nil then
    return nil, "destructive approval missing"
  end
  return selected, nil
end

function M.authorize_live(document, current_issue, opts)
  local options = opts or {}
  if type(document) ~= "table" or document.mode ~= "live" then
    return nil, "not a live command"
  end
  if options.nyxid_access_token_present ~= true then
    return nil, "nyxid access token missing"
  end
  if options.write_enabled ~= true then
    return nil, "ordinary write switch disabled"
  end
  if tostring(options.ordinary_service or "") == "" then
    return nil, "ordinary NyxID service missing"
  end
  if not valid_slug(options.ordinary_service) then
    return nil, "invalid ordinary NyxID service slug"
  end
  if document.risk_tier ~= "R2" then
    return { service = options.ordinary_service, approval = nil }, nil
  end
  if options.destructive_write_enabled ~= true then
    return nil, "destructive write switch disabled"
  end
  if tostring(options.destructive_service or "") == "" then
    return nil, "destructive NyxID service missing"
  end
  if not valid_slug(options.destructive_service) then
    return nil, "invalid destructive NyxID service slug"
  end
  if options.destructive_service == options.ordinary_service then
    return nil, "destructive NyxID service must be independent"
  end
  local approval, why = approval_evidence(document, current_issue, options)
  if approval == nil then
    return nil, why
  end
  return { service = options.destructive_service, approval = approval }, nil
end

function M.machine_command(document, current_issue, approval)
  if type(document) ~= "table" or ACTION_BY_NAME[document.action] == nil then
    return nil, "invalid command document"
  end
  local pointer, why = source_ref(current_issue and current_issue.source_ref)
  if pointer == nil then
    return nil, why
  end
  local actor = tostring(current_issue.author_login or "")
  if actor == "" or actor:match("^[A-Za-z0-9_.-]+$") == nil or #actor > 100 then
    return nil, "invalid GitHub actor"
  end
  if document.risk_tier == "R2" and type(approval) ~= "table" then
    return nil, "destructive approval missing"
  end
  local identity = command_identity(document, pointer)
  local body = {
    client_command_id = identity.client_command_id,
    action = document.action,
    target = copy(document.target),
    parameters = copy(document.parameters),
    source = {
      provider = "github",
      repository = pointer.repo,
      issue_number = pointer.issue_number,
      source_ref = "github://" .. pointer.repo .. "/issues/" .. tostring(pointer.issue_number),
    },
    actor = { login = actor },
    approval = approval and copy(approval) or nil,
    trace_id = identity.trace_id,
  }
  return {
    body = body,
    body_json = command_body_json(body, approval),
    idempotency_key = identity.idempotency_key,
  }, nil
end

function M.decode_proxy_response(stdout, label)
  return decode_proxy_stdout(stdout, label or "NyxID proxy response")
end

function M.validate_capabilities(value)
  local capabilities = value
  if type(value) == "string" then
    capabilities = decode_proxy_stdout(value, "Machine capabilities")
  end
  if type(capabilities) ~= "table" or capabilities.version ~= "v1" or type(capabilities.actions) ~= "table" then
    return false, "invalid Machine API capabilities"
  end
  local actual = {}
  local count = 0
  for _, item in ipairs(capabilities.actions) do
    if type(item) ~= "table" or type(item.action) ~= "string" or actual[item.action] ~= nil then
      return false, "Machine API action catalog mismatch"
    end
    actual[item.action] = item
    count = count + 1
  end
  if count ~= #ACTIONS then
    return false, "Machine API action catalog mismatch"
  end
  for _, expected in ipairs(ACTIONS) do
    local item = actual[expected.action]
    if item == nil then
      return false, "Machine API action catalog mismatch"
    end
    if item.risk_tier ~= expected.risk_tier
      or item.required_scope ~= expected.required_scope
      or item.forced_dry_run ~= expected.forced_dry_run then
      return false, "Machine API action metadata mismatch"
    end
  end
  local exclusions = {}
  for _, item in ipairs(type(capabilities.exclusions) == "table" and capabilities.exclusions or {}) do
    exclusions[tostring(item)] = true
  end
  for required, _ in pairs(REQUIRED_EXCLUSIONS) do
    if not exclusions[required] then
      return false, "Machine API exclusions mismatch"
    end
  end
  return true, nil
end

function M.normalize_machine_response(value)
  local response = value
  if type(value) == "string" then
    response = decode_proxy_stdout(value, "Machine command")
  end
  if type(response) ~= "table" then
    return nil, "invalid Machine API response"
  end
  local status = tostring(response.status or "")
  if not COMMAND_STATUSES[status] then
    return nil, "invalid Machine API status"
  end
  local command_id = tostring(response.command_id or "")
  if command_id == "" or #command_id > 128 or command_id:find("%s") ~= nil then
    return nil, "invalid Machine API command_id"
  end
  local action = tostring(response.action or "")
  if ACTION_BY_NAME[action] == nil then
    return nil, "invalid Machine API action"
  end
  local error_value = type(response.error) == "table" and response.error or {}
  return {
    command_id = command_id,
    client_command_id = safe_line(response.client_command_id, 128),
    action = action,
    status = status,
    risk_tier = ACTION_BY_NAME[action].risk_tier,
    trace_id = safe_line(response.trace_id, 128),
    error_code = safe_line(error_value.code, 128),
    error_message = safe_line(error_value.message, 256),
  }, nil
end

function M.validate_response_binding(response, command)
  if type(response) ~= "table" or type(command) ~= "table" or type(command.body) ~= "table" then
    return false, "invalid Machine API response binding"
  end
  if response.action ~= command.body.action then
    return false, "Machine API response action mismatch"
  end
  if response.client_command_id == "" or response.client_command_id ~= command.body.client_command_id then
    return false, "Machine API response client_command_id mismatch"
  end
  if response.trace_id == "" or response.trace_id ~= command.body.trace_id then
    return false, "Machine API response trace_id mismatch"
  end
  return true, nil
end

function M.preview_receipt(document, current_issue)
  local command, why = M.machine_command(document, current_issue, document.risk_tier == "R2" and {} or nil)
  if command == nil then
    return nil, why
  end
  return {
    schema = "telegram-governance.command-receipt.v1",
    action = document.action,
    status = "preview",
    risk_tier = document.risk_tier,
    idempotency_key = command.idempotency_key,
    trace_id = command.body.trace_id,
    source_ref = copy(current_issue.source_ref),
  }, nil
end

function M.blocked_receipt(document, current_issue, reason)
  local identity = nil
  local pointer = source_ref(current_issue and current_issue.source_ref)
  if pointer ~= nil then
    if type(document) == "table" then
      identity = command_identity(document, pointer)
    else
      local blocked_digest = digest(pointer.ref)
      identity = {
        idempotency_key = "telegram-governance/blocked/" .. blocked_digest,
        trace_id = "tg:blocked:" .. blocked_digest,
      }
    end
  end
  return {
    schema = "telegram-governance.command-receipt.v1",
    action = type(document) == "table" and document.action or "unknown",
    status = "blocked",
    risk_tier = type(document) == "table" and document.risk_tier or "unknown",
    idempotency_key = identity and identity.idempotency_key or "telegram-governance/blocked/unknown",
    trace_id = identity and identity.trace_id or "tg:blocked",
    blocked_reason = safe_line(reason, 256),
    source_ref = copy(current_issue and current_issue.source_ref or {}),
  }
end

function M.response_receipt(document, current_issue, command, response)
  return {
    schema = "telegram-governance.command-receipt.v1",
    command_id = response.command_id,
    client_command_id = response.client_command_id,
    action = response.action,
    status = response.status,
    risk_tier = response.risk_tier or document.risk_tier,
    idempotency_key = command.idempotency_key,
    trace_id = response.trace_id ~= "" and response.trace_id or command.body.trace_id,
    error_code = response.error_code ~= "" and response.error_code or nil,
    error_message = response.error_message ~= "" and response.error_message or nil,
    source_ref = copy(current_issue.source_ref),
  }
end

function M.receipt_comment(payload)
  if type(payload) ~= "table"
    or payload.schema ~= "telegram-governance.command-receipt.v1"
    or not RECEIPT_STATUSES[tostring(payload.status or "")] then
    return nil, "invalid Telegram governance receipt"
  end
  local pointer, why = source_ref(payload.source_ref)
  if pointer == nil then
    return nil, why
  end
  local status = tostring(payload.status)
  local identity = tostring(payload.command_id or "")
  if identity == "" then
    identity = safe_segment(payload.idempotency_key or "unknown", 128)
  else
    identity = safe_segment(identity, 128)
  end
  local dedup_key = "telegram-governance/receipt/" .. identity .. "/" .. safe_segment(status, 32)
  local body = "Telegram governance receipt\n\n"
    .. "status: " .. safe_line(status, 32) .. "\n"
    .. "action: " .. safe_line(payload.action, 128) .. "\n"
    .. "risk_tier: " .. safe_line(payload.risk_tier, 16) .. "\n"
  if tostring(payload.command_id or "") ~= "" then
    body = body .. "command_id: " .. safe_line(payload.command_id, 128) .. "\n"
  end
  if tostring(payload.error_code or "") ~= "" then
    body = body .. "error_code: " .. safe_line(payload.error_code, 128) .. "\n"
  end
  if tostring(payload.error_message or "") ~= "" then
    body = body .. "error_message: " .. safe_line(payload.error_message, 256) .. "\n"
  end
  if tostring(payload.blocked_reason or "") ~= "" then
    body = body .. "blocked_reason: " .. safe_line(payload.blocked_reason, 256) .. "\n"
  end
  body = body
    .. "trace_id: " .. safe_line(payload.trace_id, 128) .. "\n"
    .. "source_ref: " .. safe_line(pointer.ref, 256) .. "\n\n"
    .. "<!-- fkst:github-proxy:comment:" .. safe_line(dedup_key, 256) .. " -->\n"
  return {
    schema = "github-proxy.v1",
    repo = pointer.repo,
    issue_number = pointer.issue_number,
    body = body,
    dedup_key = dedup_key,
    source_ref = {
      kind = "external",
      ref = pointer.ref,
      reference = pointer.reference,
    },
  }, nil
end

return M
