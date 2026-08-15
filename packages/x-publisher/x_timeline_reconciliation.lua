-- Pure helpers for reconciling an intended X publish against the authenticated account timeline.
local M = {}
local strings = require("contract.strings")

local MAX_SCHEDULE_AGE_SECONDS = 30 * 24 * 60 * 60
local MAX_CLOCK_SKEW_SECONDS = 5 * 60
local MAX_TIMELINE_PAGES = 5
local MAX_TIMELINE_RESULTS = 100
local MAX_X_ID_BYTES = 19
local MAX_URL_ENTITIES = 100
local MAX_REFERENCES = 100

local function decode_json(source)
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return nil
  end
  local ok, decoded = pcall(json.decode, tostring(source or ""))
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function is_leap_year(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local function days_in_month(year, month)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and is_leap_year(year) then
    return 29
  end
  return days[month]
end

local function epoch_seconds_utc(year, month, day, hour, minute, second)
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  minute = tonumber(minute)
  second = tonumber(second)
  if year == nil or month == nil or day == nil or hour == nil or minute == nil or second == nil
      or year < 1970 or year > 2200 or month < 1 or month > 12 then
    return nil
  end
  local max_day = days_in_month(year, month)
  if day < 1 or day > max_day or hour < 0 or hour > 23
      or minute < 0 or minute > 59 or second < 0 or second > 59 then
    return nil
  end

  local adjusted_year = year
  local adjusted_month = month
  if adjusted_month <= 2 then
    adjusted_year = adjusted_year - 1
    adjusted_month = adjusted_month + 12
  end
  local era = math.floor(adjusted_year / 400)
  local year_of_era = adjusted_year - era * 400
  local day_of_year = math.floor((153 * (adjusted_month - 3) + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365
    + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100)
    + day_of_year
  local days_since_epoch = era * 146097 + day_of_era - 719468
  return days_since_epoch * 86400 + hour * 3600 + minute * 60 + second
end

local function timezone_offset_seconds(value)
  local zone = strings.trim(tostring(value or ""))
  if zone == "" or zone == "Z" or zone == "UTC" or zone == "Etc/UTC" then
    return 0
  end
  if zone == "Asia/Shanghai" or zone == "Asia/Chongqing" then
    return 8 * 60 * 60
  end
  local sign, offset_hour, offset_minute = zone:match("^([+-])(%d%d):(%d%d)$")
  if sign == nil then
    sign, offset_hour, offset_minute = zone:match("^([+-])(%d%d)(%d%d)$")
  end
  offset_hour = tonumber(offset_hour)
  offset_minute = tonumber(offset_minute)
  if sign == nil or offset_hour == nil or offset_minute == nil
      or offset_hour > 23 or offset_minute > 59 then
    return nil
  end
  local offset_seconds = offset_hour * 3600 + offset_minute * 60
  return sign == "-" and -offset_seconds or offset_seconds
end

local function parse_schedule_timestamp(value)
  local text = strings.trim(tostring(value or ""))
  local year, month, day, hour, minute, second, suffix = text:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$"
  )
  if year == nil then
    year, month, day, hour, minute, suffix = text:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d)(.*)$"
    )
    second = "00"
  end
  if year == nil then
    return nil
  end
  local _fraction, zone = tostring(suffix or ""):match("^(%.%d+)(.*)$")
  if _fraction == nil then
    zone = suffix
  end
  local offset_seconds = timezone_offset_seconds(zone)
  if offset_seconds == nil then
    return nil
  end

  local epoch = epoch_seconds_utc(year, month, day, hour, minute, second)
  if epoch == nil then
    return nil
  end
  return epoch - offset_seconds
end

