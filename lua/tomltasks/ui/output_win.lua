---@brief The single split that shows a run's buffer, used when dock.nvim is not
---installed.
---
---A run registers its log buffer and every buffer its task type spawns here with
---a priority; this window holds the highest-priority live one. One window is
---reused for all of them: registering a buffer swaps the occupant rather than
---opening a second split. There is no tab bar — `tomltasks.ui.runview` hands the
---tabbed presentation to dock.nvim when it is available.

local fixedwin       = require("tomltasks.tk.fixedwin")

---@class tomltasks.ui.output_win
local M              = {}

---One buffer registered for display.
---@class tomltasks.ui.output_win.Entry
---@field bufnr    integer
---@field priority integer
---@field seq      integer  registration order; breaks priority ties toward the newest

---@type tomltasks.ui.output_win.Entry[]
local _entries       = {}
local _seq           = 0

---@type integer?
local _win           = nil
---@type integer?
local _shown         = nil
---The buffer the window held when it was closed, live only for the tick of the
---close: nvim closes the window before announcing the buffer's deletion, so this
---is how `refresh` tells that close apart from the user closing the window.
---@type integer?
local _closed_with   = nil
---@type number?
local _ratio         = nil

local _HEIGHT_RATIO  = 0.22
local _MIN_HEIGHT    = 6

local _augroup       = vim.api.nvim_create_augroup("tomltasks.output_win", { clear = true })

-- `vim.wo[win].opt = val` also writes nvim's hidden global default, leaking this
-- window's settings into every future window. Force `scope = "local"`.
---@param win integer
---@param opt string
---@param val any
local function _setlocal(win, opt, val)
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = "local" })
end

---Drop `bufnr`, plus any entry whose buffer is already gone. Buffer numbers are
---reused, so a stale entry eventually names an unrelated buffer.
---@param bufnr? integer  a buffer being deleted, still valid at this point
local function _prune(bufnr)
    for i = #_entries, 1, -1 do
        local b = _entries[i].bufnr
        if b == bufnr or not vim.api.nvim_buf_is_valid(b) then
            table.remove(_entries, i)
        end
    end
end

---The buffer the window should hold: the highest-priority one, the newest of
---them when several share a priority.
---@return integer?  bufnr
local function _target()
    local best ---@type tomltasks.ui.output_win.Entry?
    for _, e in ipairs(_entries) do
        if not best or e.priority > best.priority
            or (e.priority == best.priority and e.seq > best.seq) then
            best = e
        end
    end
    return best and best.bufnr
end

---@return integer?  the window, when open
local function _open_win()
    if _win and vim.api.nvim_win_is_valid(_win) then return _win end
    return nil
end

---@param bufnr integer
local function _display(bufnr)
    local win = _open_win()
    if not win or _shown == bufnr then return end
    _setlocal(win, "winfixbuf", false)
    vim.api.nvim_win_set_buf(win, bufnr)
    _setlocal(win, "winfixbuf", true)
    _shown = bufnr
    if vim.bo[bufnr].buftype == "terminal" then
        local last = vim.api.nvim_buf_line_count(bufnr)
        pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    end
end

---Open the window (a no-op when already open) and show the target buffer.
---@param focus? boolean  leave the cursor in the window; default false
function M.open(focus)
    _prune()
    local bufnr = _target()
    if not bufnr then return end
    local win = _open_win()
    if win then
        if focus then vim.api.nvim_set_current_win(win) end
        _display(bufnr)
        return
    end
    -- fixedwin owns the split, its height pinning and the resize/ratio tracking;
    -- we only swap in the run's buffer. Its on_delete fires on WinClosed, so
    -- closing by any route — ours, `:q` — records the height and drops the state.
    _win = fixedwin.create_fixed_win("height", _ratio or _HEIGHT_RATIO,
        function(ratio)
            _ratio       = ratio
            _closed_with = _shown
            _win, _shown = nil, nil
            -- Only a deletion of the buffer just closed with reopens the window,
            -- and only on this tick — a `:q` a moment earlier must not.
            vim.schedule(function() _closed_with = nil end)
        end,
        { min = _MIN_HEIGHT, enter = focus or false })

    _setlocal(_win, "winfixbuf", true)
    _setlocal(_win, "number", false)
    _setlocal(_win, "relativenumber", false)
    _setlocal(_win, "signcolumn", "no")
    _setlocal(_win, "spell", false)
    _setlocal(_win, "wrap", false)

    _shown = nil
    _display(bufnr)
end

---Close the window, keeping the registry — the next registered buffer (or an
---explicit `open`) brings it back at the height it was left at.
function M.close()
    local win = _open_win()
    if win then vim.api.nvim_win_close(win, true) end
    _win, _shown = nil, nil
end

---@param focus? boolean  leave the cursor in the window when opening
function M.toggle(focus)
    if _open_win() then M.close() else M.open(focus) end
end

---Bring the window in line with the registry: show the highest-priority live
---buffer, or close once the last buffer is gone. A buffer's deletion takes the
---window with it, so `deleted` reopens it for the next buffer in line.
---@param deleted? integer  a buffer being deleted, to forget before deciding
function M.refresh(deleted)
    _prune(deleted)
    local reopen = deleted ~= nil and deleted == _closed_with
    _closed_with = nil
    local bufnr  = _target()
    if not bufnr then
        M.close()
    elseif _open_win() then
        _display(bufnr)
    elseif reopen then
        M.open(false)
    end
end

---Register a buffer for display. It takes the window immediately when it
---outranks the current occupant, and the window opens on the first registration.
---@param bufnr integer
---@param opts? { priority?: integer }
function M.add(bufnr, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    opts        = opts or {}
    _seq        = _seq + 1
    local entry = { bufnr = bufnr, priority = opts.priority or 0, seq = _seq }

    -- Re-registering a buffer restates its rank rather than adding a second entry
    -- (and a second deletion autocmd) for the same buffer.
    local known = false
    for i, e in ipairs(_entries) do
        if e.bufnr == bufnr then
            _entries[i], known = entry, true
            break
        end
    end
    if not known then
        _entries[#_entries + 1] = entry
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            group    = _augroup,
            buffer   = bufnr,
            once     = true,
            callback = function() M.refresh(bufnr) end,
        })
    end

    M.open(false)
end

---Drop a buffer from the registry without deleting it.
---@param bufnr integer
function M.remove(bufnr)
    M.refresh(bufnr)
end

---Whether any live buffer is registered, i.e. whether there is anything to open
---the window for.
---@return boolean
function M.has_content()
    _prune()
    return #_entries > 0
end

---@return boolean
function M.is_open()
    return _open_win() ~= nil
end

---@return integer? winid  the window, when open
function M.winid()
    return _open_win()
end

return M
