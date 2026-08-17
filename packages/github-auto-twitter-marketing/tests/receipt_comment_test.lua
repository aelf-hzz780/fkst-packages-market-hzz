local testing = require("testkit.testing")
local t = fkst.test

local repo = "owner/repo"
local account = "test_primary"
local work_label = "auto-x-test-primary"
local digest = "sha256:" .. string.rep("a", 64)

local function source_ref(number)
  local ref = repo .. "#issue/" .. tostring(number or 62)
  return { kind = "external", ref = ref, reference = ref }
end

local function receipt(overrides)
  local value = {
    schema = "x-publisher.publish-receipt.v2",
    artifact_id = "auto-twitter-marketing/test_primary/chronoai/2026-W33/schedule",
    status = "published",
    platform = "x",
    platform_post_id = "1234567890",
    post_uri = "https://x.com/i/web/status/1234567890",
    account = account,
    authenticated_account = account,
    work_label = work_label,
    content_ref = "#61",
    content_digest = digest,
    approval_id = "proposal-w33@2",
    channel = "live",
    dedup_key = "auto-twitter-marketing/test_primary/chronoai/2026-W33/schedule/62/occurrence/x-publish",
    trace_id = "trace-published-one-shot",
    scheduled_at = "2026-08-17T00:00:00Z",
    metadata = { schedule_type = "one-shot" },
    source_ref = source_ref(),
  }
  for key, child in pairs(overrides or {}) do
    value[key] = child
  end
  return value
end

local function run(payload)
  local module = require("departments.optional_receipt_sink.main")
  return testing.run_fake(module, {
    queue = "x-publisher.x_published",
    payload = payload,
  })
end

local function request_for_issue(result, issue_number)
  for _, raised in ipairs(result.raises) do
    if raised.payload.issue_number == issue_number then
      return raised.payload
    end
  end
  return nil
end

local function expected_request_count(payload)
  local post_id = tostring(payload.platform_post_id or "")
  local anchored = payload.status == "published"
    and payload.platform == "x"
    and payload.channel == "live"
    and payload.content_ref ~= nil
    and payload.authenticated_account == payload.account
    and post_id:match("^%d+$") ~= nil
    and payload.post_uri == "https://x.com/i/web/status/" .. post_id
  return anchored and 2 or 1
end

return {
  test_published_v2_receipt_persists_account_digest_approval_and_close_handoff = function()
    local result = run(receipt())
    t.eq(#result.raises, 2)
    local schedule_request = assert(request_for_issue(result, 62))
    local content_request = assert(request_for_issue(result, 61))
    t.eq(schedule_request.repo, repo)
    t.is_nil(schedule_request.handoff)
    t.is_true(schedule_request.body:find("account: " .. account, 1, true) ~= nil)
    t.is_true(schedule_request.body:find("authenticated_account: " .. account, 1, true) ~= nil)
    t.is_true(schedule_request.body:find("content_digest: " .. digest, 1, true) ~= nil)
    t.is_true(schedule_request.body:find("approval_id: proposal-w33@2", 1, true) ~= nil)
    t.eq(content_request.body, schedule_request.body)
    t.eq(content_request.handoff.schema, "auto-twitter-marketing.one-shot-close.v2")
    t.eq(content_request.handoff.account, account)
    t.eq(content_request.handoff.authenticated_account, account)
    t.eq(content_request.handoff.work_label, work_label)
    t.eq(content_request.handoff.content_digest, digest)
    t.eq(content_request.handoff.approval_id, "proposal-w33@2")
    t.eq(content_request.handoff.receipt_anchor_ref.ref, repo .. "#issue/61")
    t.eq(content_request.handoff.source_ref.ref, repo .. "#issue/62")
    t.is_true(content_request.dedup_key ~= receipt().dedup_key
      .. "/status/x-publish-published")
    t.is_true(content_request.body:find(
      "<!-- fkst:github-proxy:comment:" .. receipt().dedup_key
        .. "/status/x-publish-published -->", 1, true) ~= nil)
  end,

  test_blocked_preview_and_recurring_receipts_comment_but_never_close = function()
    local cases = {
      receipt({
        status = "blocked",
        blocked_reason = "content digest mismatch",
        publish_attempted = false,
        platform_post_id = nil,
        post_uri = nil,
      }),
      receipt({ status = "preview", platform_post_id = nil, post_uri = nil, channel = "shadow" }),
      receipt({ metadata = { schedule_type = "daily" } }),
      receipt({ authenticated_account = "test_secondary" }),
    }
    for _, payload in ipairs(cases) do
      local result = run(payload)
      t.eq(#result.raises, expected_request_count(payload))
      for _, raised in ipairs(result.raises) do
        t.is_nil(raised.payload.handoff)
      end
      if payload.status == "blocked" then
        t.is_true(result.raises[1].payload.body:find("publish_attempted: false", 1, true) ~= nil)
      end
    end
  end,

  test_published_handoff_requires_complete_v2_correlation_and_canonical_post = function()
    for _, field in ipairs({ "account", "work_label", "content_digest", "approval_id" }) do
      local payload = receipt()
      payload[field] = nil
      local result = run(payload)
      t.eq(#result.raises, 0)
    end
    for _, field in ipairs({
      "authenticated_account",
      "content_ref",
      "scheduled_at",
      "trace_id",
      "platform_post_id",
      "post_uri",
    }) do
      local payload = receipt()
      payload[field] = nil
      local result = run(payload)
      t.eq(#result.raises, expected_request_count(payload))
      for _, raised in ipairs(result.raises) do
        t.is_nil(raised.payload.handoff)
      end
    end
    local wrong_uri = run(receipt({ post_uri = "https://x.com/i/web/status/999" }))
    t.eq(#wrong_uri.raises, 1)
    t.is_nil(wrong_uri.raises[1].payload.handoff)
  end,

  test_v1_or_unknown_receipts_are_rejected_instead_of_dual_written = function()
    for _, schema in ipairs({ "x-publisher.x-published.v1", "unknown.v2", nil }) do
      local payload = receipt({ schema = schema or false })
      if schema == nil then
        payload.schema = nil
      end
      local result = run(payload)
      t.eq(#result.raises, 0)
    end
  end,
}
