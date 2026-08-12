-- x-publisher/publish_x - the X release seam. Shadow mode emits a preview receipt. Live mode
-- fails closed unless host env explicitly enables writes and supplies a NyxID X service slug.
local publish_caps = require("publish_x_caps")
local ports_lib = require("forge.ports")
local content_filter = require("forge.github.content_filter")
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

local function live_options()
  local write_gate = first_non_empty_env({ "X_PUBLISH_WRITE", "FKST_X_PUBLISH_WRITE" })
  return {
    live_write_enabled = write_gate == "1",
    nyxid_x_service = first_non_empty_env({ "NYXID_X_SERVICE_SLUG", "FKST_NYXID_X_SERVICE_SLUG" }),
    expected_username = first_non_empty_env({ "X_PUBLISH_EXPECTED_USERNAME", "FKST_X_PUBLISH_EXPECTED_USERNAME" }),
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

local function block(payload, reason, intent)
  log.warn("x-publisher dept=publish_x tag=BLOCKED reason=" .. tostring(reason)
    .. " artifact_id=" .. tostring(payload.artifact_id))
  raise("x_published", publish_caps.blocked_receipt(payload, reason, intent))
end

local function skip_duplicate(payload)
  local receipt = publish_caps.preview_receipt(payload, "skipped")
  receipt.skipped_reason = "duplicate publish dedup_key"
  log.info("x-publisher dept=publish_x tag=SKIP_DUPLICATE artifact_id=" .. tostring(payload.artifact_id))
  raise("x_published", receipt)
end

local function preflight_username(payload, options)
  if options.expected_username == "" then
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
  local username = publish_caps.parse_nyxid_username(result.stdout)
  if username == nil or username == "" then
    return nil, "nyxid account preflight failed"
  end
  if username ~= options.expected_username then
    return nil, "unexpected account"
  end
  log.info("x-publisher dept=publish_x tag=ACCOUNT_OK artifact_id=" .. tostring(payload.artifact_id)
    .. " username=" .. tostring(username))
  return username, nil
end

local function resolve_publish_intent(github, payload)
  local content_ref, ref_why = publish_caps.content_source_ref(payload)
  if content_ref == nil then
    return nil, ref_why
  end
  if github == nil or type(github.read_issue) ~= "function" then
    return nil, "github content resolver unavailable"
  end
  local ok, issue = pcall(function()
    return github.read_issue(content_ref, {
      consumer = "x-publisher",
      force_fresh = true,
    })
  end)
  if not ok or type(issue) ~= "table" then
    return nil, "github content read failed"
  end
  return publish_caps.extract_publish_intent(issue.body, payload)
end

local function resolve_prior_publish(github, payload)
  if github == nil or type(github.read_issue) ~= "function"
      or type(github.is_authorized_author) ~= "function" then
    return nil, "github publish receipt resolver unavailable"
  end
  local ok, issue = pcall(function()
    return github.read_issue(payload.source_ref, {
      consumer = "x-publisher-publish-guard",
      force_fresh = true,
    })
  end)
  if not ok or type(issue) ~= "table" or type(issue.comments) ~= "table" then
    return nil, "github publish receipt read failed"
  end
  return publish_caps.trusted_published_receipt(
    issue.comments,
    payload.dedup_key,
    function(login)
      if github.is_authorized_author(login) ~= true then
        return false
      end
      local receipt_whitelist = content_filter.policy_whitelist(
        receipt_author_options.trusted_author_policy
      )
      return content_filter.is_authorized(login, receipt_whitelist)
    end
  )
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

    local options = live_options()
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

    local prior_publish, prior_why = resolve_prior_publish(github, payload)
    if prior_why ~= nil then
      block(payload, prior_why)
      return
    end
    if prior_publish ~= nil then
      local receipt = publish_caps.live_receipt(payload, { id = prior_publish.post_id })
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

    local intent, intent_why = resolve_publish_intent(github, payload)
    if intent == nil then
      block(payload, intent_why)
      return
    end

    local username, username_why = preflight_username(payload, options)
    if username_why ~= nil then
      block(payload, username_why, intent)
      return
    end
    if intent.operation == "quote" and intent.quote_post.mode == "native"
        and not native_quote_enabled() then
      block(payload, "native quote capability disabled", intent)
      return
    end

    local ran = once(publish_once_key, function()
      local receipt, publish_why = publish_tweet(payload, options, username, intent)
      if receipt == nil then
        block(payload, publish_why, intent)
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
