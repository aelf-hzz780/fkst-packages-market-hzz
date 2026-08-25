local package_env = require("marketing_radar_package_env")
local week_policy = require("week_policy")

local M = {}

local function default_clock()
  return math.floor(now())
end

local function default_migration_refs()
  return package_env.get("FKST_MARKETING_PAST_WEEK_MIGRATION_REFS")
end

function M.new(options)
  local ports = options or {}
  local clock = ports.clock or default_clock
  local migration_refs = ports.past_week_migration_refs or default_migration_refs
  local evaluate_group = ports.evaluate_week_group or week_policy.evaluate_group
  local loaded = false
  local snapshot
  local snapshot_why

  local function load_snapshot()
    if loaded then
      return snapshot, snapshot_why
    end
    loaded = true

    local clock_ok, reference_epoch_seconds = pcall(clock)
    if not clock_ok then
      snapshot_why = "invalid-reference-week"
      return nil, snapshot_why
    end
    local migration_ok, raw_refs = pcall(migration_refs)
    if not migration_ok then
      snapshot_why = "invalid-migration-source-ref"
      return nil, snapshot_why
    end
    local parse_ok, migration_allowlist, parse_why = pcall(
      week_policy.parse_migration_refs, raw_refs)
    if not parse_ok or migration_allowlist == nil then
      snapshot_why = parse_ok and (parse_why or "invalid-migration-source-ref")
        or "invalid-migration-source-ref"
      return nil, snapshot_why
    end
    snapshot = {
      reference_epoch_seconds = reference_epoch_seconds,
      migration_allowlist = migration_allowlist,
    }
    return snapshot, nil
  end

  return {
    check = function(signals)
      local event_options, options_why = load_snapshot()
      if event_options == nil then
        return nil, options_why or "invalid-reference-week"
      end
      local ok, result, why = pcall(evaluate_group, signals, event_options)
      if not ok then
        return nil, "invalid-reference-week"
      end
      if result == nil then
        return nil, why or "invalid-reference-week"
      end
      return result, nil
    end,
  }
end

return M
