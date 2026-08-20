local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {
  DEDUP_KEY_LIMIT = 512,
  GROUP_KEY_LIMIT = 400,
  MAX_REVISION = 2147483647,
}

local function encode_fields(fields, keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local value = tostring(fields[key] or "")
    parts[#parts + 1] = key .. ":" .. tostring(#value) .. ":" .. value
  end
  return table.concat(parts, "\n")
end

local function encode_list(name, values)
  local parts = { name .. "-count:" .. tostring(#values) }
  for index, value in ipairs(values) do
    parts[#parts + 1] = name .. "[" .. tostring(index) .. "]:"
      .. tostring(#value) .. ":" .. value
  end
  return table.concat(parts, "\n")
end

function M.runtime_segment(value, limit)
  local raw = tostring(value or "")
  local safe = strings.runtime_safe_segment(raw)
  local max_len = tonumber(limit) or 120
  if #safe <= max_len then
    return safe
  end
  local suffix = "_" .. strings.decimal_checksum(raw)
  return safe:sub(1, math.max(1, max_len - #suffix)) .. suffix
end

function M.dedup_key(group_key, suffix)
  local value = tostring(group_key or "") .. tostring(suffix or "")
  if value == "" or #value > M.DEDUP_KEY_LIMIT then
    return nil, "proposal-dedup-key-too-large"
  end
  return value, nil
end

function M.revision(value)
  if type(value) == "string"
      and (#value > 10 or value:match("^[1-9][0-9]*$") == nil) then
    return nil
  end
  local revision = tonumber(value)
  if revision == nil or revision < 1 or revision > M.MAX_REVISION
      or revision % 1 ~= 0 then
    return nil
  end
  return revision
end

function M.next_revision(value)
  local revision = M.revision(value)
  if revision == nil then
    return nil, "invalid-proposal-revision"
  end
  if revision == M.MAX_REVISION then
    return nil, "proposal-revision-exhausted"
  end
  return revision + 1, nil
end

function M.signal_set_digest(signals)
  local ordered = {}
  for _, signal in ipairs(signals or {}) do
    ordered[#ordered + 1] = signal
  end
  table.sort(ordered, function(left, right)
    if left.signal_digest == right.signal_digest then
      return left.source_ref.ref < right.source_ref.ref
    end
    return left.signal_digest < right.signal_digest
  end)
  local digests = {}
  for _, signal in ipairs(ordered) do
    digests[#digests + 1] = signal.signal_digest
  end
  return sha256.tagged(table.concat(digests, "\n"))
end

local function encoded_group_values(values)
  local parts = {}
  for _, key in ipairs({ "project", "account", "week", "topic", "action", "target_ref" }) do
    local value = tostring(values[key] or "")
    parts[#parts + 1] = key .. ":" .. tostring(#value) .. ":" .. value
  end
  return table.concat(parts, "\n")
end

function M.group_key(signal)
  local values = {
    project = signal.project,
    account = signal.account,
    week = signal.week,
    topic = signal.topic or "general",
    action = signal.action or "unknown",
    target_ref = signal.target_ref or "none",
  }
  local readable = table.concat({
    "marketing-radar", M.runtime_segment(values.project), M.runtime_segment(values.account),
    M.runtime_segment(values.week), M.runtime_segment(values.topic), M.runtime_segment(values.action),
    M.runtime_segment(values.target_ref, 180),
  }, "/")
  local suffix = "/sha256-" .. sha256.hex(encoded_group_values(values))
    .. "/weekly-plan-change"
  return readable:sub(1, M.GROUP_KEY_LIMIT - #suffix) .. suffix
end

function M.proposal_digest(proposal)
  if type(proposal) ~= "table" or not sha256.is_tagged(proposal.signal_set_digest)
      or not sha256.is_tagged(proposal.content_digest) then
    return nil
  end
  local group_key = M.group_key(proposal)
  if proposal.group_key ~= nil and tostring(proposal.group_key) ~= group_key then
    return nil
  end
  local signals = {}
  for _, signal in ipairs(proposal.signals or {}) do
    local ref = type(signal.source_ref) == "table"
      and tostring(signal.source_ref.ref or signal.source_ref.reference or "") or ""
    if ref == "" or not sha256.is_tagged(signal.signal_digest) then
      return nil
    end
    signals[#signals + 1] = encode_fields({
      source_ref = ref,
      signal_digest = signal.signal_digest,
    }, { "source_ref", "signal_digest" })
  end
  local evidence = {}
  for _, ref in ipairs(proposal.evidence_refs or {}) do
    local value = tostring(ref or "")
    if value == "" then
      return nil
    end
    evidence[#evidence + 1] = value
  end
  if #signals == 0 or #evidence == 0 then
    return nil
  end
  table.sort(signals)
  table.sort(evidence)
  local scalar = encode_fields({
    contract = proposal.contract,
    type = "weekly-plan-change",
    status = proposal.status,
    project = proposal.project,
    account = proposal.account,
    work_label = proposal.work_label,
    week = proposal.week,
    topic = proposal.topic,
    action = proposal.action,
    target_ref = proposal.target_ref,
    change_scope = proposal.change_scope,
    supersede_mode = proposal.supersede_mode,
    group_key = group_key,
    proposal_id = proposal.proposal_id,
    proposal_revision = proposal.revision,
    content_id = proposal.content_id,
    content_revision = proposal.content_revision,
    signal_set_digest = proposal.signal_set_digest,
    content_digest = proposal.content_digest,
    tweet_text = proposal.tweet_text,
  }, {
    "contract", "type", "status", "project", "account", "work_label", "week", "topic",
    "action", "target_ref", "change_scope", "supersede_mode", "group_key",
    "proposal_id", "proposal_revision", "content_id", "content_revision",
    "signal_set_digest", "content_digest", "tweet_text",
  })
  return sha256.tagged(table.concat({
    scalar,
    encode_list("signal", signals),
    encode_list("evidence", evidence),
  }, "\n"))
end

return M
