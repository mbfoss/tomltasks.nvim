--- Per-task terminal buffer management.
---@class easytasks.process.term
local M = {}

---@return integer bufnr
function M.open()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].buflisted = true
    vim.bo[bufnr].swapfile  = false
    return bufnr
end

return M
