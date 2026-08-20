local marketing_content = require("contract.marketing_content")
local proposal_identity = require("proposal_identity")
local marketing_schedule = require("contract.marketing_schedule")
local session_route = require("contract.session_route")
local strings = require("contract.strings")

local M = {}

local MARKER_PREFIX = '<!-- fkst:auto-twitter:content-superseded:v2 content_digest="'
local PUBLISHED_RECEIPT_CONTRACT = "x-publisher.publish-receipt.v2"
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
  schema = true,
  status = true,
}

local function canonical_login(value)
  local login = strings.trim(value):lower():gsub("^app/", ""):gsub("%[bot%]$", "")
  if login == "" or #login > 80 or login:match("^[%w_.-]+$") == nil then
    return nil
  end
  return login
end

local function actor_login(value)
  if type(value) ~= "table" then
    return nil
  end
  if type(value.author) == "table" then
    return value.author.login
  end
  if type(value.user) == "table" then
    return value.user.login
  end
  return value.author_login
end

local function normalized_authority(value)
  if type(value) ~= "table" then
    return nil, "missing-supersession-authority"
  end
  local authority = {
    effective_work_label = strings.trim(value.effective_work_label),
    logical_work_label = strings.trim(value.logical_work_label),
    creator = canonical_login(value.creator),
    account = session_route.normalize_account(value.account),
    bot_login = canonical_login(value.bot_login),
  }
  if authority.effective_work_label == "" or authority.logical_work_label == ""
      or authority.creator == nil or authority.account == nil or authority.bot_login == nil then
    return nil, "invalid-supersession-authority"
  end
  return authority
end

local function source_ref(repo, number)
  local ref = tostring(repo) .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function number_from_ref(repo, value)
  local ref = strings.trim(value)
  local number = ref:match("^#(%d+)$")
  if number ~= nil then
    return tonumber(number)
  end
  local target_repo, target_number = ref:match("^([^#]+)#issue/(%d+)$")
  if target_repo == repo then
    return tonumber(target_number)
  end
  return nil
end

local function canonical_content_ref(repo, value)
  local number = number_from_ref(repo, value)
  return number and (repo .. "#issue/" .. tostring(number)) or nil
end

local function routed_to_session(issue, authority)
  if not session_route.has_label(issue and issue.labels, authority.effective_work_label) then
    return false
  end
  local assignee = session_route.single_assignee(issue.assignees)
  return canonical_login(assignee) == authority.creator
end

local function content_digest(candidate)
  local digest = type(candidate) == "table" and type(candidate.content) == "table"
    and candidate.content.content_digest or nil
  local hex = type(digest) == "string" and digest:match("^sha256:([0-9a-f]+)$") or nil
  if hex == nil or #hex ~= 64 then
    return nil
  end
  return digest
end

local function proposal_reference(proposal)
  if type(proposal) ~= "table" then
    return nil
  end
  local proposal_id = strings.trim(proposal.proposal_id)
  local revision = tonumber(proposal.revision)
  if proposal_id == "" or #proposal_id > 180 or proposal_id:match("^[%w._/-]+$") == nil
      or revision == nil or revision < 1 or revision % 1 ~= 0 then
    return nil
  end
  return proposal_id .. "@" .. string.format("%.0f", revision)
end

local function superseded_comment_body(candidate, proposal)
  local digest = content_digest(candidate)
  local proposal_ref = proposal_reference(proposal)
  if digest == nil or proposal_ref == nil then
    return nil
  end
  return MARKER_PREFIX .. digest .. '" -->\n'
    .. "Marketing radar: superseded by " .. proposal_ref .. "."
end

local function parsed_supersession(body)
  local hex, proposal_id, revision = tostring(body or ""):match(
    '^<!%-%- fkst:auto%-twitter:content%-superseded:v2 content_digest="sha256:([0-9a-f]+)" %-%->\n'
      .. 'Marketing radar: superseded by ([%w._/-]+)@([1-9]%d*)%.$')
  if hex == nil or #hex ~= 64 or #proposal_id > 180 then
    return nil
  end
  return {
    digest = "sha256:" .. hex,
    proposal_ref = proposal_id .. "@" .. revision,
  }
