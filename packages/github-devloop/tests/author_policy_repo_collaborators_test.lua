local h = require("tests.devloop_core_helpers")
local t = h.t
local github_factory = require("devloop.github_factory")

local collaborator_path = "repos/owner/repo/collaborators?permission=push&per_page=" .. "100"

local function env_exec(env)
  return function(command)
    local name = tostring(command or ""):match('^printf %%s "%$([%w_]+)"$')
    if name == nil then
      error("unexpected env command: " .. tostring(command))
    end
    return {
      stdout = tostring((env or {})[name] or ""),
      stderr = "",
      exit_code = 0,
    }
  end
end

local function github_exec(stdout, opts)
  local options = opts or {}
  local calls = {}
  local run = function(spec)
    local argv = spec.argv or {}
    table.insert(calls, table.concat(argv, " "))
    if argv[1] ~= "gh" or argv[2] ~= "api" or argv[3] ~= "--paginate" or argv[4] ~= "--slurp" or argv[5] ~= collaborator_path then
      error("unexpected gh argv: " .. table.concat(argv, " "))
    end
    if options.fail then
      return {
        stdout = "",
        stderr = "boom",
        exit_code = 1,
      }
    end
    return {
      stdout = stdout,
      stderr = "",
      exit_code = 0,
    }
  end
  return run, calls
end

local function make_handle(env, stdout, opts)
  h.mock_author_policy_configure("fkst-test-bot")
  local run, calls = github_exec(stdout or "[]", opts)
  return github_factory.new(run, env_exec(env)), calls
end

local function base_env(extra)
  local env = {
    FKST_GITHUB_REPO = "owner/repo",
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "",
    FKST_GITHUB_AUTHORIZED_LOGINS = "trusted-human",
    FKST_GITHUB_AUTHORIZE_REPO_COLLABORATORS = "",
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return env
end

return {
  test_flag_off_preserves_csv_only_authorization = function()
    local handle, calls = make_handle(base_env(), '[{"login":"write-collab","permissions":{"push":true}}]')

    t.eq(handle.is_authorized_author("trusted-human"), true)
    t.eq(handle.is_authorized_author("write-collab"), false)
    t.eq(#calls, 0)
  end,

  test_flag_on_authorizes_push_collaborator_through_normal_github_handle = function()
    local handle, calls = make_handle(base_env({
      FKST_GITHUB_AUTHORIZE_REPO_COLLABORATORS = "1",
    }), '[['
      .. '{"login":"write-collab","permissions":{"push":true}},'
      .. '{"login":"read-collab","permissions":{"pull":true}},'
      .. '{"login":"role-read","permission":"read"}'
      .. ']]')

    t.eq(handle.is_authorized_author("write-collab"), true)
    t.eq(handle.is_authorized_author("read-collab"), false)
    t.eq(handle.is_authorized_author("role-read"), false)
    t.eq(handle.is_authorized_author("unrelated"), false)
    t.eq(handle.is_authorized_author("write-collab"), true)
    t.eq(#calls, 1)
  end,

  test_collaborator_fetch_failure_falls_back_to_csv_only = function()
    local handle, calls = make_handle(base_env({
      FKST_GITHUB_AUTHORIZE_REPO_COLLABORATORS = "1",
    }), "[]", { fail = true })

    t.eq(handle.is_authorized_author("trusted-human"), true)
    t.eq(handle.is_authorized_author("write-collab"), false)
    t.eq(#calls, 1)
  end,
}
