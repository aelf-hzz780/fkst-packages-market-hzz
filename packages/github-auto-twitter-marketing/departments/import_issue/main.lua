local caps = require("import_issue_caps")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")
local env = require("workflow.env")
local strings = require("contract.strings")

local spec = {
  consumes = { "github-proxy.github_issue_changed", "github-proxy.github_issue_observed" },
  produces = {
    "strategy_imported",
    "weekly_content_imported",
    "github-proxy.github_issue_comment_request",
    "x-publisher.x_publish_request",
  },
  fanout = { "github-proxy.github_issue_changed", "github-proxy.github_issue_observed" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function status_for(item)
  if item.kind == "strategy" then
    return "strategy imported"
  end
  if item.kind == "weekly-content" then
    return "weekly content imported"
  end
  if item.mode == "live" then
    return "schedule publish live requested"
  end
  return "schedule publish preview requested"
end

local function pending_status(decision)
  return "schedule publish pending until " .. tostring(decision and decision.scheduled_at or "unknown")
end

local function fetched_issue(github, payload)
  if type(payload) ~= "table" then
    return nil
  end
  local source_ref = caps.canonical_issue_source_ref(payload)
  if source_ref == nil then
    return nil
  end
  local ok, issue = pcall(function()
    return github.read_issue(source_ref, {
      consumer = "github-auto-twitter-marketing",
      force_fresh = true,
    })
  end)
  if not ok then
    log.warn("github-auto-twitter-marketing dept=import_issue tag=FETCH_SKIP reason=github issue read failed")
    return nil
  end
  return issue
end

local function observed_event(event)
  return event and event.queue == "github-proxy.github_issue_observed"
end

local function classification_options(payload, current_issue, authority, trusted_content_author)
  local opts = { session = authority }
  opts.trusted_content_author_login = trusted_content_author
  if current_issue ~= nil then
    opts.issue_body = current_issue.body
    opts.issue_labels = current_issue.labels
    opts.issue_assignees = current_issue.assignees
    opts.issue_state = current_issue.state
    opts.issue_author_login = current_issue.author_login
  else
    opts.issue_body = payload.body
    opts.issue_labels = payload.labels
    opts.issue_assignees = payload.assignees
    opts.issue_state = payload.state
    opts.issue_author_login = payload.author_login
  end
  return opts
end

local live_options
local session_authority
local trusted_content_author_login

local function make_department(ports)
  local handles = ports or {}
  local github = handles.github
  local authority_for_run = handles.session_authority or session_authority
  local live_options_for_run = handles.live_options or live_options
  local trusted_content_author_for_run = handles.trusted_content_author_login
    or trusted_content_author_login
  local run_once = handles.once or function(key, fn)
    return once(key, fn)
  end

  local function approved_content(item, authority, trusted_content_author)
    if type(github) ~= "table" or type(github.read_issue) ~= "function" then
      return nil, "GitHub content port unavailable"
    end
    local content_ref, ref_why = caps.content_source_ref(item)
    if content_ref == nil then
      return nil, ref_why
    end
    local ok, issue_or_error = pcall(function()
      return github.read_issue(content_ref, {
        consumer = "github-auto-twitter-marketing-schedule-content-authority",
        force_fresh = true,
      })
    end)
    if not ok then
      return nil, "content fresh read failed"
    end
    return caps.validate_content(
      issue_or_error,
      item,
      authority,
      content_ref,
      trusted_content_author
    )
  end

  local function act(event)
    local payload = event.payload or {}
    local authority, authority_why = authority_for_run()
    if authority == nil then
      log.warn("github-auto-twitter-marketing dept=import_issue tag=SKIP reason=session authority invalid: "
        .. tostring(authority_why))
      return
    end
    local trusted_content_author = trusted_content_author_for_run()
    if type(trusted_content_author) ~= "string" or strings.trim(trusted_content_author) == "" then
      log.warn("github-auto-twitter-marketing dept=import_issue tag=SKIP reason=trusted content author unavailable")
      return
    end
    local current_issue = nil
    if github ~= nil then
      current_issue = fetched_issue(github, payload)
      if current_issue == nil then
        log.warn("github-auto-twitter-marketing dept=import_issue tag=SKIP reason=current issue unavailable")
        return
      end
    end

    local classify_options = classification_options(
      payload,
      current_issue,
      authority,
      trusted_content_author
    )
    local item, why = caps.classify_issue(payload, classify_options)
    if item == nil then
      local blocked_comment = caps.ingress_blocked_comment(payload, classify_options, why)
      if blocked_comment ~= nil then
        log.warn("github-auto-twitter-marketing dept=import_issue tag=INGRESS_BLOCKED reason=" .. tostring(why))
        raise("github-proxy.github_issue_comment_request", blocked_comment)
      end
      log.info("github-auto-twitter-marketing dept=import_issue tag=SKIP reason=" .. tostring(why))
      return
    end
    if observed_event(event) and item.kind ~= "schedule-publish" then
      log.info("github-auto-twitter-marketing dept=import_issue tag=SKIP reason=observed non-schedule")
      return
    end

    if item.kind == "strategy" then
      raise("strategy_imported", caps.strategy_imported(item))
    elseif item.kind == "weekly-content" then
      raise("weekly_content_imported", caps.weekly_content_imported(item))
      return
    elseif item.kind == "schedule-publish" then
      local decision = caps.schedule_decision(item, now())
      if not decision.due then
        log.info("github-auto-twitter-marketing dept=import_issue tag=SCHEDULE_WAIT reason=" .. tostring(decision.reason)
          .. " scheduled_at=" .. tostring(decision.scheduled_at))
        if not observed_event(event) then
          raise("github-proxy.github_issue_comment_request", caps.status_comment(item, pending_status(decision)))
        end
        return
      end
      local content, content_why = approved_content(item, authority, trusted_content_author)
      if content == nil then
        local status = "schedule publish blocked: " .. tostring(content_why)
        log.warn("github-auto-twitter-marketing dept=import_issue tag=SCHEDULE_BLOCKED reason="
          .. tostring(content_why))
        raise("github-proxy.github_issue_comment_request", caps.status_comment(item, status))
        return
      end
      local ran = run_once(caps.schedule_once_key(item, decision), function()
        raise("x-publisher.x_publish_request", caps.x_publish_request(item, live_options_for_run(), decision))
        raise("github-proxy.github_issue_comment_request", caps.status_comment(item, status_for(item)))
      end)
      if not ran then
        log.info("github-auto-twitter-marketing dept=import_issue tag=SCHEDULE_SKIP reason=already-dispatched occurrence="
          .. tostring(decision.occurrence_id))
      end
      return
    else
      error("github-auto-twitter-marketing: unknown-kind: " .. tostring(item.kind), 0)
    end

    raise("github-proxy.github_issue_comment_request", caps.status_comment(item, status_for(item)))
  end

  return saga.department(spec, {
    done = done,
    act = act,
    name = "import_issue",
  })
end

local function read_env_command(name)
  if name ~= "FKST_GITHUB_BOT_LOGIN"
    and name ~= "FKST_DEVLOOP_MANAGED_BOT_LOGINS"
    and name ~= "FKST_GITHUB_AUTHORIZED_LOGINS"
    and name ~= "FKST_SESSION_CREATOR"
    and name ~= "FKST_SESSION_WORK_LABEL"
    and name ~= "FKST_SESSION_WORK_LABEL_MAP_JSON"
    and name ~= "FKST_NYXID_X_SERVICE_SLUG"
    and name ~= "FKST_X_PUBLISH_EXPECTED_USERNAME"
    and name ~= "FKST_X_PUBLISH_WRITE"
    and name ~= "NYXID_X_SERVICE_SLUG"
    and name ~= "X_PUBLISH_EXPECTED_USERNAME"
    and name ~= "X_PUBLISH_WRITE" then
    error("github-auto-twitter-marketing: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })
local function first_non_empty_env(names)
  for _, name in ipairs(names) do
    local value = strings.trim(read_env(name) or "")
    if value ~= "" then
      return value
    end
  end
  return ""
end

live_options = function()
  local write_gate = first_non_empty_env({ "X_PUBLISH_WRITE", "FKST_X_PUBLISH_WRITE" })
  return {
    live_write_enabled = write_gate == "1",
    nyxid_x_service = first_non_empty_env({ "NYXID_X_SERVICE_SLUG", "FKST_NYXID_X_SERVICE_SLUG" }),
    expected_username = first_non_empty_env({ "X_PUBLISH_EXPECTED_USERNAME", "FKST_X_PUBLISH_EXPECTED_USERNAME" }),
  }
end

session_authority = function()
  return caps.resolve_session_authority({
    FKST_SESSION_CREATOR = first_non_empty_env({ "FKST_SESSION_CREATOR" }),
    FKST_SESSION_WORK_LABEL = first_non_empty_env({ "FKST_SESSION_WORK_LABEL" }),
    FKST_SESSION_WORK_LABEL_MAP_JSON = first_non_empty_env({ "FKST_SESSION_WORK_LABEL_MAP_JSON" }),
    X_PUBLISH_EXPECTED_USERNAME = first_non_empty_env({ "X_PUBLISH_EXPECTED_USERNAME" }),
    FKST_X_PUBLISH_EXPECTED_USERNAME = first_non_empty_env({ "FKST_X_PUBLISH_EXPECTED_USERNAME" }),
  })
end

trusted_content_author_login = function()
  return first_non_empty_env({ "FKST_GITHUB_BOT_LOGIN" })
end

local github_author_policy_env = {
  bot_login_env = "FKST_GITHUB_BOT_LOGIN",
  extra_login_envs = {
    "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
    "FKST_GITHUB_AUTHORIZED_LOGINS",
  },
}

return ports_lib.install(
  make_department,
  ports_lib.github_author_options(read_env, "github-auto-twitter-marketing", github_author_policy_env)
)