local function parse_provider_timestamp(value)
  local year, month, day, hour, minute, second, suffix = tostring(value or ""):match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$"
  )
  if year == nil then
    return nil
  end
  local _fraction, zone = tostring(suffix or ""):match("^(%.%d+)(.*)$")
  if _fraction == nil then
    zone = suffix
  end
  local offset_seconds = 0
  if zone ~= "Z" then
    local sign, offset_hour, offset_minute = tostring(zone or ""):match(
      "^([+-])(%d%d):(%d%d)$"
    )
    offset_hour = tonumber(offset_hour)
    offset_minute = tonumber(offset_minute)
    if sign == nil or offset_hour == nil or offset_minute == nil
        or offset_hour > 23 or offset_minute > 59 then
      return nil
    end
    offset_seconds = offset_hour * 3600 + offset_minute * 60
    if sign == "-" then
      offset_seconds = -offset_seconds
    end
  end
  local epoch = epoch_seconds_utc(year, month, day, hour, minute, second)
  if epoch == nil then
    return nil
  end
  return epoch - offset_seconds
end

local function format_utc(epoch_seconds)
  local value = tonumber(epoch_seconds)
  if value == nil then
    return nil
  end
  local parts = os.date("!*t", math.floor(value))
  if type(parts) ~= "table" then
    return nil
  end
  return string.format(
    "%04d-%02d-%02dT%02d:%02d:%02dZ",
    parts.year,
    parts.month,
    parts.day,
    parts.hour,
    parts.min,
    parts.sec
  )
end

