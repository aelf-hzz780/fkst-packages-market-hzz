local core = require("core")
local topic_policy = require("topic_policy")
local t = fkst.test

local function source_ref(number)
  local ref = "owner/repo#issue/" .. tostring(number)
  return { kind = "external", ref = ref, reference = ref }
end

local function signal_body(values)
  local fields = values or {}
  return table.concat({
    fields.contract or "contract: marketing-radar.radar-signal.v2",
    "type: radar-signal",
    "project: chronoai",
    "account: test_primary",
    "work-label: auto-x-test-primary",
    "week: 2026-W35",
    "action: add",
    fields.topic or "topic: publishing-gap",
    fields.extra or "",
  }, "\n")
end

local function classify(body, overrides)
  local values = overrides or {}
  local payload = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    labels = values.labels or { "host-session-42" },
    assignees = values.assignees or { "test-operator" },
    body = body,
    source_ref = source_ref(42),
  }
  return core.classify_issue(payload, {
    session = {
      effective_work_label = "host-session-42",
      logical_work_label = "auto-x-test-primary",
      creator = "test-operator",
      account = "test_primary",
    },
    issue_body = body,
    issue_labels = payload.labels,
    issue_assignees = payload.assignees,
  })
end

return {
  test_topic_policy_accepts_only_bounded_lower_kebab_case = function()
    for _, value in ipairs({ "publishing-gap", "mcp-v2-release", "w35-content" }) do
      local topic, why = topic_policy.validate(value)
      t.eq(topic, value)
      t.is_nil(why)
    end

    for _, value in ipairs({
      "Publishing-gap",
      "publishing gap",
      "publishing_gap",
      "-publishing-gap",
      "publishing-gap-",
      "publishing--gap",
      "发布断档",
    }) do
      local topic, why = topic_policy.validate(value)
      t.is_nil(topic)
      t.eq(why, "noncanonical-topic")
    end
  end,

  test_topic_policy_requires_a_reasonably_bounded_topic = function()
    local missing, missing_why = topic_policy.validate(nil)
    local empty, empty_why = topic_policy.validate("  ")
    local oversized, oversized_why = topic_policy.validate(
      string.rep("a", topic_policy.MAX_TOPIC_BYTES + 1))
    local wrong_type, wrong_type_why = topic_policy.validate(123)

    t.is_nil(missing)
    t.eq(missing_why, "missing-topic")
    t.is_nil(empty)
    t.eq(empty_why, "missing-topic")
    t.is_nil(oversized)
    t.eq(oversized_why, "topic-too-large")
    t.is_nil(wrong_type)
    t.eq(wrong_type_why, "noncanonical-topic")
  end,

  test_signal_classification_triages_missing_and_noncanonical_topics = function()
    local missing = assert(classify(signal_body({ topic = "" })))
    local noncanonical = assert(classify(signal_body({ topic = "topic: Publishing gap" })))
    local accepted = assert(classify(signal_body({ topic = "topic: publishing-gap" })))

    t.eq(missing.status, "needs-triage")
    t.eq(missing.triage_reason, "missing-topic")
    t.eq(noncanonical.status, "needs-triage")
    t.eq(noncanonical.triage_reason, "noncanonical-topic")
    t.eq(accepted.status, "awaiting-review")
    t.eq(accepted.topic, "publishing-gap")
  end,

  test_unfenced_loop_critic_v1_marker_gets_explicit_legacy_diagnosis = function()
    local legacy = assert(classify(signal_body({
      contract = "contract: loop-critic.radar-signal.v1",
      extra = "<!-- loop-critic:v1 source=coo -->",
    })))
    local ordinary = assert(classify(signal_body({
      contract = "contract: loop-critic.radar-signal.v1",
    })))
    local missing_contract = assert(classify(signal_body({
      contract = "",
      extra = "<!-- loop-critic:v1 -->",
    })))
    local fenced = assert(classify(signal_body({
      contract = "contract: loop-critic.radar-signal.v1",
      extra = "```html\n<!-- loop-critic:v1 source=example -->\n```",
    })))
    local other_version = assert(classify(signal_body({
      contract = "contract: loop-critic.radar-signal.v1",
      extra = "<!-- loop-critic:v10 source=coo -->",
    })))
    local unclosed = assert(classify(signal_body({
      contract = "contract: loop-critic.radar-signal.v1",
      extra = "<!-- loop-critic:v1 source=coo",
    })))

    t.eq(legacy.status, "needs-triage")
    t.eq(legacy.triage_reason, "legacy-signal-contract")
    t.eq(missing_contract.triage_reason, "legacy-signal-contract")
    t.eq(ordinary.triage_reason, "invalid-v2-contract")
    t.eq(fenced.triage_reason, "invalid-v2-contract")
    t.eq(other_version.triage_reason, "invalid-v2-contract")
    t.eq(unclosed.triage_reason, "invalid-v2-contract")
  end,

  test_legacy_diagnosis_does_not_override_existing_route_authority_priority = function()
    local body = signal_body({
      contract = "contract: loop-critic.radar-signal.v1",
      extra = "<!-- loop-critic:v1 -->",
    })
    local missing_route, route_why = classify(body, { labels = { "other" } })
    local wrong_assignee = assert(classify(body, { assignees = { "someone-else" } }))

    t.is_nil(missing_route)
    t.eq(route_why, "missing-session-work-label")
    t.eq(wrong_assignee.triage_reason, "session-creator-assignee-mismatch")
  end,
}
