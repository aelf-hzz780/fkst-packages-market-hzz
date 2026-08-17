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

local function signal_issue(insight)
  return {
    number = 11,
    state = "OPEN",
    source_ref = source_ref(11),
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "test-operator",
    comments = {},
    body = table.concat({
      "contract: marketing-radar.radar-signal.v2",
      "type: radar-signal",
      "project: chronoai",
      "account: test_primary",
      "work-label: auto-x-test-primary",
      "week: 2026-W33",
      "action: add",
      "topic: FKST automation",
      "insight: " .. tostring(insight or "Generate a cited update."),
    }, "\n"),
  }
end

local function classified(issue)
  return assert(core.classify_issue({
    schema = "github-proxy.v1",
    type = "issue",
    repo = repo,
    number = issue.number,
    labels = issue.labels,
    assignees = issue.assignees,
    body = issue.body,
    source_ref = issue.source_ref,
  }, { session = session() }))
end

local function review_issue(command)
  local source = signal_issue()
  local signal = classified(source)
  local proposal = assert(core.build_proposal({ signal }, session(), {
    action = "add",
    evidence_refs = { signal.source_ref.ref },
    tweet_text = "A terminal review close test.",
  }))
  local request = core.weekly_plan_change_issue_request(proposal, session())
  local issue = {
    number = 21,
    state = "OPEN",
    source_ref = source_ref(21),
    labels = { "host-test-primary" },
    assignees = { "test-operator" },
    author_login = "app/fkst-test-bot",
    body = request.body,
    comments = {
      { id = 101, author_login = "test-operator", body = "/marketing "
        .. tostring(command or "approve") .. " " .. proposal.proposal_id .. "@"
        .. proposal.revision .. (command == "reject" and " duplicate campaign" or "") },
    },
  }
  return issue, proposal
end

local function ack_for(item, status)
  local request = core.status_comment(
    item, status or "approved", core.close_handoff(item, "radar-signal"))
  return {
    queue = "github-proxy.github_comment_written",
    payload = {
      schema = "github-proxy.comment-written.v1",
      target = "issue",
      repo = repo,
      issue_number = item.issue_number,
      comment_id = "91",
      request_dedup_key = request.dedup_key,
      dedup_key = request.dedup_key .. "/written/91",
      source_ref = item.source_ref,
      handoff = request.handoff,
    },
  }
end

local function review_ack(issue, proposal, status)
  local item = classified(issue)
  local decision = assert(core.review_decision(issue, {
    bot_login = "fkst-test-bot",
    authorized_reviewers = { "test-operator" },
  }))
  local request = core.status_comment(item, status or "approved", core.close_handoff(
    item, "weekly-plan-change", decision))
  return {
    queue = "github-proxy.github_comment_written",
    payload = {
      schema = "github-proxy.comment-written.v1",
      target = "issue",
      repo = repo,
      issue_number = issue.number,
      comment_id = "102",
      request_dedup_key = request.dedup_key,
      dedup_key = request.dedup_key .. "/written/102",
      source_ref = issue.source_ref,
      handoff = request.handoff,
    },
  }
end

local function github_port(issue, close_response_lost)
  local model = { reads = 0, closes = 0, locks = 0, issue = issue }
  local github = { _model = model }
  function github.read_issue(_ref, options)
    model.reads = model.reads + 1
    t.eq(options.force_fresh, true)
    return model.issue
  end
  function github.issue_close(target_repo, number, timeout)
    t.eq(target_repo, repo)
    t.eq(number, issue.number)
    t.eq(timeout, 30)
    model.closes = model.closes + 1
    model.issue.state = "CLOSED"
    if close_response_lost then
      error("simulated lost response")
    end
    return { exit_code = 0, stdout = "", stderr = "" }
  end
  return github, model
end

local function department(github, write_enabled)
  local old_pipeline = pipeline
  local module = require("departments.issue_terminalizer.main")
  pipeline = old_pipeline
  return module.make_department({
    github = github,
    github_write_enabled = function() return write_enabled ~= false end,
    session_authority = session,
    review_options = function()
      return { bot_login = "fkst-test-bot", authorized_reviewers = { "test-operator" } }
    end,
    with_lock = function(_key, fn)
      github._model.locks = github._model.locks + 1
      return fn()
    end,
  })
end

return {
  test_ack_fresh_reads_locks_and_closes_unchanged_signal = function()
    local issue = signal_issue()
    local item = classified(issue)
    local github, model = github_port(issue)
    testing.run_fake(department(github), ack_for(item))
    t.eq(model.reads, 1)
    t.eq(model.locks, 1)
    t.eq(model.closes, 1)
  end,

  test_changed_signal_digest_and_disabled_write_never_close = function()
    local original = signal_issue()
    local item = classified(original)
    local changed = signal_issue("A different business instruction.")
    local github, model = github_port(changed)
    testing.run_fake(department(github), ack_for(item))
    t.eq(model.closes, 0)

    local dry_github, dry_model = github_port(original)
    testing.run_fake(department(dry_github, false), ack_for(item))
    t.eq(dry_model.reads, 0)
    t.eq(dry_model.closes, 0)
  end,

  test_lost_close_response_converges_after_fresh_reread = function()
    local issue = signal_issue()
    local item = classified(issue)
    local github, model = github_port(issue, true)
    testing.run_fake(department(github), ack_for(item))
    t.eq(model.closes, 1)
    t.eq(model.reads, 2)
  end,

  test_review_terminal_ack_revalidates_latest_decision_before_close = function()
    local issue, proposal = review_issue()
    local github, model = github_port(issue)
    testing.run_fake(department(github), review_ack(issue, proposal))
    t.eq(model.closes, 1)

    local changed, changed_proposal = review_issue()
    changed.comments[#changed.comments + 1] = {
      id = 103,
      author_login = "fkst-test-bot",
      body = assert(core.render_proposal(assert(core.build_proposal({ classified(signal_issue()) }, session(), {
        action = "add",
        evidence_refs = { source_ref(11).ref },
        tweet_text = "A changed proposal revision.",
        revision = 2,
      }, {
        proposal_id = changed_proposal.proposal_id,
        content_id = changed_proposal.content_id,
        content_revision = 2,
      })))),
    }
    local stale_github, stale_model = github_port(changed)
    testing.run_fake(department(stale_github), review_ack(issue, proposal))
    t.eq(stale_model.closes, 0)
  end,

  test_reject_acks_close_review_and_signal_after_fresh_validation = function()
    local issue, proposal = review_issue("reject")
    local review_github, review_model = github_port(issue)
    testing.run_fake(department(review_github), review_ack(issue, proposal, "rejected"))
    t.eq(review_model.reads, 1)
    t.eq(review_model.locks, 1)
    t.eq(review_model.closes, 1)

    local signal = signal_issue()
    local signal_github, signal_model = github_port(signal)
    testing.run_fake(department(signal_github), ack_for(classified(signal), "rejected"))
    t.eq(signal_model.reads, 1)
    t.eq(signal_model.locks, 1)
    t.eq(signal_model.closes, 1)
  end,
}
