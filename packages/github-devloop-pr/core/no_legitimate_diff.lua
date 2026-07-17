local M = {}

local base_ids = require("devloop.base_ids")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local transition_version = require("contract.transition_version")

M.reason = "no-legitimate-diff: current PR head has no file delta against its base; no reviewable implementation remains"

function M.risk_is_empty_diff(risk)
  return type(risk) == "table"
    and risk.known == false
    and risk.reason == "diff-name-only-empty"
end

function M.closed_unmerged_version(state_or_version)
  local version = type(state_or_version) == "table" and state_or_version.version or state_or_version
  return transition_version.strip_suffixes(version)
end

function M.closed_unmerged_comment_request(core, repo, pr_number, proposal_id, version, source_ref, reason)
  local effective_version = M.closed_unmerged_version(version)
  local request = entity_lib.build_entity_comment_request({
    kind = "pr",
    repo = repo,
    number = pr_number,
  }, "github-devloop marked delegated PR child closed without merge"
    .. "\n\nReason: " .. tostring(reason or M.reason)
    .. "\n\n" .. devloop_state.state_marker(proposal_id, "closed-unmerged", effective_version)
    .. "\n" .. "⟦AI:FKST⟧", base_ids.dedup_key({
    "child-pr",
    "closed-unmerged",
    tostring(proposal_id),
    tostring(effective_version),
    tostring(pr_number),
  }), source_ref)
  request.handoff = {
    kind = "github-devloop.closed_unmerged",
    proposal_id = proposal_id,
    pr_number = pr_number,
    version = effective_version,
    source_ref = source_ref,
  }
  return request, effective_version
end

function M.raise_closed_unmerged(dept, core, repo, pr_number, proposal_id, state, source_ref)
  local request, version = M.closed_unmerged_comment_request(core, repo, pr_number, proposal_id, state, source_ref, M.reason)
  local devloop_logging = require("devloop.logging")
  devloop_logging.log_cas_decision(dept, proposal_id, state, state and state.state or "reviewing", "closed-unmerged", "applied(no-legitimate-diff)", M.reason)
  local add_labels, remove_labels = devloop_state.state_label_changes("closed-unmerged")
  devloop_logging.log_apply(dept, proposal_id, "closed-unmerged", version, { add = add_labels, remove = remove_labels }, {
    "github-proxy.github_pr_comment_request",
  })
  devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_pr_comment_request", request)
end

return M
