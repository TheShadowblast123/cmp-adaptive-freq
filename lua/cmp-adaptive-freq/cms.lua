local bit = require("bit")
local band, bor, lshift, rshift, bnot = bit.band, bit.bor, bit.lshift, bit.rshift, bit.bnot
---@alias hash_param { a: number, b: number, P: number }
---@class CMS
---@field width number
---@field depth number
---@field counter_bits number
---@field hash_params hash_param[]
---@field rows table<number, table<number, number>> row -> [byte_index] = byte
local CMS = {}
CMS.__index = CMS

local FIXED_WIDTH = 33554432
local FIXED_DEPTH = 8
local MASK = FIXED_WIDTH - 1     -- width is power-of-two -> mask for modulo
local DEFAULT_MAX = 2^31 - 1     -- saturate counters here by default

local function splitmix32(x)
  -- keep x in 32-bit unsigned space
  x = (x + 0x9E3779B1) % 2^32
  x = band(x, 0xffffffff)
  x = bit.bxor(x, rshift(x, 15))
  x = (x * 0x85ebca6b) % 2^32
  x = bit.bxor(x, rshift(x, 13))
  x = (x * 0xc2b2ae35) % 2^32
  x = bit.bxor(x, rshift(x, 16))
  return band(x, 0xffffffff)
end

-- combine key with row index to produce per-row hash
local function hash_for_row(key, row)
  -- key assumed to be a non-negative integer (word id). row is 1..depth.
  -- mixing: incorporate row to get independent hashes per row
  -- small tweak: add row*0x9e3779b1 to diversify seeds
  local seed = (row * 0x9E3779B1) % 2^32
  local v = (key + seed) % 2^32
  return splitmix32(v)
end

---@param depth number   — number of hash functions (rows)
---@param width number   — counters per row
---@param counter_bits number — bits per counter (1, 2, or 8)
---@return CMS
function CMS.new(depth, width, counter_bits, serialize)
	---@type CMS
	local self = setmetatable({}, CMS)
	self.depth = FIXED_DEPTH
	self.width = FIXED_WIDTH
	self.max_count = DEFAULT_MAX

	self.serialize = function ()
		return {
			self.depth,
			self.width,
			32,
			self.rows
		}
	end

	---@type table<number, table<number, number>>
	self.rows = {}

	for r = 1, self.depth do
		local row = {}
		for i = 1, self.width do 
			row[i] = 0 
		end
		self.rows[r] = row
	end
	return self
end




-- @param self CMS
-- @param row number      — which hash row (1..depth)
-- @param key number      — (e.g. word_id)
-- @return number idx     — bucket index in [1..width]
function CMS:hash(row, key)
	---@type hash_param p
	local p = self.hash_params[row]
	-- ((a * key + b) mod P) mod width +1 for 1-based Lua table
	local idx = ((p.a * key + p.b) % p.P) % self.width + 1
	return idx
end

---@param self CMS
---@param key number
function CMS:increment(key, delta)
	delta = delta or 1
	-- defensive: ensure key is integer-like
	local k = math.floor(key)
	for r = 1, self.depth do
		local h = hash_for_row(k, r)
		local idx = band(h, MASK) + 1         -- 1-based index
		local cur = self.rows[r][idx] or 0
		local nv = cur + delta
		if nv > self.max_count then nv = self.max_count end
		self.rows[r][idx] = nv
	end
end

---@param self CMS
---@param key number
---@return number count — estimated count
function CMS:estimate(key)
	local k = math.floor(key)
	local best = math.huge
	for r = 1, self.depth do
		local h = hash_for_row(k, r)
		local idx = band(h, MASK) + 1
		local v = self.rows[r][idx] or 0
		if v < best then
			best = v 
		end
	end
	if best == math.huge then 
		return 0
	end
	return best
end

return CMS