end

local function supersession_markers(issue, candidate, current_ref, bot_login)
  local digest = content_digest(candidate)
  local current = false
  local other = false
  for _, comment in ipairs(type(issue) == "table" and issue.comments or {}) do
    if type(comment) == "table" and canonical_login(actor_login(comment)) == bot_login then
      local parsed = parsed_supersession(comment.body)
      if parsed ~= nil and parsed.digest == digest then
        if parsed.proposal_ref == current_ref then
          current = true
        else
          other = true
        end
      end
    end
  end
  return current, other
end

function M.is_superseded(issue, candidate, proposal, bot_login)
  local expected_login = canonical_login(bot_login)
  local current_ref = proposal_reference(proposal)
  local expected_body = superseded_comment_body(candidate, proposal)
  if type(issue) ~= "table" or expected_login == nil or current_ref == nil or expected_body == nil then
    return nil, "invalid-supersession-correlation"
  end
  local current, other = supersession_markers(issue, candidate, current_ref, expected_login)
  if other then
    return nil, "content-superseded-by-other-proposal"
  end
  if not current then
    return false, nil
  end
  -- Parsing is intentionally followed by exact comparison so extra prose cannot
  -- turn a look-alike marker into a durable ACK.
  for _, comment in ipairs(issue.comments or {}) do
    if type(comment) == "table" and canonical_login(actor_login(comment)) == expected_login
        and tostring(comment.body or "") == expected_body then
      return true, nil
    end
  end
  return false, nil
end

local function same_campaign(content, input)
  return content.project == input.project and content.account == input.account
    and content.work_label == input.work_label and content.week == input.week
end

local function validate_content_issue(issue, expected_number, input, authority)
  if type(issue) ~= "table" or tonumber(issue.number) ~= tonumber(expected_number) then
    return nil, "revision-target-read-mismatch"
  end
  if tostring(issue.state or ""):upper() ~= "CLOSED" then
    return nil, "revision-target-is-not-closed"
  end
  if canonical_login(actor_login(issue)) ~= authority.bot_login then
    return nil, "revision-target-author-mismatch"
  end
  if not routed_to_session(issue, authority) then
    return nil, "revision-target-session-mismatch"
  end
  local content, why = marketing_content.parse(issue.body)
  if content == nil then
    return nil, "revision-target-is-not-approved-content:" .. tostring(why)
  end
  if content.account ~= authority.account or content.work_label ~= authority.logical_work_label
      or not same_campaign(content, input) then
    return nil, "revision-target-campaign-mismatch"
  end
  return {
    number = tonumber(expected_number),
    source_ref = source_ref(input.repo, expected_number),
    content = content,
    issue = issue,
  }
end

local function fresh_issue(read_issue, ref)
  if type(read_issue) ~= "function" then
    return nil, "supersession-read-port-unavailable"
  end
  local issue = read_issue(ref)
  if type(issue) ~= "table" then
    return nil, "supersession-fresh-read-failed"
  end
  return issue
end

local function find_target_row(rows, target_number)
  for _, row in ipairs(rows or {}) do
    if type(row) == "table" and tonumber(row.number) == tonumber(target_number) then
      return row
    end
  end
  return nil
end

