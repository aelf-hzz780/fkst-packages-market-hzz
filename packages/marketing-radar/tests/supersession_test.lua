local marketing_content = require("contract.marketing_content")
local supersession = require("supersession")
local t = fkst.test

local repo = "owner/repo"

local function merge(base, overrides)
  local out = {}
  for key, value in pairs(base or {}) do out[key] = value end
  for key, value in pairs(overrides or {}) do out[key] = value end
  return out
end

local function authority(overrides)
  return merge({
    effective_work_label = "host-test-primary",
    logical_work_label = "auto-x-test-primary",
    creator = "test-operator",
    account = "test_primary",
    bot_login = "fkst-test-bot",
  }, overrides)
end

local function approved_content(number, overrides)
  local values = merge({
    project = "chronoai",
    account = "test_primary",
    work_label = "auto-x-test-primary",
    week = "2026-W33",
    content_id = "content-lineage-1",
    content_revision = 1,
    proposal_id = "proposal-old",
    proposal_revision = 1,
    approval_id = "proposal-old@1",
    content_status = "approved",
    tweet_text = "Approved content " .. tostring(number) .. ".",
  }, overrides and overrides.content)
  local body, digest = assert(marketing_content.render(values))
  local issue = merge({
    number = number,
    body = body,
    state = "CLOSED",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "app/fkst-test-bot",
    comments = {},
  }, overrides and overrides.issue)
  return issue, digest
end

local function schedule_body(number, content_number, digest, approval_id, overrides)
  local fields = merge({
    contract = "auto-twitter-marketing.schedule-publish.v2",
    type = "schedule-publish",
    project = "chronoai",
    account = "test_primary",
    work_label = "auto-x-test-primary",
    week = "2026-W33",
    content_ref = "#" .. tostring(content_number),
    content_digest = digest,
    approval_id = approval_id,
    mode = "live",
    scheduled_at = "2026-08-17T08:00:00Z",
  }, overrides)
  return table.concat({
    "contract: " .. fields.contract,
    "type: " .. fields.type,
    "project: " .. fields.project,
    "account: " .. fields.account,
    "work-label: " .. fields.work_label,
    "week: " .. fields.week,
    "content-ref: " .. fields.content_ref,
    "content-digest: " .. fields.content_digest,
    "approval-id: " .. fields.approval_id,
    "mode: " .. fields.mode,
    "scheduled-at: " .. fields.scheduled_at,
  }, "\n")
end

local function schedule_issue(number, content_number, digest, approval_id, overrides)
  return merge({
    number = number,
    body = schedule_body(number, content_number, digest, approval_id),
    state = "OPEN",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "test-operator",
    comments = {},
  }, overrides)
end

local function receipt(digest, approval_id, overrides)
  local fields = merge({
    account = "test_primary",
    authenticated_account = "test_primary",
    content_digest = digest,
    approval_id = approval_id,
    post_uri = "https://x.com/i/web/status/2087115957424840733",
    dedup_key = "auto-twitter-marketing/test_primary/chronoai/2026-W33/schedule/owner_repo_issue_51/occurrence/x-publish",
    status = "published",
  }, overrides)
  return {
    author_login = fields.author_login or "fkst-test-bot[bot]",
    body = "Auto Twitter marketing: X published\n\n"
      .. "schema: x-publisher.publish-receipt.v2\n"
      .. "status: " .. fields.status .. "\n"
      .. "account: " .. fields.account .. "\n"
      .. "authenticated_account: " .. fields.authenticated_account .. "\n"
      .. "content_digest: " .. fields.content_digest .. "\n"
      .. "approval_id: " .. fields.approval_id .. "\n"
      .. "post_uri: " .. fields.post_uri .. "\n"
      .. "dedup_key: " .. fields.dedup_key .. "\n\n"
      .. "<!-- fkst:github-proxy:comment:" .. tostring(fields.marker_dedup or fields.dedup_key)
      .. "/status/x-publish-published -->",
  }
end

local function proposal(action, overrides)
  return merge({
    action = action,
    target_ref = action == "revise" and "#41" or nil,
    project = "chronoai",
    account = "test_primary",
    work_label = "auto-x-test-primary",
    week = "2026-W33",
    content_id = "content-lineage-1",
    content_revision = 2,
    content_digest = "sha256:" .. string.rep("f", 64),
    proposal_id = "proposal-new",
    revision = 2,
    group_key = "marketing-radar/test/supersession",
  }, overrides)
