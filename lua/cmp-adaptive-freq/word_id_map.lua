---@class Word_ID_Map
---@field private word_to_id table<string, number>  # maps word → ID
---@field private id_to_word table<number, string>  # maps ID → word
---@field private next_id number                    # next ID to assign
local Word_ID_Map = {}
Word_ID_Map.__index = Word_ID_Map

-- @return Word_ID_Map
function Word_ID_Map.new()
	---@type Word_ID_Map
	local self = setmetatable({}, Word_ID_Map)
	self.word_to_id = {}
	self.id_to_word = {}
	self.next_id = 1
	return self
end

---@param self Word_ID_Map
---@param word string
---@return number id        # unique numeric ID ≥ 1
function Word_ID_Map:get_id(word)
	---@type number|nil
	local id = self.word_to_id[word]
	if id then
		return id
	end
	-- Assign new ID
	local new_id = self.next_id
	self.next_id = new_id + 1

	self.word_to_id[word] = new_id
	self.id_to_word[new_id] = word
	return new_id
end
---@param words {[string] : number}
function Word_ID_Map:set_ids(words)	
	local max_id = 0
	for word, id in pairs(words) do
		self.word_to_id[word] = id
		self.id_to_word[id] = word
		if id > max_id then -- in case somehow the data is not in order
			max_id = id
		end
	end
	self.next_id = max_id + 1
end

---@param self Word_ID_Map
---@param word string
---@return boolean has
function Word_ID_Map:has_word(word)
	return self.word_to_id[word] ~= nil
end

---@param self Word_ID_Map
---@param id number
---@return boolean has
function Word_ID_Map:has_id(id)
	return self.id_to_word[id] ~= nil
end

-- @param self Word_ID_Map
-- @param id number
-- @return string|nil word # the word, or nil if `id` is unassigned
function Word_ID_Map:get_word(id)
	return self.id_to_word[id]
end
--- Serialize for storage
---@return table {words: table<string, number>}
function Word_ID_Map:serialize()
    return self.word_to_id
end

--- Deserialize from storage
---@param data table {words: table<string, number>}
function Word_ID_Map:deserialize(data)
    self.word_to_id = {}
    self.id_to_word = {}
    
    local max_id = 0
    for word, id in pairs(data) do
        self.word_to_id[word] = id
        self.id_to_word[id] = word
        if id > max_id then
            max_id = id
        end
    end
    self.next_id = max_id + 1
end

return Word_ID_Map
