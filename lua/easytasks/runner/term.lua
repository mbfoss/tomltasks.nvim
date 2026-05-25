--- Per-task terminal buffer management.
--- Each task gets a terminal buffer named `easytasks://task/<name>`.
--- Terminal buffers cannot be reused after their job exits, so `open` always
--- creates a fresh buffer and discards the previous one if it is no longer visible.
---@class easytasks.term
local M = {}

---@type table<string, integer>  task_name → bufnr
local bufs = {}

--- Create a fresh terminal buffer for a task.
--- The previous buffer is deleted if it is not currently visible in any window.
---@param task_name string
---@return integer bufnr
function M.open(task_name)
    local bufname = "easytasks://task/" .. task_name
    local old = bufs[task_name]

    if old and vim.api.nvim_buf_is_valid(old) then
        local visible = false
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == old then
                visible = true
                break
            end
        end
        if not visible then
            vim.api.nvim_buf_delete(old, { force = true })
        end
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    -- buftype is set to "terminal" automatically by termopen; don't pre-set it
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile  = false
    -- pcall: name may collide if the old buffer is still visible
    pcall(vim.api.nvim_buf_set_name, bufnr, bufname)
    bufs[task_name] = bufnr
    return bufnr
end

--- Show the current buffer for a task in a bottom split.
--- Must be called after `open`. Does not create a new buffer.
---@param task_name string
---@return integer? win  window id where the buffer is shown, or nil
function M.show(task_name)
    local bufnr = bufs[task_name]
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            return win
        end
    end

    vim.cmd("botright split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.wo[win].number         = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap           = false
    return win
end

--- Return the current bufnr for a task, or nil if not yet created / invalid.
---@param task_name string
---@return integer?
function M.get(task_name)
    local b = bufs[task_name]
    return (b and vim.api.nvim_buf_is_valid(b)) and b or nil
end

return M
