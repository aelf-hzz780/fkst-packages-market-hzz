-- github-auto-twitter-marketing/core.lua - pure issue contract mapping helpers.
-- The durable payload carries only source_ref plus small control fields; strategy
-- and weekly content stay in the GitHub issue and are re-fetched through source_ref.
local M = {}
local content_filter = require("forge.github.content_filter")
local marketing_content = require("contract.marketing_content")
local marketing_schedule = require("contract.marketing_schedule")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local CONTROL_VALUE_LIMIT = 512

local ALLOWED_CONTROL_FIELDS = {
  account = true,
  ["approval-id"] = true,
  channel = true,
  contract = true,
  ["content-digest"] = true,
  ["content-id"] = true,
  ["content-ref"] = true,
  ["content-revision"] = true,
  ["content-status"] = true,
  ["interval-minutes"] = true,
  locale = true,
  mode = true,
  owner = true,
  project = true,
  ["proposal-id"] = true,
  ["proposal-revision"] = true,
  recurrence = true,
  ["scheduled-at"] = true,
  ["strategy-ref"] = true,
  time = true,
  timezone = true,
  type = true,
  week = true,
  ["work-label"] = true,
}

local SENSITIVE_PATTERNS = {
  "authorization",
  "api_key",
  "apikey",
  "bearer",
  "credential",
  "oauth",
  "password",
  "provider_response",
  "raw_response",
  "secret",
  "token",
}

local SOURCE_REF_FIELDS = {
  kind = true,
  ref = true,
  reference = true,
  uri = true,
  version = true,
}

local function is_small_scalar(value)
  local value_type = type(value)
  if value_type ~= "string" and value_type ~= "number" and value_type ~= "boolean" then
    return false
  end
  return #tostring(value) <= CONTROL_VALUE_LIMIT
end

local function normalized_key(key)
  return strings.trim(key):lower():gsub("_", "-")
end

local function has_sensitive_name(key)
  local normalized = normalized_key(key)
  for _, pattern in ipairs(SENSITIVE_PATTERNS) do
    if normalized:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function copy_source_ref(source_ref)
  local out = {}
  if type(source_ref) ~= "table" then
    return out
  end
  for key, value in pairs(source_ref) do
    if SOURCE_REF_FIELDS[key] and is_small_scalar(value) then
      out[key] = value
    end
  end
  if out.ref == nil and out.reference ~= nil then
    out.ref = out.reference
  end
  if out.reference == nil and out.ref ~= nil then
    out.reference = out.ref
  end
  return out
end

local function safe_id(value)
  local text = strings.trim(value):gsub("[^%w._#/-]", "-")
  text = text:gsub("-+", "-"):gsub("^[-/]+", ""):gsub("[-/]+$", "")
  if text == "" then
    return "unknown"
  end
  if #text > 180 then
    return text:sub(1, 180)
  end
  return text
end

