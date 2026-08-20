local core = require("core")
local testing = require("testkit.testing")
local t = fkst.test

local repo = "owner/repo"

local function session()
  return {
    effective_work_label = "host-test-primary",
    logical_work_label = "auto-x-test-primary",
    creator = "test-operator",
    account = "test_primary",
  }
end

local function source_ref(number)
  local ref = repo .. "#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function body(number, insight)
  return table.concat({
    "contract: marketing-radar.radar-signal.v2",
    "type: radar-signal",
    "project: chronoai",
    "account: test_primary",
    "work-label: auto-x-test-primary",
    "week: 2026-W33",
    "action: add",
    "topic: FKST automation",
    "source-url: https://github.example/owner/repo/issues/" .. tostring(number),
    "insight: " .. tostring(insight or "Use cited evidence for the reviewed draft."),
  }, "\n")
end

local function issue(number)
  return {
    number = number,
    body = body(number),
    state = "OPEN",
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "test-operator",
    comments = {},
    source_ref = source_ref(number),
  }
end

local function copy_list(values)
  local copied = {}
  for index, value in ipairs(values or {}) do copied[index] = value end
  return copied
end

local function snapshot_row(value)
  return {
    number = value.number,
    body = value.body,
    state = value.state,
    labels = copy_list(value.labels),
    assignees = copy_list(value.assignees),
    author = { login = value.author_login },
  }
end

local function event(value)
  return {
    queue = "github-proxy.github_issue_observed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = value.number,
      labels = value.labels,
      assignees = value.assignees,
      source_ref = source_ref(value.number),
    },
    source_ref = source_ref(value.number),
  }
end

local function classified(value)
  return assert(core.classify_issue(event(value).payload, {
    session = session(),
    issue_body = value.body,
    issue_labels = value.labels,
    issue_assignees = value.assignees,
    issue_author_login = value.author_login,
    authorized_signal_authors = { "test-operator" },
  }))
end

local function department(github, draft_generator)
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    session_authority = session,
    review_options = function()
      return { bot_login = "fkst-test-bot", authorized_reviewers = { "test-operator" } }
    end,
    signal_author_logins = function() return { "test-operator" } end,
    draft_generator = draft_generator,
  })
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

local function successful_draft(signals, revision)
  local evidence_refs = {}
  for _, signal in ipairs(signals) do
    evidence_refs[#evidence_refs + 1] = signal.source_ref.ref
  end
  return {
    revision = revision,
    action = signals[1].action,
    evidence_refs = evidence_refs,
    tweet_text = "A reviewed and bounded FKST automation update.",
  }
end

local function assert_non_anchor_change_blocks_draft(mutate)
  local issues = { [301] = issue(301), [302] = issue(302) }
  local identity = assert(core.signal_set_identity({
    classified(issues[301]), classified(issues[302]),
  }, session()))
  local anchor_number = tonumber(identity.first.source_ref.ref:match("#issue/(%d+)$"))
  local changed_number = anchor_number == 301 and 302 or 301
  local stale_rows = { snapshot_row(issues[301]), snapshot_row(issues[302]) }
  mutate(issues[changed_number])

  local fresh_reads = {}
  local github = {}
  function github.read_issue(ref, options)
    local number = tonumber(ref.ref:match("#issue/(%d+)$"))
    if options and options.force_fresh == true then
      fresh_reads[number] = (fresh_reads[number] or 0) + 1
    end
    return issues[number]
  end
  function github.api_paginate_slurp(_path, _timeout)
    return stale_rows
  end

  local draft_calls = 0
  local result = testing.run_fake(department(github, function(signals, revision)
    draft_calls = draft_calls + 1
    return successful_draft(signals, revision)
  end), event(issues[anchor_number]))

  t.is_true((fresh_reads[changed_number] or 0) >= 1)
  t.eq(draft_calls, 0)
  t.eq(#raises_for(result, "github-proxy.github_issue_create_request"), 0)
end

return {
  test_fresh_non_anchor_body_edit_blocks_proposal_draft = function()
    assert_non_anchor_change_blocks_draft(function(value)
      value.body = body(value.number, "Use newly edited evidence instead of the stale snapshot.")
    end)
  end,

  test_fresh_non_anchor_close_blocks_proposal_draft = function()
    assert_non_anchor_change_blocks_draft(function(value)
      value.state = "CLOSED"
    end)
  end,

  test_fresh_non_anchor_reroute_blocks_proposal_draft = function()
    assert_non_anchor_change_blocks_draft(function(value)
      value.labels = { "host-another-session" }
    end)
  end,

  test_fresh_non_anchor_author_change_blocks_proposal_draft = function()
    assert_non_anchor_change_blocks_draft(function(value)
      value.author_login = "untrusted-operator"
    end)
  end,
}
