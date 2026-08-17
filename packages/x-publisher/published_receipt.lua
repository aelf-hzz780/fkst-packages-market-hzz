local strings = require("contract.strings")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local dedup_keys = require("x_publisher_dedup_key")

local M = {}

local PUBLISHED_RECEIPT_TITLE = "Auto Twitter marketing: X published"
local RECEIPT_FIELDS = {
  account = true,
  approval_id = true,
  authenticated_account = true,
  content_digest = true,
  dedup_key = true,
  platform_post_id = true,
  post_id = true,
  post_uri = true,
  status = true,
}

local function receipt_comment_fields(body, expected_marker)
  local fields = {}
  local duplicate = false
  local marker_seen = false
  local in_fence = false
  local text = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"
  for line in text:gmatch("(.-)\n") do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      if strings.trim(line) == expected_marker then
        marker_seen = true
      end
      local key, value = line:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
      key = tostring(key or ""):lower():gsub("-", "_")
      if RECEIPT_FIELDS[key] then
        duplicate = duplicate or fields[key] ~= nil
        fields[key] = strings.trim(value)
      end
    end
  end
  return fields, duplicate, marker_seen
end

local function x_status_post_id(uri)
  local authority, path = tostring(uri or ""):match("^https://([^/]+)(/[^?#]*)$")
  local host = tostring(authority or ""):lower()
  if host ~= "x.com" and host ~= "www.x.com"
      and host ~= "twitter.com" and host ~= "www.twitter.com" then
    return nil
  end
  local post_id = path and path:match("^/i/web/status/(%d+)$") or nil
  if post_id == nil then
    local handle
    handle, post_id = tostring(path or ""):match("^/([A-Za-z0-9_]+)/status/(%d+)$")
    if handle == nil or #handle > 15 then
      return nil
    end
  end
  if #post_id > 32 then
    return nil
  end
  return post_id
end

function M.trusted_published_receipt(comments, expected, is_authorized_author)
  if type(comments) ~= "table" or type(expected) ~= "table"
      or not dedup_keys.is_canonical(expected.dedup_key)
      or not session_route.is_canonical_account(expected.account)
      or not sha256.is_tagged(expected.content_digest)
      or type(expected.approval_id) ~= "string" or expected.approval_id == ""
      or type(is_authorized_author) ~= "function" then
    return nil, "published receipt validation unavailable"
  end
  local expected_dedup_key = expected.dedup_key
  local expected_marker = "<!-- fkst:github-proxy:comment:" .. expected_dedup_key
    .. "/status/x-publish-published -->"
  local evidence = nil
  for _, comment in ipairs(comments) do
    local auth_ok, authorized = pcall(is_authorized_author,
      type(comment) == "table" and comment.author_login or nil)
    if not auth_ok then
      return nil, "github publish receipt authorization failed"
    end
    if authorized == true and type(comment) == "table" then
      local body = tostring(comment.body or "")
      local fields, duplicate, marker_seen = receipt_comment_fields(body, expected_marker)
      local title = body:gsub("\r\n", "\n"):gsub("\r", "\n"):match("^([^\n]*)")
      local relevant = fields.dedup_key == expected_dedup_key or marker_seen
      if relevant and (title == PUBLISHED_RECEIPT_TITLE
          or fields.status == "published" or marker_seen) then
        local post_id = x_status_post_id(fields.post_uri)
        local authenticated = session_route.normalize_account(fields.authenticated_account)
        local ids_match = (fields.platform_post_id == nil or fields.platform_post_id == post_id)
          and (fields.post_id == nil or fields.post_id == post_id)
        local corrupt = duplicate or title ~= PUBLISHED_RECEIPT_TITLE or not marker_seen
          or fields.status ~= "published" or fields.dedup_key ~= expected_dedup_key
          or fields.account ~= expected.account or authenticated ~= expected.account
          or fields.content_digest ~= expected.content_digest
          or fields.approval_id ~= expected.approval_id
          or post_id == nil or not ids_match
        if corrupt then
          return nil, "corrupt published receipt marker"
        end
        if evidence ~= nil and evidence.post_id ~= post_id then
          return nil, "conflicting published receipt markers"
        end
        evidence = evidence or {
          post_id = post_id,
          post_uri = fields.post_uri,
          authenticated_account = authenticated,
        }
      end
    end
  end
  return evidence, nil
end

return M
