local core = require("core")
local content_authority = require("content_authority")
local ingress_block = require("ingress_block")

return {
  canonical_issue_source_ref = core.canonical_issue_source_ref,
  classify_issue = core.classify_issue,
  content_source_ref = content_authority.content_source_ref,
  ingress_blocked_comment = ingress_block.comment,
  resolve_session_authority = core.resolve_session_authority,
  schedule_decision = core.schedule_decision,
  schedule_once_key = core.schedule_once_key,
  status_comment = core.status_comment,
  strategy_imported = core.strategy_imported,
  weekly_content_imported = core.weekly_content_imported,
  validate_content = content_authority.validate,
  x_publish_request = core.x_publish_request,
}
