local m_claims = require("devloop.claims")
local h = require("tests.devloop_core_helpers")
local t = h.t
local author_policy = require("testkit_internal.github_author_policy")

local function mock_bot(login)
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = login or "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_authorized_login(login, managed_bot_logins)
  author_policy.mock_env(t, {
    env = {
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = managed_bot_logins or "",
      FKST_GITHUB_AUTHORIZED_LOGINS = login or "",
    },
  }, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
  })
end

local function current_issue(author_login, comments)
  return {
    assignees = {},
    labels = {},
    author_login = author_login,
    comments = comments or {},
  }
end

local function state_marker_comment(author_login)
  return {
    author_login = author_login,
    body = 'github-devloop thinking\n<!-- fkst:github-devloop:state:v1 proposal="x" state="thinking" -->',
  }
end

local function admission_for(current)
  local inputs = m_claims.claim_admission_inputs(current)
  local admission, detail = m_claims.claim_admission_precheck(current, inputs)
  return admission, detail, inputs
end

return {
  test_authorized_state_marker_author_gets_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")

    local admission, detail, inputs = admission_for(current_issue("peer-bot", {
      state_marker_comment("peer-bot[bot]"),
    }))

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("peer-bot", inputs.managed))
  end,

  test_unauthorized_state_marker_author_does_not_get_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("")

    local admission, detail, inputs = admission_for(current_issue("drive-by", {
      state_marker_comment("drive-by"),
    }))

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-non-whitelisted-author")
    t.eq(m_claims.is_managed_bot_login("drive-by", inputs.managed), false)
  end,

  test_manual_managed_bot_login_seed_still_gets_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("", "manual-peer")

    local admission, detail, inputs = admission_for(current_issue("manual-peer", {}))

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("manual-peer", inputs.managed))
    t.is_nil(inputs.trusted_author_policy)
  end,

  test_observed_peer_set_is_rederived_from_current_issue_comments = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")

    local first_admission, first_detail, first_inputs = admission_for(current_issue("peer-bot", {
      state_marker_comment("peer-bot"),
    }))

    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")

    local second_admission, second_detail, second_inputs = admission_for(current_issue("peer-bot", {}))

    t.eq(first_admission, "denied")
    t.eq(first_detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("peer-bot", first_inputs.managed))
    t.eq(second_admission, "needs-claim")
    t.eq(second_detail.author, "peer-bot")
    t.eq(m_claims.is_managed_bot_login("peer-bot", second_inputs.managed), false)
  end,
}
