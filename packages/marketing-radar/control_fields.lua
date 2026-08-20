local markdown_fields = require("contract.markdown_fields")
local strings = require("contract.strings")

local M = {}

local BODY_LIMIT = 32000
local VALUE_LIMIT = 512
local PROPOSAL_CONTRACT = "marketing-radar.weekly-plan-change.v2"

local ALLOWED_FIELDS = {
  account = true,
  action = true,
  contract = true,
  ["content-digest"] = true,
  ["content-id"] = true,
  ["content-revision"] = true,
  ["content-status"] = true,
  ["change-scope"] = true,
  insight = true,
  project = true,
  ["proposal-id"] = true,
  ["proposal-digest"] = true,
  ["proposal-revision"] = true,
  ["signal-set-digest"] = true,
  ["source-url"] = true,
  status = true,
  ["supersede-mode"] = true,
  ["target-ref"] = true,
  topic = true,
  type = true,
  week = true,
  ["work-label"] = true,
}

local function trim(value) return strings.trim(value or "") end
local function normalized_key(value) return trim(value):lower():gsub("_", "-") end

function M.parse(body)
  local fields = {}
  if type(body) ~= "string" then
    return fields, "invalid-control-body", false, false
  end

  local oversized = #body > BODY_LIMIT
  local first_error = oversized and "control-body-too-large" or nil
  local control_body = oversized and body:sub(1, BODY_LIMIT) or body
  local proposal_contract_seen, proposal_type_seen = false, false
  local tokens, token_why = markdown_fields.tokenize(control_body)
  if tokens == nil then
    return fields, token_why, oversized, false
  end

  for _, token in ipairs(tokens) do
    if token.kind == "text" then
      local line = token.line
      local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
      local normalized = normalized_key(key)
      local cleaned = trim(value)
      if #cleaned <= VALUE_LIMIT then
        proposal_contract_seen = proposal_contract_seen
          or normalized == "contract" and cleaned == PROPOSAL_CONTRACT
        proposal_type_seen = proposal_type_seen
          or normalized == "type" and normalized_key(cleaned) == "weekly-plan-change"
      end
      if ALLOWED_FIELDS[normalized] and cleaned ~= "" then
        if fields[normalized] ~= nil then
          first_error = first_error or "duplicate-control-field:" .. normalized
        elseif #cleaned > VALUE_LIMIT then
          first_error = first_error or "control-field-too-large:" .. normalized
        else
          fields[normalized] = cleaned
        end
      end
    end
  end

  local unterminated = token_why == "unterminated-markdown-fence"
  if unterminated then first_error = first_error or "unterminated-control-fence" end
  local intent = proposal_contract_seen or proposal_type_seen or oversized or unterminated
  return fields, first_error, intent, proposal_contract_seen and proposal_type_seen
end

M.fenced_field = markdown_fields.fenced_field
M.render_fenced = markdown_fields.render_fenced
M.unfenced_lines = markdown_fields.unfenced_lines
M.PROPOSAL_CONTRACT = PROPOSAL_CONTRACT

return M