local function receipt_fields(body)
  local fields = {}
  local duplicate = false
  local markers = {}
  local in_fence = false
  local text = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"
  local title = text:match("^([^\n]*)")
  for line in text:gmatch("(.-)\n") do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      local trimmed = strings.trim(line)
      if trimmed:match("^<!%-%- fkst:github%-proxy:comment:.-/status/x%-publish%-published %-%->$") then
        markers[#markers + 1] = trimmed
      end
      local key, value = line:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
      key = tostring(key or ""):lower():gsub("-", "_")
      if RECEIPT_FIELDS[key] then
        duplicate = duplicate or fields[key] ~= nil
        fields[key] = strings.trim(value)
      end
    end
  end
  return fields, duplicate, markers, title
end

local function canonical_dedup_key(value)
  return type(value) == "string" and value ~= "" and #value <= 512
    and strings.trim(value) == value
    and value:find("[%z\1-\31\127]") == nil
end

local function x_post_id(uri)
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
  return #post_id <= 32 and post_id or nil
end

local function validate_receipt_comment(comment, expected, authority, correlation_hint)
  if type(comment) ~= "table" or canonical_login(actor_login(comment)) ~= authority.bot_login then
    return false, nil
  end
  local body = tostring(comment.body or "")
  local fields, duplicate, markers, title = receipt_fields(body)
  local looks_like_receipt = title == PUBLISHED_RECEIPT_TITLE
    or fields.schema == PUBLISHED_RECEIPT_CONTRACT
    or fields.status == "published"
    or #markers > 0
  if not looks_like_receipt then
    return false, nil
  end
  local identity_correlated = fields.content_digest == expected.content_digest
    or fields.approval_id == expected.approval_id
  if not identity_correlated and correlation_hint ~= true then
    return false, nil
  end
  local post_id = x_post_id(fields.post_uri)
  local expected_marker = canonical_dedup_key(fields.dedup_key)
    and ("<!-- fkst:github-proxy:comment:" .. fields.dedup_key .. "/status/x-publish-published -->") or nil
  local ids_match = (fields.platform_post_id == nil or fields.platform_post_id == post_id)
    and (fields.post_id == nil or fields.post_id == post_id)
  if duplicate or title ~= PUBLISHED_RECEIPT_TITLE or fields.schema ~= PUBLISHED_RECEIPT_CONTRACT
      or fields.status ~= "published" or fields.account ~= expected.account
      or fields.authenticated_account ~= expected.account
      or fields.content_digest ~= expected.content_digest
      or fields.approval_id ~= expected.approval_id or post_id == nil or not ids_match
      or expected_marker == nil or #markers ~= 1 or markers[1] ~= expected_marker then
    return nil, "corrupt-published-receipt"
  end
  return true, nil
end

function M.is_published_schedule(issue, expected, authority_value, correlation_hint)
  local authority, authority_why = normalized_authority(authority_value)
  if authority == nil then
    return nil, authority_why
  end
  local found = false
  local corrupt = nil
  for _, comment in ipairs(type(issue) == "table" and issue.comments or {}) do
    local valid, why = validate_receipt_comment(
      comment, expected or {}, authority, correlation_hint)
    found = found or valid == true
    corrupt = corrupt or why
  end
  if found then
    return true, nil
  end
  if corrupt ~= nil then
    return nil, corrupt
  end
  return false, nil
end

local function validate_schedule_issue(issue, row_number, candidate, input, repo, authority)
  if type(issue) ~= "table" or tonumber(issue.number) ~= tonumber(row_number) then
    return nil, "schedule-fresh-read-mismatch"
  end
  local state = tostring(issue.state or ""):upper()
  if state ~= "OPEN" and state ~= "CLOSED" then
    return nil, "schedule-state-invalid"
  end
  if not routed_to_session(issue, authority) then
    return nil, "schedule-session-mismatch"
  end
  local schedule, why = marketing_schedule.parse(issue.body)
  if schedule == nil then
    return nil, "schedule-contract-invalid:" .. tostring(why)
  end
  if schedule.project ~= input.project or schedule.account ~= authority.account
      or schedule.work_label ~= authority.logical_work_label or schedule.week ~= input.week
      or canonical_content_ref(repo, schedule.content_ref) ~= candidate.source_ref.ref
      or schedule.content_digest ~= candidate.content.content_digest
      or schedule.approval_id ~= candidate.content.approval_id then
    return nil, "schedule-correlation-mismatch"
  end
  return schedule, nil
end

local function schedule_correlates(row, candidate, repo)
  local schedule = type(row) == "table" and marketing_schedule.parse(row.body) or nil
  return schedule ~= nil and canonical_content_ref(repo, schedule.content_ref) == candidate.source_ref.ref
    and schedule.content_digest == candidate.content.content_digest
    and schedule.approval_id == candidate.content.approval_id
end

local function receipt_candidate_rows(candidate, repo, rows, expected, find_receipt_rows)
  if type(find_receipt_rows) ~= "function" then
    return nil, "supersession-receipt-search-port-unavailable"
  end
  local selected = {}
  local seen = {}
  for _, row in ipairs(rows or {}) do
    local number = type(row) == "table" and tonumber(row.number) or nil
    if number ~= nil and not seen[number] and schedule_correlates(row, candidate, repo) then
      seen[number] = true
      selected[#selected + 1] = row
    end
  end
  local discovered, why = find_receipt_rows(expected)
  if type(discovered) ~= "table" then
    return nil, why or "supersession-receipt-search-failed"
  end
  for _, row in ipairs(discovered) do
    local number = type(row) == "table" and tonumber(row.number) or nil
    if number == nil or number < 1 or number % 1 ~= 0 then
      return nil, "supersession-receipt-search-invalid-result"
    end
    if not seen[number] then
      seen[number] = true
      selected[#selected + 1] = row
    end
  end
  return selected, nil
end

local function published_content(candidate, input, repo, rows, read_issue, authority, find_receipt_rows)
  local expected = {
    account = candidate.content.account,
    content_digest = candidate.content.content_digest,
    approval_id = candidate.content.approval_id,
  }
  local anchored, anchor_why = M.is_published_schedule(candidate.issue, expected, authority, true)
  if anchored == nil then
    return nil, anchor_why
  end
  if anchored then
    return true, nil
  end
  local candidates, candidates_why = receipt_candidate_rows(
    candidate, repo, rows, expected, find_receipt_rows)
  if candidates == nil then
    return nil, candidates_why
  end
  for _, row in ipairs(candidates) do
    local catalog_correlated = schedule_correlates(row, candidate, repo)
    local ref = source_ref(repo, row.number)
    local issue, read_why = fresh_issue(read_issue, ref)
    if issue == nil then
      return nil, read_why
    end
    if tonumber(issue.number) ~= tonumber(row.number) then
      return nil, "schedule-fresh-read-mismatch"
    end
    local fresh_correlated = schedule_correlates(issue, candidate, repo)
    local published, receipt_why = M.is_published_schedule(
      issue, expected, authority, catalog_correlated or fresh_correlated)
    if published == nil then
      return nil, receipt_why
    end
    if published then
      return true, nil
    end
    if catalog_correlated then
      local schedule, schedule_why = validate_schedule_issue(
        issue, row.number, candidate, input, repo, authority)
      if schedule == nil then
        return nil, schedule_why
      end
    end
  end
  return false, nil
end

local function validate_input_scope(input, repo, authority)
  if type(input) ~= "table" or type(repo) ~= "string" or repo:match("^[^/]+/[^/]+$") == nil then
    return nil, "invalid-supersession-input"
  end
  if input.account ~= authority.account or input.work_label ~= authority.logical_work_label
      or strings.trim(input.project) == "" or strings.trim(input.week) == "" then
    return nil, "supersession-session-mismatch"
  end
  return {
    action = input.action,
    target_ref = input.target_ref,
    project = input.project,
    account = input.account,
    work_label = input.work_label,
    week = input.week,
    repo = repo,
    content_digest = input.content_digest,
  }
end

local function resolve_revision_target(
    input, repo, rows, read_issue, authority, proposal, find_receipt_rows)
  local target_number = number_from_ref(repo, input.target_ref)
  if target_number == nil then
    return nil, "revision-target-invalid-ref"
  end
  local row = find_target_row(rows, target_number)
  if row == nil then
    return nil, "revision-target-not-found"
  end
  local ref = source_ref(repo, target_number)
  local issue, read_why = fresh_issue(read_issue, ref)
  if issue == nil then
    return nil, read_why
  end
  local candidate, candidate_why = validate_content_issue(issue, target_number, input, authority)
  if candidate == nil then
    return nil, candidate_why
  end
  if proposal == nil then
    local _, other = supersession_markers(issue, candidate, nil, authority.bot_login)
    if other then
      return nil, "revision-target-is-superseded"
    end
  else
    local superseded, superseded_why = M.is_superseded(
      issue, candidate, proposal, authority.bot_login)
    if superseded == nil then
      return nil, superseded_why
    end
    candidate.already_superseded = superseded
  end
  local published, published_why = published_content(
    candidate, input, repo, rows, read_issue, authority, find_receipt_rows)
  if published == nil then
    return nil, published_why
  end
  if published then
    return nil, "published-content-requires-add-correction"
  end
  return candidate, nil
end

function M.resolve_revision_lineage(
    input, repo, rows, read_issue, authority_value, find_receipt_rows)
  local authority, authority_why = normalized_authority(authority_value)
  if authority == nil then
    return nil, authority_why
  end
  local scope, scope_why = validate_input_scope(input, repo, authority)
  if scope == nil then
    return nil, scope_why
  end
  if scope.action ~= "revise" then
    return nil, "revision-lineage-requires-revise"
  end
  local candidate, why = resolve_revision_target(
    scope, repo, rows, read_issue, authority, nil, find_receipt_rows)
  if candidate == nil then
    return nil, why
  end
  return {
    content_id = candidate.content.content_id,
    content_revision = candidate.content.content_revision + 1,
    target_ref = candidate.source_ref.ref,
    target = candidate,
  }, nil
end

local function campaign_rows(input, rows)
  local selected = {}
  local seen = {}
  for _, row in ipairs(rows or {}) do
    local content = type(row) == "table" and marketing_content.parse(row.body) or nil
    local number = type(row) == "table" and tonumber(row.number) or nil
    if number ~= nil and not seen[number] and content ~= nil and same_campaign(content, input)
        and content.content_digest ~= input.content_digest then
      seen[number] = true
      selected[#selected + 1] = row
    end
  end
  table.sort(selected, function(left, right) return tonumber(left.number) < tonumber(right.number) end)
  return selected
end

function M.plan(proposal, repo, rows, read_issue, authority_value, find_receipt_rows)
  local authority, authority_why = normalized_authority(authority_value)
  if authority == nil then
    return nil, authority_why
  end
  local input, input_why = validate_input_scope(proposal, repo, authority)
  if input == nil then
    return nil, input_why
  end
  if proposal.action == "add" then
    return {}, nil
  end
  if proposal.action == "revise" then
    local candidate, why = resolve_revision_target(
      input, repo, rows, read_issue, authority, proposal, find_receipt_rows)
    if candidate == nil then
      return nil, why
    end
    if proposal.content_id ~= candidate.content.content_id
        or tonumber(proposal.content_revision) ~= candidate.content.content_revision + 1 then
      return nil, "revision-lineage-mismatch"
    end
    return { candidate }, nil
  end
  if proposal.action ~= "replan" then
    return nil, "unsupported-supersession-action"
  end

  local supersede = {}
  for _, row in ipairs(campaign_rows(input, rows)) do
    local ref = source_ref(repo, row.number)
    local issue, read_why = fresh_issue(read_issue, ref)
    if issue == nil then
      return nil, read_why
    end
    local candidate = validate_content_issue(issue, row.number, input, authority)
    if candidate ~= nil then
      local already_superseded, superseded_why = M.is_superseded(
        issue, candidate, proposal, authority.bot_login)
      if already_superseded == nil then
        if superseded_why ~= "content-superseded-by-other-proposal" then
          return nil, superseded_why
        end
      else
        candidate.already_superseded = already_superseded
        local published, published_why = published_content(
          candidate, input, repo, rows, read_issue, authority, find_receipt_rows)
        if published == nil then
          return nil, published_why
        end
        if not published then
          supersede[#supersede + 1] = candidate
        end
      end
    end
  end
  return supersede, nil
end

function M.comment_request(candidate, proposal)
  local digest = candidate.content.content_digest
  local body = superseded_comment_body(candidate, proposal)
  if body == nil then
    return nil, "invalid-supersession-correlation"
  end
  local dedup_key, dedup_why = proposal_identity.dedup_key(
    proposal.group_key, "/supersede/" .. digest)
  if dedup_key == nil then
    return nil, dedup_why
  end
  return {
    schema = "github-proxy.v1",
    repo = candidate.source_ref.ref:match("^([^#]+)#"),
    issue_number = candidate.number,
    body = body,
    dedup_key = dedup_key,
    source_ref = candidate.source_ref,
  }
end

return M
