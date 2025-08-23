local cmp = require("cmp")
local uv = vim.loop

local tier = require("cmp-adaptive-freq.tier")
local global = tier[3]
local project = tier[2]
local session = tier[1]

local last_line = ""
local last_line_word_count = 0
local last_line_number = -1
local last_diff = ""
local M = {}

M.new = function()
	return setmetatable({}, {__index = M})
end
local config = {}


---@param buf number
local function scan_buffer(buf)
	if not vim.api.nvim_buf_is_loaded(buf) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	local window = {}
	local window_size = 10
	for _, line in ipairs(lines) do
		for word in line:gmatch("%S+") do
			local word_id = global.word_id_map:get_id(word)
			if #word < 4 then
				table.insert(window, word_id)
				if #window > window_size then
					table.remove(window, 1)
				end
				goto continue
			end
			
			if math.random() < 0.9 then
				project.frequency:increment(word_id, 1)
				if math.random() < 0.8 then
					global.frequency:increment(word_id, 1)
				end
			end

			table.insert(window, word_id)
			if #window > window_size then
				table.remove(window, 1)
			end

			if #window > 1 then
				-- Bigram: current word with previous word
					project.pairs:increment_results(window[#window - 1], word_id)
					global.pairs:increment_results(window[#window - 1], word_id)
					-- Relations: current word with all words in window
				-- Traverse backwards from the most recent word to find where to start context
				for i = #window - 1, 1, -1 do
					local word = window[i]
					local has_punctuation = string.find(word, "%%p")

					if has_punctuation then
						for x = 1, i, 1 do
							table.remove(window, 1)
						end
						break
					end
				end

				-- Process context from start_index to the word before current
				for i = 1, #window - 1 do
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
			::continue::
		end
	end
	global:save_data()
	project:save_data()
end

---@param buf number
local function scan_line(buf)
	if not vim.api.nvim_buf_is_loaded(buf) then
		return
	end
	---@type string
	local line = vim.api.nvim_get_current_line()
	local line_number = vim.fn.line('.')
	if line == last_line or last_line_number ~= vim.fn.line('.') then
		last_line_number = vim.fn.line('.')
		last_line = line
		return
	end
	local quickdiff, count = line:gsub("%s+","")
	if count == last_line_word_count or quickdiff < last_diff + 3 then
		return
	end
	last_diff = quickdiff
	if count < last_line_word_count or #line < #last_line then
		-- we don't decrement
		last_line = line
		last_line_word_count = count
		return
	end
	if #line == #last_line + 1 then
		return
	end
	last_line = line
	last_line_number = line_number
	last_line_word_count = count

	local idx = -1
	for i = 1, last_line_word_count do
		if line:sub(i, i) ~= last_line:sub(i, i) then
			idx = i
			break
		end
	end
	local context = {}
	local window_size = 10
	local cut = line:sub(1, idx)
	for w in cut:gmatch("%S+") do
		if #context > window_size then
			table.remove(context, 1)
		end
		table.insert(context, w)
	end
	local word = context[#context]
	local word_id = global.word_id_map:get_id(word)
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
	for i = #words - 1, 1, -1 do
		local word =words[i]
		local has_punctuation = string.find(word, "%%p")

		if has_punctuation then
			for x = 1, i, 1 do
				table.remove(words, 1)
			end
			break
		end
	end
	for i = 1, #words- 1 do
		session.relations_map:increment_results(
			word_id,
			words[i],
			#words - i
		)
		if math.random() < 0.6 then
			project.relations_map:increment_results(
				word_id,
				words[i],
				#words - i
			)
			if math.random() < 0.5 then
				global.relations_map:increment_results(
					word_id,
					words[i],
					#words- it
				)
			end
		end

	end
end

---@param ft string
---@return boolean
local function is_supported_ft()
	local ft = vim.bo.filetype
	return ft == "markdown" or ft == "org" or ft == "text" or ft == "plain" or ft == "latex" or ft == "asciidoc"
end

---@param session_score integer
---@param project_score integer
---@param global_score integer
---@return number
local function formula (session_score, project_score, global_score)
	return (math.log(session_score) * 3 + 3) + (math.log(project_score) -1) + (math.log(global_score) -2)
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
			global.relations_map:get_score(ctx_id, id)
		)
	end
	score = (math.log(uni_score + 1) * 0.55) + (math.log(bi_score + 1) * 0.35) + (math.log(rel_score + 1) * 0.1)
	return score
end
M.get_keyword_pattern = function()
    return [[.]]
end

function M:complete(params, callback)
	local line = params.context.cursor_before_line
	local input = line:match("%S+$") or ""

	if input == "" then
		return callback({ items = {} })
	end
	local min_length = #input + 2

	local candidates = {}
	for word, id in pairs(global.word_id_map.word_to_id) do
		if word:find(input, 1, true) == 1 and #word >= min_length then
			table.insert(candidates, {
				word = word,
				id = id,
				score = 0,
			})
		end
	end
	
	if #candidates == 0 then
		return callback({ items = {} })
	end

	local context = {}
	for l in line:gmatch("%S+") do
		if #context == 11 then
			table.remove(context, 1)
		end
		table.insert(context, global.word_id_map:get_id(l))
	end
	table.remove(context,#context)
	if #context > 0 then

		for _, candidate in ipairs(candidates) do
			candidate.score = calculate_score(candidate.id, context)
		end
	end

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

function M.setup(opts)
	config.max_items = opts.max_items or 5

	local group = vim.api.nvim_create_augroup("CmpAdaptiveFreq", {})

	vim.api.nvim_create_user_command("CmpAdaptiveFreqScanBuffer", 
		function ()
			local buf = vim.api.nvim_get_current_buf()
			scan_buffer(buf)
		end,
		{}
	)
	vim.api.nvim_create_user_command("CmpAdaptiveFreqDeleteGlobalData", 
		function ()
			local filepath = vim.fn.stdpath("cache") .. "/cmp-adaptive-freq/global".. ".json"
			
			local choice = vim.fn.confirm('Delete file: ' .. filepath .. ' the global autocomplete data?', "&Yes\n&No", 2)
			if choice == 1 then
				local success = vim.fn.delete(filepath) == 0
				if success then
					vim.notify('File deleted: ' .. filepath, vim.log.levels.INFO)
				else
					vim.notify('Failed to delete file', vim.log.levels.ERROR)
				end
			end
		end,
		{}
	)
	vim.api.nvim_create_user_command("CmpAdaptiveFreqDeleteProjectData", 
		function ()
			if not is_supported_ft() then
				vim.notify("unsure of project to delete, enter a buffer first!")
				return
			end
			local filepath = vim.fn.stdpath("cache") .. "/cmp-adaptive-freq" .. project.file
			
			local choice = vim.fn.confirm('Delete file: ' .. filepath .. ' the project autocomplete data?', "&Yes\n&No", 2)
			if choice == 1 then
				local success = vim.fn.delete(filepath) == 0
				if success then
					vim.notify('File deleted: ' .. filepath, vim.log.levels.INFO)
				else
					vim.notify('Failed to delete file', vim.log.levels.ERROR)
				end
			end
		end,
		{}
	)
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		group = group,
		callback = function(args)
			if is_supported_ft(vim.bo[args.buf].filetype) then
				global:load_data()
				project:load_data()
			end
		end,
	})
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = group,
		callback = function(args)
			if is_supported_ft(vim.bo[args.buf].filetype) then
				scan_line(args.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd({"VimLeave", "BufLeave", "FocusLost"},  {
		group = group,
		callback = function(args)
			if not is_supported_ft() then
				return
			end
			global:save_data()
			project:save_data()
		end,
	})

	vim.fn.mkdir(vim.fn.stdpath("cache") .. "/cmp-adaptive-freq", "p")
	vim.schedule(function()
		cmp.register_source("cmp-adaptive-freq", M.new())

	end)
end

return M