---@class easytasks.tk.fixedwin
local M = {}

-- A "fixed window" is a split whose size along one axis is pinned:
--   * axis = "height" → a full-width horizontal split with 'winfixheight'
--   * axis = "width"  → a full-height vertical split with 'winfixwidth'
-- The size is expressed as a ratio of the total editor lines/columns, tracked
-- live as the user resizes, and re-applied when the layout changes (e.g. the
-- user opens a new split) so the window recovers its intended size.

---@class easytasks.tk.fixedwin.AxisSpec
---@field split string                    ex command that creates the split
---@field fix   string                    window option that pins the axis
---@field frame "col"|"row"               parent frame kind that makes re-pinning safe
---@field total fun(): integer            total lines/columns available
---@field get   fun(win: integer): integer
---@field set   fun(win: integer, n: integer)

---@type table<string, easytasks.tk.fixedwin.AxisSpec>
local _AXES = {
    height = {
        split = "botright split",
        fix   = "winfixheight",
        frame = "col",
        total = function() return vim.o.lines end,
        get   = vim.api.nvim_win_get_height,
        set   = vim.api.nvim_win_set_height,
    },
    width = {
        split = "botright vsplit",
        fix   = "winfixwidth",
        frame = "row",
        total = function() return vim.o.columns end,
        get   = vim.api.nvim_win_get_width,
        set   = vim.api.nvim_win_set_width,
    },
}

-- `vim.wo[win].opt = val` sets both the window-local value AND nvim's hidden
-- global default (the value new windows inherit) — so it can silently leak the
-- pinning option into every future plain window. Force `scope = "local"`.
---@param win integer
---@param opt string
---@param val any
local function setlocal(win, opt, val)
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = "local" })
end

-- Find the frame kind ("col"/"row") of the node directly containing `target`.
---@param node   table    a vim.fn.winlayout() node
---@param target integer  window id
---@return "col"|"row"|nil
local function parent_frame(node, target)
    if node[1] == "leaf" then return nil end
    for _, child in ipairs(node[2]) do
        if child[1] == "leaf" and child[2] == target then return node[1] end
    end
    for _, child in ipairs(node[2]) do
        local kind = parent_frame(child, target)
        if kind then return kind end
    end
    return nil
end

---@class easytasks.tk.fixedwin.Opts
---@field min?   integer  minimum size (lines/columns); default 1
---@field enter? boolean  leave the cursor in the new window; default false (returns to the previous window)

--- Create a fixed-size split that recovers its size across layout changes.
---
--- The window is pinned along `axis` and sized to `ratio` of the total editor
--- lines (height) or columns (width). It re-applies that size whenever a new
--- split appears — but only when it has a neighbour on the fixed axis that can
--- absorb the freed space (a window above/below for height, beside it for
--- width). Without such a neighbour, shrinking would strand the freed space
--- since 'winfix{height,width}' forbids siblings from reclaiming it, so the
--- re-pin is skipped. The ratio is updated as the user resizes the window, and
--- the last-known ratio is handed to `on_delete` when the window closes.
---@param axis "height"|"width"
---@param ratio number                     fraction of total lines/columns (0..1)
---@param on_delete? fun(ratio: number)     called when the window closes, with the last-known ratio
---@param opts? easytasks.tk.fixedwin.Opts
---@return integer winid
function M.create_fixed_win(axis, ratio, on_delete, opts)
    local spec = assert(_AXES[axis], "fixedwin: unknown axis " .. tostring(axis))
    opts = opts or {}
    local min = opts.min or 1

    local prev_win = vim.api.nvim_get_current_win()
    vim.cmd(spec.split)
    local win = vim.api.nvim_get_current_win() ---@type integer?
    assert(win)

    setlocal(win, spec.fix, true)

    -- last-known ratio, kept current as the user resizes; closed over by the
    -- autocmds below and reported to on_delete.
    local state = { ratio = ratio }

    ---@param r number
    ---@return integer
    local function size_for(r)
        return math.max(min, math.floor(spec.total() * r))
    end

    -- Programmatic sizing (the initial fit and the layout-change re-pins) and
    -- the transient equalisation nvim performs while a split is being created
    -- or removed all emit WinResized, just like a user drag. Two guards keep
    -- those from clobbering the tracked ratio with a bogus, transient size:
    --   * `last_applied` — the size we set ourselves; a WinResized reporting it
    --     is our own doing and carries no new information.
    --   * `settling`     — held while a layout change is being absorbed, so the
    --     transient resizes it emits are ignored until the window re-settles.
    local last_applied ---@type integer?
    local settling = false

    ---@param n integer
    local function apply_size(n)
        spec.set(win, n)
        last_applied = spec.get(win)
    end

    apply_size(size_for(ratio))

    if not opts.enter then
        vim.api.nvim_set_current_win(prev_win)
    end

    -- Whether re-pinning the window to its fixed size is safe: it must share its
    -- parent frame with a neighbour on the fixed axis (a "col" frame for height,
    -- a "row" frame for width). Otherwise the freed space is stranded.
    ---@return boolean
    local function pinnable()
        if not win or not vim.api.nvim_win_is_valid(win) then return false end
        return parent_frame(vim.fn.winlayout(), win) == spec.frame
    end

    -- Re-pin to the tracked ratio, but only when a neighbour can absorb the
    -- freed space (see pinnable()).
    local function repin()
        if win and pinnable() then apply_size(size_for(state.ratio)) end
    end

    -- Absorb a layout change (new/closed split) on the next tick, holding
    -- `settling` across the re-pin and one tick past it so both the transient
    -- resizes the change emits and the re-pin's own resize are ignored by the
    -- WinResized handler.
    local function absorb_layout_change()
        settling = true
        vim.schedule(function()
            repin()
            vim.schedule(function() settling = false end)
        end)
    end

    local group = vim.api.nvim_create_augroup("EasyTasksFixedWin" .. win, { clear = true })

    -- re-apply the size when new splits appear so the window stays pinned
    vim.api.nvim_create_autocmd("WinNew", {
        group    = group,
        callback = absorb_layout_change,
    })

    -- track manual resizes so the pinned size and the ratio handed to on_delete
    -- follow the user's latest adjustment (ignoring our own/transient resizes)
    vim.api.nvim_create_autocmd("WinResized", {
        group    = group,
        callback = function()
            if settling or not win or not pinnable() then return end
            local size = spec.get(win)
            if size ~= last_applied then
                state.ratio = size / spec.total()
                vim.notify("new ratio: " .. state.ratio)
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group    = group,
        callback = function(args)
            if tonumber(args.match) ~= win then
                absorb_layout_change()
                return
            end
            -- state.ratio has been kept current by the (guarded) WinResized
            -- handler, so it already holds the user's latest good ratio; reading
            -- the window here would risk capturing a teardown transient instead.
            win = nil
            vim.api.nvim_del_augroup_by_id(group)
            if on_delete then on_delete(state.ratio) end
        end,
    })

    return win
end

return M
