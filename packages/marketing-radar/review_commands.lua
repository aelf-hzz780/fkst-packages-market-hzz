local session_authority = require("session_authority")
local sha256 = require("contract.sha256")
local status_contract = require("status_contract")
local strings = require("contract.strings")

local M = {}

local CONTROL_VALUE_LIMIT = 512
local FAILURE_REASON_LIMIT = CONTROL_VALUE_LIMIT + 64
local FAILURE_MARKER = "fkst:marketing-radar:review-failure:v2"
local FAILURE_STATUS_PREFIX = status_contract.prefix("needs-triage:")

local function trim(value)
  return strings.trim(value or "")
end

local function count_occurrences(body, needle)
  local count = 0
  local position = 1
  while true do
    local found = tostring(body or ""):find(needle, position, true)
    if found == nil then
      return count
    end
    count = count + 1
    position = found + #needle
  end
end

local function proxy_marker_keys(body)
  local keys = {}
  for key in tostring(body or ""):gmatch(
      "<!%-%- fkst:github%-proxy:comment:([%w%._%-%/#]+) %-%->") do
    keys[#keys + 1] = key
  end
  return keys
end

local function durable_failure_status(status)
  local prefix = "needs-triage: "
  if type(status) ~= "string" or status:sub(1, #prefix) ~= prefix
      or status_contract.canonical_line(status) ~= status then
    return false
  end
  local reason = status:sub(#prefix + 1)
  return reason:find("^semantic%-conflict:.") ~= nil
    or reason:find("^draft%-correction%-exhausted:.") ~= nil
end

local function failed_comment_ids(issue, proposal, bot_login, failure_dedup_root)
  local failed = {}
  local prefix = '<!-- ' .. FAILURE_MARKER
    .. ' proposal="' .. proposal.proposal_id .. '" revision="'
    .. tostring(proposal.revision) .. '" proposal_digest="'
    .. tostring(proposal.proposal_digest) .. '" comment_id="'
  for _, comment in ipairs(issue.comments or {}) do
    if session_authority.login_matches(comment.author_login, bot_login) then
      local body = tostring(comment.body or "")
      local status = status_contract.status_from_body(body)
      local keys = proxy_marker_keys(body)
      if failure_dedup_root ~= nil and body:sub(1, #FAILURE_STATUS_PREFIX) == FAILURE_STATUS_PREFIX
          and durable_failure_status(status) and #keys == 1
          and count_occurrences(body, "<!-- " .. FAILURE_MARKER) == 1 then
        local _, value_start = body:find(prefix, 1, true)
        local value_end = value_start and body:find('" -->', value_start + 1, true) or nil
        if value_end ~= nil then
          local comment_id = body:sub(value_start + 1, value_end - 1)
          local failure_marker = prefix .. comment_id .. '" -->'
          local failure_status = status .. "\n\n" .. failure_marker
          local expected_key = failure_dedup_root .. "/status/"
            .. status_contract.segment(failure_status)
          if comment_id:match("^%d+$") and count_occurrences(body, failure_marker) == 1
              and keys[1] == expected_key then
            failed[comment_id] = true
          end
        end
      end
    end
  end
  return failed
end

function M.failure_status(decision, failure_reason)
  if type(decision) ~= "table" or decision.command ~= "request-changes"
      or type(decision.proposal) ~= "table" then
    return nil, "invalid-failed-review-decision"
  end
  local proposal_id = trim(decision.proposal.proposal_id)
  local revision = tonumber(decision.proposal.revision)
  local proposal_digest = decision.proposal.proposal_digest
  local comment_id = tostring(decision.comment_id or "")
  local reason = trim(failure_reason):gsub("[%z\1-\32\127]+", " ")
  if proposal_id == "" or proposal_id:find('"', 1, true) ~= nil
      or revision == nil or revision < 1 or revision % 1 ~= 0
      or not sha256.is_tagged(proposal_digest)
      or not comment_id:match("^%d+$") then
    return nil, "invalid-failed-review-correlation"
  end
  if reason == "" or #reason > FAILURE_REASON_LIMIT then
    return nil, "invalid-failed-review-reason"
  end
  return "needs-triage: " .. reason .. "\n\n<!-- " .. FAILURE_MARKER
    .. ' proposal="' .. proposal_id .. '" revision="' .. tostring(revision)
    .. '" proposal_digest="' .. proposal_digest
    .. '" comment_id="' .. comment_id .. '" -->'
end

function M.decision(issue, proposal, options, failure_dedup_root)
  local opts = options or {}
  local authorized = session_authority.login_set(opts.authorized_reviewers)
  local failed_comments = failed_comment_ids(
    issue, proposal, opts.bot_login, failure_dedup_root)
  local saw_unauthorized = false
  local saw_stale = false
  local saw_stale_proposal = false
  for _, comment in ipairs(issue.comments or {}) do
    local command, id, revision, arguments = tostring(comment.body or ""):match(
      "^%s*/marketing%s+([%w-]+)%s+([^@%s]+)@([^%s]+)%s*(.-)%s*$"
    )
    if command == "approve" or command == "request-changes" or command == "reject" then
      local author = session_authority.normalize_login(comment.author_login)
      if id ~= proposal.proposal_id or tostring(revision) ~= tostring(proposal.revision) then
        saw_stale = true
      elseif author == nil or not authorized[author] then
        saw_unauthorized = true
      else
        local digest_and_reason = trim(arguments)
        local proposal_digest, reason = digest_and_reason:match("^(%S+)%s*(.-)$")
        if proposal_digest == nil then
          return nil, "review-proposal-digest-required"
        elseif not sha256.is_tagged(proposal_digest) then
          return nil, "invalid-review-proposal-digest"
        elseif proposal_digest ~= proposal.proposal_digest then
          saw_stale_proposal = true
        elseif not failed_comments[tostring(comment.id or "")] then
          local normalized_reason = trim(reason)
          if command ~= "approve" and normalized_reason == "" then
            return nil, "review-reason-required"
          end
          if #normalized_reason > CONTROL_VALUE_LIMIT
              or normalized_reason:find("[%z\1-\31\127]") ~= nil then
            return nil, "invalid-review-reason"
          end
          return {
            command = command,
            reason = normalized_reason ~= "" and normalized_reason or nil,
            reviewer = author,
            comment_id = comment.id,
            approval_id = proposal.proposal_id .. "@" .. tostring(proposal.revision),
            proposal = proposal,
          }
        end
      end
    end
  end
  if saw_unauthorized then
    return nil, "unauthorized-review-command"
  end
  if saw_stale then
    return nil, "stale-proposal-revision"
  end
  if saw_stale_proposal then
    return nil, "stale-proposal-digest"
  end
  return nil, "no-review-command"
end

return M
