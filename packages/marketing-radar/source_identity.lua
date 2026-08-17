local M = {}

function M.canonical_issue_source_ref(payload)
  if type(payload) ~= "table" or type(payload.repo) ~= "string"
      or #payload.repo > 200 or payload.repo:match("^[%w_.-]+/[%w_.-]+$") == nil then
    return nil, "invalid-issue-identity"
  end
  local number = tonumber(payload.number)
  if number == nil or number < 1 or number ~= math.floor(number) then
    return nil, "invalid-issue-identity"
  end
  local ref = payload.repo .. "#issue/" .. string.format("%.0f", number)
  if payload.source_ref ~= nil then
    local supplied = payload.source_ref
    if type(supplied) ~= "table" or supplied.kind ~= "external"
        or (supplied.ref ~= nil and supplied.reference ~= nil
          and supplied.ref ~= supplied.reference)
        or (supplied.ref or supplied.reference) ~= ref then
      return nil, "source-ref-issue-identity-mismatch"
    end
  end
  return { kind = "external", ref = ref, reference = ref }, nil
end

return M
