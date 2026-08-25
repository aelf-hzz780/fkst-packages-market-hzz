local contract_time = require("contract.time")
local strings = require("contract.strings")

local M = {}

local MAX_ALLOWLIST_BYTES = 32768
local MAX_ALLOWLIST_REFS = 256
local MAX_SOURCE_REF_BYTES = 240

local function canonical_source_ref(value)
  if type(value) ~= "string" or value == "" or #value > MAX_SOURCE_REF_BYTES then
    return nil
  end
  local owner, repo, issue_number = value:match(
    "^([%w_.-]+)/([%w_.-]+)#issue/([1-9]%d*)$"
  )
  if owner == nil or repo == nil or #issue_number > 20 then
    return nil
  end
  return owner .. "/" .. repo .. "#issue/" .. issue_number
end

local function signal_source_ref(signal)
  local source_ref = type(signal) == "table" and signal.source_ref or nil
  if type(source_ref) ~= "table" or source_ref.kind ~= "external"
      or (source_ref.ref ~= nil and source_ref.reference ~= nil
        and source_ref.ref ~= source_ref.reference) then
    return nil
  end
  return canonical_source_ref(source_ref.ref or source_ref.reference)
end

local function validate_allowlist(allowlist)
  if type(allowlist) ~= "table" then
    return nil, "invalid-migration-source-ref"
  end
  local count = 0
  for ref, enabled in pairs(allowlist) do
    count = count + 1
    if count > MAX_ALLOWLIST_REFS or enabled ~= true
        or canonical_source_ref(ref) ~= ref then
      return nil, "invalid-migration-source-ref"
    end
  end
  return allowlist, nil
end

local function reference_week(options)
  local opts = type(options) == "table" and options or {}
  if opts.reference_week ~= nil then
    if contract_time.parse_iso_week(opts.reference_week) == nil then
      return nil, "invalid-reference-week"
    end
    return opts.reference_week, nil
  end
  local derived = contract_time.iso_week_from_epoch_seconds(opts.reference_epoch_seconds)
  if derived == nil then
    return nil, "invalid-reference-week"
  end
  return derived, nil
end

function M.parse_migration_refs(raw)
  if raw == nil then
    return {}, nil
  end
  if type(raw) ~= "string" or #raw > MAX_ALLOWLIST_BYTES then
    return nil, "invalid-migration-source-ref"
  end
  local text = strings.trim(raw)
  if text == "" then
    return {}, nil
  end

  local refs = {}
  local count = 0
  for entry in (text .. ","):gmatch("(.-),") do
    local ref = strings.trim(entry)
    local canonical = canonical_source_ref(ref)
    count = count + 1
    if count > MAX_ALLOWLIST_REFS or canonical == nil or canonical ~= ref
        or refs[canonical] ~= nil then
      return nil, "invalid-migration-source-ref"
    end
    refs[canonical] = true
  end
  return refs, nil
end

function M.evaluate_group(signals, options)
  if type(signals) ~= "table" or #signals == 0 then
    return nil, "invalid-signal-group"
  end
  local current_week, clock_why = reference_week(options)
  if current_week == nil then
    return nil, clock_why
  end
  local allowlist, allowlist_why = validate_allowlist(
    type(options) == "table" and options.migration_allowlist or nil
  )
  if allowlist == nil then
    return nil, allowlist_why
  end

  local group_week = nil
  local refs = {}
  for _, signal in ipairs(signals) do
    if type(signal) ~= "table" or contract_time.parse_iso_week(signal.week) == nil then
      return nil, "invalid-week"
    end
    if group_week ~= nil and signal.week ~= group_week then
      return nil, "mixed-signal-weeks"
    end
    group_week = signal.week
    local ref = signal_source_ref(signal)
    if ref == nil then
      return nil, "invalid-migration-source-ref"
    end
    refs[#refs + 1] = ref
  end
  table.sort(refs)

  local relative = contract_time.compare_iso_weeks(group_week, current_week)
  local historical = relative < 0
  if historical then
    for _, ref in ipairs(refs) do
      if allowlist[ref] ~= true then
        return nil, "stale-signal-week"
      end
    end
    for _, signal in ipairs(signals) do
      if signal.action ~= "add" then
        return nil, "historical-signal-requires-add"
      end
    end
  end

  return {
    status = "eligible",
    signal_week = group_week,
    reference_week = current_week,
    historical = historical,
    migration = historical,
    source_refs = refs,
  }, nil
end

function M.evaluate_signal(signal, options)
  return M.evaluate_group({ signal }, options)
end

return M
