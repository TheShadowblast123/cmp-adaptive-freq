local cmp = require("cmp")
local uv = vim.loop

-- Modules
local CMS = require("cmp-adaptive-freq.cms")
local WordIDMap = require("cmp-adaptive-freq.word_id_map")
local RelationMap = require("cmp-adaptive-freq.relations_map")
local PairingMap = require("cmp-adaptive-freq.pairings_map")
local autosave = require("cmp-adaptive-freq.autosave")

local M = {}
local default_config = {
	max_items = 5,
	case_sensitive = true,
	languages = { "markdown", "org", "text", "plain", "latex", "asciidoc" },
}
local config = {}

-- Global instances
local word_id_map
local unigram_cms
local relation_map
local pairing_map

---@param word string
---@return string
local function normalize_word(word)
	return word:gsub("[%p%s]", ""):lower()
end
---@param path string
---@return string
local function hash_path(path)
	return vim.fn.sha256(path)
end
---@return string
local function get_data_path_for_dir()
	local hash = hash_path(vim.fn.getcwd())
	return vim.fn.stdpath("cache") .. "/cmp-adaptive-freq/" .. hash .. ".mpack"
end
--- Process a buffer for word frequencies
---@param buf number
local function scan_buffer(buf)
	if not vim.api.nvim_buf_is_loaded(buf) then
		print("No buffer")
		return
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	local window = {}
	local window_size = 10
	for _, line in ipairs(lines) do
		for word in line:gmatch("%S+") do
			local normalized = normalize_word(word)
			if normalized ~= "" and #normalized > 1 then
				local word_id = word_id_map:get_id(normalized)
				unigram_cms:increment(word_id)

				-- Add to sliding window
				table.insert(window, word_id)
				if #window > window_size then
					table.remove(window, 1)
				end

				-- Process bigrams and relations
				if #window > 1 then
					-- Bigram: current word with previous word
					pairing_map:increment_results(window[#window - 1], word_id)

					-- Relations: current word with all words in window
					for i = 1, #window - 1 do
						relation_map:increment_results(
							word_id,
							window[i],
							#window - i -- distance (closer words get higher weight)
						)
					end
				end
			end
		end
	end
	autosave.save(word_id_map, unigram_cms, relation_map, pairing_map)
end

--- Load data for current directory
local function load_data()
	local save_path = get_data_path_for_dir()
	if vim.fn.filereadable(save_path) == 0 then
		return false
	end

	local blob = table.concat(vim.fn.readfile(save_path, "b"), "")
	local ok, data = pcall(vim.mpack.decode, blob)
	if not ok or type(data) ~= "table" then
		return false
	end

	word_id_map = WordIDMap.new()
	word_id_map:deserialize(data.word_id_map)

	unigram_cms = CMS.new(4, 256, 8 )
	unigram_cms:deserialize(data.unigram_cms)

	relation_map = RelationMap.new()
	relation_map:deserialize(data.relation_map)

	pairing_map = PairingMap.new()
	pairing_map:deserialize(data.pairing_map)

	return true
end

--- Initialize data structures
local function init_data()
	word_id_map = WordIDMap.new()
	unigram_cms = CMS.new(4, 256, 8) -- Unigram frequency
	relation_map = RelationMap.new() -- Word relations
	pairing_map = PairingMap.new() -- Bigrams

	autosave.setup(word_id_map, unigram_cms, relation_map, pairing_map)
end

--- Check if filetype is supported
---@param ft string
---@return boolean
local function is_supported_ft(ft)
	for _, lang in ipairs(config.languages) do
		if ft == lang then
			return true
		end
	end
	return false
end

---@param id number
---@return number score
local function calculate_score(id, context)
	local score = unigram_cms:estimate(id)

	-- Bigram boost (last word)
	if context.prev_word_id then
		local bigram_score = pairing_map:get_score(context.prev_word_id, id)
		score = score * (1 + bigram_score * 0.3) -- Up to 30% boost
	end

	-- Relation boost (context words)
	for _, ctx_id in ipairs(context.recent_word_ids) do
		if relation_map:relation_exists(id, ctx_id) then
			score = score * 1.15 -- 15% boost per relation
		end
	end

	return score
end

--- Source completion function
function M:complete(params, callback)
	print("HERE")
	local input = params.context.cursor_before_line:match("%S+$") or ""
	if input == "" then
		print("No Context")
		return callback({ items = {} })
	end

	-- Normalize input
	local normalized_input = normalize_word(input)
	if normalized_input == "" then
		print("No good input")
		return callback({ items = {} })
	end

	-- Get candidates
	local candidates = {}
	for _, word in ipairs(word_id_map:get_all_words()) do
		if word:find(normalized_input, 1, true) == 1 then
			local word_id = word_id_map:get_id(word)
			table.insert(candidates, {
				word = word,
				id = word_id,
				score = 0, -- Will be calculated later
			})
		end
	end
	
	if #candidates == 0 then
		print("No candidates")
		return callback({ items = {} })
	end

	-- Build context
	local context = {
		prev_word_id = nil,
		recent_word_ids = {},
	}

	-- Score candidates
	for _, candidate in ipairs(candidates) do
		candidate.score = calculate_score(candidate.id, context)
	end

	-- Sort by score
	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)

	-- Format for cmp
	local items = {}
	for i = 1, math.min(config.max_items, #candidates) do
		local candidate = candidates[i]
		table.insert(items, {
			label = candidate.word,
			filterText = input,
			sortText = string.format("%06d", 1000000 - candidate.score), -- Sort high scores first
			kind = cmp.lsp.CompletionItemKind.Text,
		})
	end
	if items == {} then
		print("Candidates but no solutions?")
	end
	callback({ items = items, isIncomplete = #items < #candidates })
end

--- Setup function
function M.setup(opts)
	config = default_config
	--config = vim.tbl_deep_extend("force", default_config, opts or {})

	-- Initialize or load data
	if not load_data() then
		init_data()
	end

	-- Setup autocmds
	local group = vim.api.nvim_create_augroup("CmpAdaptiveFreq", {})

	-- Scan buffers on open
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		group = group,
		callback = function(args)
			if is_supported_ft(vim.bo[args.buf].filetype) then
				local hash = hash_path(vim.fn.getcwd())
				autosave.setdir(vim.fn.stdpath("cache") .. "/cmp-adaptive-freq-autosave/", hash)
				scan_buffer(args.buf)
			end
		end,
	})

	-- Scan on text changes
	vim.api.nvim_create_autocmd("TextChanged", {
		group = group,
		callback = function(args)
			if is_supported_ft(vim.bo[args.buf].filetype) then
				scan_buffer(args.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		callback = function(args)
			autosave.setdir("")
			if context and args.buf == context.buf then
				context.buf = nil -- Reset context
			end
		end,
	})
	-- Register source
	cmp.register_source("adaptive_freq", {
		complete = M.complete,
		is_available = function()
			return is_supported_ft(vim.bo.filetype)
		end,
	})
end

return M
