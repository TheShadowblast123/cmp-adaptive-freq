local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local CMS = require("cmp-adaptive-freq.cms")

---@class Relation_Map
---@field private cms CMS                -- CMS for binary relation flags
---@field private id_map table<number, number> -- Map word ID to CMS key
---@field private reverse_map table<number, number> -- Map CMS key to word ID
local Relation_Map = {}
Relation_Map.__index = Relation_Map
---@return Relation_Map
function Relation_Map:new(width, depth, counter_bits)
    ---@type Relation_Map
    local self = setmetatable({}, Relation_Map)
    
    self.cms = CMS.new(width, depth, counter_bits) -- currently everything is session based but we leave the bits alone
    
    -- ID mapping tables
    self.id_map = {}       -- word_id -> cms_key
    self.reverse_map = {}   -- cms_key -> word_id
    self.next_key = 1       -- Next available CMS key

    return self
end
function Relation_Map:serialize()
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
function Relation_Map:get_key(id)
    if not self.id_map[id] then
        self.id_map[id] = self.next_key
        self.reverse_map[self.next_key] = id
        self.next_key = self.next_key + 1
    end
    return self.id_map[id]
end

---@param self Relation_Map
---@param word number
---@param target number
---@param dist number
function Relation_Map:increment_results(word, target, dist)
    -- We're ignoring distance since we're using binary flags
	if math.random() < 0.5 then
		return
	end
    local word_key = self:get_key(word)
    local target_key = self:get_key(target)
    local relation_key = self:combine_keys(word_key, target_key)
    
    -- Set the flag in CMS
    self.cms:increment(relation_key, 10 - dist)
end

--- Combine two keys into a single CMS key
---@param key1 number
---@param key2 number
---@return number combined_key
function Relation_Map:combine_keys(key1, key2)
    -- Use XOR to create a symmetric relation (order doesn't matter)
    return bit.bxor(key1, key2)
end

function Relation_Map:decay()
	self.cms:decay()
end

---@param self Relation_Map
---@param id number
---@return table<number, boolean> -- {target_id = exists}
function Relation_Map:get_results(id)
    local results = {}
    local word_key = self:get_key(id)
    
    -- Iterate through all possible target keys
    for target_key, target_id in pairs(self.reverse_map) do
        if target_key ~= word_key then  -- Skip self-relations
            local relation_key = self:combine_keys(word_key, target_key)
            if (self.cms:estimate(relation_key) or 0) > 0 then
                results[target_id] = true
            end
        end
    end
    
    return results
end

--- Get all related words for an ID
---@param id number
---@return number[] -- list of related word IDs
function Relation_Map:get_related_words(id)
    local results = {}
    local word_key = self:get_key(id)
    
    for target_key, target_id in pairs(self.reverse_map) do
        if target_key ~= word_key then
            local relation_key = self:combine_keys(word_key, target_key)
            if (self.cms:estimate(relation_key) or 0) > 0 then
                table.insert(results, target_id)
            end
        end
    end
    
    return results
end
function Relation_Map:get_score(id1, id2)
    local k1 = self:get_key(id1)
    local k2 = self:get_key(id2)
    local relation_key = self:combine_keys(k1, k2)
    return self.cms:estimate(relation_key) or 0
end
--- Check if a relation exists between two words
---@param id1 number
---@param id2 number
---@return boolean
function Relation_Map:relation_exists(id1, id2)
    local key1 = self:get_key(id1)
    local key2 = self:get_key(id2)
    local relation_key = self:combine_keys(key1, key2)
    return (self.cms:estimate(relation_key) or 0) > 0
end


--- Deserialize from storage
---@param data table
function Relation_Map:deserialize(data)
    self.cms = self.cms:json_deserialize(data.cms) or self.cms
    self.id_map = data.id_map
    self.reverse_map = data.reverse_map
    self.next_key = data.next_key
end
return Relation_Map
