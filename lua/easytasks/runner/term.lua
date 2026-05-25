--- Per-task terminal buffer management.
--- All task output shares one split (the "output window"). Switching tasks
--- replaces the buffer in that window rather than opening new splits, which
--- lets dep task terminals be visible for jobstart without cluttering the layout.
---@class easytasks.term
local M = {}

---@type table<string, integer>  task_name → bufnr
local bufs = {}

---@type integer?  the dedicated task-output split window
local output_win = nil

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
    -- buftype is set to "terminal" by jobstart {term=true}; don't pre-set it
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].buflisted = true
    vim.bo[bufnr].swapfile  = false
    pcall(vim.api.nvim_buf_set_name, bufnr, bufname)
    bufs[task_name] = bufnr
    return bufnr
end

--- Show a task's buffer in the shared output window.
--- Creates the window (botright split) the first time; reuses it thereafter.
--- Swapping the buffer in an existing window is sufficient for jobstart {term=true}
--- — the job stays attached to its buffer regardless of which window shows it.
---@param task_name string
---@return integer? win  the output window id, or nil if the buffer is missing
function M.show(task_name)
    local bufnr = bufs[task_name]
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

    -- Reuse the shared output window if it is still open
    if output_win and vim.api.nvim_win_is_valid(output_win) then
        vim.api.nvim_win_set_buf(output_win, bufnr)
        return output_win
    end

    -- Open a new split and remember it as the output window
    vim.cmd("botright split")
    output_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(output_win, bufnr)
    vim.wo[output_win].number         = false
    vim.wo[output_win].relativenumber = false
    vim.wo[output_win].wrap           = false
    return output_win
end

--- Return the current bufnr for a task, or nil if not yet created / invalid.
---@param task_name string
---@return integer?
function M.get(task_name)
    local b = bufs[task_name]
    return (b and vim.api.nvim_buf_is_valid(b)) and b or nil
end

return M
