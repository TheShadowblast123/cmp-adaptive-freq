local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local CMS = require("cmp-adaptive-freq.cms")  -- Our custom CMS module
---@class Pairing_Map
---@field private cms CMS                -- CMS for bigram frequency
---@field private id_map table<number, number> -- Map word ID to CMS key
---@field private reverse_map table<number, number> -- Map CMS key to word ID test
local Pairing_Map = {}
Pairing_Map.__index = Pairing_Map
local function serialize(s)
    return {
        cms = s.cms,
        id_map = s.id_map,
        reverse_map = s.reverse_map,
        next_key = s.next_key
    }
end
---@return Pairing_Map
function Pairing_Map.new()
	---@type Pairing_Map
    local self = setmetatable({}, Pairing_Map)
    
    -- Initialize CMS with 2-bit counters (4 levels: 0-3)
    self.cms = CMS.new(5, 512, 2, serialize(self))  -- depth=5, width=512, 2-bit counters
    
    -- ID mapping tables
    self.id_map = {}       -- word_id -> cms_key
    self.reverse_map = {}   -- cms_key -> word_id
    self.next_key = 1       -- Next available CMS key
	return self
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
    local word_key = self:get_key(word)
    local target_key = self:get_key(target)
    local bigram_key = self:combine_keys(word_key, target_key)
    
    -- Update CMS with the combined key
    self.cms:increment(bigram_key)
end

--- Combine two keys into a single CMS key
---@param key1 number
---@param key2 number
---@return number combined_key
function Pairing_Map:combine_keys(key1, key2)
    -- Simple mixing: shift first key and add second
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

--- Get top N results for a word
---@param id number
---@param n number
---@return table<number, number> -- {target_id = score}
function Pairing_Map:get_top_results(id, n)
    local all_results = self:get_results(id)
    local sorted = {}
    
    -- Convert to sortable table
    for target_id, score in pairs(all_results) do
        table.insert(sorted, {id = target_id, score = score})
    end
    
    -- Sort by score descending
    table.sort(sorted, function(a, b) 
        return a.score > b.score 
    end)
    
    -- Return top N results
    local top_results = {}
    for i = 1, math.min(n, #sorted) do
        top_results[sorted[i].id] = sorted[i].score
    end
    
    return top_results
end

--- Serialize for storage
---@return table serialized_data


--- Deserialize from storage
---@param data table
function Pairing_Map:deserialize(data)
    self.cms = data.cms
    self.id_map = data.id_map
    self.reverse_map = data.reverse_map
    self.next_key = data.next_key
end

return Pairing_Map