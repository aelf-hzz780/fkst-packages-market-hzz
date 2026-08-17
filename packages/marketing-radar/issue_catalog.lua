local strings = require("contract.strings")

local M = {}

local MAX_ISSUES = 5000
local MAX_RECEIPT_SEARCH_RESULTS = 100

function M.row_author(row)
  if type(row.author) == "table" then
    return row.author.login
  end
  if type(row.user) == "table" then
    return row.user.login
  end
  return row.author_login
end

function M.row_labels(row)
  local labels = {}
  for _, value in ipairs(type(row) == "table" and row.labels or {}) do
    labels[#labels + 1] = type(value) == "table" and (value.name or value.label) or value
  end
  return labels
end

function M.row_assignees(row)
  local assignees = {}
  for _, value in ipairs(type(row) == "table" and row.assignees or {}) do
    assignees[#assignees + 1] = type(value) == "table" and value.login or value
  end
  return assignees
end

local function decoded(result)
  if type(result) == "table" and result.stdout == nil then
    return result
  end
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return nil, "GitHub issue catalog request failed"
  end
  local ok, value = pcall(json.decode, tostring(result.stdout or ""))
  if not ok or type(value) ~= "table" then
    return nil, "GitHub issue catalog returned invalid JSON"
  end
  return value, nil
end

local function validate_row(row)
  if type(row) ~= "table" then
    return nil, "GitHub issue catalog contains invalid issue"
  end
  if row.pull_request ~= nil then
    return false, nil
  end
  if tonumber(row.number) == nil or type(row.state) ~= "string"
      or (row.body ~= nil and type(row.body) ~= "string")
      or type(row.labels) ~= "table" or type(row.assignees) ~= "table"
      or strings.trim(M.row_author(row)) == "" then
    return nil, "GitHub issue catalog contains malformed issue fields"
  end
  return true, nil
end

function M.list(github, repo, state)
  if type(github) ~= "table" or type(github.api_paginate_slurp) ~= "function" then
    return nil, "GitHub paginated issue catalog port unavailable"
  end
  if tostring(repo):match("^[%w_.-]+/[%w_.-]+$") == nil then
    return nil, "invalid repository for issue catalog"
  end
  if state ~= "open" and state ~= "all" then
    return nil, "invalid issue catalog state"
  end
  local raw, decode_why = decoded(github.api_paginate_slurp(
    "repos/" .. repo .. "/issues?state=" .. state .. "&per_page=100",
    30
  ))
  if raw == nil then
    return nil, decode_why
  end
  local rows = {}
  local function include(row)
    local valid, why = validate_row(row)
    if valid == nil then
      error(why, 0)
    end
    if valid then
      rows[#rows + 1] = row
      if #rows > MAX_ISSUES then
        error("GitHub issue catalog exceeds safety limit", 0)
      end
    end
  end
  local ok, failure = pcall(function()
    if raw[1] ~= nil and type(raw[1]) == "table" and raw[1].number ~= nil then
      for _, row in ipairs(raw) do include(row) end
      return
    end
    for _, page in ipairs(raw) do
      if type(page) ~= "table" then
        error("GitHub issue catalog contains invalid page", 0)
      end
      for _, row in ipairs(page) do include(row) end
    end
  end)
  if not ok then
    return nil, tostring(failure)
  end
  return rows, nil
end

local function safe_search_term(value, limit)
  local text = strings.trim(value)
  if text == "" or #text > limit or text:find('["%z\1-\31\127]') ~= nil then
    return nil
  end
  return text
end

function M.receipt_issue_rows(github, repo, expected)
  if type(github) ~= "table" or type(github.issue_search) ~= "function" then
    return nil, "GitHub receipt search port unavailable"
  end
  if tostring(repo):match("^[%w_.-]+/[%w_.-]+$") == nil or type(expected) ~= "table" then
    return nil, "invalid receipt search scope"
  end
  local content_digest = safe_search_term(expected.content_digest, 80)
  local approval_id = safe_search_term(expected.approval_id, 256)
  if content_digest == nil or content_digest:match("^sha256:[0-9a-f]+$") == nil
      or #content_digest ~= 71 or approval_id == nil then
    return nil, "invalid receipt search identity"
  end
  local query = '"schema: x-publisher.publish-receipt.v2" '
    .. '"content_digest: ' .. content_digest .. '" '
    .. 'in:comments'
  local raw, decode_why = decoded(github.issue_search(repo, query, "number", 30))
  if raw == nil then
    return nil, decode_why
  end
  if #raw >= MAX_RECEIPT_SEARCH_RESULTS then
    return nil, "GitHub receipt search exceeds safety limit"
  end
  local rows = {}
  local seen = {}
  for _, result in ipairs(raw) do
    local number = type(result) == "table" and tonumber(result.number) or nil
    if number == nil or number < 1 or number % 1 ~= 0 then
      return nil, "GitHub receipt search contains invalid issue"
    end
    if not seen[number] then
      seen[number] = true
      rows[#rows + 1] = { number = number }
    end
  end
  return rows, nil
end

return M
