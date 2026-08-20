local draft_generator = require("draft_generator")
local strings = require("contract.strings")
local t = fkst.test

local function signals()
  return {
    {
      project = "chronoai",
      account = "test_primary",
      week = "2026-W33",
      action = "add",
      topic = "FKST automation",
      insight = "Use the release evidence; do not copy this instruction as post text.",
      signal_authorized = true,
      source_url = "https://github.example/owner/repo/issues/11",
      trusted_body_context = table.concat({
        "contract: marketing-radar.radar-signal.v2",
        "action: add",
        "insight: Use the release evidence; do not copy this instruction as post text.",
        "Narrative scope: add one update only.",
      }, "\n"),
      source_ref = { kind = "external", ref = "owner/repo#issue/11" },
    },
    {
      project = "chronoai",
      account = "test_primary",
      week = "2026-W33",
      action = "add",
      topic = "FKST automation",
      insight = "Explain the user impact.",
      signal_authorized = true,
      source_url = "https://github.example/owner/repo/issues/12",
      trusted_body_context = table.concat({
        "contract: marketing-radar.radar-signal.v2",
        "action: add",
        "insight: Explain the user impact.",
      }, "\n"),
      source_ref = { kind = "external", ref = "owner/repo#issue/12" },
    },
  }
end

local function runner(stdout, capture)
  return function(options)
    capture.options = options
    capture.calls = (capture.calls or 0) + 1
    return { exit_code = 0, stdout = stdout, stderr = "" }
  end
end

