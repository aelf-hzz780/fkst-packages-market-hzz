local contract_time = require("contract.time")
local week_policy = require("week_policy")
local t = fkst.test

local function source_ref(value)
  return { kind = "external", ref = value, reference = value }
end

local function signal(number, week, action)
  return {
    week = week or "2026-W33",
    action = action or "add",
    source_ref = source_ref("owner/repo#issue/" .. tostring(number)),
  }
end

local function allowlist(raw)
  return assert(week_policy.parse_migration_refs(raw))
end

return {
  test_timestamp_parser_rejects_impossible_gregorian_dates = function()
    t.is_nil(contract_time.iso_timestamp_epoch_seconds("2026-02-29T00:00:00Z"))
    t.is_nil(contract_time.iso_timestamp_epoch_seconds("2024-04-31T00:00:00Z"))
    t.is_nil(contract_time.iso_timestamp_epoch_seconds("0000-01-01T00:00:00Z"))
    t.eq(contract_time.iso_timestamp_epoch_seconds("2024-02-29T00:00:00Z"), 1709164800)
  end,

  test_iso_week_parser_rejects_out_of_range_and_nonexistent_weeks = function()
    local year, week = contract_time.parse_iso_week("2020-W53")
    t.eq(year, 2020)
    t.eq(week, 53)

    for _, invalid in ipairs({
      "2026-W00",
      "2026-W54",
      "2021-W53",
      "0000-W01",
      "2026-W5",
      "2026-w35",
      " 2026-W35",
    }) do
      t.is_nil(contract_time.parse_iso_week(invalid))
    end
  end,

  test_utc_epoch_maps_across_iso_week_year_boundaries = function()
    local cases = {
      { 1577664000, "2020-W01" }, -- 2019-12-30T00:00:00Z
      { 1609459200, "2020-W53" }, -- 2021-01-01T00:00:00Z
      { 1609718400, "2021-W01" }, -- 2021-01-04T00:00:00Z
      { -259200, "1970-W01" }, -- 1969-12-29T00:00:00Z
      { 1787616000, "2026-W35" }, -- 2026-08-25T00:00:00Z
    }
    for _, case in ipairs(cases) do
      t.eq(contract_time.iso_week_from_epoch_seconds(case[1]), case[2])
    end
    t.is_nil(contract_time.iso_week_from_epoch_seconds(0 / 0))
    t.is_nil(contract_time.iso_week_from_epoch_seconds(1.5))
  end,

  test_iso_week_comparison_uses_week_year_not_lexical_fallback = function()
    t.eq(contract_time.compare_iso_weeks("2020-W53", "2021-W01"), -1)
    t.eq(contract_time.compare_iso_weeks("2026-W35", "2026-W35"), 0)
    t.eq(contract_time.compare_iso_weeks("2027-W01", "2026-W53"), 1)
    t.is_nil(contract_time.compare_iso_weeks("2021-W53", "2022-W01"))
  end,

  test_current_and_future_signal_groups_are_eligible = function()
    local current = assert(week_policy.evaluate_group({ signal(1, "2026-W35") }, {
      reference_week = "2026-W35",
      migration_allowlist = allowlist(""),
    }))
    t.eq(current.status, "eligible")
    t.is_true(not current.historical)
    t.is_true(not current.migration)

    local future = assert(week_policy.evaluate_group({ signal(2, "2026-W36") }, {
      reference_epoch_seconds = 1787616000,
      migration_allowlist = allowlist(""),
    }))
    t.eq(future.status, "eligible")
    t.eq(future.reference_week, "2026-W35")
    t.is_true(not future.historical)
  end,

  test_invalid_signal_and_reference_weeks_fail_closed = function()
    local _, invalid_week = week_policy.evaluate_group({ signal(1, "2021-W53") }, {
      reference_week = "2026-W35",
      migration_allowlist = allowlist(""),
    })
    t.eq(invalid_week, "invalid-week")

    local _, invalid_reference = week_policy.evaluate_group({ signal(1, "2026-W35") }, {
      reference_week = "2021-W53",
      migration_allowlist = allowlist(""),
    })
    t.eq(invalid_reference, "invalid-reference-week")

    _, invalid_reference = week_policy.evaluate_group({ signal(1, "2026-W35") }, {
      migration_allowlist = allowlist(""),
    })
    t.eq(invalid_reference, "invalid-reference-week")
  end,

  test_migration_allowlist_accepts_only_exact_canonical_issue_refs = function()
    local parsed = allowlist(" owner/repo#issue/116 ,owner/repo#issue/117")
    t.is_true(parsed["owner/repo#issue/116"])
    t.is_true(parsed["owner/repo#issue/117"])
    t.is_nil(parsed["owner/repo#issue/11"])

    for _, invalid in ipairs({
      "owner/repo#issue/*",
      "owner/repo#issue/0116",
      "owner/repo#issue/0",
      "owner/repo/issues/116",
      "owner/repo#issue/116,,owner/repo#issue/117",
      "owner/repo#issue/116,owner/repo#issue/116",
    }) do
      local refs, why = week_policy.parse_migration_refs(invalid)
      t.is_nil(refs)
      t.eq(why, "invalid-migration-source-ref")
    end
  end,

  test_past_group_is_blocked_without_complete_exact_allowlist = function()
    local signals = {
      signal(116, "2026-W33"),
      signal(117, "2026-W33"),
      signal(118, "2026-W33"),
    }
    local decision, why = week_policy.evaluate_group(signals, {
      reference_week = "2026-W35",
      migration_allowlist = allowlist(
        "owner/repo#issue/116,owner/repo#issue/117,owner/repo#issue/1180"
      ),
    })
    t.is_nil(decision)
    t.eq(why, "stale-signal-week")
  end,

  test_past_group_migration_is_all_or_nothing_and_add_only = function()
    local signals = {
      signal(116, "2026-W33"),
      signal(117, "2026-W33"),
      signal(118, "2026-W33"),
    }
    local opts = {
      reference_week = "2026-W35",
      migration_allowlist = allowlist(
        "owner/repo#issue/116,owner/repo#issue/117,owner/repo#issue/118"
      ),
    }
    local decision = assert(week_policy.evaluate_group(signals, opts))
    t.eq(decision.status, "eligible")
    t.is_true(decision.historical)
    t.is_true(decision.migration)
    t.eq(#decision.source_refs, 3)

    signals[2].action = "revise"
    local blocked, why = week_policy.evaluate_group(signals, opts)
    t.is_nil(blocked)
    t.eq(why, "historical-signal-requires-add")
  end,

  test_group_policy_rejects_mixed_weeks_and_noncanonical_signal_refs = function()
    local decision, why = week_policy.evaluate_group({
      signal(116, "2026-W33"),
      signal(124, "2026-W34"),
    }, {
      reference_week = "2026-W35",
      migration_allowlist = allowlist(
        "owner/repo#issue/116,owner/repo#issue/124"
      ),
    })
    t.is_nil(decision)
    t.eq(why, "mixed-signal-weeks")

    local malformed = signal(116, "2026-W33")
    malformed.source_ref = source_ref("owner/repo#issue/0116")
    decision, why = week_policy.evaluate_group({ malformed }, {
      reference_week = "2026-W35",
      migration_allowlist = allowlist("owner/repo#issue/116"),
    })
    t.is_nil(decision)
    t.eq(why, "invalid-migration-source-ref")
  end,
}
