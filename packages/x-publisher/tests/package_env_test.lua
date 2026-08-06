local t = fkst.test
local package_env = require("x_publisher_package_env")

local COMMAND = 'printf %s "$FKST_SESSION_PACKAGE_ENV_JSON"'

local function mock_package_env(raw)
  t.mock_command(COMMAND, {
    stdout = raw or "",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_reads_native_quote_gate_from_x_publisher_block = function()
    mock_package_env('{"x-publisher":{"FKST_X_PUBLISH_NATIVE_QUOTE":"1"}}')
    t.eq(package_env.get("FKST_X_PUBLISH_NATIVE_QUOTE"), "1")
  end,

  test_missing_or_other_package_block_does_not_enable_gate = function()
    mock_package_env('{"other-package":{"FKST_X_PUBLISH_NATIVE_QUOTE":"1"}}')
    t.eq(package_env.get("FKST_X_PUBLISH_NATIVE_QUOTE"), nil)
  end,

  test_malformed_package_env_fails_closed = function()
    mock_package_env('{not-json}')
    local ok, why = pcall(function()
      return package_env.get("FKST_X_PUBLISH_NATIVE_QUOTE")
    end)
    t.eq(ok, false)
    t.eq(tostring(why):find("invalid JSON object", 1, true) ~= nil, true)
  end,

  test_unsupported_key_is_rejected_without_reading_environment = function()
    local ok, why = pcall(function()
      return package_env.get("FKST_X_PUBLISH_WRITE")
    end)
    t.eq(ok, false)
    t.eq(tostring(why):find("unsupported key", 1, true) ~= nil, true)
  end,
}
