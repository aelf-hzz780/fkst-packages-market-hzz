local core = require("core")
local marketing_content = require("contract.marketing_content")
local marketing_schedule = require("contract.marketing_schedule")
local session_route = require("contract.session_route")
local sha256 = require("contract.sha256")
local v2 = require("tests.fixtures.v2_publish")
local t = fkst.test

local DIGEST = "sha256:" .. string.rep("a", 64)

local function request(overrides)
  local payload = {
    schema = "x-publisher.publish-request.v2",
    account = v2.ACCOUNT,
    work_label = v2.LOGICAL_LABEL,
    artifact_id = "auto-twitter/test-project/test-primary/2026-W33/schedule/42",
    source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
      reference = "owner/repo#issue/42",
    },
    content_ref = "#41",
    content_digest = DIGEST,
    schedule_digest = "sha256:" .. string.rep("b", 64),
    platform = "x",
    channel = "shadow",
    dedup_key = "auto-twitter/test-project/test-primary/2026-W33/schedule/42/preview",
    trace_id = "trace-test-primary-42",
    approval_id = "proposal-test-primary-w33@1",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

return {
  test_sha256_uses_canonical_lowercase_hex = function()
    t.eq(sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    t.eq(sha256.tagged("abc"), "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    t.eq(sha256.is_tagged("sha256:" .. string.rep("0", 64)), true)
    t.eq(sha256.is_tagged("SHA256:" .. string.rep("0", 64)), false)
  end,

  test_v2_publish_request_requires_account_route_and_approval_contract = function()
    t.eq(core.validate_publish_request(request()), true)

    for _, field in ipairs({
      "schema",
      "account",
      "work_label",
      "content_ref",
      "content_digest",
      "schedule_digest",
      "dedup_key",
      "trace_id",
      "approval_id",
      "channel",
    }) do
      local payload = request({ [field] = false })
      payload[field] = nil
      local ok = core.validate_publish_request(payload)
      t.eq(ok, false)
    end

    t.eq(core.validate_publish_request(request({ schema = "x-publisher.x-published.v1" })), false)
    t.eq(core.validate_publish_request(request({ account = "@TEST_PRIMARY" })), false)
    t.eq(core.validate_publish_request(request({ content_digest = "digest-1" })), false)
  end,

  test_receipts_preserve_v2_account_content_and_approval_identity = function()
    local receipt = core.preview_receipt(request())
    t.eq(receipt.schema, "x-publisher.publish-receipt.v2")
    t.eq(receipt.account, v2.ACCOUNT)
    t.eq(receipt.work_label, v2.LOGICAL_LABEL)
    t.eq(receipt.content_digest, DIGEST)
    t.eq(receipt.approval_id, "proposal-test-primary-w33@1")
    t.is_nil(receipt.authenticated_account)
  end,

  test_session_route_reverses_host_label_map_and_rejects_ambiguity = function()
    local route = assert(session_route.resolve(
      v2.EFFECTIVE_LABEL,
      v2.WORK_LABEL_MAP_JSON
    ))
    t.eq(route.logical_label, v2.LOGICAL_LABEL)
    t.eq(route.effective_label, v2.EFFECTIVE_LABEL)
    t.eq(session_route.has_label({ "other", route.effective_label }, route.effective_label), true)
    t.eq(session_route.single_assignee({ v2.CREATOR }), v2.CREATOR)
    t.is_nil(session_route.single_assignee({}))
    t.is_nil(session_route.resolve("same", '{"a":"same","b":"same"}'))
  end,

  test_marketing_content_round_trip_binds_approved_text_to_digest = function()
    local body, digest = marketing_content.render({
      project = v2.PROJECT,
      account = v2.ACCOUNT,
      work_label = v2.LOGICAL_LABEL,
      week = "2026-W33",
      content_id = "test-primary-w33-1",
      content_revision = 1,
      proposal_id = "proposal-test-primary-w33",
      proposal_revision = 2,
      approval_id = "proposal-test-primary-w33@2",
      content_status = "approved",
      tweet_text = "A reviewed test-primary post.",
    })
    local parsed, why = marketing_content.parse(body)
    t.is_nil(why)
    t.eq(parsed.content_digest, digest)
    t.eq(parsed.account, v2.ACCOUNT)
    t.eq(parsed.tweet_text, "A reviewed test-primary post.")

    local tampered = body:gsub("A reviewed test%-primary post", "An unreviewed replacement")
    local invalid, invalid_why = marketing_content.parse(tampered)
    t.is_nil(invalid)
    t.eq(invalid_why, "content digest mismatch")

    local fenced_text = table.concat({
      "A reviewed post with literal Markdown.",
      "```",
      "operation: quote",
      "quote-mode: native",
      "account: another_account",
      "```trailing text",
    }, "\n")
    local fenced_body, fenced_digest = marketing_content.render({
      project = v2.PROJECT,
      account = v2.ACCOUNT,
      work_label = v2.LOGICAL_LABEL,
      week = "2026-W33",
      content_id = "test-primary-w33-fenced",
      content_revision = 1,
      proposal_id = "proposal-test-primary-w33-fenced",
      proposal_revision = 1,
      approval_id = "proposal-test-primary-w33-fenced@1",
      content_status = "approved",
      tweet_text = fenced_text,
    })
    local fenced_parsed = assert(marketing_content.parse(fenced_body))
    local publish_intent = assert(core.extract_publish_intent(fenced_body))
    t.eq(fenced_parsed.content_digest, fenced_digest)
    t.eq(fenced_parsed.tweet_text, fenced_text)
    t.eq(publish_intent.operation, "post")
    t.eq(publish_intent.text, fenced_text)
  end,

  test_v2_content_requires_explicit_contract_identity = function()
    local body = assert(marketing_content.render({
      project = "example-project",
      account = "test_primary",
      work_label = "auto-x-test-primary",
      week = "2026-W33",
      content_id = "example-w33-1",
      content_revision = 1,
      proposal_id = "proposal-example-w33",
      proposal_revision = 2,
      approval_id = "proposal-example-w33@2",
      content_status = "approved",
      tweet_text = "A reviewed test post.",
    }))
    local missing_contract = body:gsub("contract:[^\n]*\n", "", 1)
    local missing_type = body:gsub("type:[^\n]*\n", "", 1)

    local parsed_contract, contract_why = marketing_content.parse(missing_contract)
    local parsed_type, type_why = marketing_content.parse(missing_type)
    t.is_nil(parsed_contract)
    t.eq(contract_why, "missing content contract identity")
    t.is_nil(parsed_type)
    t.eq(type_why, "missing content contract identity")
  end,

  test_v2_schedule_rejects_controls_from_another_schedule_type = function()
    local base = table.concat({
      "contract: auto-twitter-marketing.schedule-publish.v2",
      "type: schedule-publish",
      "project: example-project",
      "account: test_primary",
      "work-label: auto-x-test-primary",
      "week: 2026-W33",
      "content-ref: #41",
      "content-digest: " .. DIGEST,
      "approval-id: proposal-example-w33@2",
      "mode: shadow",
      "scheduled-at: 2026-08-17T00:00:00Z",
    }, "\n")
    local parsed, why = marketing_schedule.parse(base .. "\ntime: 10:00")
    t.is_nil(parsed)
    t.eq(why, "invalid one-shot schedule")
  end,
}
