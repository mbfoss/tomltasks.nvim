local ui = require('easytasks.ui')

---@alias easytasks.ui.TreeBuffer.FormatterFn fun(id:any, data:any, depth:integer):string[][], string[][]

---@class easytasks.ui.TreeBufferOpts
---@field formatter easytasks.ui.TreeBuffer.FormatterFn
---@field on_selection fun(id:any, data:any)?
---@field current_item_prefix string?
---@field indent_size integer?
---@field buffer_options vim.bo?

local _ns_id = vim.api.nvim_create_namespace('EasytasksTreeBuffer')

---@class easytasks.ui.TreeBuffer.Node
---@field data any
---@field parent_id any|nil
---@field children any[]
---@field depth integer

---@class easytasks.ui.TreeBuffer
---@field _buf integer
---@field _formatter easytasks.ui.TreeBuffer.FormatterFn
---@field _on_selection fun(id:any, data:any)?
---@field _prefix string
---@field _current_id any
---@field _roots any[]
---@field _nodes table<any, easytasks.ui.TreeBuffer.Node>
---@field _render_order any[]
---@field _indent_size integer
local TreeBuffer = {}
TreeBuffer.__index = TreeBuffer

---@param opts easytasks.ui.TreeBufferOpts
---@return easytasks.ui.TreeBuffer
function TreeBuffer.new(opts)
    local self = setmetatable({}, TreeBuffer)

    self._buf = ui.create_sratch_buffer(false, opts.buffer_options)
    self._formatter = opts.formatter
    self._on_selection = opts.on_selection
    self._prefix = (opts.current_item_prefix or ">") .. " "
    self._current_id = nil
    self._roots = {}
    self._nodes = {}
    self._render_order = {}
    self._indent_size = opts.indent_size or 2

    vim.keymap.set("n", "<CR>", function()
        local id, data = self:cursor_item()
        if id and self._on_selection then
            self._on_selection(id, data)
        end
    end, { buffer = self._buf, desc = "Select item" })

    return self
end

---@return integer
function TreeBuffer:buf()
    return self._buf
end

function TreeBuffer:_compute_render_order()
    local order = {}
    local function dfs(id)
        table.insert(order, id)
        for _, child_id in ipairs(self._nodes[id].children) do
            dfs(child_id)
        end
    end
    for _, root_id in ipairs(self._roots) do
        dfs(root_id)
    end
    self._render_order = order
end

---@param index integer
---@return integer
function TreeBuffer:_row_for_index(index)
    return index - 1
end