end

local function row(issue)
  return {
    number = issue.number,
    body = issue.body,
    state = issue.state,
    labels = issue.labels,
    assignees = issue.assignees,
    comments = #(issue.comments or {}),
    user = { login = issue.author_login },
  }
end

local function content_candidate(issue)
  local content = assert(marketing_content.parse(issue.body))
  local ref = repo .. "#issue/" .. tostring(issue.number)
  return {
    number = issue.number,
    source_ref = { kind = "external", ref = ref, reference = ref },
    content = content,
    issue = issue,
  }
end

local function reader(issues)
  return function(ref)
    return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
  end
end

local function no_receipts()
  return {}
end

return {
  test_resolve_revision_lineage_uses_fresh_trusted_target = function()
    local target = approved_content(41)
    local lineage = assert(supersession.resolve_revision_lineage(
      proposal("revise"), repo, { row(target) }, reader({ [41] = target }), authority(), no_receipts))
    t.eq(lineage.content_id, "content-lineage-1")
    t.eq(lineage.content_revision, 2)
    t.eq(lineage.target_ref, repo .. "#issue/41")
  end,

  test_revision_target_requires_closed_bot_authored_session_content = function()
    local cases = {
      { issue = { state = "OPEN" }, why = "revision-target-is-not-closed" },
      { issue = { author_login = "someone-else" }, why = "revision-target-author-mismatch" },
      { issue = { labels = { "other" } }, why = "revision-target-session-mismatch" },
      { issue = { assignees = { "someone-else" } }, why = "revision-target-session-mismatch" },
    }
    for _, case in ipairs(cases) do
      local target = approved_content(41, { issue = case.issue })
      local lineage, why = supersession.resolve_revision_lineage(
        proposal("revise"), repo, { row(target) }, reader({ [41] = target }), authority(), no_receipts)
      t.is_nil(lineage)
      t.eq(why, case.why)
    end
  end,

  test_plan_rejects_revision_identity_that_does_not_continue_target = function()
    local target = approved_content(41)
    local planned, why = supersession.plan(
      proposal("revise", { content_id = "different-lineage" }),
      repo, { row(target) }, reader({ [41] = target }), authority(), no_receipts)
    t.is_nil(planned)
    t.eq(why, "revision-lineage-mismatch")

    planned, why = supersession.plan(
      proposal("revise", { content_revision = 3 }),
      repo, { row(target) }, reader({ [41] = target }), authority(), no_receipts)
    t.is_nil(planned)
    t.eq(why, "revision-lineage-mismatch")
  end,

  test_superseded_ack_requires_exact_bot_comment_for_current_proposal = function()
    local target = approved_content(41)
    local candidate = content_candidate(target)
    local current = proposal("revise")
    local request = assert(supersession.comment_request(candidate, current))

    target.comments = {
      { author_login = "test-operator", body = request.body },
      { author_login = "fkst-test-bot", body = request.body .. "\nextra" },
      {
        author_login = "fkst-test-bot",
        body = '<!-- fkst:auto-twitter:content-superseded:v2 content_digest="'
          .. candidate.content.content_digest .. '" -->',
      },
    }
    local found, why = supersession.is_superseded(
      target, candidate, current, authority().bot_login)
    t.eq(found, false)
    t.is_nil(why)

    target.comments[#target.comments + 1] = {
      author_login = "app/fkst-test-bot",
      body = request.body,
    }
    found, why = supersession.is_superseded(
      target, candidate, current, authority().bot_login)
    t.is_true(found)
    t.is_nil(why)
  end,

  test_other_proposal_supersession_fails_revise_and_is_skipped_by_replan = function()
    local target = approved_content(41)
    local candidate = content_candidate(target)
    local other = proposal("revise", { proposal_id = "proposal-other", revision = 7 })
    target.comments = {
      { author_login = "fkst-test-bot", body = assert(supersession.comment_request(candidate, other)).body },
    }

    local found, why = supersession.is_superseded(
      target, candidate, proposal("revise"), authority().bot_login)
    t.is_nil(found)
    t.eq(why, "content-superseded-by-other-proposal")

    local planned
    planned, why = supersession.plan(
      proposal("revise"), repo, { row(target) }, reader({ [41] = target }), authority(), no_receipts)
    t.is_nil(planned)
    t.eq(why, "content-superseded-by-other-proposal")

    planned, why = supersession.plan(
      proposal("replan", { content_id = "content-replan", content_revision = 1 }),
      repo, { row(target) }, reader({ [41] = target }), authority(), no_receipts)
    t.eq(#assert(planned), 0)
    t.is_nil(why)
  end,

  test_plan_keeps_candidate_already_superseded_by_current_proposal = function()
    local target = approved_content(41)
    local candidate = content_candidate(target)
    local current = proposal("revise")
    target.comments = {
      { author_login = "fkst-test-bot", body = assert(supersession.comment_request(candidate, current)).body },
    }

    local planned = assert(supersession.plan(
      current, repo, { row(target) }, reader({ [41] = target }), authority(), no_receipts))
    t.eq(#planned, 1)
    t.eq(planned[1].number, 41)
    t.is_true(planned[1].already_superseded)
  end,

  test_forged_publish_text_is_ignored_but_complete_bot_receipt_blocks_revise = function()
    local target, digest = approved_content(41)
    local fake_schedule = schedule_issue(51, 41, digest, "proposal-old@1", {
      comments = {
        { author_login = "test-operator", body = "Auto Twitter marketing: X published\nstatus: published" },
      },
    })
    local rows = { row(target), row(fake_schedule) }
    local planned = assert(supersession.plan(
      proposal("revise"), repo, rows, reader({ [41] = target, [51] = fake_schedule }), authority(), no_receipts))
    t.eq(#planned, 1)

    fake_schedule.comments = { receipt(digest, "proposal-old@1") }
    local blocked, why = supersession.plan(
      proposal("revise"), repo, rows, reader({ [41] = target, [51] = fake_schedule }), authority(), no_receipts)
    t.is_nil(blocked)
    t.eq(why, "published-content-requires-add-correction")
  end,

  test_non_publish_bot_status_comment_does_not_mark_content_published = function()
    local target, digest = approved_content(41)
    local schedule = schedule_issue(51, 41, digest, "proposal-old@1", {
      comments = {
        {
          author_login = "fkst-test-bot",
          body = "Auto Twitter marketing: schedule imported\n\n"
            .. "<!-- fkst:github-proxy:comment:schedule/import/status/imported -->",
        },
      },
    })
    local planned = assert(supersession.plan(
      proposal("revise"), repo, { row(target), row(schedule) },
      reader({ [41] = target, [51] = schedule }), authority(), no_receipts))
    t.eq(#planned, 1)
    t.eq(planned[1].number, 41)
  end,

  test_content_anchored_receipt_blocks_revise_without_catalog_search = function()
    local target, digest = approved_content(41)
    target.comments = { receipt(digest, "proposal-old@1") }
    local search_calls = 0
    local planned, why = supersession.plan(
      proposal("revise"), repo, { row(target) }, reader({ [41] = target }), authority(), function()
        search_calls = search_calls + 1
        return {}
      end)
    t.is_nil(planned)
    t.eq(why, "published-content-requires-add-correction")
    t.eq(search_calls, 0)
  end,

  test_content_anchor_fails_closed_on_account_digest_or_approval_mismatch = function()
    local mismatches = {
      { account = "test_secondary" },
      { authenticated_account = "test_secondary" },
      { content_digest = "sha256:" .. string.rep("9", 64) },
      { approval_id = "proposal-other@1" },
    }
    for _, mismatch in ipairs(mismatches) do
      local target, digest = approved_content(41)
      target.comments = { receipt(digest, "proposal-old@1", mismatch) }
      local planned, why = supersession.plan(
        proposal("revise"), repo, { row(target) }, reader({ [41] = target }), authority(), no_receipts)
      t.is_nil(planned)
      t.eq(why, "corrupt-published-receipt")
    end
  end,

  test_corrupt_bot_receipt_fails_closed = function()
    local target, digest = approved_content(41)
    local published_schedule = schedule_issue(51, 41, digest, "proposal-old@1", {
      comments = { receipt(digest, "proposal-old@1", { marker_dedup = "different" }) },
    })
    local planned, why = supersession.plan(
      proposal("revise"), repo, { row(target), row(published_schedule) },
      reader({ [41] = target, [51] = published_schedule }), authority(), no_receipts)
    t.is_nil(planned)
    t.eq(why, "corrupt-published-receipt")
  end,

  test_published_receipt_survives_schedule_body_retarget_or_corruption = function()
    local target, digest = approved_content(41)
    for _, edited_body in ipairs({
      schedule_body(51, 999, "sha256:" .. string.rep("9", 64), "other@1"),
      "This schedule body was replaced after publication.",
    }) do
      local published_schedule = schedule_issue(51, 41, digest, "proposal-old@1", {
        body = edited_body,
        comments = { receipt(digest, "proposal-old@1") },
      })
      local planned, why = supersession.plan(
        proposal("revise"), repo, { row(target), row(published_schedule) },
        reader({ [41] = target, [51] = published_schedule }), authority(), function()
          return { row(published_schedule) }
        end)
      t.is_nil(planned)
      t.eq(why, "published-content-requires-add-correction")
    end
  end,

  test_replan_supersedes_only_trusted_unpublished_content = function()
    local unpublished, unpublished_digest = approved_content(41, {
      content = { content_id = "content-unpublished", proposal_id = "proposal-41", approval_id = "proposal-41@1" },
    })
    local published, published_digest = approved_content(42, {
      content = { content_id = "content-published", proposal_id = "proposal-42", approval_id = "proposal-42@1" },
    })
    local foreign = approved_content(43, {
      content = { content_id = "content-foreign", proposal_id = "proposal-43", approval_id = "proposal-43@1" },
      issue = { labels = { "other-session" } },
    })
    local published_schedule = schedule_issue(52, 42, published_digest, "proposal-42@1", {
      comments = { receipt(published_digest, "proposal-42@1", { author_login = "app/fkst-test-bot" }) },
    })
    local issues = { [41] = unpublished, [42] = published, [43] = foreign, [52] = published_schedule }
    local rows = { row(unpublished), row(published), row(foreign), row(published_schedule) }
    local planned = assert(supersession.plan(
      proposal("replan", { content_id = "content-replan", content_revision = 1 }),
      repo, rows, reader(issues), authority(), no_receipts))
    t.eq(#planned, 1)
    t.eq(planned[1].number, 41)
    t.eq(planned[1].content.content_digest, unpublished_digest)
  end,

  test_unrelated_published_receipt_does_not_block_unpublished_content = function()
    local target = approved_content(41)
    local other, other_digest = approved_content(42, {
      content = { content_id = "other", proposal_id = "other", approval_id = "other@1" },
    })
    local published_schedule = schedule_issue(51, 42, other_digest, "other@1", {
      body = "body no longer identifies the original schedule",
      comments = { receipt(other_digest, "other@1") },
    })
    local planned = assert(supersession.plan(
      proposal("revise"), repo, { row(target), row(other), row(published_schedule) },
      reader({ [41] = target, [42] = other, [51] = published_schedule }), authority(), function()
        return { row(published_schedule) }
      end))
    t.eq(#planned, 1)
    t.eq(planned[1].number, 41)
  end,

  test_receipt_discovery_is_targeted_in_large_repositories = function()
    local target, digest = approved_content(41)
    local published_schedule = schedule_issue(2051, 41, digest, "proposal-old@1", {
      body = "This schedule body was replaced after publication.",
      comments = { receipt(digest, "proposal-old@1") },
    })
    local rows = { row(target) }
    local issues = { [41] = target, [2051] = published_schedule }
    for number = 1000, 1999 do
      local unrelated = {
        number = number,
        body = "Unrelated issue.",
        state = "OPEN",
        labels = {},
        assignees = {},
        author_login = "someone-else",
        comments = { { author_login = "someone-else", body = "Unrelated comment." } },
      }
      rows[#rows + 1] = row(unrelated)
      issues[number] = unrelated
    end
    rows[#rows + 1] = row(published_schedule)

    local reads = 0
    local function counted_reader(ref)
      reads = reads + 1
      return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
    end
    local function targeted_receipt_rows(expected)
      t.eq(expected.content_digest, digest)
      t.eq(expected.approval_id, "proposal-old@1")
      return { row(published_schedule) }
    end

    local planned, why = supersession.plan(
      proposal("revise"), repo, rows, counted_reader, authority(), targeted_receipt_rows)
    t.is_nil(planned)
    t.eq(why, "published-content-requires-add-correction")
    t.is_true(reads <= 3)
  end,
}
