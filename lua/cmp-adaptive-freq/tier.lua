local cms = require("cmp-adaptive-freq.cms")
local rel = require("cmp-adaptive-freq.relations_map")
local pair = require("cmp-adaptive-freq.pairings_map")
---@alias width integer
---@alias depth integer
---@alias counter_bits integer

---@alias cms_params table<width, depth, counter_bits> #width, depth, counter_bits

---@class Tiered_Data
---@field pairs Pairing_Map
---@field relations_map Relation_Map
---@field frequency CMS
---@field update_count integer
---@field save_data function
---@field load_data function
local tier_data = {}

local function wrap_method(tbl, key, wrapper)
    local original = tbl[key]
    tbl[key] = function (self, ...)
        return wrapper(self, original, ...)
    end
end
---@param pairs_params cms_params 
---@param relations_params cms_params
---@param frequency_params cms_params
---@param threshold integer
function tier_data:new ( pairs_params, relations_params, frequency_params, threshold )
    local obj = setmetatable({}, self)
    self.__index = self
    self.pairs = require("cmp-adaptive-freq.pairings_map"):new(pairs_params[1], pairs_params[2], pairs_params[3] )
    self.relations_map = require("cmp-adaptive-freq.relations_map"):new(relations_params[1], relations_params[2], relations_params[3])
    self.frequency = cms.new(frequency_params[1],frequency_params[2], frequency_params[3] )
    self.update_count = 0
    self.threshold = threshold
    self.save = true
    local o_inc = self.relations_map.increment_results
    self.relations_map.increment_results = function(inner_self, ...)
        self:increment()
        return o_inc(inner_self, ...)
    end
    local o_f_inc = self.frequency.increment
    self.frequency.increment = function (inner_self, ...)
        self:increment()
        return o_f_inc(inner_self, ...)
    end
    local o_p_inc = self.pairs.increment_results
     self.pairs.increment_results = function (inner_self, ...)
        self:increment()
        return o_p_inc(inner_self, ...)
    end
    return obj
end

function tier_data:increment()
    self.update_count = (self.update_count or 0) + 1
    if self.update_count > self.threshold and self.save then
        vim.schedule(self.save_data())
    end

end


---@class Project_data: Tiered_Data
local project_data = tier_data:
    new(
        {4096, 4, 32}, 
        {4096, 4, 32}, 
        {2048, 8, 32}, 
        2100
    )
    project_data.dir = vim.fn.stdpath("cache") .. "/cmp-adaptive-freq"
    project_data.file = "/"..vim.fn.sha256(vim.fn.getcwd()) .. ".json"
function project_data:setdir()
    self.file = vim.fn.sha256(vim.fn.getcwd()) .. ".json"
