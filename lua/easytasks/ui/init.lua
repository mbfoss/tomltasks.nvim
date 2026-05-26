local M = {}

local _PREFIX = "[easytasks] "

---@param msg string
function M.notify_info(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.INFO)
end

---@param msg string
function M.notify_warning(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.WARN)
end

---@param msg string
function M.notify_error(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.ERROR)
end

---@param winid number?
function M.get_window_text_width(winid)
    if not winid or winid == 0 then winid = vim.api.nvim_get_current_win() end
    local infos = vim.fn.getwininfo(winid)
    if not infos or #infos == 0 then
        return vim.o.columns - 3 -- fallback assumption
    end
    local info = infos[1]
    return info.width - info.textoff
end

function M.is_regular_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if vim.bo[bufnr].buftype ~= '' then
        return false
    end
    return true
end

---@param msg string
---@param default_yes boolean
---@param callback fun(confirmed: boolean|nil)
function M.confirm_action(msg, default_yes, callback)
    local choices = "&Yes\n&No"
    local default = default_yes and 1 or 2

    local ok, choice = pcall(vim.fn.confirm, msg, choices, default)
    if not ok then
        callback(nil)
        return
    end
    if choice == 1 then
        callback(true)
    elseif choice == 2 then
        callback(false)
    else
        callback(nil)
    end
end

---@param c1 number
---@param c2 number
---@param alpha number
---@return string
function M.blend_colors(c1, c2, alpha)
    local r1 = bit.rshift(c1, 16)
    local g1 = bit.band(bit.rshift(c1, 8), 0xFF)
    local b1 = bit.band(c1, 0xFF)

    local r2 = bit.rshift(c2, 16)
    local g2 = bit.band(bit.rshift(c2, 8), 0xFF)
    local b2 = bit.band(c2, 0xFF)

    local r = math.floor(r1 * (1 - alpha) + r2 * alpha)
    local g = math.floor(g1 * (1 - alpha) + g2 * alpha)
    local b = math.floor(b1 * (1 - alpha) + b2 * alpha)

    return string.format("#%02x%02x%02x", r, g, b)
end

--- @param buffer integer Buffer to display, or 0 for current buffer
--- @param enter boolean Enter the window (make it the current window)
--- @param config vim.api.keyset.win_config Map defining the window configuration
--- @param on_close function
--- @return integer winid, integer augroup
function M.create_window(buffer, enter, config, on_close)
    local win = vim.api.nvim_open_win(buffer, enter, config)
    local augroup = vim.api.nvim_create_augroup("keystone_window_#" .. win, { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        callback = function(args)
            local closedwin = tonumber(args.match)
            if closedwin == win then
                vim.api.nvim_del_augroup_by_id(augroup)
                on_close()
            end
        end
    })
    return win, augroup
end

---@param listed boolean
---@param buffer_options vim.bo?
---@param on_delete function?
function M.create_sratch_buffer(listed, buffer_options, on_delete)
    local buf = vim.api.nvim_create_buf(listed, true)
    local bo = { ---@type vim.bo
        buftype = "nofile",
        swapfile = false,
        modeline = false,
    }
    if not listed then
        bo.bufhidden = 'wipe'
    end
    if buffer_options then
        for k, v in pairs(buffer_options) do
            bo[k] = v
        end
    end
    for k, v in pairs(bo) do
        vim.bo[buf][k] = v
    end
    if on_delete then
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            buffer = buf,
            once = true,
            callback = function(ev)
                on_delete()
            end,
        })
    end
    return buf
end

return M
