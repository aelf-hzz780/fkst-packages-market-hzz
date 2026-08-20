local markdown_fields = require("contract.markdown_fields")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {
  CONTRACT = "auto-twitter-marketing.weekly-content.v2",
}

local FIELD_NAMES = {
  account = "account",
  ["approval-id"] = "approval_id",
  contract = "contract",
  ["content-digest"] = "content_digest",
  ["content-id"] = "content_id",
  ["content-revision"] = "content_revision",
  ["content-status"] = "content_status",
  operation = "operation",
  project = "project",
  ["proposal-id"] = "proposal_id",
  ["proposal-revision"] = "proposal_revision",
  ["quote-mode"] = "quote_mode",
  ["quote-url"] = "quote_url",
  type = "type",
  week = "week",
  ["work-label"] = "work_label",
}

local CANONICAL_FIELDS = {
  "contract",
  "type",
  "project",
  "account",
  "work_label",
  "week",
  "content_id",
  "content_revision",
  "proposal_id",
  "proposal_revision",
  "approval_id",
  "content_status",
  "operation",
  "quote_mode",
  "quote_url",
  "tweet_text",
}

local function bounded(value, limit)
  return type(value) == "string"
    and value ~= ""
    and value == strings.trim(value)
    and #value <= limit
    and value:find("[%z\1-\31\127]") == nil
end

local function positive_integer(value)
  local number = tonumber(value)
  if number == nil or number < 1 or number ~= math.floor(number) then
    return nil
  end
  return number
end

local function normalized_record(input)
  if type(input) ~= "table" then
    return nil, "invalid content contract"
  end
  local account = session_route.normalize_account(input.account)
  local operation = strings.trim(input.operation or "post"):lower()
  local record = {
    contract = strings.trim(input.contract or M.CONTRACT),
    type = strings.trim(input.type or "weekly-content"):lower(),
    project = strings.trim(input.project),
    account = account,
    work_label = strings.trim(input.work_label),
    week = strings.trim(input.week),
    content_id = strings.trim(input.content_id),
    content_revision = positive_integer(input.content_revision),
    proposal_id = strings.trim(input.proposal_id),
    proposal_revision = positive_integer(input.proposal_revision),
    approval_id = strings.trim(input.approval_id),
    content_status = strings.trim(input.content_status):lower(),
    operation = operation,
    quote_mode = strings.trim(input.quote_mode):lower(),
    quote_url = strings.trim(input.quote_url),
    tweet_text = strings.trim(tostring(input.tweet_text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")),
  }
  if record.contract ~= M.CONTRACT then
    return nil, "unsupported content contract"
  end
  if record.type ~= "weekly-content" then
    return nil, "invalid content type"
  end
  if account == nil or strings.trim(input.account) ~= account then
    return nil, "invalid content account"
  end
  if not bounded(record.project, 120) or not bounded(record.work_label, 80)
      or not bounded(record.content_id, 180) or not bounded(record.proposal_id, 180)
      or not bounded(record.approval_id, 256) then
    return nil, "invalid content identity"
  end
  if record.week:match("^%d%d%d%d%-W%d%d$") == nil then
    return nil, "invalid content week"
  end
  if record.content_revision == nil or record.proposal_revision == nil then
    return nil, "invalid content revision"
  end
  if record.content_status ~= "approved" then
    return nil, "content is not approved"
  end
  if record.approval_id ~= record.proposal_id .. "@" .. tostring(record.proposal_revision) then
    return nil, "content approval mismatch"
  end
  if record.operation ~= "post" and record.operation ~= "quote" then
    return nil, "unsupported content operation"
  end
  if record.operation == "post" and (record.quote_mode ~= "" or record.quote_url ~= "") then
    return nil, "post content carries quote controls"
  end
  if record.operation == "quote"
      and ((record.quote_mode ~= "native" and record.quote_mode ~= "link") or record.quote_url == "") then
    return nil, "invalid quote content"
  end
  if record.tweet_text == "" or #record.tweet_text > 1200 then
    return nil, "invalid tweet text"
  end
  return record, nil
end

local function append_canonical(parts, name, value)
  local text = tostring(value or "")
  parts[#parts + 1] = name
  parts[#parts + 1] = tostring(#text)
  parts[#parts + 1] = text
end

function M.digest(input)
  local record, why = normalized_record(input)
  if record == nil then
    return nil, why
  end
  local parts = {}
  for _, name in ipairs(CANONICAL_FIELDS) do
    append_canonical(parts, name, record[name])
  end
  return sha256.tagged(table.concat(parts, "\n")), nil
end

local function append(lines, key, value)
  lines[#lines + 1] = key .. ": " .. tostring(value)
end

function M.render(input)
  local record, why = normalized_record(input)
  if record == nil then
    return nil, why
  end
  local digest = assert(M.digest(record))
  local lines = {}
  append(lines, "contract", record.contract)
  append(lines, "type", record.type)
  append(lines, "project", record.project)
  append(lines, "account", record.account)
  append(lines, "work-label", record.work_label)
  append(lines, "week", record.week)
  append(lines, "content-id", record.content_id)
  append(lines, "content-revision", record.content_revision)
  append(lines, "proposal-id", record.proposal_id)
  append(lines, "proposal-revision", record.proposal_revision)
  append(lines, "approval-id", record.approval_id)
  append(lines, "content-status", record.content_status)
  append(lines, "content-digest", digest)
  if record.operation ~= "post" then
    append(lines, "operation", record.operation)
    append(lines, "quote-mode", record.quote_mode)
    append(lines, "quote-url", record.quote_url)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "tweet-text:"
  lines[#lines + 1] = markdown_fields.render_fenced(record.tweet_text)
  return table.concat(lines, "\n"), digest
end

local function parse_fields(body)
  if type(body) ~= "string" or #body > 32000 then
    return nil, "invalid content body"
  end
  local fields = {}
  local tokens, token_why = markdown_fields.tokenize(body)
  if tokens == nil then
    return nil, "invalid content body"
  end
  for _, token in ipairs(tokens) do
    if token.kind == "text" then
      local line = token.line
      local key, value = line:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
      if key ~= nil then
        local normalized = key:lower():gsub("_", "-")
        if normalized ~= "tweet-text" then
          local target = FIELD_NAMES[normalized]
          if target == nil then
            return nil, "unsupported content field"
          end
          if fields[target] ~= nil then
            return nil, "duplicate content field"
          end
          fields[target] = strings.trim(value)
        end
      end
    end
  end
  if token_why ~= nil then
    return nil, "unterminated content fence"
  end
  local tweet, tweet_why = markdown_fields.fenced_field(body, "tweet-text")
  if tweet == nil then
    if tweet_why == "duplicate-fenced-field:tweet-text" then
      return nil, "duplicate tweet text"
    end
    return nil, "missing tweet text"
  end
  fields.tweet_text = tweet
  return fields, nil
end

function M.parse(body)
  local fields, why = parse_fields(body)
  if fields == nil then
    return nil, why
  end
  if fields.contract == nil or fields.type == nil then
    return nil, "missing content contract identity"
  end
  local declared = fields.content_digest
  if not sha256.is_tagged(declared) then
    return nil, "invalid content digest"
  end
  fields.content_digest = nil
  local record, normalize_why = normalized_record(fields)
  if record == nil then
    return nil, normalize_why
  end
  local actual = assert(M.digest(record))
  if actual ~= declared then
    return nil, "content digest mismatch"
  end
  record.content_digest = actual
  return record, nil
end

return M
