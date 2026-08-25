-- contract.time: dependency-free timestamp helpers shared across packages.
local T = {}

local function is_finite_integer(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

local function is_leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function days_in_month(year, month)
  if month == 2 then
    return is_leap_year(year) and 29 or 28
  end
  if month == 4 or month == 6 or month == 9 or month == 11 then
    return 30
  end
  return 31
end

-- Howard Hinnant's civil-calendar transforms keep these helpers independent
-- from the process timezone and from platform-specific os.time behavior.
local function days_from_civil(year, month, day)
  local adjusted_year = month <= 2 and year - 1 or year
  local adjusted_month = month <= 2 and month + 12 or month
  local era = math.floor(adjusted_year / 400)
  local year_of_era = adjusted_year - era * 400
  local day_of_year = math.floor((153 * (adjusted_month - 3) + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365
    + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100)
    + day_of_year
  return era * 146097 + day_of_era - 719468
end

local function civil_from_days(days_since_epoch)
  local shifted = days_since_epoch + 719468
  local era = math.floor(shifted / 146097)
  local day_of_era = shifted - era * 146097
  local year_of_era = math.floor((day_of_era
    - math.floor(day_of_era / 1460)
    + math.floor(day_of_era / 36524)
    - math.floor(day_of_era / 146096)) / 365)
  local year = year_of_era + era * 400
  local day_of_year = day_of_era - (365 * year_of_era
    + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100))
  local month_part = math.floor((5 * day_of_year + 2) / 153)
  local day = day_of_year - math.floor((153 * month_part + 2) / 5) + 1
  local month = month_part + (month_part < 10 and 3 or -9)
  if month <= 2 then
    year = year + 1
  end
  return year, month, day
end

local function weekday(year, month, day)
  -- Monday=1 through Sunday=7; 1970-01-01 was a Thursday.
  return (days_from_civil(year, month, day) + 3) % 7 + 1
end

local function iso_weeks_in_year(year)
  local january_first = weekday(year, 1, 1)
  if january_first == 4 or (january_first == 3 and is_leap_year(year)) then
    return 53
  end
  return 52
end

local function iso_week_for_date(year, month, day)
  local day_of_year = days_from_civil(year, month, day)
    - days_from_civil(year, 1, 1) + 1
  local week = math.floor((day_of_year - weekday(year, month, day) + 10) / 7)
  local week_year = year
  if week < 1 then
    week_year = year - 1
    week = iso_weeks_in_year(week_year)
  elseif week > iso_weeks_in_year(year) then
    week_year = year + 1
    week = 1
  end
  return week_year, week
end

function T.iso_timestamp_epoch_seconds(timestamp)
  local year, month, day, hour, minute, second = tostring(timestamp or ""):match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d)[%-:](%d%d)[%-:](%d%d)Z$"
  )
  if year == nil then
    return nil
  end
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  minute = tonumber(minute)
  second = tonumber(second)
  if year < 1 or year > 9999
    or month < 1 or month > 12
    or day < 1 or day > days_in_month(year, month)
    or hour > 23
    or minute > 59
    or second > 59 then
    return nil
  end
  local days_since_epoch = days_from_civil(year, month, day)
  return days_since_epoch * 86400 + hour * 3600 + minute * 60 + second
end

function T.parse_iso_week(value)
  if type(value) ~= "string" then
    return nil
  end
  local year_text, week_text = value:match("^(%d%d%d%d)%-W(%d%d)$")
  if year_text == nil then
    return nil
  end
  local year = tonumber(year_text)
  local week = tonumber(week_text)
  if year < 1 or year > 9999 or week < 1 or week > iso_weeks_in_year(year) then
    return nil
  end
  return year, week
end

function T.iso_week_from_epoch_seconds(epoch_seconds)
  if not is_finite_integer(epoch_seconds) then
    return nil
  end
  local days_since_epoch = math.floor(epoch_seconds / 86400)
  local year, month, day = civil_from_days(days_since_epoch)
  if year < 1 or year > 9999 then
    return nil
  end
  local week_year, week = iso_week_for_date(year, month, day)
  if week_year < 1 or week_year > 9999 then
    return nil
  end
  return string.format("%04d-W%02d", week_year, week)
end

function T.compare_iso_weeks(left, right)
  local left_year, left_week = T.parse_iso_week(left)
  local right_year, right_week = T.parse_iso_week(right)
  if left_year == nil or right_year == nil then
    return nil
  end
  if left_year ~= right_year then
    return left_year < right_year and -1 or 1
  end
  if left_week == right_week then
    return 0
  end
  return left_week < right_week and -1 or 1
end

return T
