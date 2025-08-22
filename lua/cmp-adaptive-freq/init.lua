local cmp = require("cmp")
local uv = vim.loop

-- Modules
local tier= require("cmp-adaptive-freq.tier")
local global = tier[3]
local project = tier[2]
local session = tier[1]
local last_line = ""
local last_line_word_count = 0
local last_line_number = -1
local M = {}
local default_config = {
	max_items = 5,
	case_sensitive = true,
	types = { "markdown", "org", "text", "plain", "latex", "asciidoc" },
}
M.new = function()
	return setmetatable({}, {__index = M})
end
local config = {}

-- Global instances

---@param word string
---@return string
local function normalize_word(word)
	return word:sub("[%s]", "")
end
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
			local normalized= normalize_word(word)
			if normalized ~= "" and #normalized > 1 then
				local word_id = global.word_id_map:get_id(normalized)
				if math.random() < 0.9 then
					project.frequency:increment(word_id, 1)
					if math.random() < 0.8 then
						global.frequency:increment(word_id, 1)
					end
				end

				-- Add to sliding window
				table.insert(window, word_id)
				if #window > window_size then
					table.remove(window, 1)
				end

				-- Process bigrams and relations
				if #window > 1 then
					-- Bigram: current word with previous word
						project.pairs:increment_results(window[#window - 1], word_id)
						global.pairs:increment_results(window[#window - 1], word_id)
					-- Relations: current word with all words in window
				-- Traverse backwards from the most recent word to find where to start context
					local start_index = #window - 1
					for i = #window - 1, 1, -1 do
						local word = window[i]
						local has_punctuation = string.find(word, "%%p")

						if has_punctuation then
							for x = 1, i, 1 do
								table.remove(window, 1)
							end
							start_index = i + 1  -- Context starts after the punctuated word
							break
						end
					end

				-- Process context from start_index to the word before current
					for i = 1, start_index - 1 do
						global.relations_map:increment_results(
							word_id,
							window[i],
							#window - i  -- distance weight
						)
						project.relations_map:increment_results(
							word_id,
							window[i],
							#window - i  -- distance weight
						)
					end
				end
			end
		end
	end
	global:save_data()
	project:save_data()
end
---@param buf number
local function scan_line(buf)
	if not vim.api.nvim_buf_is_loaded(buf) then
		print("No buffer")
		return
	end
	---@type string
	local line = vim.api.nvim_get_current_line()
	
	if line == last_line or last_line_number ~= vim.fn.line('.') then
		last_line_number = vim.fn.line('.')
		last_line = line
		return
	end
	local _, count = line:gsub("%s+","")
	if count == last_line_word_count then
		return
	end
	if count < last_line_word_count then
		-- we don't decrement
		last_line = line
		last_line_word_count = count
		return
	end
	local idx = -1
	for i = 1, last_line_word_count do
		if line:sub(i, i) ~= last_line:sub(i, i) then
			idx = i
			break
		end
	end
	local word = string.sub(line, idx):match("^%S+")

	local window_size = 10
	local normalized = normalize_word(word)
	if normalized == "" or #normalize_word(word) < 1 then
		last_line = line
		last_line_word_count = count
		return
	end
	local word_id = global.word_id_map:get_id(normalized)
	session.frequency:increment(word_id, 1)
	if math.random() < 0.9 then
		project.frequency:increment(word_id, 1)
		if math.random() < 0.8 then
			global.frequency:increment(word_id, 1)
		end
	end
	local words = {}
	for item in line:gmatch("%S+") do
		if item ~= word  and #words < window_size then
			table.insert(words, global.word_id_map:get_id(item))
			goto continue
		end
		if item == word and #words < window_size then
			table.insert(words, global.word_id_map:get_id(item))
			break
		end
		table.remove(words, 1)
		if item == word then
			goto continue
			break
		end
		table.insert(words, word_id)
	    ::continue::
	end
	if #words == 1 then
		return
	end
	session.pairs:increment_results(words[#words - 1], word_id)
	if math.random() < 0.8 then
		project.pairs:increment_results(words[#words - 1], word_id)
		if math.random() < 0.7 then
			global.pairs:increment_results(words[#words - 1], word_id)
		end
	end
	local start_index = #words- 1
	for i = #words- 1, 1, -1 do
		local item = words[i]
		local has_punctuation = string.find(item, "%%p")

		if has_punctuation then
			start_index = i-- Context starts after the punctuated word
			break
		end
	end
	if start_index == window_size -1 then 
		return
	end
				-- Process context from start_index to the word before current
	for i = start_index, window_size - 1 do
		session.relations_map:increment_results(
			word_id,
			words[i],
			#words - i  -- distance weight
		)
		if math.random() < 0.6 then
			project.relations_map:increment_results(
				word_id,
				words[i],
				#words - i  -- distance weight
			)
			if math.random() < 0.5 then
				global.relations_map:increment_results(
					word_id,
					words[i],
					#words- i  -- distance weight
				)
			end
		end

	end
end

--- Load data for current directory
---@param change_dir boolean
---@return boolean
local function load_data(change_dir)
	if change_dir then
		project:setdir()
	end
	return project:load_data() and global:load_data()
end

---@param ft string
---@return boolean
local function is_supported_ft(ft)
	for _, type in ipairs(config.type) do
		if ft == type then
			return true
		end
	end
	return false
end
---comment
---@param session_score integer
---@param project_score integer
---@param global_score integer
---@return number
function formula (session_score, project_score, global_score)
	return (session_score * 2) + (project_score * 0.6) + (global_score * 0.2)
end
---@param id number
---@return number score
local function calculate_score(id, context)
	local score = 0
	local uni_score = formula(
		session.frequency:estimate(id),
		project.frequency:estimate(id),
		global.frequency:estimate(id)
	)
	local bi_score = 0
	local rel_score = 0
	
	-- Bigram boost (last word)
	if #context > 0 then
		local prev_id = context[#context]
		bi_score = formula(
			session.pairs:get_score(prev_id, id),
			project.pairs:get_score(prev_id, id),
			global.pairs:get_score(prev_id,id )
		)
		
	end
	table.remove(context, #context)
	for _, ctx_id in ipairs(context) do
		rel_score = formula(
			session.relations_map:get_score(ctx_id, id),
			project.relations_map:get_score(ctx_id, id),
			global.relations_map:get_score(ctx_id, id )
		)


	end
	score = (math.log(uni_score + 1) * 0.55) + (math.log(bi_score + 1) * 0.35) + (math.log(rel_score + 1) * 0.1)
	return score
end
M.get_keyword_pattern = function()
    return [[.]]
end
--- Source completion function
function M:complete(params, callback)
	local line = param.context.cursor_before_line
	local input = line:match("%S+$") or ""

	if input == "" then
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
	for word, id in pairs(global.word_id_map) do
		if word:find(normalized_input, 1, true) == 1 then
			table.insert(candidates, {
				word = word,
				id = id,
				score = 0,  -- Will be calculated later
			})
		end
	end
	
	if #candidates == 0 then
		print("No candidates")
		return callback({ items = {} })
	end

	-- Build context
	local context = {}
	for l in line:gmatch("%S+") do
		if #context == 11 then
			table.remove(context, 1)
		end
		table.insert(context, global.word_id_map:get_id(l))
	end
	table.remove(context,#context)

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
	callback({ items = items, isIncomplete = #items < #candidates })
end

function M:is_available()
	local ft = vim.bo.filetype
	return ft == "markdown" or ft == "org" or ft == "text" or ft == "plain" or ft == "latex" or ft == "asciidoc"
end
--- Setup function
function M.setup(opts)
	config = default_config
	--config = vim.tbl_deep_extend("force", default_config, opts or {})

	-- Setup autocmds
	local group = vim.api.nvim_create_augroup("CmpAdaptiveFreq", {})

	-- Scan buffers on open
	vim.api.nvim_create_user_command("CmpAdaptiveFreqScanBuffer", function ()
	local buf = vim.api.nvim_get_current_buf()
	scan_buffer(buf)
	end,
	{}
	)

	-- Scan on text changes
	vim.api.nvim_create_autocmd("TextChanged", {
		group = group,
		callback = function(args)
			if is_supported_ft(vim.bo[args.buf].filetype) then
				scan_line(args.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		callback = function(args)
			if context and args.buf == context.buf then
				context.buf = nil -- Reset context
			end
			global:save_data()
			project:save_data()
		end,
	})
	vim.schedule(function()
		cmp.register_source("cmp-adaptive-freq", M.new())
	end)

	
end

return M