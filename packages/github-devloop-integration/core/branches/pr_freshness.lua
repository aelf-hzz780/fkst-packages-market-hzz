local base_ids = require("devloop.base_ids")
local PrFreshness = {}
local strings = require("contract.strings")
local decimal_checksum = strings.decimal_checksum

function PrFreshness.install(M, shared)
  local require_safe_branch = shared.require_safe_branch
  local require_safe_sha = shared.require_safe_sha
  local require_safe_repo = shared.require_safe_repo
  local runtime_root_path = shared.runtime_root_path

  function M.pr_freshness_lock_key(repo, branch)
    local prefix = "github-devloop/pr-freshness/"
    local safe_repo = base_ids.safe_repo(require_safe_repo(repo))
    local safe_branch = require_safe_branch("managed branch", branch)
    local key = prefix .. safe_repo .. "/" .. safe_branch
    if not strings.is_path_safe_key(key, M._max_key_len) then
      -- HOTFIX (upstream ChronoAIProject/fkst-packages#2603): bound long branch
      -- names via truncate+checksum (mirrors branch_train bounded_lock_key) instead
      -- of fail-closed. Short branches keep their exact key (no lock churn).
      local budget = M._max_key_len - #prefix - #safe_repo - 1
      local checksum = decimal_checksum(safe_branch)
      local readable = strings.sanitize_key(safe_branch, false):gsub("/", "-"):sub(1, budget - #checksum - 1)
      key = prefix .. safe_repo .. "/" .. readable .. "-" .. checksum
    end
    return key
  end

  function M.pr_freshness_dedup_key(repo, branch, baseline_sha)
    return base_ids.dedup_key({
      "pr-freshness",
      require_safe_repo(repo),
      require_safe_branch("managed branch", branch),
      require_safe_sha("baseline sha", baseline_sha),
    })
  end

  function M.pr_freshness_source_ref(repo, pr_number)
    return {
      kind = "external",
      ref = require_safe_repo(repo) .. "#pr/" .. tostring(pr_number),
    }
  end

  function M.pr_freshness_commit_message(repo, branch, integration, branch_parent, integration_sha)
    return "Refresh " .. require_safe_branch("managed branch", branch)
      .. " from " .. require_safe_branch("integration branch", integration)
      .. "\n\n"
      .. "<!-- fkst:github-devloop:pr-freshness:v1 repo=\"" .. require_safe_repo(repo)
      .. "\" branch=\"" .. require_safe_branch("managed branch", branch)
      .. "\" integration=\"" .. require_safe_branch("integration branch", integration)
      .. "\" branch_parent=\"" .. require_safe_sha("branch parent", branch_parent)
      .. "\" integration_sha=\"" .. require_safe_sha("integration sha", integration_sha)
      .. "\" -->"
  end

  function M.pr_freshness_message_file(runtime_root, repo, branch, integration, branch_parent, integration_sha)
    local suffix = decimal_checksum(
      require_safe_repo(repo)
        .. "#"
        .. require_safe_branch("managed branch", branch)
        .. "#"
        .. require_safe_branch("integration branch", integration)
        .. "#"
        .. require_safe_sha("branch parent", branch_parent)
        .. "#"
        .. require_safe_sha("integration sha", integration_sha)
    )
    runtime_root_path(runtime_root)
    return "/tmp/fkst-github-devloop-pr-freshness-message-" .. suffix .. ".txt"
  end
end

return PrFreshness
