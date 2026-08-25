local package_env = require("marketing_radar_package_env")
local t = fkst.test

local COMMAND = 'printf %s "$FKST_SESSION_PACKAGE_ENV_JSON"'

local function mock_package_env(raw)
  t.mock_command(COMMAND, {
    stdout = raw or "",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_reads_exact_past_week_migration_refs_from_marketing_radar_block = function()
    mock_package_env('{"marketing-radar":{"FKST_MARKETING_PAST_WEEK_MIGRATION_REFS"'
      .. ':"owner/repo#issue/116,owner/repo#issue/117"}}')
    t.eq(package_env.get("FKST_MARKETING_PAST_WEEK_MIGRATION_REFS"),
      "owner/repo#issue/116,owner/repo#issue/117")
  end,

  test_missing_or_other_package_block_does_not_enable_migration = function()
    mock_package_env('{"x-publisher":{"FKST_MARKETING_PAST_WEEK_MIGRATION_REFS"'
      .. ':"owner/repo#issue/116"}}')
    t.is_nil(package_env.get("FKST_MARKETING_PAST_WEEK_MIGRATION_REFS"))
  end,

  test_malformed_package_env_fails_closed = function()
    mock_package_env('{not-json}')
    local ok, why = pcall(function()
      return package_env.get("FKST_MARKETING_PAST_WEEK_MIGRATION_REFS")
    end)
    t.eq(ok, false)
    t.is_true(tostring(why):find("invalid JSON object", 1, true) ~= nil)
  end,

  test_non_string_and_unsupported_values_fail_closed = function()
    mock_package_env('{"marketing-radar":{"FKST_MARKETING_PAST_WEEK_MIGRATION_REFS":true}}')
    local string_ok, string_why = pcall(function()
      return package_env.get("FKST_MARKETING_PAST_WEEK_MIGRATION_REFS")
    end)
    t.eq(string_ok, false)
    t.is_true(tostring(string_why):find("must be a string", 1, true) ~= nil)

    local key_ok, key_why = pcall(function()
      return package_env.get("FKST_MARKETING_UNKNOWN")
    end)
    t.eq(key_ok, false)
    t.is_true(tostring(key_why):find("unsupported key", 1, true) ~= nil)
  end,
}
