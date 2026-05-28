local M   = {}
local Cst = require("easytasks.toml.Cst")
local K   = Cst.Kind

local _SYMBOL_KIND_FUNCTION = 12

---@param r integer[]  {r1, c1, r2, c2} 0-indexed
---@return lsp.Range
local function _to_lsp_range(r)
    return {
        start   = { line = r[1], character = r[2] },
        ["end"] = { line = r[3], character = r[4] },
    }
end

---@param context easytasks.LspBufferContext
---@param _params lsp.DocumentSymbolParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.DocumentSymbol[])
function M.handler(context, _params, callback)
    local tasks = context.data and context.data.tasks
    if not tasks or #tasks == 0 then
        callback(nil, {})
        return
    end

    local dt  = context.decode_tree
    local cst = context.cst
    if not dt or not cst then callback(nil, {}) return end

    local tasks_id = dt:get_child_id(dt:root_id(), "tasks")
    if not tasks_id then callback(nil, {}) return end

    ---@type lsp.DocumentSymbol[]
    local symbols = {}

    for i, task in ipairs(tasks) do
        if type(task) == "table" and task.name then
            local task_id    = dt:get_child_id(tasks_id, tostring(i))
            local name_id    = task_id and dt:get_child_id(task_id, "name")
            local task_range = task_id and dt:range_of_id(task_id)

            if task_range then
                symbols[#symbols + 1] = {
                    name           = task.name,
                    detail         = task.type or "",
                    kind           = _SYMBOL_KIND_FUNCTION,
                    range          = _to_lsp_range(task_range),
                    selectionRange = _to_lsp_range(task_range),
                }
            end
        end
    end

    callback(nil, symbols)
end

return M
