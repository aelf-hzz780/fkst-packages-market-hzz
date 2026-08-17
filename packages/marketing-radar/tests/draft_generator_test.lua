local draft_generator = require("draft_generator")
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
    return { exit_code = 0, stdout = stdout, stderr = "" }
  end
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
    t.eq(draft.revision, 2)
    t.eq(draft.action, "add")
    t.eq(#draft.evidence_refs, 2)
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

  test_generator_rejects_missing_or_oversized_trusted_body_context = function()
    local missing = signals()
    missing[1].trusted_body_context = nil
    local generated, why = draft_generator.generate(missing, 1, runner("{}", {}))
    t.is_nil(generated)
    t.eq(why, "unauthorized-or-unbounded-signal")

    local oversized = signals()
    oversized[1].trusted_body_context = string.rep("x", 8001)
    generated, why = draft_generator.generate(oversized, 1, runner("{}", {}))
    t.is_nil(generated)
    t.eq(why, "unauthorized-or-unbounded-signal")
  end,
}
