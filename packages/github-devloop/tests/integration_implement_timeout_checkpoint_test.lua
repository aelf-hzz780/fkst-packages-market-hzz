local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local ready = h.ready
local run_implement = h.run_implement
local mock_issue_implement = h.mock_issue_implement
local deterministic_branch_for = h.deterministic_branch_for
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree_reuse = h.mock_existing_empty_implement_worktree_reuse
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_branch_diff_paths = h.mock_branch_diff_paths
local mock_git_commit = h.mock_git_commit
local count_calls = h.count_calls
local find_raise = h.find_raise
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")

local function stale_started_at()
  return tostring(now() - 7201)
end

local function mock_real_write_mode()
  for _ = 1, 6 do
    h.mock_write_env("1")
  end
end

local function mock_remote_branch(branch, head_sha)
  t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'" .. tostring(branch) .. "'^{commit}", {
    stdout = tostring(head_sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function checkpoint_comment(result)
  return find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("fkst:github-devloop:implement-checkpoint:v1", 1, true) ~= nil
  end)
end

return {
  test_timeout_self_committed_progress_is_pushed_as_wip_checkpoint = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" })
    mock_fresh_implement_worktree()
    mock_implement_codex(124, "partial progress committed", "codex timed out")
    mock_git_status("")
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "1111111111111111111111111111111111111111\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("scripts/run.sh test-affected", {
      stdout = "",
      stderr = "local verification failed",
      exit_code = 1,
    })
    mock_real_write_mode()
    t.mock_command("push origin HEAD:refs/heads/" .. branch, {
      stdout = "pushed " .. branch .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    })

    local result = run_implement(event, opts("implement-timeout-checkpoint", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("push origin HEAD:refs/heads/"), 1)
    t.eq(count_calls("impl-failed"), 0)
    local checkpoint = checkpoint_comment(result)
    t.is_true(checkpoint ~= nil)
    local fact = m_facts.implement_checkpoint_fact({ checkpoint.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.branch, branch)
    t.eq(fact.head_sha, "1111111111111111111111111111111111111111")
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end), nil)
  end,

  test_retry_continues_from_wip_checkpoint_without_opening_pr_from_checkpoint_head = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local checkpoint_head = "1111111111111111111111111111111111111111"
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
      m_builders.implement_checkpoint_marker(event.proposal_id, event.dedup_key, branch, checkpoint_head, "dev", "abc123", 1),
    })
    mock_remote_branch(branch, checkpoint_head)
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = checkpoint_head .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    mock_existing_empty_implement_worktree_reuse(nil, branch, "1")
    mock_implement_codex(0, "finished from checkpoint")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("2222222222222222222222222222222222222222", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    })

    local result = run_implement(event, opts("implement-timeout-checkpoint-retry"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    local final = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil)
    local fact = m_facts.implementing_fact({ final.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.head_sha, "2222222222222222222222222222222222222222")
  end,
}
