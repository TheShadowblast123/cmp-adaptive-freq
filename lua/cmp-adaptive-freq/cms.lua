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
---@param depth number
---@return hash_param[]
local function generate_hash_params(depth)
	local params = {}
	for i = 1, depth do
		local a = 19999999 -- don't question it
		local b = 213373 -- I told you not to question it
		params[i] = { a = a, b = b, P = 13337 }
	end
	return params
end



---@param depth number   — number of hash functions (rows)
---@param width number   — counters per row
---@param counter_bits number — bits per counter (1, 2, or 8)
---@return CMS
function CMS.new(depth, width, counter_bits, serialize)
	---@type CMS
	local self = setmetatable({}, CMS)
	self.depth = depth
	self.width = width
	self.counter_bits = counter_bits
	self.hash_params = generate_hash_params(depth)
	self.bytes_per_row = math.ceil(width * counter_bits / 8)
	if serialize then
		self.serialize = serialize
	else
		self.serialize = function ()
			return self
		end
	end
	---@type table<number, table<number, number>>
	self.rows = {}
	for i = 1, depth do
		self.rows[i] = {}
		for j = 1, self.bytes_per_row do
			self.rows[i][j] = 0
		end
		
	end
	return self
end

-- Helper function to get byte/bit position
---@param counter_index number (1-based)
---@return number byte_index, number bit_offset
function CMS:get_bit_position(counter_index)
    if self.counter_bits == 8 then
        return counter_index, 0
    elseif self.counter_bits == 2 then
        local byte_index = math.floor((counter_index - 1) / 4) + 1
        local bit_offset = ((counter_index - 1) % 4) * 2
        return byte_index, bit_offset
    else -- 1-bit
        local byte_index = math.floor((counter_index - 1) / 8) + 1
        local bit_offset = (counter_index - 1) % 8
        return byte_index, bit_offset
    end
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
function CMS:increment(key)
    for r = 1, self.depth do
        local counter_index = self:hash(r, key)
        local byte_index, bit_offset = self:get_bit_position(counter_index)
        local byte = self.rows[r][byte_index] or 0
        
        if self.counter_bits == 8 then
            -- 8-bit counter: direct byte storage
            local new_val = math.min(255, (byte or 0) + 1)
            self.rows[r][byte_index] = new_val
        else
            -- Extract current value
            local mask = bit.lshift(1, self.counter_bits) - 1
            local current = rshift(byte, bit_offset)
            current = band(current, mask)
            
            -- Increment with saturation
            local new_val = math.min(mask, current + 1)
            
            -- Update byte
            local clear_mask = bnot(lshift(mask, bit_offset))
            local updated = band(byte, clear_mask)
            updated = bor(updated, lshift(new_val, bit_offset))
            self.rows[r][byte_index] = updated
        end
    end
end

---@param self CMS
---@param key number
---@return number count — estimated count
function CMS:estimate(key)
    local min_val = math.huge
    
    for r = 1, self.depth do
        local counter_index = self:hash(r, key)
        local byte_index, bit_offset = self:get_bit_position(counter_index)
        local byte = self.rows[r][byte_index] or 0
        
        local val
        if self.counter_bits == 8 then
            val = byte
        else
            -- Extract bits
            local mask = bit.lshift(1, self.counter_bits) - 1
            val = rshift(byte, bit_offset)
            val = band(val, mask)
        end
        
        if val < min_val then
            min_val = val
        end
    end
    
    return min_val
end

-- Set value directly (for binary flags)
---@param self CMS
---@param key number
function CMS:set_flag(key)
    for r = 1, self.depth do
        local counter_index = self:hash(r, key)
        local byte_index, bit_offset = self:get_bit_position(counter_index)
        local byte = self.rows[r][byte_index] or 0
        
        -- Set the bit
        self.rows[r][byte_index] = bor(byte, lshift(1, bit_offset))
    end
end

-- Check if flag is set (for binary relations)
---@param self CMS
---@param key number
---@return boolean
function CMS:check_flag(key)
    for r = 1, self.depth do
        local counter_index = self:hash(r, key)
        local byte_index, bit_offset = self:get_bit_position(counter_index)
        local byte = self.rows[r][byte_index] or 0
        
        -- Check if bit is set
        if band(rshift(byte, bit_offset), 1) == 0 then
            return false
        end
    end
    return true
end
return CMS