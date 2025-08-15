local autosave = {}
local uv = vim.loop
-- Configurable save intervals (seconds)
local SAVE_INTERVAL = 30 -- 5 minutes
local DEBOUNCE_DELAY = 30 -- Quick save after last edit

-- State tracking
local dirty = false
local last_activity = uv.now()

--- Schedule save if data changed
local function mark_dirty()
	dirty = true
	last_activity = os.time()
end
autosave.dir = ""
---@param string
function autosave.setdir(dir, hash)
	autosave.dir = dir
	autosave.hash = hash
end
local function save_data(word_id_map, uni, relation_map, pairing_map)
    if not dirty or autosave.dir == "" then return end

    local data = {
        word_id_map = word_id_map:serialize(),
        unigram_cms = uni:serialize(),
        relation_map = relation_map:serialize(),
        pairing_map = pairing_map:serialize(),
        timestamp = os.time(),
    }

    -- Serialize with vim.mpack
    local blob = vim.mpack.encode(data)
    vim.fn.mkdir(autosave.dir, "p")

    local f, err = io.open(autosave.dir .. autosave.hash ..".mpack", "wb")
    if not f then
        vim.notify("Failed to open file for writing: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local ok, write_err = pcall(function() f:write(blob) end)
    f:close()

    if not ok then
		dirty = false
        vim.notify("Failed to write data: " .. tostring(write_err), vim.log.levels.ERROR)
    end
end
function autosave.save(word_id_map, unigram_cms, relation_map, pairing_map)
	save_data(word_id_map, unigram_cms, relation_map, pairing_map)
end
--- Initialize autosave system
function autosave.setup(word_id_map, unigram_cms, relation_map, pairing_map)
    -- Wrap increment methods to mark dirty
    local original_increment = unigram_cms.increment
    unigram_cms.increment = function(self, key)
        mark_dirty()
        return original_increment(self, key)
    end

    relation_map.increment_results = function(self, ...)
        mark_dirty()
        return getmetatable(self).__index.increment_results(self, ...)
    end

    pairing_map.increment_results = function(self, ...)
        mark_dirty()
        return getmetatable(self).__index.increment_results(self, ...)
    end

    -- Setup periodic save
    local timer = uv.new_timer()
    timer:start(
        SAVE_INTERVAL * 1000,
        SAVE_INTERVAL * 1000,
        vim.schedule_wrap(function()
            if dirty and uv.now() - last_activity > DEBOUNCE_DELAY * 1000 then
                save_data(word_id_map, unigram_cms, relation_map, pairing_map)
            end
        end
    ))
end
return autosave
