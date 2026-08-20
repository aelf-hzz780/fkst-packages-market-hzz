local strings = require("contract.strings")

local M = {}

local PREFIX = "Marketing radar v0.3.0: "
local STATUS_SEGMENT_LIMIT = 100

function M.canonical_line(value)
  local line = tostring(value or ""):gsub("[%z\1-\32\127]+", " ")
  return strings.trim(line:gsub("%s+", " "))
end

function M.prefix(status)
  return PREFIX .. tostring(status or "")
end

function M.status_from_body(body)
  local line = tostring(body or ""):match("^([^\r\n]*)") or ""
  if line:sub(1, #PREFIX) ~= PREFIX then
    return nil
  end
  return line:sub(#PREFIX + 1)
end

function M.segment(status)
  local raw = tostring(status or "")
  local safe = strings.runtime_safe_segment(raw)
  if #safe <= STATUS_SEGMENT_LIMIT then
    return safe
  end
  local suffix = "_" .. strings.decimal_checksum(raw)
  return safe:sub(1, STATUS_SEGMENT_LIMIT - #suffix) .. suffix
end

return M
