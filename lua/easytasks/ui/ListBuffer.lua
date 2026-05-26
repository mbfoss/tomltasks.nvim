local ui = require('easytasks.ui')

---@alias easytasks.ui.ListBuffer.FormatterFn fun(id:any, data:any):string[][], string[][]

---@class easytasks.ui.ListBufferOpts
---@field formatter easytasks.ui.ListBuffer.FormatterFn
---@field on_selection fun(id:any, data:any)?
---@field current_item_prefix string?
---@field buffer_options vim.bo?

local _ns_id = vim.api.nvim_create_namespace('EasytasksListBuffer')

---@class easytasks.ui.ListBuffer
---@field _buf integer
---@field _formatter easytasks.ui.ListBuffer.FormatterFn
---@field _on_selection fun(id:any, data:any)?
---@field _prefix string
---@field _current_id any
---@field _ids any[]
---@field _items_map table<any, number>
---@field _items_data { userdata: any }[]
local ListBuffer = {}
ListBuffer.__index = ListBuffer

---@param opts easytasks.ui.ListBufferOpts
---@return easytasks.ui.ListBuffer
function ListBuffer.new(opts)
    local self = setmetatable({}, ListBuffer)

    self._buf = ui.create_sratch_buffer(false, opts.buffer_options)
    self._formatter = opts.formatter
    self._on_selection = opts.on_selection
    self._prefix = (opts.current_item_prefix or ">") .. " "
    self._current_id = nil
    self._ids = {}
    self._items_map = {}
    self._items_data = {}

    vim.keymap.set("n", "<CR>", function()
        local id, data = self:cursor_item()
        if id and self._on_selection then
            self._on_selection(id, data)
        end
    end, { buffer = self._buf, desc = "Select item" })
    return self
end

---@return integer
function ListBuffer:buf()
    return self._buf
end

---@param index integer
---@return integer
function ListBuffer:_row_for_index(index)
    return index - 1
end

---@param id any
---@param data any
---@param row integer
---@return string line, table hl_calls, table extmark_data
function ListBuffer:_render_item(id, data, row)
    local hl_calls = {}
    local extmark_data = {}
    local text_chunks, virt = self._formatter(id, data)
    local is_current = (id == self._current_id)
    local prefix_text = is_current and self._prefix or string.rep(" ", #self._prefix)

    local current_line = prefix_text
    local col = #prefix_text

    if is_current and #self._prefix > 0 then
        table.insert(hl_calls, { hl = "Statement", row = row, s_col = 0, e_col = col })
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

function ListBuffer:render()
    local buf = self._buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    local buffer_lines = {}
    local extmarks_data = {}
    local hl_calls = {}

    for i, id in ipairs(self._ids) do
        local row = self:_row_for_index(i)
        local data = self._items_data[i].userdata
        local line, n_hls, n_exts = self:_render_item(id, data, row)

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

---@param items { id: any, data: any }[]
function ListBuffer:set_items(items)
    self._ids = {}
    self._items_map = {}
    self._items_data = {}

    for i, item in ipairs(items) do
        self._ids[i] = item.id
        self._items_map[item.id] = i
        self._items_data[i] = { userdata = item.data }
    end

    self:render()
end

---@param id any
---@param data any
function ListBuffer:add_item(id, data)
    local buf = self._buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    if self._items_map[id] then
        return self:update_item(id, data)
    end

    local index = #self._ids + 1
    table.insert(self._ids, id)
    table.insert(self._items_data, { userdata = data })
    self._items_map[id] = index

    local row = self:_row_for_index(index)
    local line, hl_calls, extmarks = self:_render_item(id, data, row)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, row, row, false, { line })
    vim.bo[buf].modifiable = false

    for _, h in ipairs(hl_calls) do
        vim.hl.range(buf, _ns_id, h.hl, { h.row, h.s_col }, { h.row, h.e_col })
    end
    for _, d in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end
end

---@param id any
---@param data any
function ListBuffer:update_item(id, data)
    local buf = self._buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    local index = self._items_map[id]
    if not index then return end

    self._items_data[index].userdata = data

    local row = self:_row_for_index(index)
    local line, hl_calls, extmarks = self:_render_item(id, data, row)

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
function ListBuffer:remove_item(id)
    local buf = self._buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    local index = self._items_map[id]
    if not index then return end

    table.remove(self._ids, index)
    table.remove(self._items_data, index)
    self._items_map[id] = nil

    for i = index, #self._ids do
        self._items_map[self._ids[i]] = i
    end

    local row = self:_row_for_index(index)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {})
    vim.api.nvim_buf_clear_namespace(buf, _ns_id, row, row + 1)
    vim.bo[buf].modifiable = false
end

function ListBuffer:clear()
    self._ids = {}
    self._items_map = {}
    self._items_data = {}
    self:render()
end

---@return any id, any data
function ListBuffer:cursor_item()
    local winid = vim.fn.bufwinid(self._buf)
    if winid <= 0 then return nil, nil end

    local row = vim.api.nvim_win_get_cursor(winid)[1]
    local id = self._ids[row]
    if not id then return nil, nil end

    return id, self._items_data[row].userdata
end

---@param id any|nil
function ListBuffer:set_current(id)
    if self._current_id == id then return end

    local old_id = self._current_id
    self._current_id = id

    if old_id and self._items_map[old_id] then
        local old_index = self._items_map[old_id]
        self:update_item(old_id, self._items_data[old_index].userdata)
    end
    if id and self._items_map[id] then
        local new_index = self._items_map[id]
        self:update_item(id, self._items_data[new_index].userdata)
    end
end

---@return any
function ListBuffer:current_item()
    return self._current_id
end

---@return fun():any, any
function ListBuffer:iter_items()
    local i = 0
    return function()
        i = i + 1
        local id = self._ids[i]
        if id == nil then return nil end
        return id, self._items_data[i].userdata
    end
end

return ListBuffer
