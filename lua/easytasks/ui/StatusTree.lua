local uitool = require("easytasks.ui.utils")

---@class easytasks.ui.StatusTree.Item
---@field id any
---@field data any

---@class easytasks.ui.StatusTree.ItemDef
---@field id any
---@field data any

---@class easytasks.ui.StatusTree.Opts
---@field filetype string?
---@field formatter fun(id:any, data:any, expanded:boolean):string[][], string[][]
---@field collapsible boolean?

local _ns_id = vim.api.nvim_create_namespace('easytasksStatusTreeBuffer')

---@class easytasks.ui.StatusTree
---@field private _filetype     string?
---@field private _formatter    fun(id:any, data:any, expanded:boolean):string[][], string[][]
---@field private _bufnr        integer
---@field private _on_selection fun(id:any, data:any)?
---@field private _nodes        table<any, { data:any, parent_id:any, children:any[] }>
---@field private _roots        any[]
---@field private _flat_ids     any[]
local StatusTree = {}
StatusTree.__index = StatusTree

---@param opts easytasks.ui.StatusTree.Opts
---@return easytasks.ui.StatusTree
function StatusTree.new(opts)
    return setmetatable({
        _filetype     = opts.filetype,
        _formatter    = opts.formatter,
        _bufnr        = -1,
        _on_selection = nil,
        _nodes        = {},
        _roots        = {},
        _flat_ids     = {},
    }, StatusTree)
end

---@return integer
function StatusTree:get_bufnr()
    return self._bufnr
end

---@param callbacks { on_selection?: fun(id:any, data:any) }
function StatusTree:subscribe(callbacks)
    if callbacks.on_selection then
        self._on_selection = callbacks.on_selection
    end
end

---@private
function StatusTree:_render()
    local buf = self._bufnr
    if buf <= 0 or not vim.api.nvim_buf_is_loaded(buf) then return end

    self._flat_ids = {}
    for _, id in ipairs(self._roots) do
        table.insert(self._flat_ids, id)
        for _, child_id in ipairs(self._nodes[id].children) do
            table.insert(self._flat_ids, child_id)
        end
    end

    local lines, hl_calls = {}, {}
    for row0, id in ipairs(self._flat_ids) do
        local chunks = self._formatter(id, self._nodes[id].data, false)
        local line, col = "", 0
        for _, chunk in ipairs(chunks) do
            local txt, hl = chunk[1], chunk[2]
            txt = (txt or ""):gsub("\n", "↵")
            local len = #txt
            if len > 0 then
                if hl then
                    hl_calls[#hl_calls + 1] = { hl = hl, row = row0 - 1, s_col = col, e_col = col + len }
                end
                line = line .. txt
                col  = col + len
            end
        end
        lines[#lines + 1] = line
    end

    vim.api.nvim_buf_clear_namespace(buf, _ns_id, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    for _, h in ipairs(hl_calls) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, h.row, h.s_col, {
            end_col = h.e_col, hl_group = h.hl,
        })
    end
end

---@param on_deleted function
---@return integer bufnr, boolean created
function StatusTree:create_buffer(on_deleted)
    if self._bufnr ~= -1 then
        return self._bufnr, false
    end

    self._bufnr = uitool.create_sratch_buffer(false, {
        buftype    = "nofile",
        bufhidden  = "wipe",
        filetype   = self._filetype or "easytasks-tree",
        modifiable = false,
        swapfile   = false,
        undolevels = -1,
        buflisted  = false,
        modeline   = false,
    }, function()
        self._bufnr = -1
        on_deleted()
    end)

    self:_render()

    local function on_enter()
        local item = self:get_cursor_item()
        if item and self._on_selection then
            self._on_selection(item.id, item.data)
        end
    end

    vim.keymap.set("n", "<CR>",          on_enter, { buffer = self._bufnr, desc = "Select" })
    vim.keymap.set("n", "<2-LeftMouse>", on_enter, { buffer = self._bufnr, desc = "Select" })

    return self._bufnr, true
end

---@param parent_id any  -- nil for root
---@param item easytasks.ui.StatusTree.ItemDef
function StatusTree:add_item(parent_id, item)
    self._nodes[item.id] = { data = item.data, parent_id = parent_id, children = {} }
    if parent_id == nil then
        table.insert(self._roots, item.id)
    else
        local parent = self._nodes[parent_id]
        if parent then
            table.insert(parent.children, item.id)
        end
    end
    self:_render()
end

---@param id any
function StatusTree:remove_item(id)
    local node = self._nodes[id]
    if not node then return end

    for _, child_id in ipairs(node.children) do
        self._nodes[child_id] = nil
    end

    if node.parent_id == nil then
        for i, rid in ipairs(self._roots) do
            if rid == id then table.remove(self._roots, i); break end
        end
    else
        local parent = self._nodes[node.parent_id]
        if parent then
            for i, cid in ipairs(parent.children) do
                if cid == id then table.remove(parent.children, i); break end
            end
        end
    end

    self._nodes[id] = nil
    self:_render()
end

---@param id any
---@param data any
---@return boolean
function StatusTree:set_item_data(id, data)
    local node = self._nodes[id]
    if not node then return false end
    node.data = data
    self:_render()
    return true
end

---@return easytasks.ui.StatusTree.Item?
function StatusTree:get_cursor_item()
    local buf = self._bufnr
    if buf <= 0 then return nil end
    local winid = vim.fn.bufwinid(buf)
    if winid <= 0 then return nil end
    local row = vim.api.nvim_win_get_cursor(winid)[1]
    local id  = self._flat_ids[row]
    if not id then return nil end
    local node = self._nodes[id]
    if not node then return nil end
    return { id = id, data = node.data }
end

return StatusTree