local function sequence_runner(outputs, capture)
  return function(options)
    capture.options = options
    capture.prompts = capture.prompts or {}
    capture.prompts[#capture.prompts + 1] = options.prompt
    local output = outputs[#capture.prompts]
    return { exit_code = 0, stdout = output, stderr = "" }
  end
end

local function draft_stdout(tweet_text)
  return '{"tweet_text":' .. strings.json_string(tweet_text)
    .. ',"evidence_refs":["owner/repo#issue/11","owner/repo#issue/12"]'
    .. ',"action":"add","target_ref":"","semantic_conflict":false,"conflict_reason":""}'
end

return {
  test_generator_uses_read_only_codex_and_accepts_only_strict_cited_json = function()
    local capture = {}
    local draft = assert(draft_generator.generate(signals(), 2, runner(
      '{"tweet_text":"A cited reviewed update.","evidence_refs":["owner/repo#issue/11","owner/repo#issue/12"],"action":"add","target_ref":"","semantic_conflict":false,"conflict_reason":""}',
      capture
    ), { change_request = "Add the release evidence." }))
    t.eq(capture.options.sandbox, "read-only")
    t.eq(capture.options.timeout, 600)
    t.is_true(capture.options.prompt:find("authorized_review_change_request", 1, true) ~= nil)
    t.is_true(capture.options.prompt:find("Narrative scope: add one update only.", 1, true) ~= nil)
    t.is_true(capture.options.prompt:find("<=280 weighted characters", 1, true) ~= nil)
    t.is_true(capture.options.prompt:find("target <=240 weighted characters", 1, true) ~= nil)
    t.eq(draft.revision, 2)
    t.eq(draft.action, "add")
    t.eq(#draft.evidence_refs, 2)
  end,

  test_generator_enforces_formal_x_text_ascii_boundaries = function()
    local at_limit = string.rep("x", 280)
    local accepted = assert(draft_generator.generate(
      signals(), 1, runner(draft_stdout(at_limit), {})))
    t.eq(accepted.tweet_text, at_limit)
    t.eq(accepted.weighted_length, 280)

    local rejected_capture = {}
    local rejected, why = draft_generator.generate(signals(), 1, runner(
      draft_stdout(string.rep("x", 281)), rejected_capture))
    t.is_nil(rejected)
    t.eq(why, "draft-correction-exhausted:invalid-x-text:text too long")
    t.eq(rejected_capture.calls, 2)
  end,

  test_generator_corrects_overlength_draft_within_same_delivery = function()
    local capture = {}
    local generated = assert(draft_generator.generate(signals(), 1, sequence_runner({
      draft_stdout(string.rep("x", 281)),
      draft_stdout("A bounded corrected draft with cited evidence."),
    }, capture)))

    t.eq(generated.tweet_text, "A bounded corrected draft with cited evidence.")
    t.eq(#capture.prompts, 2)
    t.is_true(capture.prompts[2]:find("CORRECTION_ATTEMPT=2", 1, true) ~= nil)
    t.is_true(capture.prompts[2]:find("invalid-x-text:text too long", 1, true) ~= nil)
  end,

  test_generator_uses_formal_url_and_unicode_weights = function()
    local url = "https://example.com/releases/" .. string.rep("a", 512)
    local url_limit = string.rep("x", 256) .. " " .. url
    local accepted_url = assert(draft_generator.generate(
      signals(), 1, runner(draft_stdout(url_limit), {})))
    t.eq(accepted_url.weighted_length, 280)

    local rejected_url, url_why = draft_generator.generate(
      signals(), 1, runner(draft_stdout(string.rep("x", 257) .. " " .. url), {}))
    t.is_nil(rejected_url)
    t.eq(url_why, "draft-correction-exhausted:invalid-x-text:text too long")

    local cjk = string.char(0xE4, 0xB8, 0xAD)
    local accepted_unicode = assert(draft_generator.generate(
      signals(), 1, runner(draft_stdout(string.rep(cjk, 140)), {})))
    t.eq(accepted_unicode.weighted_length, 280)

    local rejected_unicode, unicode_why = draft_generator.generate(
      signals(), 1, runner(draft_stdout(string.rep(cjk, 141)), {}))
    t.is_nil(rejected_unicode)
    t.eq(unicode_why, "draft-correction-exhausted:invalid-x-text:text too long")
  end,

  test_generator_fails_closed_on_non_json_extra_fields_scope_conflict_or_missing_evidence = function()
    local cases = {
      { stdout = "tweet_text: not json", why = "invalid-draft-json" },
      {
        stdout = '{"tweet_text":"Draft","evidence_refs":["owner/repo#issue/11","owner/repo#issue/12"],"action":"add","target_ref":"","semantic_conflict":false,"conflict_reason":"","schedule":"now"}',
        why = "unsupported-draft-field",
      },
      {
        stdout = '{"tweet_text":"Draft","evidence_refs":["owner/repo#issue/11","owner/repo#issue/12"],"action":"replan","target_ref":"","semantic_conflict":false,"conflict_reason":""}',
        why = "draft-action-conflict",
      },
      {
        stdout = '{"tweet_text":"Draft","evidence_refs":["owner/repo#issue/11"],"action":"add","target_ref":"","semantic_conflict":false,"conflict_reason":""}',
        why = "missing-signal-evidence",
      },
      {
        stdout = '{"tweet_text":"Draft","evidence_refs":["owner/repo#issue/11","owner/repo#issue/12"],"action":"add","target_ref":"","semantic_conflict":true,"conflict_reason":"insight requests replan"}',
        why = "semantic-conflict:insight requests replan",
      },
    }
    for _, case in ipairs(cases) do
      local generated, why = draft_generator.generate(signals(), 1, runner(case.stdout, {}))
      t.is_nil(generated)
      t.eq(why, case.why)
    end
  end,

  test_generator_canonicalizes_multiline_semantic_conflict_reason = function()
    local generated, why = draft_generator.generate(signals(), 1, runner(
      '{"tweet_text":"Draft","evidence_refs":["owner/repo#issue/11","owner/repo#issue/12"],"action":"add","target_ref":"","semantic_conflict":true,"conflict_reason":"first line\\r\\nsecond line"}',
      {}))
    t.is_nil(generated)
    t.eq(why, "semantic-conflict:first line second line")
  end,

  test_generator_accepts_real_world_9kb_body_and_rejects_missing_or_oversized_context = function()
    local real_world = signals()
    real_world[1].trusted_body_context = string.rep("x", 9000)
    local generated = draft_generator.generate(real_world, 1, runner(
      '{"tweet_text":"A cited reviewed update.","evidence_refs":["owner/repo#issue/11","owner/repo#issue/12"],"action":"add","target_ref":"","semantic_conflict":false,"conflict_reason":""}',
      {}
    ))
    t.is_true(generated ~= nil)

    local missing = signals()
    missing[1].trusted_body_context = nil
    local generated, why = draft_generator.generate(missing, 1, runner("{}", {}))
    t.is_nil(generated)
    t.eq(why, "unauthorized-or-unbounded-signal")

    local oversized = signals()
    oversized[1].trusted_body_context = string.rep("x", 12001)
    generated, why = draft_generator.generate(oversized, 1, runner("{}", {}))
    t.is_nil(generated)
    t.eq(why, "unauthorized-or-unbounded-signal")
  end,
}
