local t = fkst.test

local function load(path)
  local old_pipeline = pipeline
  local module = require(path)
  pipeline = old_pipeline
  return module
end

local function contains(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then
      return true
    end
  end
  return false
end

return {
  test_departments_declare_only_explicit_namespaced_external_seams = function()
    local importer = load("departments.import_issue.main")
    local terminalizer = load("departments.issue_terminalizer.main")
    t.is_true(contains(importer.spec.consumes, "github-proxy.github_issue_changed"))
    t.is_true(contains(importer.spec.consumes, "github-proxy.github_issue_observed"))
    t.is_true(contains(importer.spec.produces, "github-proxy.github_issue_comment_request"))
    t.is_true(contains(importer.spec.produces, "github-proxy.github_issue_create_request"))
    t.is_true(contains(terminalizer.spec.consumes, "github-proxy.github_comment_written"))
    t.is_true(contains(terminalizer.spec.fanout, "github-proxy.github_comment_written"))
    for _, env_name in ipairs({
      "FKST_SESSION_CREATOR",
      "FKST_MARKETING_COLLABORATOR_LOGINS",
      "FKST_GITHUB_AUTHORIZED_LOGINS",
    }) do
      t.is_true(contains(importer.github_author_login_envs, env_name))
      t.is_true(contains(terminalizer.github_author_login_envs, env_name))
    end
  end,
}
