local marketing_content = require("contract.marketing_content")
local forge_strings = require("forge.strings")
local session_route = require("contract.session_route")
local strings = require("contract.strings")

local M = {}

local function canonical_login(value)
  return strings.trim(forge_strings.strip_bot_login_suffix(tostring(value or ""):lower()))
end

function M.trusted_created_issue_number(comments, dedup_key, bot_login)
  local expected_bot = canonical_login(bot_login)
  if expected_bot == "" or type(dedup_key) ~= "string" or dedup_key == "" then
    return nil
  end
  local marker_pattern = "<!%-%- fkst:github%-proxy:issue%-created:v1.-%-%->"
  for _, comment in ipairs(comments or {}) do
    if canonical_login(comment.author_login) == expected_bot then
      for marker in tostring(comment.body or ""):gmatch(marker_pattern) do
        if marker:match('dedup="([^"]+)"') == dedup_key then
          local number = marker:match('issue="(%d+)"')
          if tonumber(number) ~= nil and tonumber(number) >= 1 then
            return tonumber(number)
          end
        end
      end
    end
  end
  return nil
end

function M.validate_content_issue(issue, proposal, session, expected_number, bot_login)
  if type(issue) ~= "table" or tonumber(issue.number) ~= tonumber(expected_number) then
    return nil, "materialized-content-target-mismatch"
  end
  if tostring(issue.state or ""):upper() ~= "CLOSED" then
    return nil, "materialized-content-not-immutable"
  end
  if canonical_login(issue.author_login) ~= canonical_login(bot_login) then
    return nil, "materialized-content-author-mismatch"
  end
  if not session_route.has_label(issue.labels, session.effective_work_label) then
    return nil, "materialized-content-route-mismatch"
  end
  local assignee = session_route.single_assignee(issue.assignees)
  if canonical_login(assignee) ~= canonical_login(session.creator) then
    return nil, "materialized-content-assignee-mismatch"
  end
  local content, why = marketing_content.parse(issue.body)
  if content == nil then
    return nil, "invalid-materialized-content:" .. tostring(why)
  end
  if content.project ~= proposal.project or content.account ~= proposal.account
      or content.work_label ~= proposal.work_label or content.week ~= proposal.week
      or content.proposal_id ~= proposal.proposal_id or content.proposal_revision ~= proposal.revision
      or content.approval_id ~= proposal.proposal_id .. "@" .. tostring(proposal.revision)
      or content.content_digest ~= proposal.content_digest then
    return nil, "materialized-content-identity-mismatch"
  end
  return content, nil
end

return M