local function runtime_key_segment(value, limit)
  local max_len = limit or 120
  local raw = tostring(value or "")
  local safe = strings.runtime_safe_segment(raw)
  local suffix = "_" .. strings.decimal_checksum(raw)
  if #safe > max_len then
    safe = safe:sub(1, math.max(1, max_len - #suffix)) .. suffix
  end
  return safe
end

function M.work_label(value)
  local label = strings.trim(value)
  if label == "" then
    return nil
  end
  return label
end

function M.saga_conformance_errors()
  return {}
end

function M.has_work_label(labels, work_label)
  return session_route.has_label(labels, work_label)
end

function M.parse_control_fields(body)
  local fields = {}
  if type(body) ~= "string" then
    return fields
  end
  for line in body:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
    if key ~= nil then
      local normalized = normalized_key(key)
      local cleaned = strings.trim(value)
      if ALLOWED_CONTROL_FIELDS[normalized] and not has_sensitive_name(normalized)
          and cleaned ~= "" and #cleaned <= CONTROL_VALUE_LIMIT then
        fields[normalized] = cleaned
      end
    end
  end
  return fields
end

local function control_fields(payload, opts)
  local options = opts or {}
  local fields = M.parse_control_fields(options.issue_body)
  if type(payload.controls) == "table" then
    for key, value in pairs(payload.controls) do
      local normalized = normalized_key(key)
      if ALLOWED_CONTROL_FIELDS[normalized] and not has_sensitive_name(normalized)
          and is_small_scalar(value) and tostring(value) ~= "" then
        fields[normalized] = tostring(value)
      end
    end
  end
  return fields
end

function M.canonical_issue_source_ref(payload)
  if type(payload) ~= "table" or type(payload.repo) ~= "string"
      or #payload.repo > 200 or payload.repo:match("^[%w_.-]+/[%w_.-]+$") == nil then
    return nil, "invalid issue identity"
  end
  local number = tonumber(payload.number)
  if number == nil or number < 1 or number ~= math.floor(number) then
    return nil, "invalid issue identity"
  end
  local derived = payload.repo .. "#issue/" .. string.format("%.0f", number)
  if payload.source_ref ~= nil then
    local supplied = payload.source_ref
    if type(supplied) ~= "table" or supplied.kind ~= "external"
        or (supplied.ref ~= nil and supplied.reference ~= nil and supplied.ref ~= supplied.reference) then
      return nil, "source_ref does not match issue identity"
    end
    local reference = supplied.ref or supplied.reference
    if type(reference) ~= "string" or #reference > CONTROL_VALUE_LIMIT or reference ~= derived then
      return nil, "source_ref does not match issue identity"
    end
  end
  return {
    kind = "external",
    ref = derived,
    reference = derived,
  }, nil
end

local function trace_id_for(source_ref)
  return "github:auto-twitter-marketing:" .. tostring(source_ref.ref)
end

local function canonical_digest_for(kind, fields, source_ref)
  return sha256.tagged(table.concat({
    tostring(kind or ""),
    tostring(fields.project or ""),
    tostring(fields.account or ""),
    tostring(fields.week or ""),
    tostring(fields["content-id"] or ""),
    tostring(fields["content-revision"] or ""),
    tostring(fields["content-ref"] or ""),
    tostring(fields["content-digest"] or ""),
    tostring(fields["approval-id"] or ""),
    tostring(fields["strategy-ref"] or ""),
    tostring(fields.recurrence or ""),
    tostring(fields["scheduled-at"] or ""),
    tostring(fields["interval-minutes"] or ""),
    tostring(fields.time or ""),
    tostring(fields.timezone or ""),
    tostring(source_ref.ref or ""),
  }, "\n"))
end

local function dedup_key_for(kind, fields, source_ref)
  local digest = canonical_digest_for(kind, fields, source_ref)
  local parts = {
    "auto-twitter-marketing",
    safe_id(fields.account),
    safe_id(kind),
    safe_id(fields.project),
    safe_id(fields.week or "default"),
    safe_id(source_ref.ref),
    safe_id(digest),
  }
  return table.concat(parts, "/")
end

local function canonical_login(value)
  local login = strings.trim(value):lower()
  if login == "" then
    return nil
  end
  return login
end

local function session_from_options(options)
  local supplied = type(options.session) == "table" and options.session or {}
  local effective = options.effective_work_label
    or supplied.effective_work_label
    or supplied.session_work_label
  local logical = options.logical_work_label
    or supplied.logical_work_label
    or supplied.work_label
  local creator = options.session_creator or supplied.creator
  local account = options.expected_account or supplied.account
  account = session_route.normalize_account(account)
  creator = canonical_login(creator)
  if type(effective) ~= "string" or effective == ""
      or type(logical) ~= "string" or logical == ""
      or creator == nil or account == nil then
    return nil
  end
  return {
    effective_work_label = effective,
    logical_work_label = logical,
    creator = creator,
    account = account,
  }
end

function M.resolve_session_authority(values)
  local source = type(values) == "table" and values or {}
  local route, why = session_route.resolve(
    source.FKST_SESSION_WORK_LABEL,
    source.FKST_SESSION_WORK_LABEL_MAP_JSON
  )
  if route == nil then
    return nil, why
  end
  local primary_raw = strings.trim(source.X_PUBLISH_EXPECTED_USERNAME)
  local fallback_raw = strings.trim(source.FKST_X_PUBLISH_EXPECTED_USERNAME)
  local primary = primary_raw ~= "" and session_route.normalize_account(primary_raw) or nil
  local fallback = fallback_raw ~= "" and session_route.normalize_account(fallback_raw) or nil
  if primary_raw ~= "" and primary == nil or fallback_raw ~= "" and fallback == nil then
    return nil, "invalid expected account"
  end
  if primary ~= nil and fallback ~= nil and primary ~= fallback then
    return nil, "conflicting expected account"
  end
  local account = primary or fallback
  local creator = canonical_login(source.FKST_SESSION_CREATOR)
  if creator == nil then
    return nil, "invalid session creator"
  end
  if account == nil then
    return nil, "invalid expected account"
  end
  return {
    effective_work_label = route.effective_label,
    logical_work_label = route.logical_label,
    creator = creator,
    account = account,
  }, nil
end

local function normalize_kind(value)
  local kind = normalized_key(value)
  if kind == "strategy" then
    return "strategy"
  end
  if kind == "weekly-content" or kind == "weekly" then
    return "weekly-content"
  end
  if kind == "schedule-publish" or kind == "schedule" then
    return "schedule-publish"
  end
  if kind == "recurring-schedule-publish" or kind == "daily-schedule-publish" then
    return "schedule-publish"
  end
  return nil
end

local function normalize_mode(value)
  local mode = normalized_key(value or "shadow")
  if mode == "live" then
    return "live"
  end
  return "shadow"
end

local function normalize_recurrence(value)
  local recurrence = normalized_key(value)
  if recurrence == "" then
    return nil
  end
  if recurrence == "daily" then
    return "daily"
  end
  if recurrence == "every-minutes" or recurrence == "every-minute" or recurrence == "minutely" then
    return "every-minutes"
  end
  return nil
end

local function parse_interval_minutes(value)
  local text = strings.trim(value)
  local minutes = tonumber(text)
  if minutes == nil or minutes < 1 or minutes > 1440 or minutes ~= math.floor(minutes) then
    return nil
  end
  return minutes
end

local function parse_timezone_offset(value)
  local zone = strings.trim(value)
  if zone == "" or zone == "Z" or zone == "UTC" or zone == "Etc/UTC" then
    return 0, "+00:00"
  end
  if zone == "Asia/Shanghai" or zone == "Asia/Chongqing" then
    return 8 * 60 * 60, "+08:00"
  end
  local sign, hours, minutes = zone:match("^([+-])(%d%d):(%d%d)$")
  if sign == nil then
    sign, hours, minutes = zone:match("^([+-])(%d%d)(%d%d)$")
  end
  if sign == nil then
    return nil, "unsupported timezone"
  end
  local hour_value = tonumber(hours)
  local minute_value = tonumber(minutes)
  if hour_value == nil or minute_value == nil or hour_value > 23 or minute_value > 59 then
    return nil, "invalid timezone"
  end
  local offset = hour_value * 60 * 60 + minute_value * 60
  if sign == "-" then
    offset = -offset
  end
  return offset, string.format("%s%02d:%02d", sign, hour_value, minute_value)
end

local function is_leap_year(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local function days_in_month(year, month)
  local month_days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and is_leap_year(year) then
    return 29
  end
  return month_days[month]
end

local function epoch_seconds_utc(year, month, day, hour, minute, second)
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  minute = tonumber(minute)
  second = tonumber(second or 0)
  if year == nil or month == nil or day == nil or hour == nil or minute == nil or second == nil then
    return nil
  end
  if year < 1970 or year > 2200 or month < 1 or month > 12 then
    return nil
  end
  local max_day = days_in_month(year, month)
  if day < 1 or day > max_day or hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59 then
    return nil
  end
  local days = 0
  for y = 1970, year - 1 do
    days = days + (is_leap_year(y) and 366 or 365)
  end
  for m = 1, month - 1 do
    days = days + days_in_month(year, m)
  end
  days = days + day - 1
  return (((days * 24 + hour) * 60 + minute) * 60 + second)
end

local function parse_clock_time(value)
  local text = strings.trim(value)
  local hour, minute, second = text:match("^(%d%d):(%d%d):(%d%d)$")
  if hour == nil then
    hour, minute = text:match("^(%d%d):(%d%d)$")
    second = "00"
  end
  local h = tonumber(hour)
  local m = tonumber(minute)
  local s = tonumber(second)
  if h == nil or m == nil or s == nil or h > 23 or m > 59 or s > 59 then
    return nil
  end
  return h, m, s
end

local function parse_iso8601(value)
  local text = strings.trim(value)
  local year, month, day, hour, minute, second, zone =
    text:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
  if year == nil then
    year, month, day, hour, minute, zone =
      text:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d)(.*)$")
    second = "00"
  end
  if year == nil then
    return nil, "invalid scheduled-at"
  end
  local offset, _offset_text = parse_timezone_offset(zone)
  if offset == nil then
    return nil, "invalid scheduled-at timezone"
  end
  local epoch = epoch_seconds_utc(year, month, day, hour, minute, second)
  if epoch == nil then
    return nil, "invalid scheduled-at"
  end
  return {
    epoch_seconds = epoch - offset,
    offset_seconds = offset,
    offset_text = _offset_text,
  }, nil
end

local function parse_iso8601_seconds(value)
  local parsed, why = parse_iso8601(value)
  if parsed == nil then
    return nil, why
  end
  return parsed.epoch_seconds, nil
end

local function format_epoch_with_offset(epoch_seconds, offset_seconds, offset_text)
  local local_date = os.date("!*t", epoch_seconds + offset_seconds)
  if type(local_date) ~= "table" then
    return nil
  end
  return string.format(
    "%04d-%02d-%02dT%02d:%02d:%02d%s",
    local_date.year,
    local_date.month,
    local_date.day,
    local_date.hour,
    local_date.min,
    local_date.sec,
    offset_text
  )
end

local function daily_occurrence(item, now_seconds)
  local hour, minute, second = parse_clock_time(item.time)
  if hour == nil then
    return { due = false, reason = "invalid daily time" }
  end
  local offset, offset_text = parse_timezone_offset(item.timezone)
  if offset == nil then
    return { due = false, reason = offset_text }
  end
  local local_date = os.date("!*t", now_seconds + offset)
  if type(local_date) ~= "table" then
    return { due = false, reason = "invalid now" }
  end
  local due_epoch = epoch_seconds_utc(local_date.year, local_date.month, local_date.day, hour, minute, second)
  if due_epoch == nil then
    return { due = false, reason = "invalid occurrence date" }
  end
  due_epoch = due_epoch - offset
  local local_day = string.format("%04d-%02d-%02d", local_date.year, local_date.month, local_date.day)
  local local_time = string.format("%02d:%02d:%02d", hour, minute, second)
  return {
    due = now_seconds >= due_epoch,
    reason = now_seconds >= due_epoch and "due" or "not due",
    occurrence_id = local_day .. "T" .. local_time .. offset_text,
    scheduled_at = local_day .. "T" .. local_time .. offset_text,
    due_epoch_seconds = due_epoch,
  }
end

local function every_minutes_occurrence(item, now_seconds)
  local parsed, why = parse_iso8601(item.scheduled_at)
  if parsed == nil then
    return { due = false, reason = why or "invalid scheduled-at" }
  end
  local interval_minutes = parse_interval_minutes(item.interval_minutes)
  if interval_minutes == nil then
    return { due = false, reason = "invalid interval-minutes" }
  end
  if now_seconds < parsed.epoch_seconds then
    return {
      due = false,
      reason = "not due",
      occurrence_id = item.scheduled_at,
      scheduled_at = item.scheduled_at,
      due_epoch_seconds = parsed.epoch_seconds,
    }
  end
  local interval_seconds = interval_minutes * 60
  local occurrence_index = math.floor((now_seconds - parsed.epoch_seconds) / interval_seconds)
  local due_epoch = parsed.epoch_seconds + occurrence_index * interval_seconds
  local scheduled_at = format_epoch_with_offset(due_epoch, parsed.offset_seconds, parsed.offset_text)
  if scheduled_at == nil then
    return { due = false, reason = "invalid occurrence date" }
  end
  return {
    due = true,
    reason = "due",
    occurrence_id = scheduled_at,
    scheduled_at = scheduled_at,
    due_epoch_seconds = due_epoch,
  }
end

function M.classify_issue(payload, opts)
  local options = opts or {}
  if type(payload) ~= "table" then
    return nil, "invalid payload"
  end
  if payload.schema ~= "github-proxy.v1" and payload.schema ~= "github-proxy.issue-observed.v1" then
    return nil, "unsupported schema"
  end
  if payload.type ~= "issue" then
    return nil, "not issue"
  end
  local session = session_from_options(options)
  if session == nil then
    return nil, "missing session authority"
  end
  local labels = options.issue_labels or payload.labels
  if not M.has_work_label(labels, session.effective_work_label) then
    return nil, "missing session work label"
  end
  local assignee = session_route.single_assignee(options.issue_assignees or payload.assignees)
  if canonical_login(assignee) ~= session.creator then
    return nil, "session creator must be sole assignee"
  end

  local fields = control_fields(payload, options)
  local kind = normalize_kind(fields.type)
  if kind == nil then
    return nil, "missing type"
  end
  if fields.project == nil then
    return nil, "missing project"
  end
  if fields.account == nil then
    return nil, "missing account"
  end
  local account = session_route.normalize_account(fields.account)
  if account == nil or account ~= session.account then
    return nil, "account does not match session"
  end
  if fields["work-label"] == nil then
    return nil, "missing work label field"
  end
  if fields["work-label"] ~= session.logical_work_label then
    return nil, "work label does not match session"
  end

  local source_ref, source_why = M.canonical_issue_source_ref(payload)
  if source_ref == nil then
    return nil, source_why
  end

  local raw_type = normalized_key(fields.type)
  local recurrence = normalize_recurrence(fields.recurrence)
  if recurrence == nil and (raw_type == "recurring-schedule-publish" or raw_type == "daily-schedule-publish") then
    recurrence = "daily"
  end

  local out = {
    kind = kind,
    project = safe_id(fields.project),
    account = account,
    work_label = session.logical_work_label,
    effective_work_label = session.effective_work_label,
    week = fields.week,
    strategy_ref = fields["strategy-ref"],
    content_ref = fields["content-ref"],
    content_digest = fields["content-digest"],
    approval_id = fields["approval-id"],
    mode = normalize_mode(fields.mode or fields.channel),
    recurrence = recurrence,
    scheduled_at = fields["scheduled-at"],
    interval_minutes = parse_interval_minutes(fields["interval-minutes"]),
    time = fields.time,
    timezone = fields.timezone,
    locale = fields.locale,
    owner = fields.owner,
    issue_number = payload.number,
    repo = payload.repo,
    source_ref = source_ref,
    trace_id = trace_id_for(source_ref),
  }

  if kind == "weekly-content" then
    local issue_author = content_filter.canon_login(options.issue_author_login or payload.author_login)
    local trusted_author = content_filter.canon_login(options.trusted_content_author_login)
    if trusted_author == nil or issue_author ~= trusted_author then
      return nil, "weekly content author is not trusted bot"
    end
    if fields.contract ~= marketing_content.CONTRACT then
      return nil, "unsupported weekly content contract"
    end
    if fields["content-id"] == nil then
      return nil, "missing content id"
    end
    local content_revision = tonumber(fields["content-revision"])
    if content_revision == nil or content_revision < 1 or content_revision ~= math.floor(content_revision) then
      return nil, "invalid content revision"
    end
    if fields["proposal-id"] == nil then
      return nil, "missing proposal id"
    end
    local proposal_revision = tonumber(fields["proposal-revision"])
    if proposal_revision == nil or proposal_revision < 1 or proposal_revision ~= math.floor(proposal_revision) then
      return nil, "invalid proposal revision"
    end
    if fields["approval-id"] ~= fields["proposal-id"] .. "@" .. tostring(proposal_revision) then
      return nil, "approval does not match proposal revision"
    end
    if fields["content-status"] ~= "approved" then
      return nil, "content is not approved"
    end
    local content, content_why = marketing_content.parse(options.issue_body)
    if content == nil then
      if content_why == "invalid content digest" or content_why == "content digest mismatch" then
        return nil, content_why
      end
      return nil, "invalid weekly content:" .. tostring(content_why)
    end
    if content.account ~= out.account or content.work_label ~= out.work_label
        or safe_id(content.project) ~= out.project or content.week ~= out.week then
      return nil, "weekly content identity mismatch"
    end
    out.content_id = content.content_id
    out.content_revision = content.content_revision
    out.proposal_id = content.proposal_id
    out.proposal_revision = content.proposal_revision
    out.approval_id = content.approval_id
    out.content_status = content.content_status
    out.content_digest = content.content_digest
    out.tweet_text = content.tweet_text
    out.operation = content.operation
    out.quote_mode = content.quote_mode
    out.quote_url = content.quote_url
    if out.week == nil then
      return nil, "missing week"
    end
  end
  if kind == "schedule-publish" then
    local schedule, schedule_why = marketing_schedule.parse(options.issue_body)
    if schedule == nil then
      if schedule_why == "unsupported schedule contract" then
        return nil, schedule_why
      end
      if fields["content-ref"] == nil or fields["content-digest"] == nil or fields["approval-id"] == nil then
        return nil, "missing schedule content fields"
      end
      if not sha256.is_tagged(fields["content-digest"]) then
        return nil, "invalid content digest"
      end
      return nil, "invalid schedule:" .. tostring(schedule_why)
    end
    if schedule.account ~= out.account or schedule.work_label ~= out.work_label
        or safe_id(schedule.project) ~= out.project or schedule.week ~= out.week then
      return nil, "schedule identity mismatch"
    end
    out.content_ref = schedule.content_ref
    out.content_digest = schedule.content_digest
    out.schedule_digest = schedule.schedule_digest
    out.approval_id = schedule.approval_id
    out.mode = schedule.mode
    out.recurrence = schedule.recurrence
    out.scheduled_at = schedule.scheduled_at
    out.interval_minutes = schedule.interval_minutes
    out.time = schedule.time
    out.timezone = schedule.timezone
    if out.recurrence == "daily" then
      if out.time == nil or out.timezone == nil then
        return nil, "missing recurring schedule fields"
      end
      if parse_clock_time(out.time) == nil then
        return nil, "invalid recurring time"
      end
      if parse_timezone_offset(out.timezone) == nil then
        return nil, "invalid recurring timezone"
      end
    elseif out.recurrence == "every-minutes" then
      if out.scheduled_at == nil or fields["interval-minutes"] == nil then
        return nil, "missing recurring schedule fields"
      end
      if out.interval_minutes == nil then
        return nil, "invalid interval-minutes"
      end
      if parse_iso8601_seconds(out.scheduled_at) == nil then
        return nil, "invalid scheduled-at"
      end
    elseif fields.recurrence ~= nil then
      return nil, "unsupported recurrence"
    elseif out.scheduled_at == nil then
      return nil, "missing schedule timing fields"
    elseif parse_iso8601_seconds(out.scheduled_at) == nil then
      return nil, "invalid scheduled-at"
    end
  end
  out.dedup_key = dedup_key_for(kind, fields, source_ref)
  return out
end

function M.artifact_id(item)
  if item.kind == "strategy" then
    return "auto-twitter-marketing/" .. item.account .. "/" .. item.project .. "/strategy"
  end
  if item.kind == "weekly-content" then
    return "auto-twitter-marketing/" .. item.account .. "/" .. item.project .. "/"
      .. tostring(item.week) .. "/weekly-content/" .. safe_id(item.content_id)
  end
  return "auto-twitter-marketing/" .. item.account .. "/" .. item.project .. "/"
    .. tostring(item.week) .. "/schedule"
end

function M.strategy_imported(item)
  return {
    schema = "auto-twitter-marketing.strategy-imported.v2",
    artifact_id = M.artifact_id(item),
    project = item.project,
    account = item.account,
    work_label = item.work_label,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.weekly_content_imported(item)
  return {
    schema = "auto-twitter-marketing.weekly-content-imported.v2",
    artifact_id = M.artifact_id(item),
    project = item.project,
    account = item.account,
    work_label = item.work_label,
    week = item.week,
    strategy_ref = item.strategy_ref,
    content_id = item.content_id,
    content_revision = item.content_revision,
    proposal_id = item.proposal_id,
    proposal_revision = item.proposal_revision,
    approval_id = item.approval_id,
    content_digest = item.content_digest,
    content_status = item.content_status,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.live_gate(item, opts)
  opts = opts or {}
  local expected = session_route.normalize_account(opts.expected_username)
  return item ~= nil
    and item.mode == "live"
    and expected ~= nil
    and expected == item.account
    and type(opts.nyxid_x_service) == "string"
    and opts.nyxid_x_service ~= ""
    and opts.live_write_enabled == true
end

function M.schedule_decision(item, now_seconds)
  if type(item) ~= "table" or item.kind ~= "schedule-publish" then
    return { due = false, reason = "not schedule" }
  end
  local current = tonumber(now_seconds)
  if current == nil then
    return { due = false, reason = "invalid now" }
  end
  if item.recurrence == "daily" then
    return daily_occurrence(item, current)
  end
  if item.recurrence == "every-minutes" then
    return every_minutes_occurrence(item, current)
  end
  local scheduled_seconds, why = parse_iso8601_seconds(item.scheduled_at)
  if scheduled_seconds == nil then
    return { due = false, reason = why or "invalid scheduled-at" }
  end
  return {
    due = current >= scheduled_seconds,
    reason = current >= scheduled_seconds and "due" or "not due",
    occurrence_id = tostring(item.scheduled_at),
    scheduled_at = item.scheduled_at,
    due_epoch_seconds = scheduled_seconds,
  }
end

function M.schedule_once_key(item, decision)
  local occurrence = decision and decision.occurrence_id or item and item.scheduled_at or "unknown"
  return table.concat({
    "auto-twitter-marketing",
    "schedule",
    runtime_key_segment(item and item.account or "account", 80),
    runtime_key_segment(item and item.project or "project", 80),
    runtime_key_segment(item and item.week or "week", 80),
    runtime_key_segment(item and item.source_ref and item.source_ref.ref or "source", 120),
    runtime_key_segment(occurrence, 120),
    runtime_key_segment(item and item.mode or "mode", 32),
    runtime_key_segment(item and item.content_digest or "content", 120),
    runtime_key_segment(item and item.approval_id or "approval", 120),
  }, "/")
end

function M.schedule_publish_dedup_key(item, decision)
  local occurrence = decision and decision.occurrence_id or item.scheduled_at or "unscheduled"
  return table.concat({
    "auto-twitter-marketing",
    safe_id(item.account),
    safe_id(item.project),
    safe_id(item.week),
    "schedule",
    safe_id(item.source_ref and item.source_ref.ref or "source"),
    safe_id(occurrence),
    "x-publish",
  }, "/")
end

function M.x_publish_request(item, opts, decision)
  local channel = item.mode == "live" and "live" or "shadow"
  local metadata = {
    campaign_id = item.project,
    content_type = "weekly-content",
    tag = "content:" .. tostring(item.content_ref),
    variant = channel == "live" and "live" or "preview",
  }
  metadata.schedule_type = item.recurrence or "one-shot"
  if item.interval_minutes ~= nil then
    metadata.interval_minutes = item.interval_minutes
  end
  if decision ~= nil and decision.occurrence_id ~= nil then
    metadata.occurrence_id = decision.occurrence_id
  end
  if item.locale ~= nil then
    metadata.locale = item.locale
  end
  if item.owner ~= nil then
    metadata.owner = item.owner
  end
  return {
    schema = "x-publisher.publish-request.v2",
    artifact_id = M.artifact_id(item),
    source_ref = copy_source_ref(item.source_ref),
    account = item.account,
    work_label = item.work_label,
    content_ref = item.content_ref,
    content_digest = item.content_digest,
    schedule_digest = item.schedule_digest,
    approval_id = item.approval_id,
    platform = "x",
    channel = channel,
    dedup_key = M.schedule_publish_dedup_key(item, decision),
    trace_id = item.trace_id,
    scheduled_at = decision and decision.scheduled_at or item.scheduled_at,
    metadata = metadata,
  }
end

M.parse_iso8601_seconds = parse_iso8601_seconds
M.runtime_key_segment = runtime_key_segment

function M.status_comment(item, status)
  local body = "Auto Twitter marketing: " .. tostring(status) .. "\n\n"
    .. "account: " .. tostring(item.account) .. "\n"
    .. "work_label: " .. tostring(item.work_label) .. "\n"
    .. "content_digest: " .. tostring(item.content_digest or "") .. "\n"
    .. "approval_id: " .. tostring(item.approval_id or "") .. "\n"
    .. "source_ref: " .. tostring((item.source_ref or {}).ref) .. "\n"
    .. "dedup_key: " .. tostring(item.dedup_key)
  return {
    schema = "github-proxy.v1",
    repo = item.repo,
    issue_number = item.issue_number,
    body = body,
    dedup_key = item.dedup_key .. "/status/" .. safe_id(status),
    source_ref = copy_source_ref(item.source_ref),
  }
end

return M
