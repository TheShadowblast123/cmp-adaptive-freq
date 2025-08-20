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

local FIXED_WIDTH = 512
local FIXED_DEPTH = 8
local MASK = FIXED_WIDTH - 1     -- width is power-of-two -> mask for modulo
local DEFAULT_MAX = 2^31 - 1     -- saturate counters here by default
local MASKS = {
    [16] = 0xFFFF,
    [32] = 0xFFFFFFFF
}
---@param key number
---@param seed number
---@return number
local function hash(key, seed)
    key = band(key + seed, 0xFFFFFFFF)
    key = band(key * 0xcc9e2d51, 0xFFFFFFFF)
    key = band(lshift(key, 15) + rshift(key, 17), 0xFFFFFFFF)
    key = band(key * 0x1b873593, 0xFFFFFFFF)
    return key
end

---@param width number   — default 8192
---@param depth number   — default 4
---@param counter_bits number — bits per counter (16 or [32] default)
---@return CMS
function CMS.new(width, depth, counter_bits)
	---@type CMS
	local self = setmetatable({}, CMS)
	self.width = width or 8192
	self.depth = depth or 4
	self.counter_bits = counter_bits or 32
	self.max_count = MASKS[counter_bits]
	self.mask = width - 1
	---@type table<number, table<number, number>>
	self.rows = {}

	for i = 1, self.depth do
		self.rows[i] = {} 
		for j = 1, self.width do 
			self.rows[i][j] = 0
		end
		
	end
	return self
end

function CMS:serialize()
    local parts = {}
    
    -- Header: width (4 bytes), depth (1 byte), counter_bits (1 byte)
    table.insert(parts, string.pack("I4I1I1", self.width, self.depth, self.counter_bits))
    
    -- Counter data
    for i = 1, self.depth do
        local row = self.rows[i]
        if self.counter_bits == 16 then
            for j = 1, self.width do
                table.insert(parts, string.pack("I2", row[j]))
            end
        else
            for j = 1, self.width do
                table.insert(parts, string.pack("I4", row[j]))
            end
        end
    end
    
    return table.concat(parts)
end

---@param data string Serialized data
---@return CMS|nil Deserialized CMS or nil on error
function CMS.deserialize(data)
    local pos = 1
    
    -- Read header
    local width, depth, counter_bits
    width, depth, counter_bits, pos = string.unpack("I4I1I1", data, pos)
    
    if not (counter_bits == 16 or counter_bits == 32) then
        return nil
    end
    
    local self = CMS.new(width, depth, counter_bits)
    
    -- Read counter data
    local format = counter_bits == 16 and "I2" or "I4"
    for i = 1, depth do
        for j = 1, width do
            self.rows[i][j], pos = string.unpack(format, data, pos)
        end
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

---@param key number Key to increment
---@param delta number Increment amount (default: 1)
function CMS:increment(key, delta)
    delta = delta or 1
    local max_count = self.max_count
    
    for i = 1, self.depth do
        local h = hash(key, i)
        local idx = band(h, self.mask) + 1  -- 1-based indexing
        local current = self.rows[i][idx]
        
        -- Handle saturation
        if current > max_count - delta then
            self.rows[i][idx] = max_count
        else
            self.rows[i][idx] = current + delta
        end
    end
end


---@param key number Key to estimate
---@return number Estimated count
function CMS:estimate(key)
    local min = math.huge
    
    for i = 1, self.depth do
        local h = hash(key, i)
        local idx = band(h, self.mask) + 1  -- 1-based indexing
        local count = self.rows[i][idx]
        
        if count < min then
            min = count
        end
    end
    
    return min == math.huge and 0 or min
end

return CMS