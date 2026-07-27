-- x-publisher/publish_x - the X release seam. Shadow mode emits a preview receipt. Live mode
-- fails closed unless host env explicitly enables writes and supplies a NyxID X service slug.
local publish_caps = require("publish_x_caps")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")
local env = require("workflow_internal.env")
local strings = require("contract.strings")

local spec = {
  consumes = { "x_publish_request" },
  -- x_publish_request is the package's public entry point: a host composer produces it.
  published_seam = { "x_publish_request" },
  produces = { "x_published" },
  stall_window = "10m",
  retry = false,
}

local ALLOWED_ENV = {
  FKST_DEVLOOP_MANAGED_BOT_LOGINS = true,
  FKST_GITHUB_AUTHORIZED_LOGINS = true,
  FKST_GITHUB_BOT_LOGIN = true,
  FKST_NYXID_X_SERVICE_SLUG = true,
  FKST_X_PUBLISH_EXPECTED_USERNAME = true,
  FKST_X_PUBLISH_WRITE = true,
}

local function done(_event)
  return false
end

local function read_env_command(name)
  if not ALLOWED_ENV[name] then
    error("x-publisher: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

local function live_options()
  return {
    live_write_enabled = strings.trim(read_env("FKST_X_PUBLISH_WRITE") or "") == "1",
    nyxid_x_service = strings.trim(read_env("FKST_NYXID_X_SERVICE_SLUG") or ""),
    expected_username = strings.trim(read_env("FKST_X_PUBLISH_EXPECTED_USERNAME") or ""),
  }
end

local function nyxid_request(argv, timeout)
  if type(exec_argv) ~= "function" then
    return { exit_code = 127, stdout = "", stderr = "exec_argv unavailable" }
  end
  return exec_argv({ argv = argv, timeout = timeout or 60 })
end

local function block(payload, reason)
  log.warn("x-publisher dept=publish_x tag=BLOCKED reason=" .. tostring(reason)
    .. " artifact_id=" .. tostring(payload.artifact_id))
  raise("x_published", publish_caps.blocked_receipt(payload, reason))
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
  if username ~= options.expected_username then
    return nil, "unexpected account"
  end
  log.info("x-publisher dept=publish_x tag=ACCOUNT_OK artifact_id=" .. tostring(payload.artifact_id)
    .. " username=" .. tostring(username))
  return username, nil
end

local function resolve_tweet_text(github, payload)
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
  return publish_caps.extract_tweet_text(issue.body)
end

local function publish_tweet(payload, options, username, tweet_text)
  local result = nyxid_request({
    "nyxid",
    "proxy",
    "request",
    options.nyxid_x_service,
    "/tweets",
    "-m",
    "POST",
    "-d",
    publish_caps.tweet_body_json(tweet_text),
  }, 60)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    return nil, "nyxid tweet publish failed"
  end
  local tweet_id = publish_caps.parse_nyxid_tweet_id(result.stdout)
  if tweet_id == nil then
    return nil, "invalid nyxid tweet response"
  end
  return publish_caps.live_receipt(payload, {
    id = tweet_id,
    username = username,
    nyxid_x_service = options.nyxid_x_service,
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

    local username, username_why = preflight_username(payload, options)
    if username_why ~= nil then
      block(payload, username_why)
      return
    end

    local tweet_text, text_why = resolve_tweet_text(github, payload)
    if tweet_text == nil then
      block(payload, text_why)
      return
    end

    local receipt, publish_why = publish_tweet(payload, options, username, tweet_text)
    if receipt == nil then
      block(payload, publish_why)
      return
    end
    log.info("x-publisher dept=publish_x tag=PUBLISHED artifact_id=" .. tostring(payload.artifact_id)
      .. " post_uri=" .. tostring(receipt.post_uri))
    raise("x_published", receipt)
  end

  return saga.department(spec, { done = done, act = act, name = "publish_x" })
end

return ports_lib.install(
  make_department,
  ports_lib.github_author_options(read_env, "x-publisher", {
    bot_login_env = "FKST_GITHUB_BOT_LOGIN",
    extra_login_envs = {
      "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
      "FKST_GITHUB_AUTHORIZED_LOGINS",
    },
  })
)
