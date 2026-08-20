local core = require("core")
local marketing_content = require("contract.marketing_content")
local sha256 = require("contract.sha256")
local testing = require("testkit.testing")
local t = fkst.test

local repo = "aelf-hzz780/fkst-packages-market-hzz"

local function session()
  return {
    effective_work_label = "auto-x-hzz780",
    logical_work_label = "auto-x-hzz780",
    creator = "aelf-hzz780",
    account = "hzz780",
  }
end

local function source_ref(number)
  local ref = repo .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function signal_issue(number)
  return {
    number = number,
    body = table.concat({
      "contract: marketing-radar.radar-signal.v2",
      "type: radar-signal",
      "project: aelf-x-ops",
      "account: hzz780",
      "work-label: auto-x-hzz780",
      "week: 2026-W34",
      "action: add",
      "topic: content-supply-gap",
      "insight: Turn the cited COO evidence into one reviewed weekly draft.",
    }, "\n"),
    state = "OPEN",
    labels = { "auto-x-hzz780" },
    assignees = { "aelf-hzz780" },
    author_login = "nwnwnw413",
    comments = {},
    source_ref = source_ref(number),
  }
end

local function event(issue)
  return {
    queue = "github-proxy.github_issue_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue.number,
      labels = issue.labels,
      assignees = issue.assignees,
      source_ref = source_ref(issue.number),
    },
    source_ref = source_ref(issue.number),
  }
end

local function classified(issue)
  return assert(core.classify_issue(event(issue).payload, {
    session = session(),
    issue_body = issue.body,
    issue_labels = issue.labels,
    issue_assignees = issue.assignees,
    issue_author_login = issue.author_login,
    authorized_signal_authors = { "nwnwnw413" },
  }))
end

local function legacy_review(number, source, values)
  local options = values or {}
  local signal = classified(source)
  local work_label = options.work_label or session().logical_work_label
  local legacy_group = core.proposal_rc2_group_key(signal)
  local signal_set_digest = assert(core.signal_set_identity({ signal }, session())).signal_set_digest
  local proposal_id = "proposal-"
    .. sha256.hex(legacy_group .. "\n" .. signal_set_digest):sub(1, 24)
  local content_id = "content-" .. sha256.hex(proposal_id):sub(1, 24)
  local tweet_text = "One reviewed W34 draft turns the cited COO signal into a concrete update."
  local content_digest = assert(marketing_content.digest({
    project = signal.project,
    account = signal.account,
    work_label = work_label,
    week = signal.week,
    content_id = content_id,
    content_revision = 1,
    proposal_id = proposal_id,
    proposal_revision = 1,
    approval_id = proposal_id .. "@1",
    content_status = "approved",
    tweet_text = tweet_text,
  }))
  local body = table.concat({
    "contract: marketing-radar.weekly-plan-change.v2",
    "type: weekly-plan-change",
    "project: " .. signal.project,
    "account: " .. signal.account,
    "work-label: " .. work_label,
    "week: " .. signal.week,
    "topic: " .. signal.topic,
    "action: " .. signal.action,
    "change-scope: " .. signal.change_scope,
    "supersede-mode: " .. signal.supersede_mode,
    "proposal-id: " .. proposal_id,
    "proposal-revision: 1",
    "content-id: " .. content_id,
    "content-revision: 1",
    "signal-set-digest: " .. signal_set_digest,
    "content-digest: " .. content_digest,
    "status: awaiting-review",
    "signal: " .. signal.source_ref.ref .. " " .. signal.signal_digest,
    "evidence: " .. signal.source_ref.ref,
    "",
    "tweet-text:",
    "```",
    tweet_text,
    "```",
    "",
    "<!-- fkst:github-proxy:issue-create:" .. legacy_group .. "/create/cycle-1 -->",
  }, "\n")
  return {
    number = number,
    body = body,
    state = "CLOSED",
    labels = { "auto-x-hzz780" },
    assignees = { "aelf-hzz780" },
    author_login = "aelf-hzz780",
    comments = {},
    source_ref = source_ref(number),
  }, {
    content_digest = content_digest,
    proposal_id = proposal_id,
    signal_ref = signal.source_ref.ref,
    signal_set_digest = signal_set_digest,
  }
end

