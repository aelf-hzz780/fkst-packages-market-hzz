local caps = require("import_issue_caps")
local strings = require("contract.strings")

local M = {}

local ATTRIBUTION_PREFIX = "Written by session: "
local DEBUG_STAMP_PREFIX = "<!-- fkst:debug-stamp:v1 "

local function issue_source_ref(repo, number)
  if strings.trim(repo) == "" or tonumber(number) == nil then
    return nil
  end
  local ref = tostring(repo) .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function source_number(source_ref)
  return tonumber(source_ref and source_ref.ref and source_ref.ref:match("#issue/(%d+)$"))
end

local function hosted_suffix_is_valid(suffix)
  local normalized = tostring(suffix or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local saw_attribution = false
  local saw_debug = false
  for raw_line in (normalized .. "\n"):gmatch("(.-)\n") do
    local line = strings.trim(raw_line)
    if line ~= "" then
      if not saw_attribution and not saw_debug
          and line:sub(1, #ATTRIBUTION_PREFIX) == ATTRIBUTION_PREFIX
          and #line <= 600 and line:find("[%z\1-\31\127]") == nil then
        saw_attribution = true
      elseif not saw_debug and line:sub(1, #DEBUG_STAMP_PREFIX) == DEBUG_STAMP_PREFIX
          and line:sub(-4) == " -->" and #line <= 1200
          and line:find(DEBUG_STAMP_PREFIX, #DEBUG_STAMP_PREFIX + 1, true) == nil then
        saw_debug = true
      else
        return false
      end
    end
  end
  return true
end

local function exact_proxy_comment(body, request_body, marker)
  local normalized = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local expected = tostring(request_body) .. "\n\n" .. tostring(marker)
  if normalized:sub(1, #expected) ~= expected then
    return false
  end
  return hosted_suffix_is_valid(normalized:sub(#expected + 1))
end

function M.signal_item(signal, session)
  return {
    kind = "radar-signal",
    account = session.account,
    source_ref = signal.source_ref,
    repo = signal.source_ref.ref:match("^([^#]+)#"),
    issue_number = source_number(signal.source_ref),
    signal_digest = signal.signal_digest,
    dedup_key = "marketing-radar/v2/terminal/" .. caps.runtime_segment(signal.source_ref.ref, 180)
      .. "/" .. caps.runtime_segment(signal.signal_digest, 80),
    session_work_label = session.effective_work_label,
    logical_work_label = session.logical_work_label,
    session_creator = session.creator,
    trace_id = "github:marketing-radar:" .. signal.source_ref.ref,
  }
end

function M.review_item(item, decision, session)
  return {
    kind = "weekly-plan-change",
    account = session.account,
    source_ref = item.source_ref,
    repo = item.repo,
    issue_number = item.issue_number,
    content_digest = decision.proposal.content_digest,
    proposal_id = decision.proposal.proposal_id,
    proposal_revision = decision.proposal.revision,
    group_key = decision.proposal.group_key,
    session_work_label = session.effective_work_label,
    logical_work_label = session.logical_work_label,
    session_creator = session.creator,
    trace_id = item.trace_id,
  }
end

function M.status(decision)
  if decision.command == "approve" then
    return "approved; immutable weekly-content requested"
  end
  return "rejected: " .. tostring(decision.reason)
end

function M.trusted_status(candidate, repo, session, bot_login)
  local number = tonumber(candidate and candidate.row and candidate.row.number)
  local ref = number and issue_source_ref(repo, number) or nil
  if ref == nil or type(candidate.decision) ~= "table" then
    return nil
  end
  candidate.decision.proposal.review_source_ref = ref
  local item = M.review_item({
    source_ref = ref,
    repo = repo,
    issue_number = number,
    trace_id = "github:marketing-radar:" .. ref.ref,
  }, candidate.decision, session)
  local status = M.status(candidate.decision)
  local request = caps.status_comment(
    item, status, caps.close_handoff(item, "weekly-plan-change", candidate.decision))
  local marker = "<!-- fkst:github-proxy:comment:" .. request.dedup_key .. " -->"
  local expected_bot = caps.normalized_login(bot_login)
  for _, comment in ipairs(candidate.issue.comments or {}) do
    if expected_bot ~= nil and caps.normalized_login(comment.author_login) == expected_bot
        and exact_proxy_comment(comment.body, request.body, marker) then
      return status
    end
  end
  return nil
end

function M.recoverable_signals(github, proposal, session, signal_authors, classify)
  local open = {}
  for _, expected in ipairs(proposal and proposal.signals or {}) do
    local issue = github.read_issue(expected.source_ref, {
      force_fresh = true,
      consumer = "marketing-radar-v2-terminal-recovery",
    })
    local state = type(issue) == "table" and tostring(issue.state or ""):upper() or ""
    if state ~= "OPEN" and state ~= "CLOSED" then
      return nil, "terminal-signal-unavailable"
    end
    local payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = expected.source_ref.ref:match("^([^#]+)#"),
      number = source_number(expected.source_ref),
      source_ref = expected.source_ref,
    }
    local current, why = classify(payload, issue, session, signal_authors)
    if current == nil or current.kind ~= "radar-signal" or current.status == "needs-triage"
        or current.signal_digest ~= expected.signal_digest then
      return nil, "terminal-signal-changed:" .. tostring(why or current and current.triage_reason)
    end
    if state == "OPEN" then
      open[#open + 1] = current
    end
  end
  return open, nil
end

return M
