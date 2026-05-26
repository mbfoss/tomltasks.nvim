--- Per-task terminal buffer management.
---@class easytasks.process.term
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
    -- buftype is set to "terminal" by jobstart {term=true}; don't pre-set it
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].buflisted = true
    vim.bo[bufnr].swapfile  = false
    pcall(vim.api.nvim_buf_set_name, bufnr, bufname)
    bufs[task_name] = bufnr
    return bufnr
end

--- Return the current bufnr for a task, or nil if not yet created / invalid.
---@param task_name string
---@return integer?
function M.get(task_name)
    local b = bufs[task_name]
    return (b and vim.api.nvim_buf_is_valid(b)) and b or nil
end

return M