local function replace_once(value, from, to)
  local at = assert(tostring(value):find(from, 1, true))
  return value:sub(1, at - 1) .. to .. value:sub(at + #from)
end

local function row(issue)
  return {
    number = issue.number,
    body = issue.body,
    state = issue.state,
    labels = issue.labels,
    assignees = issue.assignees,
    author = { login = issue.author_login },
  }
end

local function department(github, draft_counter)
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    session_authority = session,
    review_options = function()
      return { bot_login = "aelf-hzz780", authorized_reviewers = { "aelf-hzz780" } }
    end,
    signal_author_logins = function() return { "nwnwnw413", "aelf-hzz780" } end,
    draft_generator = function(signals, revision)
      draft_counter.count = draft_counter.count + 1
      local evidence_refs = {}
      for _, signal in ipairs(signals) do
        evidence_refs[#evidence_refs + 1] = signal.source_ref.ref
      end
      return {
        revision = revision,
        action = signals[1].action,
        evidence_refs = evidence_refs,
        tweet_text = "A fresh W34 draft is ready for explicit human review.",
      }
    end,
  })
end

local function run_signal(source, review)
  local issues = { [source.number] = source, [review.number] = review }
  local github = {}
  function github.read_issue(ref, _options)
    return issues[tonumber(ref.ref:match("#issue/(%d+)$"))]
  end
  function github.api_paginate_slurp(path, _timeout)
    return tostring(path):find("state=all", 1, true)
      and { row(source), row(review) } or { row(source) }
  end
  local drafts = { count = 0 }
  return testing.run_fake(department(github, drafts), event(source)), drafts.count
end

local function raises_for(result, queue)
  local values = {}
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue or raised.queue == "marketing-radar." .. queue then
      values[#values + 1] = raised.payload
    end
  end
  return values
end

return {
  test_w34_rc2_history_allows_complete_catalog_creation_path = function()
    local source = signal_issue(124)
    local review = legacy_review(132, source)
    local result, drafts = run_signal(source, review)
    t.eq(drafts, 1)
    local creates = raises_for(result, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    local created = assert(core.parse_proposal(creates[1].body))
    t.eq(created.week, "2026-W34")
    t.eq(created.topic, "content-supply-gap")
    t.is_true(creates[1].dedup_key:find("/sha256-", 1, true) ~= nil)
    t.is_true(creates[1].dedup_key:sub(-#"/create/cycle-1") == "/create/cycle-1")
  end,

  test_catalog_rejects_wrong_rc2_logical_work_label = function()
    local source = signal_issue(224)
    local review = legacy_review(232, source, { work_label = "other-marketing-workflow" })
    local parsed = assert(core.inspect_rc2_proposal(review.body))
    t.eq(parsed.work_label, "other-marketing-workflow")
    local result, drafts = run_signal(source, review)
    t.eq(drafts, 0)
    t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
    local comments = raises_for(result, "github-proxy.github_issue_comment_request")
    t.eq(#comments, 1)
    t.is_true(comments[1].body:find("needs-triage", 1, true) ~= nil)
  end,

  test_catalog_rejects_corrupted_rc2_identity_digests_and_lineage = function()
    local corruptions = {
      {
        name = "proposal-id",
        expected = "rc2-proposal-id-mismatch",
        mutate = function(body, identity)
          return replace_once(body, identity.proposal_id, "proposal-" .. string.rep("f", 24))
        end,
      },
      {
        name = "signal-set-digest",
        expected = "rc2-signal-set-digest-mismatch",
        mutate = function(body, identity)
          return replace_once(body, identity.signal_set_digest, "sha256:" .. string.rep("f", 64))
        end,
      },
      {
        name = "content-digest",
        expected = "rc2-content-digest-mismatch",
        mutate = function(body, identity)
          return replace_once(body, identity.content_digest, "sha256:" .. string.rep("f", 64))
        end,
      },
      {
        name = "lineage",
        expected = "invalid-rc2-evidence-lineage",
        mutate = function(body, identity)
          return replace_once(body, "evidence: " .. identity.signal_ref,
            "evidence: " .. repo .. "#issue/999")
        end,
      },
    }
    for index, corruption in ipairs(corruptions) do
      local source = signal_issue(300 + index * 2)
      local review, identity = legacy_review(source.number + 1, source)
      review.body = corruption.mutate(review.body, identity)
      local parsed, why = core.inspect_rc2_proposal(review.body)
      t.is_nil(parsed)
      t.eq(why, corruption.expected, corruption.name)
      local result, drafts = run_signal(source, review)
      t.eq(drafts, 0, corruption.name)
      t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0, corruption.name)
      local comments = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#comments, 1, corruption.name)
      t.is_true(comments[1].body:find("needs-triage", 1, true) ~= nil, corruption.name)
    end
  end,
}
