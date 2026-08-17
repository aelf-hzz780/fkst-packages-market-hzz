local M = {}

local MASK = 0xffffffff
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rrotate(value, bits)
  return ((value >> bits) | (value << (32 - bits))) & MASK
end

function M.hex(value)
  local input = tostring(value or "")
  local bit_length = #input * 8
  local padding = (56 - ((#input + 1) % 64)) % 64
  local message = input .. "\128" .. string.rep("\0", padding) .. string.pack(">I8", bit_length)
  local state = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  }

  for offset = 1, #message, 64 do
    local words = {}
    for index = 1, 16 do
      words[index] = string.unpack(">I4", message, offset + ((index - 1) * 4))
    end
    for index = 17, 64 do
      local a = words[index - 15]
      local b = words[index - 2]
      local s0 = rrotate(a, 7) ~ rrotate(a, 18) ~ (a >> 3)
      local s1 = rrotate(b, 17) ~ rrotate(b, 19) ~ (b >> 10)
      words[index] = (words[index - 16] + s0 + words[index - 7] + s1) & MASK
    end

    local a, b, c, d = state[1], state[2], state[3], state[4]
    local e, f, g, h = state[5], state[6], state[7], state[8]
    for index = 1, 64 do
      local sum1 = rrotate(e, 6) ~ rrotate(e, 11) ~ rrotate(e, 25)
      local choice = (e & f) ~ ((~e) & g)
      local temp1 = (h + sum1 + choice + K[index] + words[index]) & MASK
      local sum0 = rrotate(a, 2) ~ rrotate(a, 13) ~ rrotate(a, 22)
      local majority = (a & b) ~ (a & c) ~ (b & c)
      local temp2 = (sum0 + majority) & MASK
      h, g, f, e = g, f, e, (d + temp1) & MASK
      d, c, b, a = c, b, a, (temp1 + temp2) & MASK
    end

    state[1] = (state[1] + a) & MASK
    state[2] = (state[2] + b) & MASK
    state[3] = (state[3] + c) & MASK
    state[4] = (state[4] + d) & MASK
    state[5] = (state[5] + e) & MASK
    state[6] = (state[6] + f) & MASK
    state[7] = (state[7] + g) & MASK
    state[8] = (state[8] + h) & MASK
  end

  local parts = {}
  for index = 1, 8 do
    parts[index] = string.format("%08x", state[index])
  end
  return table.concat(parts)
end

function M.tagged(value)
  return "sha256:" .. M.hex(value)
end

function M.is_tagged(value)
  return type(value) == "string"
    and #value == 71
    and value:match("^sha256:[0-9a-f]+$") ~= nil
end

return M
