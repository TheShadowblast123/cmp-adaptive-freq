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
---@param x number
---@return number
local function wrap32(x)
    return x % 2^32
end

---@param key number
---@param seed number
---@return number
local function hash(key, seed)
    key = wrap32(key + seed)
    key = wrap32(key * 0xcc9e2d51)
    key = wrap32((key * 2^15 % 2^32) +math.floor(key / 2^17) )
    key = band(key * 0x1b873593)
    return key
end

local function pack_uint16(n)
    return string.char(n % 256, math.floor(n / 256))
end

local function pack_uint32(n)
    local b1 = n % 256
    local b2 = math.floor(n / 256) % 256
    local b3 = math.floor(n / 65536) % 256
    local b4 = math.floor(n / 16777216) % 256
    return string.char(b1, b2, b3, b4)
end

local function unpack_uint16(s, pos)
    local b1, b2 = string.byte(s, pos, pos + 1)
    return b1 + b2 * 256, pos + 2
end

local function unpack_uint32(s, pos)
    local b1, b2, b3, b4 = string.byte(s, pos, pos + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216, pos + 4
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
	self.max_count =  (2 ^ self.counter_bits) - 1
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


---@return string
function CMS:serialize()
    local parts = {}
    
    -- Header: width (2 bytes), depth (1 byte), counter_bits (1 byte)
    table.insert(parts, pack_uint16(self.width))
    table.insert(parts, string.char(self.depth))
    table.insert(parts, string.char(self.counter_bits))
    
    -- Counter data
    for i = 1, self.depth do
        local row = self.rows[i]
        if self.counter_bits == 16 then
            for j = 1, self.width do
                table.insert(parts, pack_uint16(row[j]))
            end
        else
            for j = 1, self.width do
                table.insert(parts, pack_uint32(row[j]))
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
    width, pos = unpack_uint16(data, pos)
    depth = string.byte(data, pos); pos = pos + 1
    counter_bits = string.byte(data, pos); pos = pos + 1
    
    if not (counter_bits == 16 or counter_bits == 32) then
        return nil
    end
    
    local self = CMS.new(width, depth, counter_bits)
    
    -- Read counter data
    for i = 1, depth do
        for j = 1, width do
            if counter_bits == 16 then
                self.rows[i][j], pos = unpack_uint16(data, pos)
            else
                self.rows[i][j], pos = unpack_uint32(data, pos)
            end
        end
    end
    
    return self
end
function CMS:json_serialize()
    local data = {
        width = self.width,
        depth = self.depth,
        counter_bits = self.counter_bits,
        rows = {}
    }
    
    -- Convert each row to a JSON-compatible format
    for i = 1, self.depth do
        data.rows[i] = {}
        for j = 1, self.width do
            data.rows[i][j] = self.rows[i][j]
        end
    end
    
    return data
end

-- JSON-compatible deserialization for CMS
function CMS.json_deserialize(data)
    if type(data) ~= "table" then
        return nil
    end
    
    local self = CMS.new(data.width, data.depth, data.counter_bits)
    
    -- Restore the counter values
    for i = 1, data.depth do
        for j = 1, data.width do
            if data.rows[i] and data.rows[i][j] then
                self.rows[i][j] = data.rows[i][j]
            end
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
    
    for i = 1, self.depth do
        local h = hash(key, i)
        local idx = band(h, self.mask) + 1  -- 1-based indexing
        local current = self.rows[i][idx]
        
        -- Handle saturation
        if current > self.max_count - delta then
            self.rows[i][idx] = self.max_count
        else
            self.rows[i][idx] = current + delta
        end
    end
end

function CMS:decay()
    local factor = 0.9  -- Default to halving counts
    
    for i = 1, self.depth do
        for j = 1, self.width do
            self.rows[i][j] = math.max(0, math.floor(self.rows[i][j] * factor))
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