local strings = require("contract.strings")

local M = {
  MAX_BYTES = 512,
}

function M.is_canonical(value)
  return strings.is_bounded_string(value, M.MAX_BYTES)
    and strings.trim(value) == value
    and value:find("[%z\1-\31\127]") == nil
end

return M
