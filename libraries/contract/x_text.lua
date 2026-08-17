-- X text length helpers aligned with twitter-text v3 weights. Ordinary HTTP(S) URLs receive
-- X's transformed length automatically; callers may still identify prevalidated URL spans.
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
  local covered = {}
  for _, url in ipairs(urls or {}) do
    if type(url) ~= "string" or url == "" then
      return nil, nil, "invalid transformed url"
    end
    local start_at = 1
    local found = false
    while true do
      local first, last = text:find(url, start_at, true)
      if first == nil then
        break
      end
      if ranges[first] ~= nil then
        return nil, nil, "overlapping transformed url"
      end
      ranges[first] = last
      for index = first, last do
        covered[index] = true
      end
      start_at = last + 1
      found = true
    end
    if not found then
      return nil, nil, "missing transformed url"
    end
  end
  return ranges, covered, nil
end

local function http_scheme_length(text, index)
  local previous = index > 1 and text:sub(index - 1, index - 1) or ""
  if previous:match("[%w_]") then
    return nil
  end
  if text:sub(index, index + 7):lower() == "https://" then
    return 8
  end
  if text:sub(index, index + 6):lower() == "http://" then
    return 7
  end
  return nil
end

local function url_terminator(byte)
  return byte == nil or byte <= 0x20 or byte == 0x7F
    or byte == 0x22 or byte == 0x27 or byte == 0x3C or byte == 0x3E or byte == 0x60
end

local function valid_url_text(text, first, last)
  local index = first
  while index <= last do
    local codepoint, next_index = decode_codepoint(text, index)
    if codepoint == nil or next_index > last + 1
        or codepoint == 0xFEFF or codepoint == 0xFFFE or codepoint == 0xFFFF then
      return false
    end
    index = next_index
  end
  return true
end

local function trim_url_end(text, first, last)
  local balance = { [")"] = 0, ["]"] = 0, ["}"] = 0 }
  local opening = { ["("] = ")", ["["] = "]", ["{"] = "}" }
  for index = first, last do
    local char = text:sub(index, index)
    if opening[char] ~= nil then
      balance[opening[char]] = balance[opening[char]] + 1
    elseif balance[char] ~= nil then
      balance[char] = balance[char] - 1
    end
  end

  while last >= first do
    local char = text:sub(last, last)
    if char:match("[.,!?;:]") or opening[char] ~= nil then
      last = last - 1
    elseif balance[char] ~= nil and balance[char] < 0 then
      balance[char] = balance[char] + 1
      last = last - 1
    else
      break
    end
  end
  return last
end

local function ordinary_url_end(text, index)
  local scheme_length = http_scheme_length(text, index)
  if scheme_length == nil then
    return nil
  end
  local content_start = index + scheme_length
  local cursor = content_start
  while cursor <= #text and not url_terminator(text:byte(cursor)) do
    cursor = cursor + 1
  end
  local last = trim_url_end(text, content_start, cursor - 1)
  if last < content_start then
    return nil
  end
  local remainder = text:sub(content_start, last)
  local authority = remainder:match("^([^/?#]+)")
  if authority == nil or authority == "" or authority:find("[%w\128-\255]") == nil
      or not valid_url_text(text, index, last) then
    return nil
  end
  return last
end

local function add_ordinary_url_ranges(text, ranges, covered)
  local index = 1
  while index <= #text do
    local last = ordinary_url_end(text, index)
    if last == nil then
      index = index + 1
    else
      local overlaps_explicit = false
      for cursor = index, last do
        if covered[cursor] then
          overlaps_explicit = true
          break
        end
      end
      if not overlaps_explicit then
        ranges[index] = last
      end
      index = last + 1
    end
  end
end

function M.analyze(text, opts)
  if type(text) ~= "string" or text:match("^%s*$") then
    return { valid = false, weighted_length = 0, max_weighted_length = MAX_WEIGHTED_LENGTH,
      reason = "empty text" }
  end
  local ranges, covered, ranges_why = transformed_url_ranges(text, opts and opts.transformed_urls)
  if ranges == nil then
    return { valid = false, weighted_length = 0, max_weighted_length = MAX_WEIGHTED_LENGTH,
      reason = ranges_why }
  end
  add_ordinary_url_ranges(text, ranges, covered)

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