end
function project_data:save_data ()

    local dir = self.dir
    local file = self.file
    local data = {
        unigram_cms = self.frequency:serialize(),
        relation_map = self.relations_map:serialize(),
        pairing_map = self.pairs:serialize(),
    }
	if vim.fn.filereadable(dir.. file) == 0 then
		vim.fn.writefile({}, dir.. file)
	end
    -- Serialize with vim.mpack
    -- local blob = vim.mpack.encode(data)
    -- vim.fn.mkdir(dir, "p")

    -- local f, err = io.open(dir .. file, "wb")
    -- if not f then
        -- vim.notify("Failed to open file for writing: "..dir .. tostring(err), vim.log.levels.ERROR)
        -- return
    -- end

    -- local ok, write_err = pcall(function() f:write(blob) end)
    -- f:close()

    -- if not ok then
        -- vim.notify("Failed to write data: " .. tostring(write_err), vim.log.levels.ERROR)
    -- end
	-- Serialize with JSON
	local json_str = vim.fn.json_encode(data)
    vim.fn.mkdir(dir, "p")

    local f, err = io.open(dir .. file, "w")
    if not f then
        vim.notify("Failed to open file for writing: "..dir .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local ok, write_err = pcall(function() f:write(json_str) end)
    f:close()

    if not ok then
        vim.notify("Failed to write data: " .. tostring(write_err), vim.log.levels.ERROR)
    end
    self.update_count = 0
end



---@return boolean
function project_data:load_data ()
    local dir = self.dir
    local file = self.file
	if vim.fn.filereadable(dir.. file) == 0 then
		vim.fn.writefile({}, dir.. file)
		return false
	end

	-- local blob = table.concat(vim.fn.readfile(dir .. file, "b"), "")
	-- local ok, data = pcall(vim.mpack.decode, blob)
	-- if not ok or type(data) ~= "table" then
		-- return false
	-- end

	-- self.frequency.deserialize(data.unigram_cms)
	-- self.relations_map:deserialize(data.relation_map)
    -- self.pairs:deserialize(data.pairing_map)
    -- self.update_count = 0
	-- return true
	
		-- Json
    local json_str = table.concat(vim.fn.readfile(dir .. file), "")
    local ok, data = pcall(vim.fn.json_decode, json_str)
    if not ok or type(data) ~= "table" then
		if data == "Vim:E474: Attempt to decode a blank string" then
			return true
		end
        vim.notify("Failed to decode JSON data for project " .. tostring(data), vim.log.levels.ERROR)
        return false
    end

    -- Deserialize each component
    self.frequency:json_deserialize(data.unigram_cms)
    self.relations_map:deserialize(data.relation_map)
    self.pairs:deserialize(data.pairing_map)
	return true
end
---@class Global_data: Tiered_Data
local global_data = tier_data:
    new( 
        {8192, 4, 32}, 
        {8192, 4, 32}, 
        {8192, 8, 32}, 
        2700
    )
    global_data.file = "/global".. ".json"
global_data.word_id_map = require("cmp-adaptive-freq.word_id_map").new()
global_data.total_updates = 0
global_data.decay_threshold = 300000
function global_data:save_data ()
    if self.total_updates >= self.decay_threshold then
        self:apply_decay()
        self.total_updates = 0  -- Reset counter after decay
    end
    local dir = vim.fn.stdpath("cache") .. "/cmp-adaptive-freq"
    local file = self.file
    local data = {
        word_id_map = self.word_id_map:serialize(),
        unigram_cms = self.frequency:json_serialize(),
        relation_map = self.relations_map:serialize(),
        pairing_map = self.pairs:serialize(),
		total_updates = self.total_updates,
    }
	if vim.fn.filereadable(dir.. file) == 0 then
		vim.fn.writefile({}, dir.. file)
	end
    -- -- Serialize with vim.mpack
    -- local blob = vim.mpack.encode(data)
    -- vim.fn.mkdir(dir, "p")

    -- local f, err = io.open(dir .. file , "wb")
    -- if not f then
        -- vim.notify("Failed to open file for writing: "..dir .. tostring(err), vim.log.levels.ERROR)
        -- return
    -- end

    -- local ok, write_err = pcall(function() f:write(blob) end)
    -- f:close()

    -- if not ok then
        -- vim.notify("Failed to write data: " .. tostring(write_err), vim.log.levels.ERROR)
    -- end
    -- self.update_count = 0
	    -- Serialize with JSON
	local json_str = vim.fn.json_encode(data)
    vim.fn.mkdir(dir, "p")

    local f, err = io.open(dir .. file, "w")
    if not f then
        vim.notify("Failed to open file for writing: ".. dir .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local ok, write_err = pcall(function() f:write(json_str) end)
    f:close()

    if not ok then
        vim.notify("Failed to write data: " .. tostring(write_err), vim.log.levels.ERROR)
    end
    self.update_count = 0
end
function project_data:reset()
    self.frequency = cms.new(2048, 8, 32)
    self.relations_map = rel:new(4096, 4, 32)
    self.pairs = pair:new(4096, 4, 32)
    
end
function global_data:reset()
    self.frequency = cms.new(8192, 8, 32)
    self.relations_map = rel:new(8192, 4, 32)
    self.pairs = pair:new(8192, 8, 32)
end
function global_data:load_data ()
    local dir = vim.fn.stdpath("cache") .. "/cmp-adaptive-freq"
    local file = self.file
	if vim.fn.filereadable(dir.. file) == 0 then
		vim.fn.writefile({}, dir .. file)
		return
	end
	-- mpack
	-- local blob = table.concat(vim.fn.readfile(dir .. file, "b"), "")
	-- local ok, data = pcall(vim.mpack.decode, blob)
	-- if not ok or type(data) ~= "table" then
		-- print(data)
		-- return false
	-- end
	-- local debug_output = ""
	-- for key, _ in pairs(data) do
		-- debug_output = debug_output .. tostring(key) .. ", "
	-- end
	-- print("SUCESS: " .. debug_output)
	-- self.word_id_map:deserialize(data.word_id_map)
	-- self.frequency.deserialize(data.unigram_cms)
	-- self.relations_map:deserialize(data.relation_map)
    -- self.pairs:deserialize(data.pairing_map)
	
	-- Json
    local json_str = table.concat(vim.fn.readfile(dir .. file), "")
    local ok, data = pcall(vim.fn.json_decode, json_str)
    if not ok or type(data) ~= "table" then
		if data == "Vim:E474: Attempt to decode a blank string" then
			return true
		end
        vim.notify("Failed to decode JSON data for global " .. tostring(data), vim.log.levels.ERROR)
        return false
    end

    -- Deserialize each component
    self.word_id_map:deserialize(data.word_id_map)
    self.frequency:json_deserialize(data.unigram_cms)
    self.relations_map:deserialize(data.relation_map)
    self.pairs:deserialize(data.pairing_map)
	self.total_updates = data.total_updates
	return true
end 
function global_data:apply_decay()
    self.frequency:decay()
    self.pairs:decay()
    self.relations_map:decay()
end

---@type Tiered_Data
local session_data = tier_data:
    new(
        {512, 4, 16}, 
        {1024, 4, 16}, 
        {512, 8, 16},
        100000000000
    )
session_data.save = false
local tiers = {session_data, project_data, global_data}
return tiers