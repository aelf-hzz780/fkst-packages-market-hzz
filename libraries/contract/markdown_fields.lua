local strings = require("contract.strings")

local M = {}

local function trim(value)
  return strings.trim(value or "")
end

local function normalized_key(value)
  return trim(value):lower():gsub("_", "-")
end

local function line_iter(body)
  local text = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local position = 1
  return function()
    if position > #text then
      return nil
    end
    local next_position = text:find("\n", position, true)
    local line = text:sub(position, next_position - 1)
    position = next_position + 1
    return line
  end
end

local function fence_run(line, marker)
  local pattern = marker == "`" and "^( *)(`+)(.*)$" or "^( *)(~+)(.*)$"
  local indent, run, rest = line:match(pattern)
  if indent == nil or #indent > 3 or #run < 3 then
    return nil
  end
  return run, rest
end

local function opening_fence(line)
  for _, marker in ipairs({ "`", "~" }) do
    local run, rest = fence_run(line, marker)
    if run ~= nil and (marker ~= "`" or not rest:find("`", 1, true)) then
      return marker, #run
    end
  end
  return nil, nil
end

local function closes_fence(line, marker, width)
  local run, rest = fence_run(line, marker)
  return run ~= nil and #run >= width and trim(rest) == ""
end

function M.tokenize(body)
  if type(body) ~= "string" then
    return nil, "invalid-markdown-body"
  end
  local tokens = {}
  local marker, width = nil, nil
  for line in line_iter(body) do
    if marker ~= nil then
      if closes_fence(line, marker, width) then
        tokens[#tokens + 1] = { kind = "fence-close", line = line }
        marker, width = nil, nil
      else
        tokens[#tokens + 1] = { kind = "fence-content", line = line }
      end
    else
      local next_marker, next_width = opening_fence(line)
      if next_marker ~= nil then
        marker, width = next_marker, next_width
        tokens[#tokens + 1] = { kind = "fence-open", line = line }
      else
        tokens[#tokens + 1] = { kind = "text", line = line }
      end
    end
  end
  if marker ~= nil then
    return tokens, "unterminated-markdown-fence"
  end
  return tokens, nil
end

function M.unfenced_lines(body)
  local tokens, why = M.tokenize(body)
  if tokens == nil or why ~= nil then
    return nil, why
  end
  local lines = {}
  for _, token in ipairs(tokens) do
    if token.kind == "text" then
      lines[#lines + 1] = token.line
    end
  end
  return lines, nil
end

function M.fenced_field(body, field)
  local tokens, token_why = M.tokenize(body)
  if tokens == nil then
    return nil, token_why
  end
  local target = normalized_key(field)
  local waiting, collecting = false, false
  local found, count = nil, 0
  local lines = {}

  local function accept(value)
    count = count + 1
    if count == 1 then
      found = trim(value)
    end
  end

  for _, token in ipairs(tokens) do
    if token.kind == "fence-content" and collecting then
      lines[#lines + 1] = token.line
    elseif token.kind == "fence-close" and collecting then
      accept(table.concat(lines, "\n"))
      waiting, collecting, lines = false, false, {}
    elseif token.kind == "fence-open" and waiting then
      collecting = true
    elseif token.kind == "text" and not collecting then
      local key, value = token.line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
      if waiting and trim(token.line) ~= "" then
        if key == nil then
          accept(token.line)
          waiting = false
        else
          accept("")
          waiting = false
        end
      end
      if not waiting and key ~= nil and normalized_key(key) == target then
        local inline = trim(value)
        if inline ~= "" and inline ~= "|" and inline ~= ">" then
          accept(inline)
        else
          waiting = true
        end
      end
    end
  end

  if token_why ~= nil then
    return nil, token_why
  end
  if collecting then
    return nil, "unterminated-fenced-field:" .. target
  end
  if waiting then
    accept("")
  end
  if count > 1 then
    return nil, "duplicate-fenced-field:" .. target
  end
  if count == 0 or found == "" then
    return nil, "missing-fenced-field:" .. target
  end
  return found, nil
end

function M.render_fenced(value)
  local text = tostring(value or "")
  local width = 3
  for run in text:gmatch("(`+)") do
    width = math.max(width, #run + 1)
  end
  local delimiter = string.rep("`", width)
  return delimiter .. "\n" .. text .. "\n" .. delimiter
end

return M
