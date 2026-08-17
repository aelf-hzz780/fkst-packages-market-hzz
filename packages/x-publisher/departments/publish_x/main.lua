-- x-publisher/publish_x - the X release seam. Shadow mode emits a preview receipt. Live mode
-- fails closed unless host env explicitly enables writes and supplies a NyxID X service slug.
local publish_caps = require("publish_x_caps")
local marketing_content = require("contract.marketing_content")
local marketing_schedule = require("contract.marketing_schedule")
local ports_lib = require("forge.ports")
local content_filter = require("forge.github.content_filter")
local session_route = require("contract.session_route")
local saga = require("workflow.saga")
local env = require("workflow.env")
local strings = require("contract.strings")
local package_env = require("x_publisher_package_env")

local spec = {
  consumes = { "x_publish_request" },
  -- x_publish_request is the package's public entry point: a host composer produces it.
  published_seam = { "x_publish_request" },
  produces = { "x_published" },
  stall_window = "10m",
  retry = false,
}

local VALUE_ENV = {
  FKST_DEVLOOP_MANAGED_BOT_LOGINS = true,
  FKST_GITHUB_AUTHORIZED_LOGINS = true,
  FKST_GITHUB_BOT_LOGIN = true,
  FKST_SESSION_CREATOR = true,
  FKST_SESSION_WORK_LABEL = true,
  FKST_SESSION_WORK_LABEL_MAP_JSON = true,
  FKST_NYXID_X_SERVICE_SLUG = true,
  FKST_X_PUBLISH_NATIVE_QUOTE = true,
  FKST_X_PUBLISH_EXPECTED_USERNAME = true,
  FKST_X_PUBLISH_WRITE = true,
  NYXID_X_SERVICE_SLUG = true,
  X_PUBLISH_NATIVE_QUOTE = true,
  X_PUBLISH_EXPECTED_USERNAME = true,
  X_PUBLISH_WRITE = true,
}

local PRESENCE_ENV = {
  ["NYXID_ACCESS_TOKEN"] = true,
}

local function done(_event)
  return false
end

