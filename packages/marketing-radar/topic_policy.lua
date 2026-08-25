local strings = require("contract.strings")

local M = {
  MAX_TOPIC_BYTES = 80,
}

function M.validate(value)
  if value ~= nil and type(value) ~= "string" then
    return nil, "noncanonical-topic"
  end
  local topic = strings.trim(value)
  if topic == "" then
    return nil, "missing-topic"
  end
  if #topic > M.MAX_TOPIC_BYTES then
    return nil, "topic-too-large"
  end
  if topic:match("^[a-z0-9%-]+$") == nil
      or topic:sub(1, 1) == "-" or topic:sub(-1) == "-"
      or topic:find("--", 1, true) ~= nil then
    return nil, "noncanonical-topic"
  end
  return topic, nil
end

return M
