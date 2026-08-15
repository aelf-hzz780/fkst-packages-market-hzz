local t = fkst.test
local timeline = require("x_timeline_reconciliation")

local NOW = 1786838400 -- 2026-08-16T00:00:00Z

local function reconcile_window()
  return assert(timeline.reconciliation_window({
    scheduled_at = "2026-08-15T00:00:00Z",
  }, NOW))
end

local function post(id, text, opts)
  local options = opts or {}
  return {
    id = tostring(id),
    text = text,
    created_at = options.created_at or "2026-08-15T23:00:00.000Z",
    entities = options.entities,
    referenced_tweets = options.referenced_tweets,
  }
end

return {
  test_account_response_requires_numeric_id_and_username = function()
    local account = assert(timeline.parse_account_response(
      '{"data":{"id":"100000000000000001","username":"example_user"}}'
    ))

    t.eq(account.id, "100000000000000001")
    t.eq(account.username, "example_user")
    t.is_nil(timeline.parse_account_response('{"data":{"id":"bad","username":"example_user"}}'))
    t.is_nil(timeline.parse_account_response('{"data":{"id":"0123","username":"example_user"}}'))
    t.is_nil(timeline.parse_account_response('{"data":{"id":"12345678901234567890","username":"example_user"}}'))
    t.is_nil(timeline.parse_account_response('{"data":{"id":"123","username":""}}'))
    t.is_nil(timeline.parse_account_response("not-json"))
  end,

  test_window_requires_scheduled_at_and_bounds_its_age = function()
    local scheduled = assert(timeline.reconciliation_window({
      scheduled_at = "2026-08-15T08:00:00+08:00",
    }, NOW))

    t.eq(scheduled.start_time, "2026-08-15T00:00:00Z")
    t.eq(scheduled.start_epoch, 1786752000)
    t.eq(scheduled.end_epoch, NOW)
    t.is_nil(timeline.reconciliation_window({}, NOW))
    t.is_nil(timeline.reconciliation_window({ scheduled_at = "bad" }, NOW))
    t.is_nil(timeline.reconciliation_window({
      scheduled_at = "2026-07-01T00:00:00Z",
    }, NOW))
  end,

  test_window_preserves_existing_schedule_timestamp_compatibility = function()
    for _, scheduled_at in ipairs({
      "2026-08-15T00:00Z",
      "2026-08-15t00:00:00Z",
      "2026-08-15 08:00:00+08:00",
      "2026-08-15T08:00:00+0800",
      "2026-08-15T08:00:00Asia/Shanghai",
      "2026-08-15T08:00:00Asia/Chongqing",
      "2026-08-15T00:00:00UTC",
      "2026-08-15T00:00:00Etc/UTC",
      "2026-08-15T00:00:00",
    }) do
      local window = assert(timeline.reconciliation_window({
        scheduled_at = scheduled_at,
      }, NOW))
      t.eq(window.start_epoch, 1786752000)
      t.eq(window.start_time, "2026-08-15T00:00:00Z")
    end
  end,

  test_timeline_path_is_bounded_and_encodes_pagination_token = function()
    t.eq(timeline.timeline_path(
      "100000000000000001",
      "2026-08-15T00:00:00Z",
      "token+/="
    ), "/users/100000000000000001/tweets"
      .. "?exclude=retweets%2Creplies"
      .. "&max_results=100"
      .. "&start_time=2026-08-15T00%3A00%3A00Z"
      .. "&tweet.fields=created_at%2Centities%2Creferenced_tweets"
      .. "&pagination_token=token%2B%2F%3D")
    t.is_nil(timeline.timeline_path("bad", "2026-08-15T00:00:00Z"))
  end,

  test_timeline_page_parser_accepts_empty_and_paginated_pages = function()
    local empty = assert(timeline.parse_timeline_page('{"meta":{"result_count":0}}'))
    local page = assert(timeline.parse_timeline_page([[
      {
        "data":[{
          "id":"2087450477755863434",
          "text":"published text",
          "created_at":"2026-08-15T23:00:00.000Z"
        }],
        "meta":{"result_count":1,"next_token":"abc123"}
      }
    ]]))

    t.eq(#empty.posts, 0)
    t.eq(#page.posts, 1)
    t.eq(page.next_token, "abc123")
    t.is_nil(timeline.parse_timeline_page('{"errors":[{"detail":"forbidden"}]}'))
    t.is_nil(timeline.parse_timeline_page('{"data":[{"id":"bad"}],"meta":{}}'))
    t.is_nil(timeline.parse_timeline_page("not-json"))
  end,

  test_timeline_page_parser_rejects_problem_json_and_invalid_result_shapes = function()
    local valid_post = '{"id":"2087450477755863434","text":"ok",'
      .. '"created_at":"2026-08-15T23:00:00.000Z"}'

    t.is_nil(timeline.parse_timeline_page('{}'))
    t.is_nil(timeline.parse_timeline_page('{"status":503,"title":"Service Unavailable"}'))
    t.is_nil(timeline.parse_timeline_page('{"meta":{"result_count":-1}}'))
    t.is_nil(timeline.parse_timeline_page('{"meta":{"result_count":1.5}}'))
    t.is_nil(timeline.parse_timeline_page('{"meta":{"result_count":101}}'))
    t.is_nil(timeline.parse_timeline_page('{"data":[' .. valid_post
      .. '],"meta":{"result_count":0}}'))
    t.is_nil(timeline.parse_timeline_page('{"data":{},"meta":{"result_count":1}}'))
    t.is_nil(timeline.parse_timeline_page('{"data":[null,' .. valid_post
      .. '],"meta":{"result_count":2}}'))
    t.is_nil(timeline.parse_timeline_page('{"data":['
      .. '{"id":"12345678901234567890","text":"ok",'
      .. '"created_at":"2026-08-15T23:00:00.000Z"}'
      .. '],"meta":{"result_count":1}}'))
  end,

  test_timeline_page_keeps_provider_created_at_strict = function()
    for _, created_at in ipairs({
      "2026-08-15T23:00Z",
      "2026-08-15t23:00:00Z",
      "2026-08-15 23:00:00Z",
      "2026-08-15T23:00:00",
    }) do
      t.is_nil(timeline.parse_timeline_page('{"data":[{'
        .. '"id":"2087450477755863434","text":"ok","created_at":"'
        .. created_at .. '"}],"meta":{"result_count":1}}'))
    end
  end,

  test_plain_post_matches_canonical_text_and_time_window = function()
    local window = reconcile_window()
    local matches = assert(timeline.matching_post_ids({
      post("101", "Other text"),
      post("102", "Expected text"),
      post("103", "Expected text", { created_at = "2026-08-14T23:59:59.000Z" }),
    }, {
      operation = "post",
      publish_text = "Expected text",
    }, window))

    t.eq(#matches, 1)
    t.eq(matches[1], "102")
  end,

  test_plain_post_does_not_recover_same_text_quote = function()
    local matches = assert(timeline.matching_post_ids({ post(
      "104",
      "Expected text",
      { referenced_tweets = {{ type = "quoted", id = "777" }} }
    ) }, {
      operation = "post",
      publish_text = "Expected text",
    }, reconcile_window()))

    t.eq(#matches, 0)
  end,

  test_url_entities_restore_the_original_publish_text = function()
    local window = reconcile_window()
    local matches = assert(timeline.matching_post_ids({ post(
      "201",
      "Read https://t.co/short",
      {
        entities = {
          urls = {{
            url = "https://t.co/short",
            expanded_url = "https://example.com/articles/one",
          }},
        },
      }
    ) }, {
      operation = "post",
      publish_text = "Read https://example.com/articles/one",
    }, window))

    t.eq(#matches, 1)
    t.eq(matches[1], "201")
  end,

  test_repeated_url_entities_replace_one_occurrence_each = function()
    local matches = assert(timeline.matching_post_ids({ post(
      "205",
      "One https://t.co/repeated Two https://t.co/repeated",
      {
        entities = {
          urls = {
            {
              url = "https://t.co/repeated",
              expanded_url = "https://example.com/repeated",
            },
            {
              url = "https://t.co/repeated",
              expanded_url = "https://example.com/repeated",
            },
          },
        },
      }
    ) }, {
      operation = "post",
      publish_text = "One https://example.com/repeated Two https://example.com/repeated",
    }, reconcile_window()))

    t.eq(#matches, 1)
    t.eq(matches[1], "205")
  end,

  test_status_url_requires_a_complete_numeric_path_segment = function()
    local matches = assert(timeline.matching_post_ids({ post(
      "203",
      "Read https://t.co/short",
      {
        entities = {
          urls = {{
            url = "https://t.co/short",
            expanded_url = "https://x.com/example/status/777evil",
          }},
        },
      }
    ) }, {
      operation = "post",
      publish_text = "Read https://x.com/i/web/status/777",
    }, reconcile_window()))

    t.eq(#matches, 0)
  end,

  test_malformed_url_entity_fails_closed = function()
    local matches, why = timeline.matching_post_ids({ post(
      "202",
      "Read https://t.co/short",
      {
        entities = {
          urls = {{
            url = "https://t.co/short",
          }},
        },
      }
    ) }, {
      operation = "post",
      publish_text = "Read https://example.com/articles/one",
    }, reconcile_window())

    t.is_nil(matches)
    t.eq(why, "invalid timeline url entity")
  end,

  test_t_co_text_without_url_entity_evidence_fails_closed = function()
    local matches, why = timeline.matching_post_ids({ post(
      "204",
      "Read https://t.co/short"
    ) }, {
      operation = "post",
      publish_text = "Read https://example.com/articles/one",
    }, reconcile_window())

    t.is_nil(matches)
    t.eq(why, "incomplete timeline url evidence")
  end,

  test_native_quote_matches_appended_entity_and_quote_target = function()
    local window = reconcile_window()
    local matches = assert(timeline.matching_post_ids({ post(
      "301",
      "Native commentary https://t.co/quote",
      {
        entities = {
          urls = {{
            url = "https://t.co/quote",
            expanded_url = "https://twitter.com/example_user/status/777",
          }},
        },
        referenced_tweets = {{ type = "quoted", id = "777" }},
      }
    ) }, {
      operation = "quote",
      text = "Native commentary",
      publish_text = "Native commentary",
      quote_post = {
        mode = "native",
        provider_post_id = "777",
        url = "https://x.com/example/status/777",
      },
    }, window))

    t.eq(#matches, 1)
    t.eq(matches[1], "301")
  end,

  test_quote_validates_all_reference_evidence_before_matching = function()
    local matches, why = timeline.matching_post_ids({ post(
      "305",
      "Native commentary",
      {
        referenced_tweets = {
          { type = "quoted", id = "777" },
          { type = "quoted" },
        },
      }
    ) }, {
      operation = "quote",
      text = "Native commentary",
      publish_text = "Native commentary",
      quote_post = {
        mode = "native",
        provider_post_id = "777",
        url = "https://x.com/example/status/777",
      },
    }, reconcile_window())

    t.is_nil(matches)
    t.eq(why, "invalid timeline quote evidence")
  end,

  test_quote_requires_the_expected_referenced_post = function()
    local window = reconcile_window()
    local matches = assert(timeline.matching_post_ids({ post(
      "302",
      "Native commentary https://t.co/quote",
      {
        entities = {
          urls = {{
            url = "https://t.co/quote",
            expanded_url = "https://twitter.com/example/status/888",
          }},
        },
        referenced_tweets = {{ type = "quoted", id = "888" }},
      }
    ) }, {
      operation = "quote",
      text = "Native commentary",
      publish_text = "Native commentary",
      quote_post = {
        mode = "native",
        provider_post_id = "777",
        url = "https://x.com/example/status/777",
      },
    }, window))

    t.eq(#matches, 0)
  end,

  test_matching_quote_text_without_reference_evidence_fails_closed = function()
    local intent = {
      operation = "quote",
      text = "Native commentary",
      publish_text = "Native commentary",
      quote_post = {
        mode = "native",
        provider_post_id = "777",
        url = "https://x.com/example/status/777",
      },
    }

    local missing, missing_why = timeline.matching_post_ids({ post(
      "303",
      "Native commentary"
    ) }, intent, reconcile_window())
    t.is_nil(missing)
    t.eq(missing_why, "incomplete timeline quote evidence")

    local malformed, malformed_why = timeline.matching_post_ids({ post(
      "304",
      "Native commentary",
      { referenced_tweets = {{ type = "quoted" }} }
    ) }, intent, reconcile_window())
    t.is_nil(malformed)
    t.eq(malformed_why, "invalid timeline quote evidence")
  end,

  test_link_quote_matches_canonical_target_after_t_co_expansion = function()
    local window = reconcile_window()
    local matches = assert(timeline.matching_post_ids({ post(
      "401",
      "Link commentary\n\nhttps://t.co/quote",
      {
        entities = {
          urls = {{
            url = "https://t.co/quote",
            expanded_url = "https://twitter.com/example/status/777?source=fkst",
          }},
        },
        referenced_tweets = {{ type = "quoted", id = "777" }},
      }
    ) }, {
      operation = "quote",
      text = "Link commentary",
      publish_text = "Link commentary\n\nhttps://x.com/example/status/777",
      quote_post = {
        mode = "link",
        provider_post_id = "777",
        url = "https://x.com/example/status/777",
      },
    }, window))

    t.eq(#matches, 1)
    t.eq(matches[1], "401")
  end,

  test_duplicate_matching_posts_remain_ambiguous = function()
    local window = reconcile_window()
    local matches = assert(timeline.matching_post_ids({
      post("501", "Repeated text"),
      post("502", "Repeated text"),
    }, {
      operation = "post",
      publish_text = "Repeated text",
    }, window))

    t.eq(#matches, 2)
  end,
}
