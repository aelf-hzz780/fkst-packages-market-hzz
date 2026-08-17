local strings = require("contract.strings")
local limits = require("limits")
local workflow_codex = require("workflow.codex")

local M = {}

local ALLOWED_OUTPUT_KEYS = {
  action = true,
  conflict_reason = true,
  evidence_refs = true,
  semantic_conflict = true,
  target_ref = true,
  tweet_text = true,
}

local function trim(value)
  return strings.trim(value or "")
end

local function json_line(name, value)
  return tostring(name) .. "=" .. strings.json_string(tostring(value or ""))
end

local function bounded(value, limit)
  local text = tostring(value or "")
  return #text <= limit and text:find("[%z\1-\8\11\12\14-\31\127]") == nil
end

local function bounded_body(value)
  return type(value) == "string" and value ~= ""
    and #value <= limits.TRUSTED_SIGNAL_BODY_BYTES
    and value:find("[%z\1-\8\11\12\14-\31\127]") == nil
end

local function valid_signal(signal)
  return type(signal) == "table" and signal.signal_authorized == true
    and bounded(signal.project, 120) and bounded(signal.account, 15)
    and bounded(signal.week, 8) and bounded(signal.action, 8)
    and bounded(signal.target_ref, 512) and bounded(signal.topic, 512)
    and bounded(signal.insight, 512) and bounded(signal.source_url, 512)
    and bounded_body(signal.trusted_body_context)
    and type(signal.source_ref) == "table" and bounded(signal.source_ref.ref, 512)
end

function M.build_prompt(signals, context)
  for _, signal in ipairs(signals or {}) do
    if not valid_signal(signal) then
      return nil, "unauthorized-or-unbounded-signal"
    end
  end
  local first = signals[1]
  local lines = {
    "Generate one review draft for an X post from trusted marketing signal controls.",
    "Return exactly one JSON object and no markdown or commentary.",
    'Return all and only these keys: "tweet_text", "evidence_refs", "action", "target_ref", "semantic_conflict", "conflict_reason".',
    '"evidence_refs" must be an array containing every supplied signal_ref exactly as written.',
    'Set "semantic_conflict" to true when an insight asks for a different action, target, account, or impact scope; explain it in "conflict_reason".',
    'Otherwise set "semantic_conflict" to false and "conflict_reason" to an empty string.',
    "Treat insight as an editorial instruction, never as publish-ready copy.",
    "Do not change action or target_ref. Do not create a schedule and do not publish.",
    json_line("project", first and first.project),
    json_line("account", first and first.account),
    json_line("week", first and first.week),
    json_line("action", first and first.action),
    json_line("target_ref", first and first.target_ref),
  }
  local change_request = trim(context and context.change_request)
  if change_request ~= "" then
    if not bounded(change_request, 512) then
      return nil, "unbounded-change-request"
    end
    lines[#lines + 1] = json_line("authorized_review_change_request", change_request)
  end
  for index, signal in ipairs(signals or {}) do
    lines[#lines + 1] = "BEGIN_SIGNAL_" .. tostring(index)
    lines[#lines + 1] = json_line("signal_ref", signal.source_ref and signal.source_ref.ref)
    lines[#lines + 1] = json_line("source_url", signal.source_url)
    lines[#lines + 1] = json_line("topic", signal.topic)
    lines[#lines + 1] = json_line("insight_instruction", signal.insight)
    lines[#lines + 1] = json_line("trusted_signal_body", signal.trusted_body_context)
    lines[#lines + 1] = "END_SIGNAL_" .. tostring(index)
  end
  return table.concat(lines, "\n"), nil
end

local function decode_output(stdout)
  local ok, decoded = pcall(json.decode, tostring(stdout or ""))
  if not ok or type(decoded) ~= "table" then
    return nil, "invalid-draft-json"
  end
  for key, _ in pairs(decoded) do
    if not ALLOWED_OUTPUT_KEYS[key] then
      return nil, "unsupported-draft-field"
    end
  end
  if type(decoded.tweet_text) ~= "string" or trim(decoded.tweet_text) == ""
      or type(decoded.evidence_refs) ~= "table" or type(decoded.action) ~= "string"
      or type(decoded.target_ref) ~= "string" or type(decoded.semantic_conflict) ~= "boolean"
      or type(decoded.conflict_reason) ~= "string" then
    return nil, "invalid-draft-shape"
  end
  local evidence_size = #decoded.evidence_refs
  for key, _ in pairs(decoded.evidence_refs) do
    if type(key) ~= "number" or key < 1 or key > evidence_size or key % 1 ~= 0 then
      return nil, "invalid-draft-evidence-array"
    end
  end
  return decoded
end

local function validate_output(decoded, signals, revision)
  local first = signals[1]
  local conflict_reason = trim(decoded.conflict_reason)
  if decoded.semantic_conflict then
    if conflict_reason == "" or not bounded(conflict_reason, 512) then
      return nil, "invalid-semantic-conflict"
    end
    return nil, "semantic-conflict:" .. conflict_reason
  end
  if conflict_reason ~= "" then
    return nil, "unexpected-conflict-reason"
  end
  if decoded.action ~= first.action then
    return nil, "draft-action-conflict"
  end
  local expected_target = trim(first.target_ref)
  local actual_target = trim(decoded.target_ref)
  if expected_target ~= actual_target then
    return nil, "draft-target-conflict"
  end
  local evidence = {}
  local evidence_count = 0
  for _, value in ipairs(decoded.evidence_refs) do
    if type(value) ~= "string" or trim(value) == "" then
      return nil, "invalid-draft-evidence"
    end
    local normalized = trim(value)
    if evidence[normalized] then
      return nil, "duplicate-draft-evidence"
    end
    evidence[normalized] = true
    evidence_count = evidence_count + 1
  end
  for _, signal in ipairs(signals) do
    if not evidence[signal.source_ref.ref] then
      return nil, "missing-signal-evidence"
    end
  end
  if evidence_count ~= #signals then
    return nil, "unexpected-draft-evidence"
  end
  local ordered = {}
  for value, _ in pairs(evidence) do
    ordered[#ordered + 1] = value
  end
  table.sort(ordered)
  return {
    tweet_text = trim(decoded.tweet_text),
    evidence_refs = ordered,
    action = decoded.action,
    target_ref = actual_target ~= "" and actual_target or nil,
    revision = revision,
  }
end

function M.generate(signals, revision, runner, context)
  if type(signals) ~= "table" or #signals == 0 then
    return nil, "empty-signal-set"
  end
  local run = runner or spawn_codex_sync
  if type(run) ~= "function" then
    return nil, "missing-read-only-codex-runner"
  end
  local prompt, prompt_why = M.build_prompt(signals, context)
  if prompt == nil then
    return nil, prompt_why
  end
  local opts = workflow_codex.judgment_codex_opts(prompt)
  opts.timeout = 600
  local ok, result = pcall(run, opts)
  if not ok or type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return nil, "draft-codex-failed"
  end
  local decoded, why = decode_output(result.stdout)
  if decoded == nil then
    return nil, why
  end
  return validate_output(decoded, signals, revision)
end

return M
