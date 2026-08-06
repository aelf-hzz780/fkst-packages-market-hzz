local t = fkst.test
local contract = require("contract.x_publishing_contract")
local core = require("core")
local fixtures = require("tests.fixtures.x_publishing_conformance")

local function assert_expected(actual, expected, path)
  local location = path or "result"
  for key, expected_value in pairs(expected or {}) do
    local actual_value = actual and actual[key]
    if type(expected_value) == "table" then
      t.eq(type(actual_value), "table", location .. "." .. tostring(key) .. " type")
      assert_expected(actual_value, expected_value, location .. "." .. tostring(key))
    else
      t.eq(actual_value, expected_value, location .. "." .. tostring(key))
    end
  end
end

local function nyxid_write_count()
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    local rendered = tostring(call.rendered or call.command or call.cmd or "")
    if rendered:find("nyxid proxy request", 1, true) then
      count = count + 1
    end
  end
  return count
end

local tests = {
  test_generated_contract_metadata_matches_fixture_catalog = function()
    t.eq(contract.metadata.contract_version, fixtures.contractVersion)
    t.eq(contract.metadata.source_sha256, fixtures.sourceSha256)
    t.eq(contract.metadata.generator_version, fixtures._generated.generatorVersion)
    t.eq(contract.consumer_capabilities["fkst-x-publisher"].operations[1], "post")
    t.eq(contract.consumer_capabilities["fkst-x-publisher"].operations[2], "quote")
  end,
  test_issue_adapter_preserves_legacy_keys_without_duplicate_link = function()
    local intent, why = core.extract_publish_intent([[
operation: quote
quote-mode: link
quote-url: https://twitter.com/example/status/3234567890123456789?source=fkst
tweet: Already linked https://x.com/example/status/3234567890123456789
]])

    t.eq(why, nil)
    t.eq(intent.operation, "quote")
    t.eq(intent.quote_post.mode, "link")
    t.eq(intent.publish_text,
      "Already linked https://x.com/example/status/3234567890123456789")
  end,
  test_receipts_add_canonical_fields_without_removing_legacy_fields = function()
    local intent = assert(core.extract_publish_intent(
      "operation: quote\nquote-mode: native\nquote-url: https://x.com/a/status/123\ntweet: Commentary"))
    local receipt = core.live_receipt({ trace_id = "trace-receipt" }, {
      id = "456",
      intent = intent,
    })

    t.eq(receipt.quote_mode, "native")
    t.eq(receipt.quote_target_uri, "https://x.com/a/status/123")
    t.eq(receipt.quote_target_post_id, "123")
    t.eq(receipt.quoteMode, "native")
    t.eq(receipt.quoteTargetUrl, "https://x.com/a/status/123")
    t.eq(receipt.quoteTargetPostId, "123")
    t.eq(receipt.traceId, "trace-receipt")
  end,
  test_blocked_receipt_uses_stable_error_and_correlation_fallback = function()
    local receipt = core.blocked_receipt({ artifact_id = "artifact-fallback" },
      "nyxid access token missing")

    t.eq(receipt.status, "blocked")
    t.eq(receipt.error_code, "unsupported_capability")
    t.eq(receipt.errorCode, "unsupported_capability")
    t.eq(receipt.trace_id, "artifact-fallback")
    t.eq(receipt.traceId, "artifact-fallback")
  end,
  test_contract_evaluator_rejects_credential_bearing_or_unknown_fields = function()
    local credential_field = "access" .. "Token"
    local result = core.evaluate_contract_request({
      operation = "post",
      text = "Safe fixture text",
      idempotencyKey = "fixture-sensitive-field",
      traceId = "trace-sensitive-field",
      [credential_field] = "fixture-value",
    })

    t.eq(result.status, "blocked")
    t.eq(result.errorCode, "invalid_request")
    t.eq(result.traceId, "trace-sensitive-field")
  end,
}

for _, item in ipairs(fixtures.cases) do
  local fixture = item
  tests["test_contract_fixture_" .. fixture.id] = function()
    local before = nyxid_write_count()
    local result = core.evaluate_contract_request(fixture.request, {
      adapter_capabilities = fixture.adapterCapabilities,
      provider_result = fixture.providerResult,
    })

    assert_expected(result, fixture.expected, fixture.id)
    if fixture.expected.status == "blocked" and fixture.id ~= "native_provider_failure" then
      t.eq(nyxid_write_count(), before, fixture.id .. " must not call NyxID")
    end
  end
end

return tests
