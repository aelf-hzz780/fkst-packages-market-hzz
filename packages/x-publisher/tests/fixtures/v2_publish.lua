local marketing_content = require("contract.marketing_content")
local marketing_schedule = require("contract.marketing_schedule")

local M = {
  ACCOUNT = "test_primary",
  SECONDARY_ACCOUNT = "test_secondary",
  BOT_LOGIN = "fkst-test-bot",
  CREATOR = "test-maintainer",
  EFFECTIVE_LABEL = "auto-x-test-primary-ci",
  LOGICAL_LABEL = "auto-x-test-primary",
  PROJECT = "test-project",
  SERVICE_SLUG = "test-x-service",
  WEEK = "2026-W33",
}

M.WORK_LABEL_MAP_JSON = '{"' .. M.LOGICAL_LABEL .. '":"' .. M.EFFECTIVE_LABEL .. '"}'

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  return text
end

local function string_array_json(values, field)
  local rows = {}
  for _, value in ipairs(values or {}) do
    rows[#rows + 1] = '{"' .. field .. '":"' .. json_escape(value) .. '"}'
  end
  return "[" .. table.concat(rows, ",") .. "]"
end

function M.issue_rest_json(repo, issue_number, body, options)
  local opts = options or {}
  return string.format(
    '{"number":%d,"title":"Auto Twitter marketing content %d","body":"%s","html_url":"https://github.example/%s/issues/%d","updated_at":"2026-07-24T09:00:00Z","state":"%s","labels":%s,"assignees":%s,"user":{"login":"%s"}}\n',
    issue_number,
    issue_number,
    json_escape(body),
    repo,
    issue_number,
    json_escape(opts.state or "open"),
    string_array_json(opts.labels or { M.EFFECTIVE_LABEL }, "name"),
    string_array_json(opts.assignees or { M.CREATOR }, "login"),
    json_escape(opts.author_login or M.BOT_LOGIN)
  )
end

function M.comments_rest_json(comments)
  local rows = {}
  for index, comment in ipairs(comments or {}) do
    rows[#rows + 1] = string.format(
      '{"id":%d,"body":"%s","created_at":"2026-07-24T09:%02d:00Z","user":{"login":"%s"}}',
      index,
      json_escape(comment.body),
      index,
      json_escape(comment.author_login or M.BOT_LOGIN)
    )
  end
  return "[" .. table.concat(rows, ",") .. "]\n"
end

function M.mock_author_env(t, options)
  local opts = options or {}
  for name, value in pairs({
    FKST_GITHUB_BOT_LOGIN = opts.bot_login or M.BOT_LOGIN,
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = opts.managed_bot_logins or M.BOT_LOGIN,
    FKST_GITHUB_AUTHORIZED_LOGINS = opts.authorized_logins or M.BOT_LOGIN,
  }) do
    t.mock_command('printf %s "$' .. name .. '"', {
      stdout = value,
      stderr = "",
      exit_code = 0,
    })
  end
end

local function merge(base, overrides)
  local result = {}
  for key, value in pairs(base or {}) do
    result[key] = value
  end
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

function M.content(overrides)
  local record = merge({
    project = M.PROJECT,
    account = M.ACCOUNT,
    work_label = M.LOGICAL_LABEL,
    week = M.WEEK,
    content_id = "test-primary-w33-content-1",
    content_revision = 1,
    proposal_id = "test-primary-w33-proposal",
    proposal_revision = 2,
    approval_id = "test-primary-w33-proposal@2",
    content_status = "approved",
    operation = "post",
    tweet_text = "A reviewed test post.",
  }, overrides)
  local body, digest = assert(marketing_content.render(record))
  return {
    body = body,
    digest = digest,
    record = record,
  }
end

function M.payload(suffix, content, overrides)
  local approved = content or M.content()
  local payload = merge({
    schema = "x-publisher.publish-request.v2",
    account = approved.record.account,
    work_label = approved.record.work_label,
    artifact_id = "auto-twitter/test-project/test-primary/" .. tostring(suffix),
    source_ref = {
      kind = "external",
      ref = "owner/repo#issue/43",
      reference = "owner/repo#issue/43",
    },
    content_ref = "#42",
    content_digest = approved.digest,
    platform = "x",
    channel = "live",
    dedup_key = "auto-twitter/test-project/test-primary/" .. tostring(suffix) .. "/x-publish",
    trace_id = "trace-test-primary-" .. tostring(suffix),
    approval_id = approved.record.approval_id,
  }, overrides)
  if payload.schedule_digest == nil then
    local ok, digest = pcall(function()
      return assert(marketing_schedule.digest(M.schedule_body(payload)))
    end)
    payload.schedule_digest = ok and digest or ("sha256:" .. string.rep("0", 64))
  end
  return payload
end

function M.schedule_body(payload, overrides)
  local fields = merge({
    contract = "auto-twitter-marketing.schedule-publish.v2",
    type = payload.scheduled_at and "schedule-publish" or "recurring-schedule-publish",
    project = M.PROJECT,
    account = payload.account,
    work_label = payload.work_label,
    week = M.WEEK,
    content_ref = payload.content_ref,
    content_digest = payload.content_digest,
    approval_id = payload.approval_id,
    mode = payload.channel,
  }, overrides)
  local lines = {
    "contract: " .. fields.contract,
    "type: " .. fields.type,
    "project: " .. fields.project,
    "account: " .. fields.account,
    "work-label: " .. fields.work_label,
    "week: " .. fields.week,
    "content-ref: " .. fields.content_ref,
    "content-digest: " .. fields.content_digest,
    "approval-id: " .. fields.approval_id,
    "mode: " .. fields.mode,
  }
  if fields.type == "schedule-publish" then
    lines[#lines + 1] = "scheduled-at: " .. tostring(fields.scheduled_at or payload.scheduled_at)
  elseif fields.recurrence == "every-minutes" then
    lines[#lines + 1] = "recurrence: every-minutes"
    lines[#lines + 1] = "interval-minutes: " .. tostring(fields.interval_minutes or 10)
    lines[#lines + 1] = "scheduled-at: " .. tostring(fields.scheduled_at or payload.scheduled_at)
  else
    lines[#lines + 1] = "recurrence: daily"
    lines[#lines + 1] = "time: " .. tostring(fields.time or "09:00")
    lines[#lines + 1] = "timezone: " .. tostring(fields.timezone or "UTC")
  end
  return table.concat(lines, "\n")
end

function M.receipt_comment(payload, post_id, author_login, overrides)
  local fields = merge({
    account = payload.account,
    approval_id = payload.approval_id,
    authenticated_account = payload.account,
    content_digest = payload.content_digest,
    dedup_key = payload.dedup_key,
    post_uri = "https://x.com/i/web/status/" .. tostring(post_id),
    status = "published",
  }, overrides)
  return {
    author_login = author_login or M.BOT_LOGIN,
    body = "Auto Twitter marketing: X published\n\n"
      .. "schema: x-publisher.publish-receipt.v2\n"
      .. "status: " .. fields.status .. "\n"
      .. "account: " .. fields.account .. "\n"
      .. "authenticated_account: " .. fields.authenticated_account .. "\n"
      .. "content_digest: " .. fields.content_digest .. "\n"
      .. "approval_id: " .. fields.approval_id .. "\n"
      .. "post_uri: " .. fields.post_uri .. "\n"
      .. "dedup_key: " .. fields.dedup_key .. "\n\n"
      .. "<!-- fkst:github-proxy:comment:" .. fields.dedup_key
      .. "/status/x-publish-published -->",
  }
end

return M
