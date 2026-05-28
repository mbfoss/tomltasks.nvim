--- Append-only file logger for tracing exec/coroutine bugs.
--- Disabled by default; call log.enable() from init.lua or interactively.
---@class easytasks.util.log
local M = {}

---@type file*?
local _file    = nil
local _enabled = false
local _min     = 1  -- 1=debug 2=info 3=warn 4=error

local _labels = { "DEBUG", "INFO ", "WARN ", "ERROR" }

local function write(level, msg)
    if not _enabled or not _file or level < _min then return end
    local ts = os.date("%H:%M:%S")
    _file:write(string.format("[%s] %s %s\n", ts, _labels[level], msg))
    _file:flush()
end

--- Open the log file and start writing. Appends to existing content.
---@param path? string  defaults to {stdpath("log")}/easytasks.log
---@param min_level? "debug"|"info"|"warn"|"error"
function M.enable(path, min_level)
    if _enabled then M.disable() end
    local levels = { debug = 1, info = 2, warn = 3, error = 4 }
    _min = levels[min_level or "info"] or 2
    local p = path or (vim.fn.stdpath("log") .. "/easytasks.log")
    _file = io.open(p, "a")
    if not _file then
        vim.notify("easytasks: cannot open log " .. p, vim.log.levels.ERROR)
        return
    end
    _enabled = true
    write(2, "=== easytasks log opened (level=" .. (min_level or "debug") .. ") ===")
end

--- Close the log file.
function M.disable()
    if _enabled then write(2, "=== easytasks log closed ===") end
    if _file then _file:close(); _file = nil end
    _enabled = false
end

---@return boolean
function M.is_enabled() return _enabled end

---@param fmt string
---@param ... any
function M.debug(fmt, ...) write(1, string.format(fmt, ...)) end

---@param fmt string
---@param ... any
function M.info(fmt, ...)  write(2, string.format(fmt, ...)) end

---@param fmt string
---@param ... any
function M.warn(fmt, ...)  write(3, string.format(fmt, ...)) end

---@param fmt string
---@param ... any
function M.error(fmt, ...) write(4, string.format(fmt, ...)) end

return M
