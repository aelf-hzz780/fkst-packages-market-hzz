local marketing_content = require("contract.marketing_content")
local content_filter = require("forge.github.content_filter")
local session_route = require("contract.session_route")
local strings = require("contract.strings")

local M = {}

local SUPERSEDED_PREFIX = "<!-- fkst:auto-twitter:content-superseded:v2 content_digest=\""

local function canonical_login(value)
  local login = strings.trim(value):lower()
  if login == "" then
    return nil
  end
  return login
end

local function source_ref_value(source_ref)
  if type(source_ref) ~= "table" or source_ref.kind ~= "external" then
    return nil
  end
  if source_ref.ref ~= nil and source_ref.reference ~= nil and source_ref.ref ~= source_ref.reference then
    return nil
  end
  local ref = source_ref.ref or source_ref.reference
  if type(ref) ~= "string" or ref:match("^[^#]+#issue/%d+$") == nil then
    return nil
  end
  return ref
end

function M.content_source_ref(schedule)
  if type(schedule) ~= "table" or type(schedule.content_ref) ~= "string" then
    return nil, "invalid content ref"
  end
  local ref = strings.trim(schedule.content_ref)
  local repo = schedule.repo
    or (source_ref_value(schedule.source_ref) or ""):match("^([^#]+)#issue/%d+$")
  local number = ref:match("^#(%d+)$")
  if number ~= nil and repo ~= nil then
    ref = repo .. "#issue/" .. number
  end
  if ref:match("^[^#]+#issue/%d+$") == nil then
    return nil, "invalid content ref"
  end
  return { kind = "external", ref = ref, reference = ref }, nil
end

local function has_superseded_marker(comments, digest, trusted_author_login)
  local marker = SUPERSEDED_PREFIX .. tostring(digest) .. "\" -->"
  for _, comment in ipairs(type(comments) == "table" and comments or {}) do
    local body = type(comment) == "table" and comment.body or nil
    if content_filter.canon_login(type(comment) == "table" and comment.author_login or nil)
        == content_filter.canon_login(trusted_author_login)
        and type(body) == "string" and body:find(marker, 1, true) ~= nil then
      return true
    end
  end
  return false
end

function M.validate(issue, schedule, authority, expected_source_ref, trusted_author_login)
  if type(issue) ~= "table" then
    return nil, "invalid content issue"
  end
  if tostring(issue.state or ""):upper() ~= "CLOSED" then
    return nil, "content import is not finalized"
  end
  local trusted_author = content_filter.canon_login(trusted_author_login)
  if trusted_author == nil or content_filter.canon_login(issue.author_login) ~= trusted_author then
    return nil, "content author is not trusted bot"
  end
  local expected_ref = source_ref_value(expected_source_ref)
  if expected_ref == nil or source_ref_value(issue.source_ref) ~= expected_ref then
    return nil, "content source mismatch"
  end
  if not session_route.has_label(issue.labels, authority.effective_work_label) then
    return nil, "content is outside session route"
  end
  local assignee = session_route.single_assignee(issue.assignees)
  if canonical_login(assignee) ~= canonical_login(authority.creator) then
    return nil, "content assignee mismatch"
  end

  local content, why = marketing_content.parse(issue.body)
  if content == nil then
    return nil, "invalid content: " .. tostring(why)
  end
  if content.account ~= authority.account or content.account ~= schedule.account then
    return nil, "content account mismatch"
  end
  if content.work_label ~= authority.logical_work_label or content.work_label ~= schedule.work_label then
    return nil, "content work label mismatch"
  end
  if content.project ~= schedule.project or content.week ~= schedule.week then
    return nil, "content campaign mismatch"
  end
  if content.content_digest ~= schedule.content_digest then
    return nil, "content digest mismatch"
  end
  if content.approval_id ~= schedule.approval_id then
    return nil, "content approval mismatch"
  end
  if has_superseded_marker(issue.comments, content.content_digest, trusted_author) then
    return nil, "content is superseded"
  end
  return content, nil
end

return M
