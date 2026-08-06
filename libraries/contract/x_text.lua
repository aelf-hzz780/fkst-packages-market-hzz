-- X text length helpers aligned with twitter-text v3 weights. Callers may pass URLs that are
-- already validated by their domain contract; each such URL receives X's transformed length.
local M = {}

local MAX_WEIGHTED_LENGTH = 280
local TRANSFORMED_URL_LENGTH = 23

local function codepoint_weight(codepoint)
  if codepoint <= 4351
      or (codepoint >= 8192 and codepoint <= 8205)
      or (codepoint >= 8208 and codepoint <= 8223)
      or (codepoint >= 8242 and codepoint <= 8247) then
    return 1
  end
  return 2
end

local function decode_codepoint(text, index)
  local first = text:byte(index)
  if first == nil then
    return nil, nil, "invalid utf-8"
  end
  if first < 0x80 then
    return first, index + 1, nil
  end

  local length
  local codepoint
  local minimum
  if first >= 0xC2 and first <= 0xDF then
    length, codepoint, minimum = 2, first - 0xC0, 0x80
  elseif first >= 0xE0 and first <= 0xEF then
    length, codepoint, minimum = 3, first - 0xE0, 0x800
  elseif first >= 0xF0 and first <= 0xF4 then
    length, codepoint, minimum = 4, first - 0xF0, 0x10000
  else
    return nil, nil, "invalid utf-8"
  end

  for offset = 1, length - 1 do
    local continuation = text:byte(index + offset)
    if continuation == nil or continuation < 0x80 or continuation > 0xBF then
      return nil, nil, "invalid utf-8"
    end
    codepoint = codepoint * 0x40 + continuation - 0x80
  end
  if codepoint < minimum or codepoint > 0x10FFFF
      or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
    return nil, nil, "invalid utf-8"
  end
  return codepoint, index + length, nil
end

local function is_emoji_base(codepoint)
  return (codepoint >= 0x1F000 and codepoint <= 0x1FAFF)
    or (codepoint >= 0x2300 and codepoint <= 0x23FF)
    or (codepoint >= 0x2600 and codepoint <= 0x27BF)
    or (codepoint >= 0x2B00 and codepoint <= 0x2BFF)
    or codepoint == 0x00A9
    or codepoint == 0x00AE
    or codepoint == 0x203C
    or codepoint == 0x2049
    or codepoint == 0x2122
    or codepoint == 0x2139
    or codepoint == 0x3030
    or codepoint == 0x303D
    or codepoint == 0x3297
    or codepoint == 0x3299
end

local function consume_variants(text, index)
  local cursor = index
  while cursor <= #text do
    local codepoint, next_index = decode_codepoint(text, cursor)
    if codepoint == 0xFE0F or (codepoint >= 0x1F3FB and codepoint <= 0x1F3FF) then
      cursor = next_index
    else
      break
    end
  end
  return cursor
end

local function emoji_cluster_end(text, codepoint, next_index)
  if codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF then
    local next_codepoint, after_flag = decode_codepoint(text, next_index)
    if next_codepoint ~= nil and next_codepoint >= 0x1F1E6 and next_codepoint <= 0x1F1FF then
      return after_flag
    end
  end

  if codepoint == 0x23 or codepoint == 0x2A or (codepoint >= 0x30 and codepoint <= 0x39) then
    local cursor = consume_variants(text, next_index)
    local keycap, after_keycap = decode_codepoint(text, cursor)
    return keycap == 0x20E3 and after_keycap or next_index
  end
  if not is_emoji_base(codepoint) then
    return next_index
  end

  local cursor = consume_variants(text, next_index)
  while cursor <= #text do
    local joiner, after_joiner = decode_codepoint(text, cursor)
    if joiner ~= 0x200D then
      break
    end
    local joined, after_joined = decode_codepoint(text, after_joiner)
    if joined == nil or not is_emoji_base(joined) then
      break
    end
    cursor = consume_variants(text, after_joined)
  end
  return cursor
end

local function transformed_url_ranges(text, urls)
  local ranges = {}
  for _, url in ipairs(urls or {}) do
    if type(url) ~= "string" or url == "" then
      return nil, "invalid transformed url"
    end
    local start_at = 1
    local found = false
    while true do
      local first, last = text:find(url, start_at, true)
      if first == nil then
        break
      end
      if ranges[first] ~= nil then
        return nil, "overlapping transformed url"
      end
      ranges[first] = last
      start_at = last + 1
      found = true
    end
    if not found then
      return nil, "missing transformed url"
    end
  end
  return ranges, nil
end

function M.analyze(text, opts)
  if type(text) ~= "string" or text:match("^%s*$") then
    return { valid = false, weighted_length = 0, max_weighted_length = MAX_WEIGHTED_LENGTH,
      reason = "empty text" }
  end
  local ranges, ranges_why = transformed_url_ranges(text, opts and opts.transformed_urls)
  if ranges == nil then
    return { valid = false, weighted_length = 0, max_weighted_length = MAX_WEIGHTED_LENGTH,
      reason = ranges_why }
  end

  local weighted = 0
  local index = 1
  while index <= #text do
    local url_end = ranges[index]
    if url_end ~= nil then
      weighted = weighted + TRANSFORMED_URL_LENGTH
      index = url_end + 1
    else
      local codepoint, next_index, why = decode_codepoint(text, index)
      if codepoint == nil then
        return { valid = false, weighted_length = weighted,
          max_weighted_length = MAX_WEIGHTED_LENGTH, reason = why }
      end
      if codepoint == 0xFEFF or codepoint == 0xFFFE or codepoint == 0xFFFF then
        return { valid = false, weighted_length = weighted + codepoint_weight(codepoint),
          max_weighted_length = MAX_WEIGHTED_LENGTH, reason = "invalid character" }
      end
      local cluster_end = emoji_cluster_end(text, codepoint, next_index)
      weighted = weighted + (cluster_end > next_index and 2 or codepoint_weight(codepoint))
      index = cluster_end
    end
  end

  return {
    valid = weighted > 0 and weighted <= MAX_WEIGHTED_LENGTH,
    weighted_length = weighted,
    max_weighted_length = MAX_WEIGHTED_LENGTH,
    reason = weighted > MAX_WEIGHTED_LENGTH and "text too long" or nil,
  }
end

return M
