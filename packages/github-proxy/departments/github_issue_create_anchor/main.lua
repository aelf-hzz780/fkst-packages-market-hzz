local saga = require("workflow.saga")

local spec = {
  consumes = { "github_issue_observed" },
  produces = { "github_issue_create_request" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(_event)
  -- Capability anchor only.
  --
  -- The hosted graph validator requires every consumed queue to have at least
  -- one producer in the composed package set. github-proxy includes the
  -- issue-create adapter for workflows that need it, while some hosted manifests
  -- only need labels/comments/polling. This no-op anchor keeps the adapter's
  -- queue closed without creating GitHub issues or changing write behavior.
  log.info("github-proxy dept=github_issue_create_anchor tag=NOOP")
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "github_issue_create_anchor",
})
