-- social-metrics/core.lua - pure helpers that normalize social metrics into a common shape.
-- No network reads happen here; host-pinned egress skills provide raw observations at the seam.
local M = {}

local METRIC_ALIASES = {
  favorite = "likes",
  favorites = "likes",
  like = "likes",
  likes = "likes",
  reply = "replies",
  replies = "replies",
  comment = "replies",
  comments = "replies",
  repost = "reposts",
  reposts = "reposts",
  retweet = "reposts",
  retweets = "reposts",
  quote = "quotes",
  quotes = "quotes",
  impression = "impressions",
  impressions = "impressions",
  bookmark = "bookmarks",
  bookmarks = "bookmarks",
  profile_click = "profile_clicks",
  profile_clicks = "profile_clicks",
  profileclicks = "profile_clicks",
  url_click = "url_clicks",
  url_clicks = "url_clicks",
  link_click = "url_clicks",
  link_clicks = "url_clicks",
  engagement = "engagement",
  engagements = "engagement",
}

function M.persistence_class()
  return "stateless_adapter"
end

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback
end

local function normalized_metric(metric)
  local value = safe_string(metric, "engagement"):lower()
  value = value:gsub("[%s%-]+", "_")
  return METRIC_ALIASES[value] or value
end

local function total_value(value)
  local number = tonumber(value) or 0
  if number < 0 then
    return 0
  end
  return number
end

-- Normalize a raw metric reading into { platform, post_uri, metric, value }. Fail-closed: a
-- missing/garbage value normalizes to 0 (never nil), so arithmetic downstream is total.
function M.normalize(platform, raw)
  if type(raw) ~= "table" then
    raw = {}
  end
  local out = {
    platform = safe_string(platform or raw.platform, "unknown"),
    post_uri = safe_string(raw.post_uri, "unknown"),
    metric = normalized_metric(raw.metric),
    value = total_value(raw.value),
  }
  if type(raw.artifact_id) == "string" and raw.artifact_id ~= "" then
    out.artifact_id = raw.artifact_id
  end
  if type(raw.campaign_id) == "string" and raw.campaign_id ~= "" then
    out.campaign_id = raw.campaign_id
  end
  if type(raw.observed_at) == "string" and raw.observed_at ~= "" then
    out.observed_at = raw.observed_at
  end
  if type(raw.trace_id) == "string" and raw.trace_id ~= "" then
    out.trace_id = raw.trace_id
  end
  return out
end

function M.preview_metric(payload)
  if type(payload) ~= "table" then
    payload = {}
  end
  return M.normalize(payload.platform, {
    post_uri = payload.post_uri,
    metric = payload.metric,
    value = 0,
    artifact_id = payload.artifact_id,
    campaign_id = payload.campaign_id,
    observed_at = payload.observed_at,
    trace_id = payload.trace_id,
  })
end

return M
