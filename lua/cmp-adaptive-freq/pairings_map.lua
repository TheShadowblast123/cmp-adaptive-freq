local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local CMS = require("cmp-adaptive-freq.cms")  -- Our custom CMS module
---@class Pairing_Map
---@field private cms CMS                -- CMS for bigram frequency
---@field private id_map table<number, number> -- Map word ID to CMS key
---@field private reverse_map table<number, number> -- Map CMS key to word ID test
local Pairing_Map = {}
Pairing_Map.__index = Pairing_Map
---@param width integer
---@param depth integer
---@param counter_bits integer
---@return Pairing_Map
function Pairing_Map:new(width, depth, counter_bits)
	---@type Pairing_Map
    local self = setmetatable({}, Pairing_Map)
    
    self.cms = CMS.new(width, depth, counter_bits)  -- currently everything is session based but we leave the bits alone
    
    -- ID mapping tables
    self.id_map = {}       -- word_id -> cms_key
    self.reverse_map = {}   -- cms_key -> word_id
    self.next_key = 1       -- Next available CMS key

	return self
end

function Pairing_Map:serialize()
    return {
        cms = self.cms:json_serialize(),
        id_map = self.id_map,
        reverse_map = self.reverse_map,
        next_key = self.next_key
    }
end
--- Get or create a CMS key for a word ID
---@param id number
---@return number cms_key
function Pairing_Map:get_key(id)
    if not self.id_map[id] then
        self.id_map[id] = self.next_key
        self.reverse_map[self.next_key] = id
        self.next_key = self.next_key + 1
    end
    return self.id_map[id]
end

---@param self Pairing_Map
---@param word number
---@param target number
function Pairing_Map:increment_results(word, target)
	if math.random() < 0.8 then
		return
	end
    local word_key = self:get_key(word)
    local target_key = self:get_key(target)
    local bigram_key = self:combine_keys(word_key, target_key)
    self.cms:increment(bigram_key, 1)
end

--- Combine two keys into a single CMS key
---@param key1 number
---@param key2 number
---@return number combined_key
function Pairing_Map:combine_keys(key1, key2)
    return bit.bor(bit.lshift(key1, 16), key2)
end

--- Split combined key back into original keys
---@param combined number
---@return number key1, number key2
function Pairing_Map:split_keys(combined)
    local key1 = bit.rshift(combined, 16)
    local key2 = band(combined, 0xFFFF)
    return key1, key2
end

---@param self Pairing_Map
---@param id number
---@return table<number, number> -- {target_id = score}
function Pairing_Map:get_results(id)
    local results = {}
    local word_key = self:get_key(id)
    
    -- Iterate through all possible target keys
    for target_key, target_id in pairs(self.reverse_map) do
        if target_key ~= word_key then  -- Skip self-pairs
            local bigram_key = self:combine_keys(word_key, target_key)
            local score = self.cms:estimate(bigram_key)
            
            if score > 0 then
                results[target_id] = score
            end
        end
    end
    
    return results
end
function Pairing_Map:get_score(id1, id2)
    local k1 = self:get_key(id1)
    local k2 = self:get_key(id2)
    local relation_key = self:combine_keys(k1, k2)
    return self.cms:estimate(relation_key) or 0
end
--- Get top N results for a word
---@param id number
---@param n number
---@return table<number, number> -- {target_id = score}
function Pairing_Map:get_top_results(id, n)
    local all_results = self:get_results(id)
    local sorted = {}
    
    for target_id, score in pairs(all_results) do
        table.insert(sorted, {id = target_id, score = score})
    end
    
    table.sort(sorted, function(a, b) 
        return a.score > b.score 
    end)
    
    local top_results = {}
    for i = 1, math.min(n, #sorted) do
        top_results[sorted[i].id] = sorted[i].score
    end
    
    return top_results
end

--- Serialize for storage
---@return table serialized_data

function Pairing_Map:decay()
	self.cms:decay()
end
local function clean (t)
	for k, v in pairs(t) do
		t[tonumber(k)] = tonumber(v)
	end
	return t
end
--- Deserialize from storage
---@param data table
function Pairing_Map:deserialize(data)
    local new_cms = CMS.json_deserialize(data.cms)
    if new_cms then
        self.cms = new_cms
    end
    self.id_map = clean(data.id_map) or {}
	
    self.reverse_map = clean(data.id_map) or {}
    self.next_key = tonumber(data.next_key) or 1
end

return Pairing_Map