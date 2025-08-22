local cms = require("cmp-adaptive-freq.cms")
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
    project_data.file = "/"..vim.fn.sha256(vim.fn.getcwd()) .. ".mpack"
function project_data:setdir()
    self.file = vim.fn.sha256(vim.fn.getcwd()) .. ".mpack"
end
function project_data:save_data ()
    local dir = self.dir
    local file = self.file
    local data = {
        unigram_cms = self.frequency:serialize(),
        relation_map = self.relations_map:serialize(),
        pairing_map = self.pairs:serialize(),
    }

    -- Serialize with vim.mpack
    local blob = vim.mpack.encode(data)
    vim.fn.mkdir(dir, "p")

    local f, err = io.open(dir .. file, "wb")
    if not f then
        vim.notify("Failed to open file for writing: "..dir .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local ok, write_err = pcall(function() f:write(blob) end)
    f:close()

    if not ok then
        vim.notify("Failed to write data: " .. tostring(write_err), vim.log.levels.ERROR)
    end
end



---@return boolean
function project_data:load_data ()
    local dir = self.dir
    local file = self.file
	if vim.fn.filereadable(dir.. file) == 0 then
		vim.fn.writefile({}, dir.. file)
	end

	local blob = table.concat(vim.fn.readfile(dir .. file, "b"), "")
	local ok, data = pcall(vim.mpack.decode, blob)
	if not ok or type(data) ~= "table" then
		return false
	end

	self.frequency.deserialize(data.unigram_cms)
	self.relations_map:deserialize(data.relation_map)
    self.pairs:deserialize(data.pairing_map)
    self.update_count = 0
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
    global_data.file = "/global".. ".mpack"
global_data.word_id_map = require("cmp-adaptive-freq.word_id_map").new()

function global_data:save_data ()
    local dir = vim.fn.stdpath("cache") .. "/cmp-adaptive-freq"
    local file = self.file
    local data = {
        word_id_map = self.word_id_map:serialize(),
        unigram_cms = self.frequency:serialize(),
        relation_map = self.relations_map:serialize(),
        pairing_map = self.pairs:serialize(),
    }

    -- Serialize with vim.mpack
    local blob = vim.mpack.encode(data)
    vim.fn.mkdir(dir, "p")

    local f, err = io.open(dir .. file , "wb")
    if not f then
        vim.notify("Failed to open file for writing: "..dir .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local ok, write_err = pcall(function() f:write(blob) end)
    f:close()

    if not ok then
        vim.notify("Failed to write data: " .. tostring(write_err), vim.log.levels.ERROR)
    end
    self.update_count = 0
end

function global_data:load_data ()
    local dir = vim.fn.stdpath("cache") .. "/cmp-adaptive-freq"
    local file = self.file
	if vim.fn.filereadable(dir.. file) == 0 then
		vim.fn.writefile({}, dir .. file)
	end

	local blob = table.concat(vim.fn.readfile(dir .. file, "b"), "")
	local ok, data = pcall(vim.mpack.decode, blob)
	if not ok or type(data) ~= "table" then
		return false
	end

	self.word_id_map:deserialize(data.word_id_map)
	self.frequency.deserialize(data.unigram_cms)
	self.relations_map:deserialize(data.relation_map)
    self.pairs:deserialize(data.pairing_map)

	return true
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