local function percent_encode(value)
  return (tostring(value or ""):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function safe_token(value)
  if value == nil then
    return nil
  end
  local token = tostring(value)
  if token == "" or #token > 512 or token:find("[%s%c]") then
    return nil
  end
  return token
end

local function bounded_numeric_id(value)
  return type(value) == "string"
    and #value >= 1
    and #value <= MAX_X_ID_BYTES
    and value:match("^[1-9]%d*$") ~= nil
end

local function contiguous_array_length(value, limit)
  if type(value) ~= "table" then
    return nil
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > limit then
      return nil
    end
    count = count + 1
  end
  for index = 1, count do
    if rawget(value, index) == nil then
      return nil
    end
  end
  return count
end

local function replace_literal(text, needle, replacement)
  local source = tostring(text or "")
  local target = tostring(needle or "")
  if target == "" then
    return source, false
  end
  local first, last = source:find(target, 1, true)
  if first == nil then
    return source, false
  end
  return source:sub(1, first - 1)
    .. tostring(replacement or "")
    .. source:sub(last + 1), true
end

local function status_post_id(url)
  local scheme, authority, path = tostring(url or ""):match("^([%a][%w+.-]*)://([^/]+)(/.*)$")
  local host = tostring(authority or ""):lower():gsub("^www%.", "")
  if tostring(scheme or ""):lower() ~= "https"
      or (host ~= "x.com" and host ~= "twitter.com") then
    return nil
  end
  local post_id, suffix = tostring(path or ""):match("^/[^/?#]+/status/(%d+)(.*)$")
  if post_id == nil then
    post_id, suffix = tostring(path or ""):match("^/i/web/status/(%d+)(.*)$")
  end
  if not bounded_numeric_id(post_id)
      or (suffix ~= "" and suffix:match("^[/?#]") == nil) then
    return nil
  end
  return post_id
end

local function canonical_url(url)
  local post_id = status_post_id(url)
  if post_id ~= nil then
    return "https://x.com/i/web/status/" .. post_id
  end
  return tostring(url or "")
end

local function normalize_status_urls(text)
  return tostring(text or ""):gsub("(https://[^%s]+)", function(url)
    local trailing = ""
    while url:match("[%)%]%}%.,;!%?]$") do
      trailing = url:sub(-1) .. trailing
      url = url:sub(1, -2)
    end
    return canonical_url(url) .. trailing
  end)
end

local function normalized_text(value)
  return strings.trim(normalize_status_urls(
    tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  ))
end

local function candidate_text(post)
  local text = tostring(post.text or "")
  local entities = post.entities
  if entities ~= nil and type(entities) ~= "table" then
    return nil, "invalid timeline entities"
  end
  local urls = type(entities) == "table" and entities.urls or nil
  if urls ~= nil and type(urls) ~= "table" then
    return nil, "invalid timeline url entities"
  end
  local url_count = contiguous_array_length(urls or {}, MAX_URL_ENTITIES)
  if url_count == nil then
    return nil, "invalid timeline url entities"
  end
  for index = 1, url_count do
    local entity = urls[index]
    if type(entity) ~= "table" or type(entity.url) ~= "string" or entity.url == "" then
      return nil, "invalid timeline url entity"
    end
    local expanded = entity.expanded_url or entity.unwound_url
    if type(expanded) ~= "string" or expanded == "" or #expanded > 2048 then
      return nil, "invalid timeline url entity"
    end
    local replaced
    text, replaced = replace_literal(text, entity.url, canonical_url(expanded))
    if not replaced then
      return nil, "timeline url entity missing from text"
    end
  end
  if text:find("https://t.co/", 1, true) ~= nil then
    return nil, "incomplete timeline url evidence"
  end
  return normalized_text(text), nil
end

local function validated_references(post, required)
  local references = post.referenced_tweets
  if references == nil then
    if required then
      return nil, nil, "incomplete timeline quote evidence"
    end
    return {}, 0, nil
  end
  local reference_count = contiguous_array_length(references, MAX_REFERENCES)
  if reference_count == nil then
    return nil, nil, "invalid timeline reference evidence"
  end
  for index = 1, reference_count do
    local reference = references[index]
    if type(reference) ~= "table" or type(reference.type) ~= "string"
        or not bounded_numeric_id(reference.id) then
      return nil, nil, "invalid timeline reference evidence"
    end
  end
  return references, reference_count, nil
end

local function references_quote(post, expected_post_id)
  if not bounded_numeric_id(expected_post_id) then
    return nil, "invalid timeline quote intent"
  end
  local references, reference_count, why = validated_references(post, true)
  if references == nil then
    if why == "invalid timeline reference evidence" then
      return nil, "invalid timeline quote evidence"
    end
    return nil, why
  end
  local matched = false
  for index = 1, reference_count do
    local reference = references[index]
    if reference.type == "quoted" and reference.id == expected_post_id then
      matched = true
    end
  end
  return matched, nil
end

local function native_quote_text_matches(actual, intent)
  local expected = normalized_text(intent.text)
  if actual == expected then
    return true
  end
  local target = canonical_url(type(intent.quote_post) == "table" and intent.quote_post.url or "")
  if target == "" or actual:sub(-#target) ~= target then
    return false
  end
  return strings.trim(actual:sub(1, #actual - #target)) == expected
end

local function post_matches(post, intent, window)
  local created_epoch = parse_provider_timestamp(post.created_at)
  if created_epoch == nil or created_epoch < window.start_epoch
      or created_epoch > window.end_epoch + MAX_CLOCK_SKEW_SECONDS then
    return false, nil
  end
  local actual, text_why = candidate_text(post)
  if actual == nil then
    return nil, text_why
  end

  if intent.operation ~= "quote" then
    if actual ~= normalized_text(intent.publish_text) then
      return false, nil
    end
    local references, reference_count, reference_why = validated_references(post, false)
    if references == nil then
      return nil, reference_why
    end
    return reference_count == 0, nil
  end
  local quote_post = intent.quote_post
  if type(quote_post) ~= "table" then
    return nil, "invalid timeline quote intent"
  end
  local text_matches
  if quote_post.mode == "native" then
    text_matches = native_quote_text_matches(actual, intent)
  elseif quote_post.mode == "link" then
    text_matches = actual == normalized_text(intent.publish_text)
  else
    return nil, "invalid timeline quote intent"
  end
  if not text_matches then
    return false, nil
  end
  local quoted, quote_why = references_quote(post, quote_post.provider_post_id)
  if quoted == nil then
    return nil, quote_why
  end
  return quoted, nil
end

function M.parse_account_response(source)
  local decoded = decode_json(source)
  local data = type(decoded) == "table" and decoded.data or nil
  local account_id = type(data) == "table" and data.id or nil
  local username = type(data) == "table" and data.username or nil
  if not bounded_numeric_id(account_id)
      or type(username) ~= "string" or not username:match("^[A-Za-z0-9_]+$")
      or #username < 1 or #username > 15 then
    return nil, "invalid nyxid account response"
  end
  return { id = account_id, username = username }, nil
end

function M.reconciliation_window(payload, now_seconds)
  local current = tonumber(now_seconds)
  if current == nil or current < 0 then
    return nil, "invalid timeline reconciliation time"
  end
  local scheduled_at = type(payload) == "table" and payload.scheduled_at or nil
  if scheduled_at == nil or strings.trim(scheduled_at) == "" then
    return nil, nil
  end
  local start_epoch = parse_schedule_timestamp(strings.trim(scheduled_at))
  if start_epoch == nil then
    return nil, "invalid timeline reconciliation scheduled_at"
  end
  if current - start_epoch > MAX_SCHEDULE_AGE_SECONDS then
    return nil, "timeline reconciliation window too old"
  end
  if start_epoch > current + MAX_CLOCK_SKEW_SECONDS then
    return nil, "timeline reconciliation scheduled_at is in the future"
  end
  local start_time = format_utc(start_epoch)
  if start_time == nil then
    return nil, "invalid timeline reconciliation window"
  end
  return {
    start_epoch = start_epoch,
    start_time = start_time,
    end_epoch = current,
  }, nil
end

function M.timeline_path(account_id, start_time, pagination_token)
  if not bounded_numeric_id(account_id)
      or parse_provider_timestamp(start_time) == nil then
    return nil
  end
  local path = "/users/" .. account_id .. "/tweets"
    .. "?exclude=" .. percent_encode("retweets,replies")
    .. "&max_results=100"
    .. "&start_time=" .. percent_encode(start_time)
    .. "&tweet.fields=" .. percent_encode("created_at,entities,referenced_tweets")
  if pagination_token ~= nil then
    local token = safe_token(pagination_token)
    if token == nil then
      return nil
    end
    path = path .. "&pagination_token=" .. percent_encode(token)
  end
  return path
end

function M.parse_timeline_page(source)
  local decoded = decode_json(source)
  if decoded == nil or decoded.errors ~= nil or type(decoded.meta) ~= "table" then
    return nil, "invalid timeline response"
  end
  local result_count = decoded.meta.result_count
  if type(result_count) ~= "number" or result_count % 1 ~= 0
      or result_count < 0 or result_count > MAX_TIMELINE_RESULTS then
    return nil, "invalid timeline response"
  end
  local posts = decoded.data
  if posts == nil and result_count == 0 then
    posts = {}
  end
  local post_count = contiguous_array_length(posts, MAX_TIMELINE_RESULTS)
  if post_count == nil or post_count ~= result_count then
    return nil, "invalid timeline response"
  end
  for index = 1, post_count do
    local post = posts[index]
    if type(post) ~= "table" or not bounded_numeric_id(post.id)
        or type(post.text) ~= "string" or #post.text > 4096
        or parse_provider_timestamp(post.created_at) == nil then
      return nil, "invalid timeline post"
    end
  end
  local next_token = type(decoded.meta) == "table" and decoded.meta.next_token or nil
  if next_token ~= nil then
    next_token = safe_token(next_token)
    if next_token == nil then
      return nil, "invalid timeline pagination token"
    end
  end
  return { posts = posts, next_token = next_token }, nil
end

function M.matching_post_ids(posts, intent, window)
  if type(posts) ~= "table" or type(intent) ~= "table"
      or type(intent.publish_text) ~= "string" or type(window) ~= "table"
      or type(window.start_epoch) ~= "number" or type(window.end_epoch) ~= "number" then
    return nil, "invalid timeline reconciliation input"
  end
  local post_count = contiguous_array_length(posts, MAX_TIMELINE_RESULTS)
  if post_count == nil then
    return nil, "invalid timeline reconciliation input"
  end
  local matches = {}
  for index = 1, post_count do
    local post = posts[index]
    local matched, why = post_matches(post, intent, window)
    if matched == nil then
      return nil, why
    end
    if matched then
      matches[#matches + 1] = post.id
    end
  end
  return matches, nil
end

function M.max_timeline_pages()
  return MAX_TIMELINE_PAGES
end

return M