---@param id any
---@param data any
---@param row integer
---@param depth integer
---@return string line, table hl_calls, table extmark_data
function TreeBuffer:_render_item(id, data, row, depth)
    local hl_calls = {}
    local extmark_data = {}
    local text_chunks, virt = self._formatter(id, data, depth)
    local is_current = (id == self._current_id)

    local indent = string.rep(" ", depth * self._indent_size)
    local prefix_text = is_current and self._prefix or string.rep(" ", #self._prefix)
    local current_line = indent .. prefix_text
    local col = #indent + #prefix_text

    if is_current and #self._prefix > 0 then
        table.insert(hl_calls, { hl = "Statement", row = row, s_col = #indent, e_col = #indent + #prefix_text })
    end

    for _, chunk in ipairs(text_chunks) do
        local txt, hl = chunk[1], chunk[2]
        local len = #txt
        if len > 0 then
            if hl then
                table.insert(hl_calls, { hl = hl, row = row, s_col = col, e_col = col + len })
            end
            current_line = current_line .. txt
            col = col + len
        end
    end

    if virt and #virt > 0 then
        table.insert(extmark_data, { row, 0, { virt_text = virt, hl_mode = "combine" } })
    end

    return current_line, hl_calls, extmark_data
end

function TreeBuffer:render()
    local buf = self._buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    self:_compute_render_order()

    local buffer_lines = {}
    local extmarks_data = {}
    local hl_calls = {}

    for i, id in ipairs(self._render_order) do
        local row = self:_row_for_index(i)
        local node = self._nodes[id]
        local line, n_hls, n_exts = self:_render_item(id, node.data, row, node.depth)

        table.insert(buffer_lines, line)
        for _, h in ipairs(n_hls) do table.insert(hl_calls, h) end
        for _, e in ipairs(n_exts) do table.insert(extmarks_data, e) end
    end

    vim.api.nvim_buf_clear_namespace(buf, _ns_id, 0, -1)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_lines)
    vim.bo[buf].modifiable = false

    for _, h in ipairs(hl_calls) do
        vim.hl.range(buf, _ns_id, h.hl, { h.row, h.s_col }, { h.row, h.e_col })
    end

    for _, d in ipairs(extmarks_data) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end
end

---@param items { id: any, data: any, parent_id: any? }[]
function TreeBuffer:set_items(items)
    self._roots = {}
    self._nodes = {}

    for _, item in ipairs(items) do
        self._nodes[item.id] = {
            data = item.data,
            parent_id = item.parent_id or nil,
            children = {},
            depth = 0,
        }
    end

    for _, item in ipairs(items) do
        if item.parent_id and self._nodes[item.parent_id] then
            table.insert(self._nodes[item.parent_id].children, item.id)
        else
            table.insert(self._roots, item.id)
        end
    end

    local function set_depth(id, depth)
        local node = self._nodes[id]
        node.depth = depth
        for _, child_id in ipairs(node.children) do
            set_depth(child_id, depth + 1)
        end
    end
    for _, root_id in ipairs(self._roots) do
        set_depth(root_id, 0)
    end

    self:render()
end

---@param id any
---@param data any
---@param parent_id any?
function TreeBuffer:add_item(id, data, parent_id)
    if self._nodes[id] then
        return self:update_item(id, data)
    end

    local depth = 0
    if parent_id and self._nodes[parent_id] then
        depth = self._nodes[parent_id].depth + 1
        table.insert(self._nodes[parent_id].children, id)
    else
        table.insert(self._roots, id)
    end

    self._nodes[id] = {
        data = data,
        parent_id = parent_id,
        children = {},
        depth = depth,
    }

    self:render()
end

---@param id any
---@param data any
function TreeBuffer:update_item(id, data)
    local buf = self._buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    local node = self._nodes[id]
    if not node then return end

    node.data = data

    local row = nil
    for i, rid in ipairs(self._render_order) do
        if rid == id then
            row = self:_row_for_index(i)
            break
        end
    end
    if row == nil then return end

    local line, hl_calls, extmarks = self:_render_item(id, data, row, node.depth)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { line })
    vim.api.nvim_buf_clear_namespace(buf, _ns_id, row, row + 1)
    vim.bo[buf].modifiable = false

    for _, h in ipairs(hl_calls) do
        vim.hl.range(buf, _ns_id, h.hl, { h.row, h.s_col }, { h.row, h.e_col })
    end
    for _, d in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end
end

---@param id any
function TreeBuffer:remove_item(id)
    local node = self._nodes[id]
    if not node then return end

    local to_remove = {}
    local function collect(nid)
        table.insert(to_remove, nid)
        for _, child_id in ipairs(self._nodes[nid].children) do
            collect(child_id)
        end
    end
    collect(id)

    if node.parent_id and self._nodes[node.parent_id] then
        local siblings = self._nodes[node.parent_id].children
        for i, sid in ipairs(siblings) do
            if sid == id then
                table.remove(siblings, i)
                break
            end
        end
    else
        for i, rid in ipairs(self._roots) do
            if rid == id then
                table.remove(self._roots, i)
                break
            end
        end
    end

    for _, nid in ipairs(to_remove) do
        self._nodes[nid] = nil
    end

    self:render()
end

function TreeBuffer:clear()
    self._roots = {}
    self._nodes = {}
    self._render_order = {}
    self:render()
end

---@return any id, any data
function TreeBuffer:cursor_item()
    local winid = vim.fn.bufwinid(self._buf)
    if winid <= 0 then return nil, nil end

    local row = vim.api.nvim_win_get_cursor(winid)[1]
    local id = self._render_order[row]
    if not id then return nil, nil end

    return id, self._nodes[id].data
end

---@param id any|nil
function TreeBuffer:set_current(id)
    if self._current_id == id then return end

    local old_id = self._current_id
    self._current_id = id

    if old_id and self._nodes[old_id] then
        self:update_item(old_id, self._nodes[old_id].data)
    end
    if id and self._nodes[id] then
        self:update_item(id, self._nodes[id].data)
    end
end

---@return any
function TreeBuffer:current_item()
    return self._current_id
end

---@return fun():any, any, integer?
function TreeBuffer:iter_items()
    local i = 0
    return function()
        i = i + 1
        local id = self._render_order[i]
        if id == nil then return nil, nil, nil end
        local node = self._nodes[id]
        return id, node.data, node.depth
    end
end

return TreeBuffer
