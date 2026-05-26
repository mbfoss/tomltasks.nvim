--- Per-task terminal buffer management.
---@class easytasks.process.term
local M = {}

---@type table<string, integer>  task_name → run counter (increments each open)
local _counters = {}

--- Create a fresh terminal buffer for a task.
--- Each call produces a uniquely-named buffer; parallel runs for the same task
--- each receive their own buffer.
---@param task_name string
---@return integer bufnr
function M.open(task_name)
    local idx = (_counters[task_name] or 0) + 1
    _counters[task_name] = idx

    local bufname = idx == 1
        and "easytasks://task/" .. task_name
        or  "easytasks://task/" .. task_name .. "/" .. idx

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].buflisted = true
    vim.bo[bufnr].swapfile  = false
    pcall(vim.api.nvim_buf_set_name, bufnr, bufname)
    return bufnr
end

return M
