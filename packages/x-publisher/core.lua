-- x-publisher/core.lua - pure, side-effect-free publish contract helpers. Payloads carry only
-- small control fields and a source_ref pointer; post content is re-fetched by the host seam.
local M = {}
local strings = require("contract.strings")
local x_text = require("contract.x_text")
local x_publishing_contract = require("contract.x_publishing_contract")
local published_receipt = require("published_receipt")
local dedup_keys = require("x_publisher_dedup_key")

local function values_by_name(values)
  local names = {}
  for _, value in ipairs(values or {}) do
    names[value] = value
  end
  return names
end

local function contains(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then
      return true
    end
  end
  return false
end

local OPERATIONS = values_by_name((function()
  local names = {}
  for _, definition in ipairs(x_publishing_contract.operations or {}) do
    table.insert(names, definition.name)
  end
  return names
end)())
local QUOTE_MODES = values_by_name(
  x_publishing_contract.operations_by_name.quote.modes
)
local RECEIPT_STATUSES = values_by_name(x_publishing_contract.receipt_statuses)
local ERROR_CODES = values_by_name(x_publishing_contract.error_codes)
local CONSUMER_CAPABILITIES = x_publishing_contract.consumer_capabilities["fkst-x-publisher"]
local NATIVE_PROVIDER_POST_ID_FIELD = "quote_tweet_id"

local TOP_LEVEL_FIELDS = {
  artifact_id = true,
  source_ref = true,
  content_ref = true,
  platform = true,
  channel = true,
  dedup_key = true,
  trace_id = true,
  approval_id = true,
  scheduled_at = true,
  metadata = true,
}

local SENSITIVE_PATTERNS = {
  "token",
  "bearer",
  "oauth",
  "secret",
  "credential",
  "password",
  "api_key",
  "apikey",
  "authorization",
  "provider_response",
  "raw_response",
}

local CONTENT_FIELDS = {
  tweet = true,
  body = true,
  text = true,
  message = true,
  media_bytes = true,
  media = true,
  raw = true,
  raw_provider_response = true,
  provider_raw_response = true,
  provider_response = true,
}

local SOURCE_REF_FIELDS = {
  kind = true,
  ref = true,
  reference = true,
  uri = true,
  version = true,
}

local METADATA_FIELDS = {
  campaign_id = true,
  content_type = true,
  interval_minutes = true,
  occurrence_id = true,
  locale = true,
  owner = true,
  schedule_type = true,
  tag = true,
  variant = true,
}

local SCALAR_TYPES = {
  boolean = true,
  number = true,
  string = true,
}

function M.persistence_class()
  return "saga"
end

function M.saga_conformance_errors()
  return {}
end

local function is_scalar(value)
  return SCALAR_TYPES[type(value)] == true
end

local function is_small_scalar(value)
  local value_type = type(value)
  if not SCALAR_TYPES[value_type] then
    return false
  end
  if value_type == "string" and #value > 512 then
    return false
  end
  return true
end

local function has_sensitive_name(key)
  local normalized = tostring(key or ""):lower()
  for _, pattern in ipairs(SENSITIVE_PATTERNS) do
    if normalized:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function has_denylisted_name(key)
  local normalized = tostring(key or ""):lower()
  return CONTENT_FIELDS[normalized] == true or has_sensitive_name(key)
end

local function validate_small_table(value, allowed_fields, label)
  if type(value) ~= "table" then
    return false, "invalid " .. label
  end
  local count = 0
  for key, item in pairs(value) do
    count = count + 1
    local key_type = type(key)
    if key_type ~= "string" or allowed_fields[key] ~= true then
      return false, "unsupported " .. label .. " field"
    end
    if has_denylisted_name(key) then
      return false, "unsafe " .. label .. " field"
    end
    if not is_small_scalar(item) then
      return false, "unsafe " .. label .. " value"
    end
    if count > 12 then
      return false, label .. " too large"
    end
  end
  return true, nil
end

local function copy_allowed_scalars(source, allowed_fields)
  local safe = {}
  if type(source) ~= "table" then
    return safe
  end
  for key, value in pairs(source) do
    local allowed = allowed_fields[key] == true
    if allowed and is_small_scalar(value) then
      safe[key] = value
    end
  end
  return safe
end

local function source_ref_reference(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  local reference = source_ref.ref or source_ref.reference
  if type(reference) ~= "string" or reference == "" then
    return nil
  end
  return reference
end

local function source_ref_repo(source_ref)
  local reference = source_ref_reference(source_ref)
  if reference == nil then
    return nil
  end
  return reference:match("^([^#]+)#issue/%d+$")
end

local function normalized_platform(platform)
  if platform == nil or platform == "" then
    return "x"
  end
  local value = tostring(platform):lower()
  if value == "x" or value == "twitter" then
    return "x"
  end
  return nil
end

-- A publish request is usable only if it carries an artifact_id and a safe source_ref pointer.
-- Fail-closed: unsupported fields, content fields, or sensitive field names are rejected.
function M.validate_publish_request(payload)
  payload = payload or {}
  if type(payload) ~= "table" then
    return false, "invalid payload"
  end
  for key, _ in pairs(payload) do
    if type(key) ~= "string" or not TOP_LEVEL_FIELDS[key] then
      return false, "unsupported field"
    end
    if has_denylisted_name(key) then
      return false, "unsafe field"
    end
  end
  if type(payload.artifact_id) ~= "string" or payload.artifact_id == "" then
    return false, "missing artifact_id"
  end
  if source_ref_reference(payload.source_ref) == nil then
    return false, "missing source_ref"
  end
  local platform = normalized_platform(payload.platform)
  if not platform then
    return false, "unsupported platform"
  end
  local source_ok, source_why = validate_small_table(payload.source_ref, SOURCE_REF_FIELDS, "source_ref")
  if not source_ok then
    return false, source_why
  end
  if payload.metadata ~= nil then
    local metadata_ok, metadata_why = validate_small_table(payload.metadata, METADATA_FIELDS, "metadata")
    if not metadata_ok then
      return false, metadata_why
    end
  end
  local dedup_key = payload.dedup_key
  if dedup_key ~= nil and not dedup_keys.is_canonical(dedup_key) then
    return false, "invalid dedup_key"
  end
  for _, field in ipairs({ "channel", "dedup_key", "trace_id", "approval_id", "scheduled_at" }) do
    if payload[field] ~= nil and not is_small_scalar(payload[field]) then
      return false, "invalid " .. field
    end
  end
  if payload.content_ref ~= nil and not is_small_scalar(payload.content_ref) then
    return false, "invalid content_ref"
  end
  return true, nil
end

function M.is_usable_request(payload)
  return M.validate_publish_request(payload)
end

local function receipt_trace_id(payload)
  for _, field in ipairs({ "trace_id", "dedup_key", "artifact_id" }) do
    local value = type(payload) == "table" and payload[field] or nil
    if type(value) == "string" and strings.trim(value) ~= "" then
      return value
    end
  end
  return "fkst-x-publisher"
end

function M.preview_receipt(payload, status)
  if type(payload) ~= "table" then
    payload = {}
  end
  local source_ref = copy_allowed_scalars(payload.source_ref, SOURCE_REF_FIELDS)
  if source_ref.ref == nil and source_ref.reference ~= nil then
    source_ref.ref = source_ref.reference
  end
  if source_ref.reference == nil and source_ref.ref ~= nil then
    source_ref.reference = source_ref.ref
  end
  return {
    artifact_id = payload.artifact_id,
    platform = "x",
    status = status or RECEIPT_STATUSES.preview,
    post_uri = nil,
    source_ref = source_ref,
    content_ref = payload.content_ref,
    channel = payload.channel,
    dedup_key = payload.dedup_key,
    trace_id = receipt_trace_id(payload),
    traceId = receipt_trace_id(payload),
    approval_id = payload.approval_id,
    scheduled_at = payload.scheduled_at,
    metadata = copy_allowed_scalars(payload.metadata, METADATA_FIELDS),
  }
end

local function normalized_channel(payload)
  if type(payload) ~= "table" then
    return "shadow"
  end
  local channel = tostring(payload.channel or ""):lower()
  if channel == "live" then
    return "live"
  end
  local metadata = payload.metadata
  if type(metadata) == "table" and tostring(metadata.variant or ""):lower() == "live" then
    return "live"
  end
  return "shadow"
end

local function safe_service_slug(value)
  local slug = strings.trim(value)
  if slug == "" then
    return nil
  end
  if slug:find("secret://", 1, true) or slug:find("token", 1, true) then
    return nil
  end
  if not slug:match("^[%w._-]+$") then
    return nil
  end
  return slug
end

function M.live_gate(payload, opts)
  local options = opts or {}
  local service_slug = safe_service_slug(options.nyxid_x_service)
  if normalized_channel(payload) ~= "live" then
    return false, "not live"
  end
  if options.live_write_enabled ~= true then
    return false, "live gate disabled"
  end
  if service_slug == nil then
    return false, "missing nyxid x service"
  end
  return true, nil
end

function M.publish_once_key(payload)
  if type(payload) ~= "table" or type(payload.dedup_key) ~= "string" or payload.dedup_key == "" then
    return nil
  end
  local raw = payload.dedup_key
  local segment = strings.runtime_safe_segment(raw)
  local suffix = "_" .. strings.decimal_checksum(raw)
  if #segment > 160 then
    segment = segment:sub(1, 160 - #suffix) .. suffix
  end
  return "x-publisher/publish/" .. segment
end

M.trusted_published_receipt = published_receipt.trusted_published_receipt

local function metadata_tag_content_ref(payload)
  if type(payload) ~= "table" or type(payload.metadata) ~= "table" then
    return nil
  end
  local tag = tostring(payload.metadata.tag or "")
  return tag:match("^calendar:(.+)$")
end

function M.content_source_ref(payload)
  if type(payload) ~= "table" then
    return nil, "invalid payload"
  end
  local raw_ref = strings.trim(payload.content_ref or metadata_tag_content_ref(payload))
  if raw_ref == "" then
    return nil, "missing content_ref"
  end

  local direct_repo, direct_number = raw_ref:match("^([^#]+)#issue/(%d+)$")
  if direct_repo ~= nil then
    local reference = direct_repo .. "#issue/" .. direct_number
    return { kind = "external", ref = reference, reference = reference }, nil
  end

  local url_repo, url_issue = raw_ref:match("^https://github%.com/([^/]+/[^/]+)/issues/(%d+)")
  if url_repo ~= nil then
    local reference = url_repo .. "#issue/" .. url_issue
    return { kind = "external", ref = reference, reference = reference }, nil
  end

  local number = raw_ref:match("^#(%d+)$") or raw_ref:match("^(%d+)$")
  if number ~= nil then
    local repo = source_ref_repo(payload.source_ref)
    if repo == nil then
      return nil, "content_ref requires issue source_ref repo"
    end
    local reference = repo .. "#issue/" .. number
    return { kind = "external", ref = reference, reference = reference }, nil
  end

  return nil, "unsupported content_ref"
end

local TWEET_PLACEHOLDERS = {
  interval_minutes = true,
  occurrence_id = true,
  scheduled_at = true,
  schedule_type = true,
}

local function template_scalar(value)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return strings.trim(value)
  end
  return ""
end

local function tweet_placeholder_value(name, payload)
  local data = type(payload) == "table" and payload or {}
  local metadata = type(data.metadata) == "table" and data.metadata or {}
  if name == "scheduled_at" then
    return template_scalar(data.scheduled_at)
  end
  if name == "occurrence_id" then
    return template_scalar(metadata.occurrence_id or data.scheduled_at)
  end
  if name == "interval_minutes" then
    return template_scalar(metadata.interval_minutes)
  end
  if name == "schedule_type" then
    return template_scalar(metadata.schedule_type)
  end
  return ""
end

local function render_tweet_template(text, payload)
  local failure = nil
  local rendered = tostring(text or ""):gsub("{{%s*([%w_%-]+)%s*}}", function(name)
    if not TWEET_PLACEHOLDERS[name] then
      failure = "unsupported tweet placeholder"
      return ""
    end
    local value = tweet_placeholder_value(name, payload)
    if value == "" then
      failure = "missing tweet placeholder value"
      return ""
    end
    return value
  end)
  if failure ~= nil then
    return nil, failure
  end
  return rendered, nil
end

local function normalize_tweet_text(text, payload, transformed_urls)
  local rendered, template_why = render_tweet_template(text, payload)
  if rendered == nil then
    return nil, template_why
  end
  local cleaned = strings.trim(rendered:gsub("\r\n", "\n"):gsub("\r", "\n"))
  if cleaned == "" then
    return nil, "missing tweet text"
  end
  local analysis = x_text.analyze(cleaned, { transformed_urls = transformed_urls })
  if not analysis.valid then
    return nil, "tweet text too long"
  end
  return cleaned, nil, analysis.weighted_length
end

local function extract_tweet_text_value(body)
  local text = tostring(body or "")
  for _, marker in ipairs({ "tweet%-text", "tweet", "x%-post", "post" }) do
    local fenced = text:match(marker .. "%s*:%s*```[^\n]*\n(.-)\n```")
    if fenced ~= nil then
      return fenced
    end
  end
  for line in text:gmatch("[^\r\n]+") do
    for _, marker in ipairs({ "tweet%-text", "tweet", "x%-post", "post" }) do
      local inline = line:match("^%s*" .. marker .. "%s*:%s*(.-)%s*$")
      if inline ~= nil and strings.trim(inline) ~= "" and inline:sub(1, 3) ~= "```" then
        return inline
      end
    end
  end
  return nil, "missing tweet text"
end

function M.extract_tweet_text(body, payload)
  local value, why = extract_tweet_text_value(body)
  if value == nil then
    return nil, why
  end
  return normalize_tweet_text(value, payload)
end

local QUOTE_CONTROL_FIELDS = {
  operation = true,
  ["quote-mode"] = true,
  ["quote-url"] = true,
}

local function content_control_fields(body)
  local fields = {}
  local seen = {}
  local in_fence = false
  local text = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"
  for line in text:gmatch("(.-)\n") do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      local key, value = line:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
      local normalized = tostring(key or ""):lower():gsub("_", "-")
      if QUOTE_CONTROL_FIELDS[normalized] then
        if seen[normalized] then
          return nil, "duplicate quote control field"
        end
        seen[normalized] = true
        local cleaned = strings.trim(value)
        if cleaned ~= "" and #cleaned <= 512 then
          fields[normalized] = cleaned
        end
      end
    end
  end
  return fields, nil
end

local function normalize_quote_target(mode, raw_url, canonical_semantics)
  if not QUOTE_MODES[mode] then
    return nil, mode == "" and "missing quote mode" or "unsupported quote mode"
  end
  local url = strings.trim(raw_url)
  if url == "" then
    return nil, "missing quote url"
  end
  if #url > 512 or url:find("#", 1, true) or url:find("%s") then
    return nil, "invalid quote url"
  end

  local scheme, remainder = url:match("^([%a]+)://(.+)$")
  if tostring(scheme or ""):lower() ~= "https" then
    return nil, "invalid quote url"
  end
  local authority, raw_path = tostring(remainder or ""):match("^([^/]+)(/.*)$")
  if authority == nil or authority:find("@", 1, true) or authority:find(":", 1, true) then
    return nil, "invalid quote url"
  end
  local hostname = authority:lower()
  if not canonical_semantics then
    hostname = hostname:gsub("^www%.", "")
  end
  local allowed_host = false
  for _, candidate in ipairs(x_publishing_contract.normalization.quoteTarget.allowedHosts) do
    if hostname == candidate then
      allowed_host = true
      break
    end
  end
  if not allowed_host then
    return nil, "invalid quote url"
  end

  local path = raw_path:match("^([^?]+)")
  local handle, post_id
  if canonical_semantics then
    handle, post_id = path:match("^/([A-Za-z0-9_]+)/status/(%d+)$")
  else
    handle, post_id = path:match("^/([A-Za-z0-9_]+)/status/(%d+)/?$")
    if post_id == nil then
      post_id = path:match("^/i/web/status/(%d+)/?$")
      handle = nil
    end
  end
  if post_id == nil or (handle ~= nil and (#handle < 1 or #handle > 15)) then
    return nil, "invalid quote url"
  end
  local canonical_owner
  if handle == nil then
    canonical_owner = "i/web"
  elseif canonical_semantics then
    canonical_owner = handle
  else
    canonical_owner = handle:lower()
  end
  return {
    mode = mode,
    provider_post_id = post_id,
    url = "https://" .. x_publishing_contract.normalization.quoteTarget.canonicalHost
      .. "/" .. canonical_owner .. "/status/" .. post_id,
    author_handle = handle and handle:lower() or nil,
  }, nil
end

local function contract_trace_id(request)
  local value = type(request) == "table" and request.traceId or nil
  if type(value) == "string" and strings.trim(value) ~= "" then
    return value
  end
  local idempotency_key = type(request) == "table" and request.idempotencyKey or nil
  if type(idempotency_key) == "string" and strings.trim(idempotency_key) ~= "" then
    return "fkst:" .. idempotency_key
  end
  return "fkst-contract-validation"
end

local function blocked_contract_result(request, operation, error_code, extra)
  local result = {
    status = RECEIPT_STATUSES.blocked,
    operation = operation,
    errorCode = error_code,
    traceId = contract_trace_id(request),
  }
  for key, value in pairs(extra or {}) do
    result[key] = value
  end
  return result
end

local function missing_required_field(request, definition)
  for _, field in ipairs(definition.requiredFields or {}) do
    local value = request[field]
    if type(value) ~= "string" or strings.trim(value) == "" then
      return field
    end
  end
  return nil
end

local function request_fields_are_safe(request, definition)
  local allowed = { operation = true }
  for _, field in ipairs(definition.requiredFields or {}) do
    allowed[field] = true
  end
  for _, field in ipairs(definition.optionalFields or {}) do
    allowed[field] = true
  end
  for key, _ in pairs(request) do
    if type(key) ~= "string" or not allowed[key] or has_sensitive_name(key) then
      return false
    end
  end
  return true
end

local function capability_allows(capabilities, operation, quote_mode)
  if type(capabilities) ~= "table" then
    return false
  end
  if not contains(capabilities.operations, operation) then
    return false
  end
  return operation ~= OPERATIONS.quote or contains(capabilities.quoteModes, quote_mode)
end

function M.evaluate_contract_request(request, opts)
  local options = type(opts) == "table" and opts or {}
  if type(request) ~= "table" then
    return blocked_contract_result({}, nil, ERROR_CODES.invalid_request)
  end

  local operation = request.operation
  local definition = type(operation) == "string"
    and x_publishing_contract.operations_by_name[operation] or nil
  if definition == nil then
    local missing_operation = operation == nil or operation == ""
    local code = missing_operation
      and ERROR_CODES.missing_required_field or ERROR_CODES.unsupported_operation
    return blocked_contract_result(request, operation, code)
  end
  if not request_fields_are_safe(request, definition) then
    return blocked_contract_result(request, operation, ERROR_CODES.invalid_request)
  end
  if not contains(CONSUMER_CAPABILITIES.operations, operation) then
    return blocked_contract_result(request, operation, ERROR_CODES.unsupported_capability)
  end

  local missing = missing_required_field(request, definition)
  if missing ~= nil then
    return blocked_contract_result(request, operation, ERROR_CODES.missing_required_field)
  end

  local adapter_capabilities = options.adapter_capabilities or CONSUMER_CAPABILITIES
  if operation ~= OPERATIONS.quote then
    if not capability_allows(adapter_capabilities, operation) then
      return blocked_contract_result(request, operation, ERROR_CODES.unsupported_capability)
    end
    return {
      status = RECEIPT_STATUSES.preview,
      operation = operation,
      text = request.text,
      traceId = contract_trace_id(request),
    }
  end

  if not QUOTE_MODES[request.quoteMode] then
    return blocked_contract_result(request, operation, ERROR_CODES.unsupported_quote_mode)
  end
  if not capability_allows(adapter_capabilities, operation, request.quoteMode) then
    return blocked_contract_result(request, operation, ERROR_CODES.unsupported_capability)
  end

  local quote_post = normalize_quote_target(request.quoteMode, request.quoteTargetUrl, true)
  if quote_post == nil then
    return blocked_contract_result(request, operation, ERROR_CODES.invalid_quote_target)
  end
  if request.quoteTargetPostId ~= nil and request.quoteTargetPostId ~= quote_post.provider_post_id then
    return blocked_contract_result(request, operation, ERROR_CODES.invalid_quote_target)
  end

  local publish_text = request.text
  if request.quoteMode == QUOTE_MODES.link and not publish_text:find(quote_post.url, 1, true) then
    publish_text = publish_text .. "\n\n" .. quote_post.url
  end
  local provider_fields = {}
  if request.quoteMode == QUOTE_MODES.native then
    provider_fields[NATIVE_PROVIDER_POST_ID_FIELD] = quote_post.provider_post_id
  end

  local result = {
    status = RECEIPT_STATUSES.preview,
    operation = operation,
    text = request.text,
    publishText = publish_text,
    quoteMode = request.quoteMode,
    quoteTargetUrl = quote_post.url,
    quoteTargetPostId = quote_post.provider_post_id,
    providerFields = provider_fields,
    traceId = contract_trace_id(request),
  }
  if type(options.provider_result) == "table" and options.provider_result.status == "failed" then
    result.status = RECEIPT_STATUSES.blocked
    result.errorCode = ERROR_CODES[options.provider_result.errorCode]
      or ERROR_CODES.provider_failure
    result.publishText = nil
    result.providerFields = nil
  end
  return result
end

function M.extract_publish_intent(body, payload)
  local fields, fields_why = content_control_fields(body)
  if fields == nil then
    return nil, fields_why
  end
  local operation = strings.trim(fields.operation or OPERATIONS.post):lower()
  local has_quote_fields = fields["quote-mode"] ~= nil or fields["quote-url"] ~= nil
  if x_publishing_contract.operations_by_name[operation] == nil then
    return nil, "unsupported operation"
  end
  if not contains(CONSUMER_CAPABILITIES.operations, operation) then
    return nil, "unsupported operation"
  end
  if operation ~= OPERATIONS.quote and has_quote_fields then
    return nil, "quote fields require quote operation"
  end

  local value, value_why = extract_tweet_text_value(body)
  if value == nil then
    return nil, value_why
  end
  if operation == OPERATIONS.post then
    local text, why, weighted = normalize_tweet_text(value, payload)
    if text == nil then
      return nil, why
    end
    return { operation = OPERATIONS.post, text = text, publish_text = text, weighted_length = weighted }, nil
  end

  local quote_post, quote_why = normalize_quote_target(
    strings.trim(fields["quote-mode"]):lower(),
    fields["quote-url"]
  )
  if quote_post == nil then
    return nil, quote_why
  end
  local text, text_why = normalize_tweet_text(value, payload)
  if text == nil then
    return nil, text_why
  end
  local publish_text = text
  if quote_post.mode == QUOTE_MODES.link and not text:find(quote_post.url, 1, true) then
    publish_text = text .. "\n\n" .. quote_post.url
  end
  local transformed_urls = quote_post.mode == QUOTE_MODES.link and { quote_post.url } or nil
  local normalized_publish_text, publish_why, weighted = normalize_tweet_text(
    publish_text,
    nil,
    transformed_urls
  )
  if normalized_publish_text == nil then
    return nil, publish_why
  end
  return {
    operation = OPERATIONS.quote,
    text = text,
    publish_text = normalized_publish_text,
    weighted_length = weighted,
    quote_post = quote_post,
  }, nil
end

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  return text
end

function M.tweet_body_json(text)
  return '{"text":"' .. json_escape(text) .. '"}'
end

function M.publish_body_json(intent)
  if type(intent) ~= "table" or type(intent.publish_text) ~= "string" then
    return nil
  end
  local body = '{"text":"' .. json_escape(intent.publish_text) .. '"'
  if intent.operation == OPERATIONS.quote and type(intent.quote_post) == "table"
      and intent.quote_post.mode == QUOTE_MODES.native then
    body = body .. ',"quote_tweet_id":"' .. json_escape(intent.quote_post.provider_post_id) .. '"'
  end
  return body .. "}"
end

local function enrich_receipt_with_intent(receipt, intent)
  if type(intent) ~= "table" then
    return receipt
  end
  receipt.operation = intent.operation
  if intent.operation == OPERATIONS.quote and type(intent.quote_post) == "table" then
    receipt.quote_mode = intent.quote_post.mode
    receipt.quote_target_uri = intent.quote_post.url:lower()
    receipt.quote_target_post_id = intent.quote_post.provider_post_id
    receipt.quoteMode = intent.quote_post.mode
    receipt.quoteTargetUrl = intent.quote_post.url
    receipt.quoteTargetPostId = intent.quote_post.provider_post_id
  end
  return receipt
end

local function decode_json(stdout)
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return nil
  end
  local ok, decoded = pcall(json.decode, tostring(stdout or ""))
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

function M.parse_nyxid_username(stdout)
  local decoded = decode_json(stdout)
  local data = type(decoded) == "table" and decoded.data or nil
  return type(data) == "table" and data.username or nil
end

function M.parse_nyxid_tweet_id(stdout)
  local decoded = decode_json(stdout)
  local data = type(decoded) == "table" and decoded.data or nil
  local post_id = type(data) == "table" and data.id or nil
  if type(post_id) == "string" and post_id ~= "" then
    return post_id
  end
  return nil
end

function M.blocked_receipt(payload, reason, intent)
  local receipt = M.preview_receipt(payload, RECEIPT_STATUSES.blocked)
  receipt.blocked_reason = reason
  local error_code = ERROR_CODES.provider_failure
  if reason == "native quote capability disabled" or reason == "live gate disabled"
      or reason == "nyxid access token missing" or reason == "missing nyxid x service"
      or reason == "nyxid cli unavailable" then
    error_code = ERROR_CODES.unsupported_capability
  elseif reason == "unsupported operation" then
    error_code = ERROR_CODES.unsupported_operation
  elseif reason == "unsupported quote mode" then
    error_code = ERROR_CODES.unsupported_quote_mode
  elseif reason == "unsupported capability" then
    error_code = ERROR_CODES.unsupported_capability
  elseif reason == "invalid quote url" then
    error_code = ERROR_CODES.invalid_quote_target
  elseif tostring(reason or ""):find("missing", 1, true) then
    error_code = ERROR_CODES.missing_required_field
  end
  receipt.error_code = error_code
  receipt.errorCode = error_code
  return enrich_receipt_with_intent(receipt, intent)
end

function M.live_receipt(payload, opts)
  local options = opts or {}
  local receipt = M.preview_receipt(payload, RECEIPT_STATUSES.published)
  local post_id = tostring(options.id or "")
  receipt.platform_post_id = post_id
  receipt.post_uri = post_id ~= "" and ("https://x.com/i/web/status/" .. post_id) or nil
  receipt.account_username = options.username
  receipt.nyxid_x_service = safe_service_slug(options.nyxid_x_service)
  return enrich_receipt_with_intent(receipt, options.intent)
end

return M