local function read_env_command(name)
  if not VALUE_ENV[name] then
    error("x-publisher: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

local author_env_cache = {}
local function read_author_env(name)
  if author_env_cache[name] == nil then
    author_env_cache[name] = { value = read_env(name) }
  end
  return author_env_cache[name].value
end

local receipt_author_options = ports_lib.github_author_options(read_author_env, "x-publisher receipt", {
  bot_login_env = "FKST_GITHUB_BOT_LOGIN",
  extra_login_envs = {
    "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
  },
})

local function read_env_presence_command(name)
  if not PRESENCE_ENV[name] then
    error("x-publisher: invalid-env-name: " .. tostring(name), 0)
  end
  return 'if [ -n "$' .. name .. '" ]; then printf 1; else printf 0; fi'
end

local read_env_presence = env.read_env(read_env_presence_command, { propagate_exec_errors = true })

local function first_non_empty_env(names)
  for _, name in ipairs(names) do
    local value = strings.trim(read_env(name) or "")
    if value ~= "" then
      return value
    end
  end
  return ""
end

local function native_quote_enabled()
  local process_value = first_non_empty_env({
    "X_PUBLISH_NATIVE_QUOTE",
    "FKST_X_PUBLISH_NATIVE_QUOTE",
  })
  if process_value == "1" then
    return true
  end
  return strings.trim(package_env.get("FKST_X_PUBLISH_NATIVE_QUOTE") or "") == "1"
end

local function expected_account_config()
  local primary_raw = strings.trim(read_env("X_PUBLISH_EXPECTED_USERNAME") or "")
  local fallback_raw = strings.trim(read_env("FKST_X_PUBLISH_EXPECTED_USERNAME") or "")
  local primary = primary_raw ~= "" and session_route.normalize_account(primary_raw) or nil
  local fallback = fallback_raw ~= "" and session_route.normalize_account(fallback_raw) or nil
  if (primary_raw ~= "" and primary == nil)
      or (fallback_raw ~= "" and fallback == nil) then
    return nil, "missing or invalid expected account"
  end
  if primary ~= nil and fallback ~= nil and primary ~= fallback then
    return nil, "conflicting expected account"
  end
  local expected = primary or fallback
  if expected == nil then
    return nil, "missing or invalid expected account"
  end
  return expected, nil
end

local function session_context()
  local expected_account, expected_why = expected_account_config()
  if expected_account == nil then
    return nil, expected_why
  end
  local effective_label = first_non_empty_env({ "FKST_SESSION_WORK_LABEL" })
  local route, route_why = session_route.resolve(
    effective_label,
    first_non_empty_env({ "FKST_SESSION_WORK_LABEL_MAP_JSON" })
  )
  if route == nil then
    return nil, route_why
  end
  local creator = session_route.single_assignee({
    first_non_empty_env({ "FKST_SESSION_CREATOR" }),
  })
  if creator == nil then
    return nil, "missing or invalid session creator"
  end
  route.account = expected_account
  route.creator = creator
  return route, nil
end

local function request_matches_session(payload, context)
  if payload.account ~= context.account then
    return false, "request account mismatch"
  end
  if payload.work_label ~= context.logical_label then
    return false, "request work label mismatch"
  end
  return true, nil
end

local function live_options(expected_account)
  local write_gate = first_non_empty_env({ "X_PUBLISH_WRITE", "FKST_X_PUBLISH_WRITE" })
  return {
    live_write_enabled = write_gate == "1",
    nyxid_x_service = first_non_empty_env({ "NYXID_X_SERVICE_SLUG", "FKST_NYXID_X_SERVICE_SLUG" }),
    expected_username = expected_account,
    nyxid_access_token_present = strings.trim(read_env_presence("NYXID_ACCESS_TOKEN") or "") == "1",
  }
end

local function nyxid_request(argv, timeout)
  if type(exec_argv) ~= "function" then
    return { exit_code = 127, stdout = "", stderr = "exec_argv unavailable" }
  end
  return exec_argv({ argv = argv, timeout = timeout or 60 })
end

local function live_environment_ready(options)
  if options.nyxid_access_token_present ~= true then
    return false, "nyxid access token missing"
  end
  local result = nyxid_request({ "nyxid", "--version" }, 10)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    return false, "nyxid cli unavailable"
  end
  return true, nil
end

local function block(payload, reason, intent, authenticated_account, publish_attempted)
  log.warn("x-publisher dept=publish_x tag=BLOCKED reason=" .. tostring(reason)
    .. " artifact_id=" .. tostring(payload.artifact_id))
  raise("x_published", publish_caps.blocked_receipt(payload, reason, intent, {
    authenticated_account = authenticated_account,
    publish_attempted = publish_attempted,
  }))
end

local function skip_duplicate(payload)
  local receipt = publish_caps.preview_receipt(payload, "skipped")
  receipt.skipped_reason = "duplicate publish dedup_key"
  log.info("x-publisher dept=publish_x tag=SKIP_DUPLICATE artifact_id=" .. tostring(payload.artifact_id))
  raise("x_published", receipt)
end

local function preflight_account(payload, options, required)
  if not required and options.expected_username == "" then
    return nil, nil
  end
  local result = nyxid_request({
    "nyxid",
    "proxy",
    "request",
    options.nyxid_x_service,
    "/users/me?user.fields=id,name,username",
    "-m",
    "GET",
  }, 30)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    return nil, "nyxid account preflight failed"
  end
  local account = publish_caps.parse_nyxid_account(result.stdout)
  if account == nil then
    return nil, "nyxid account preflight failed"
  end
  local authenticated_account = session_route.normalize_account(account.username)
  if authenticated_account == nil then
    return nil, "nyxid account preflight failed"
  end
  account.username = authenticated_account
  if options.expected_username ~= "" and authenticated_account ~= options.expected_username then
    return account, "unexpected account"
  end
  log.info("x-publisher dept=publish_x tag=ACCOUNT_OK artifact_id=" .. tostring(payload.artifact_id)
    .. " username=" .. tostring(account.username))
  return account, nil
end

local function issue_is_routed(issue, context)
  return session_route.has_label(issue and issue.labels, context.effective_label)
    and session_route.single_assignee(issue and issue.assignees) == context.creator
end

local function read_fresh_issue(github, source_ref, consumer)
  if github == nil or type(github.read_issue) ~= "function" then
    return nil, "github resolver unavailable"
  end
  local ok, issue = pcall(function()
    return github.read_issue(source_ref, {
      consumer = consumer,
      force_fresh = true,
    })
  end)
  if not ok or type(issue) ~= "table" then
    return nil, "github issue read failed"
  end
  return issue, nil
end

local function resolve_schedule(github, payload, context)
  local issue, read_why = read_fresh_issue(github, payload.source_ref, "x-publisher-schedule-guard")
  if issue == nil then
    return nil, nil, read_why
  end
  if tostring(issue.state or ""):upper() ~= "OPEN" then
    return nil, nil, "schedule issue is not open"
  end
  if not issue_is_routed(issue, context) then
    return nil, nil, "schedule route mismatch"
  end
  local schedule, schedule_why = marketing_schedule.parse(issue.body)
  if schedule == nil then
    return nil, nil, schedule_why
  end
  if schedule.account ~= payload.account or schedule.work_label ~= payload.work_label
      or schedule.content_ref ~= payload.content_ref
      or schedule.content_digest ~= payload.content_digest
      or schedule.approval_id ~= payload.approval_id
      or schedule.mode ~= payload.channel then
    return nil, nil, "schedule request correlation mismatch"
  end
  if schedule.schedule_digest ~= payload.schedule_digest then
    return nil, nil, "schedule digest mismatch"
  end
  if schedule.type == "schedule-publish" and schedule.scheduled_at ~= payload.scheduled_at then
    return nil, nil, "schedule occurrence mismatch"
  end
  return issue, schedule, nil
end

local function bot_comment_authorized(github, login)
  if github.is_authorized_author(login) ~= true then
    return false
  end
  local receipt_whitelist = content_filter.policy_whitelist(
    receipt_author_options.trusted_author_policy
  )
  return content_filter.is_authorized(login, receipt_whitelist)
end

local function content_is_superseded(github, issue, digest)
  local marker = '<!-- fkst:auto-twitter:content-superseded:v2 content_digest="'
    .. tostring(digest) .. '" -->'
  for _, comment in ipairs(issue.comments or {}) do
    if type(comment) == "table"
        and bot_comment_authorized(github, comment.author_login)
        and tostring(comment.body or ""):find(marker, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function resolve_publish_intent(github, payload, context)
  local content_ref, ref_why = publish_caps.content_source_ref(payload)
  if content_ref == nil then
    return nil, nil, ref_why
  end
  local issue, read_why = read_fresh_issue(github, content_ref, "x-publisher-content-guard")
  if issue == nil then
    return nil, nil, read_why
  end
  if tostring(issue.state or ""):upper() ~= "CLOSED" then
    return nil, nil, "content issue is not immutable"
  end
  if not issue_is_routed(issue, context) then
    return nil, nil, "content route mismatch"
  end
  local trusted_authors = content_filter.policy_whitelist(
    receipt_author_options.trusted_author_policy
  )
  if not content_filter.is_authorized(issue.author_login, trusted_authors) then
    return nil, nil, "content author mismatch"
  end
  local content, content_why = marketing_content.parse(issue.body)
  if content == nil then
    return nil, nil, content_why
  end
  if content.account ~= payload.account or content.work_label ~= payload.work_label
      or content.content_digest ~= payload.content_digest
      or content.approval_id ~= payload.approval_id then
    return nil, nil, "content request correlation mismatch"
  end
  if content_is_superseded(github, issue, content.content_digest) then
    return nil, nil, "content revision superseded"
  end
  local intent, intent_why = publish_caps.extract_publish_intent(issue.body, payload)
  if intent == nil then
    return nil, nil, intent_why
  end
  return intent, content, nil, issue
end

local function resolve_prior_publish(github, payload, schedule_issue, content_issue)
  if github == nil or type(github.is_authorized_author) ~= "function" then
    return nil, "github publish receipt resolver unavailable"
  end
  if type(schedule_issue) ~= "table" or type(schedule_issue.comments) ~= "table"
      or type(content_issue) ~= "table" or type(content_issue.comments) ~= "table" then
    return nil, "github publish receipt read failed"
  end
  local authorized = function(login)
    return bot_comment_authorized(github, login)
  end
  for _, comments in ipairs({ schedule_issue.comments, content_issue.comments }) do
    local prior, why = publish_caps.trusted_published_receipt(comments, payload, authorized)
    if why ~= nil or prior ~= nil then
      return prior, why
    end
  end
  return nil, nil
end

local function publish_tweet(payload, options, username, intent)
  local result = nyxid_request({
    "nyxid",
    "proxy",
    "request",
    options.nyxid_x_service,
    "/tweets",
    "-m",
    "POST",
    "-d",
    publish_caps.publish_body_json(intent),
  }, 60)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    local operation = type(intent) == "table" and intent.operation or "post"
    return nil, operation == "quote" and "nyxid quote publish failed" or "nyxid tweet publish failed"
  end
  local tweet_id = publish_caps.parse_nyxid_tweet_id(result.stdout)
  if tweet_id == nil then
    return nil, "invalid nyxid tweet response"
  end
  return publish_caps.live_receipt(payload, {
    id = tweet_id,
    username = username,
    nyxid_x_service = options.nyxid_x_service,
    intent = intent,
  }), nil
end

local function reconcile_timeline_publish(payload, options, account, intent, window)
  if window == nil then
    return nil, nil
  end
  if type(account) ~= "table" or type(account.id) ~= "string" then
    return nil, "nyxid account preflight failed"
  end

  local matched_ids = {}
  local matched_by_id = {}
  local pagination_token = nil
  for _ = 1, publish_caps.max_timeline_pages() do
    local path = publish_caps.timeline_path(account.id, window.start_time, pagination_token)
    if path == nil then
      return nil, "invalid X timeline reconciliation request"
    end
    local result = nyxid_request({
      "nyxid",
      "proxy",
      "request",
      options.nyxid_x_service,
      path,
      "-m",
      "GET",
    }, 30)
    if type(result) ~= "table" or result.exit_code ~= 0 then
      return nil, "nyxid timeline reconciliation failed"
    end
    local page = publish_caps.parse_timeline_page(result.stdout)
    if page == nil then
      return nil, "invalid X timeline reconciliation response"
    end
    local page_matches, match_why = publish_caps.matching_timeline_post_ids(
      page.posts,
      intent,
      window
    )
    if page_matches == nil then
      return nil, match_why or "invalid X timeline reconciliation response"
    end
    for _, post_id in ipairs(page_matches) do
      if not matched_by_id[post_id] then
        matched_by_id[post_id] = true
        matched_ids[#matched_ids + 1] = post_id
      end
    end
    if #matched_ids > 1 then
      return nil, "ambiguous X timeline publish match"
    end
    pagination_token = page.next_token
    if pagination_token == nil then
      return matched_ids[1], nil
    end
  end
  return nil, "incomplete X timeline reconciliation"
end

local function make_department(ports)
  local handles = ports or {}
  local github = handles.github

  local function act(event)
    local payload = event.payload or {}
    local ok, why = publish_caps.validate_publish_request(payload)
    if not ok then
      log.warn("x-publisher dept=publish_x tag=SKIP why=" .. tostring(why))
      return
    end

    local context, context_why = session_context()
    if context == nil then
      block(payload, context_why)
      return
    end
    local session_ok, session_why = request_matches_session(payload, context)
    if not session_ok then
      block(payload, session_why)
      return
    end
    local schedule_issue, _schedule, schedule_why = resolve_schedule(github, payload, context)
    if schedule_issue == nil then
      block(payload, schedule_why)
      return
    end
    local intent, _content, intent_why, content_issue = resolve_publish_intent(github, payload, context)
    if intent == nil then
      block(payload, intent_why)
      return
    end

    local options = live_options(context.account)
    local live_ok, live_why = publish_caps.live_gate(payload, options)
    if not live_ok then
      if tostring(payload.channel or ""):lower() == "live" then
        block(payload, live_why)
        return
      end
      local receipt = publish_caps.preview_receipt(payload, "preview")
      log.info("x-publisher dept=publish_x tag=PREVIEW artifact_id=" .. tostring(payload.artifact_id)
        .. " source_ref=" .. tostring((payload.source_ref or {}).ref))
      raise("x_published", receipt)
      return
    end

    local publish_once_key = publish_caps.publish_once_key(payload)
    if publish_once_key == nil then
      block(payload, "missing dedup_key")
      return
    end

    local prior_publish, prior_why = resolve_prior_publish(
      github, payload, schedule_issue, content_issue)
    if prior_why ~= nil then
      block(payload, prior_why)
      return
    end
    if prior_publish ~= nil then
      local receipt = publish_caps.live_receipt(payload, {
        id = prior_publish.post_id,
        username = prior_publish.authenticated_account,
        intent = intent,
      })
      log.info("x-publisher dept=publish_x tag=REPLAY_PUBLISHED artifact_id="
        .. tostring(payload.artifact_id) .. " post_uri=" .. tostring(receipt.post_uri))
      raise("x_published", receipt)
      return
    end

    local environment_ok, environment_why = live_environment_ready(options)
    if not environment_ok then
      block(payload, environment_why)
      return
    end

    local window, window_why = publish_caps.reconciliation_window(payload, now())
    if window_why ~= nil then
      block(payload, window_why, intent)
      return
    end
    local account, account_why = preflight_account(payload, options, true)
    if account_why ~= nil then
      block(payload, account_why, intent, account and account.username or nil)
      return
    end
    local reconciled_post_id, reconcile_why = reconcile_timeline_publish(
      payload,
      options,
      account,
      intent,
      window
    )
    if reconcile_why ~= nil then
      block(payload, reconcile_why, intent)
      return
    end
    if reconciled_post_id ~= nil then
      local receipt = publish_caps.live_receipt(payload, {
        id = reconciled_post_id,
        username = account.username,
        nyxid_x_service = options.nyxid_x_service,
        intent = intent,
      })
      log.info("x-publisher dept=publish_x tag=RECONCILED_PUBLISHED artifact_id="
        .. tostring(payload.artifact_id) .. " post_uri=" .. tostring(receipt.post_uri))
      raise("x_published", receipt)
      return
    end
    if intent.operation == "quote" and intent.quote_post.mode == "native"
        and not native_quote_enabled() then
      block(payload, "native quote capability disabled", intent)
      return
    end

    local ran = once(publish_once_key, function()
      local receipt, publish_why = publish_tweet(
        payload,
        options,
        account and account.username or nil,
        intent
      )
      if receipt == nil then
        block(payload, publish_why, intent, account and account.username or nil, true)
        return
      end
      log.info("x-publisher dept=publish_x tag=PUBLISHED artifact_id=" .. tostring(payload.artifact_id)
        .. " post_uri=" .. tostring(receipt.post_uri))
      raise("x_published", receipt)
    end)
    if not ran then
      skip_duplicate(payload)
    end
  end

  return saga.department(spec, { done = done, act = act, name = "publish_x" })
end

return ports_lib.install(
  make_department,
  ports_lib.github_author_options(read_author_env, "x-publisher", {
    bot_login_env = "FKST_GITHUB_BOT_LOGIN",
    extra_login_envs = {
      "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
      "FKST_GITHUB_AUTHORIZED_LOGINS",
    },
  })
)
