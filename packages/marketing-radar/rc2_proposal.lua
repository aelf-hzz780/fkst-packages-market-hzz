local action_strategies = require("action_strategies")
local control_fields = require("control_fields")
local marketing_content = require("contract.marketing_content")
local proposal_identity = require("proposal_identity")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")
local x_text = require("contract.x_text")

local M = {}

local SIGNAL_SET_LIMIT = 20

local function trim(value)
  return strings.trim(value or "")
end

local function normalized_key(value)
  return trim(value):lower():gsub("_", "-")
end

local function content_record(proposal)
  return {
    project = proposal.project,
    account = proposal.account,
    work_label = proposal.work_label,
    week = proposal.week,
    content_id = proposal.content_id,
    content_revision = proposal.content_revision,
    proposal_id = proposal.proposal_id,
    proposal_revision = proposal.revision,
    approval_id = proposal.proposal_id .. "@" .. tostring(proposal.revision),
    content_status = "approved",
    tweet_text = proposal.tweet_text,
  }
end

local function lineage(body)
  local lines, why = control_fields.unfenced_lines(body)
  if lines == nil then
    return nil, nil, why
  end
  local signals = {}
  local evidence_refs = {}
  local signal_refs = {}
  local evidence = {}
  for _, line in ipairs(lines) do
    if line:match("^%s*signal:") then
      local ref, digest = line:match("^%s*signal:%s*([^%s]+)%s+(sha256:[0-9a-f]+)%s*$")
      if ref == nil or #ref > 240 or ref:match("^[^#]+#issue/%d+$") == nil
          or not sha256.is_tagged(digest) or signal_refs[ref]
          or #signals >= SIGNAL_SET_LIMIT then
        return nil, nil, "invalid-rc2-signal-lineage"
      end
      signal_refs[ref] = true
      signals[#signals + 1] = {
        source_ref = { kind = "external", ref = ref, reference = ref },
        signal_digest = digest,
      }
    elseif line:match("^%s*evidence:") then
      local ref = line:match("^%s*evidence:%s*([^%s]+)%s*$")
      if ref == nil or not signal_refs[ref] or evidence[ref] then
        return nil, nil, "invalid-rc2-evidence-lineage"
      end
      evidence[ref] = true
      evidence_refs[#evidence_refs + 1] = ref
    end
  end
  if #signals == 0 or #evidence_refs ~= #signals then
    return nil, nil, "invalid-rc2-evidence-lineage"
  end
  for ref, _ in pairs(signal_refs) do
    if not evidence[ref] then
      return nil, nil, "invalid-rc2-evidence-lineage"
    end
  end
  return signals, evidence_refs, nil
end

-- RC2 is a read-only compatibility adapter. It validates the historical root
-- contract but never emits an RC2 artifact.
function M.inspect(body)
  local fields, fields_why, intent, complete_identity = control_fields.parse(body)
  if not intent then
    return nil, "not-rc2-proposal-root"
  end
  if fields_why ~= nil then
    return nil, fields_why
  end
  if not complete_identity or fields["proposal-digest"] ~= nil then
    return nil, "not-rc2-proposal-root"
  end
  local tweet_text, tweet_why = control_fields.fenced_field(body, "tweet-text")
  if tweet_text == nil then
    return nil, tweet_why
  end
  local signals, evidence_refs, lineage_why = lineage(body)
  if signals == nil then
    return nil, lineage_why
  end
  local project = strings.sanitize_key(trim(fields.project):lower(), 180)
  local account = session_route.normalize_account(fields.account)
  local revision = proposal_identity.revision(fields["proposal-revision"])
  local content_revision = proposal_identity.revision(fields["content-revision"])
  local proposal = {
    contract = fields.contract,
    status = normalized_key(fields.status),
    project = project,
    account = account,
    work_label = trim(fields["work-label"]),
    week = trim(fields.week),
    topic = fields.topic,
    action = normalized_key(fields.action),
    target_ref = fields["target-ref"],
    change_scope = fields["change-scope"],
    supersede_mode = fields["supersede-mode"],
    proposal_id = trim(fields["proposal-id"]),
    revision = revision,
    content_id = trim(fields["content-id"]),
    content_revision = content_revision,
    signal_set_digest = fields["signal-set-digest"],
    content_digest = fields["content-digest"],
    tweet_text = tweet_text,
    signals = signals,
    evidence_refs = evidence_refs,
  }
  local strategy = action_strategies.evaluate(proposal.action, proposal.target_ref)
  if proposal.contract ~= control_fields.PROPOSAL_CONTRACT
      or trim(fields.project) ~= project or trim(fields.account) ~= account
      or proposal.status ~= "awaiting-review" or proposal.work_label == ""
      or proposal.week:match("^%d%d%d%d%-W%d%d$") == nil
      or revision ~= 1 or content_revision == nil
      or proposal.proposal_id == "" or #proposal.proposal_id > 180
      or proposal.content_id == "" or #proposal.content_id > 180
      or not sha256.is_tagged(proposal.signal_set_digest)
      or not sha256.is_tagged(proposal.content_digest)
      or strategy == nil or strategy.change_scope ~= proposal.change_scope
      or strategy.supersede_mode ~= proposal.supersede_mode
      or not x_text.analyze(proposal.tweet_text).valid then
    return nil, "invalid-rc2-proposal-contract"
  end
  proposal.group_key = proposal_identity.rc2_group_key(proposal)
  if proposal.signal_set_digest ~= proposal_identity.signal_set_digest(signals) then
    return nil, "rc2-signal-set-digest-mismatch"
  end
  local expected_id = "proposal-" .. sha256.hex(
    proposal.group_key .. "\n" .. proposal.signal_set_digest):sub(1, 24)
  if proposal.proposal_id ~= expected_id then
    return nil, "rc2-proposal-id-mismatch"
  end
  if proposal.action ~= "revise" then
    local expected_content_id = "content-" .. sha256.hex(proposal.proposal_id):sub(1, 24)
    if proposal.content_id ~= expected_content_id or proposal.content_revision ~= 1 then
      return nil, "rc2-content-lineage-mismatch"
    end
  end
  if marketing_content.digest(content_record(proposal)) ~= proposal.content_digest then
    return nil, "rc2-content-digest-mismatch"
  end
  return proposal, nil
end

return M
