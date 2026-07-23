local Tree = require("tomltasks.tk.Tree")
local uiutil = require("tomltasks.tk.ui")
local Signal = require("tomltasks.tk.Signal")

---@class tomltasks.tk.TreeBuffer.Item
---@field id any
---@field data any
---@field expandable boolean
---@field expanded boolean

---@class tomltasks.tk.TreeBuffer.ItemDef
---@field id any
---@field data any
---@field expandable boolean?
---@field expanded boolean?

---@class tomltasks.tk.TreeBuffer.ItemData
---@field userdata any
---@field expandable boolean?
---@field expanded boolean?

---@alias tomltasks.tk.TreeBuffer.FormatterFn fun(id:any, data:any, expanded:boolean):string[][], string[][], string?

---@class tomltasks.tk.TreeBuffer.Opts
---@field filetype string?
---@field formatter tomltasks.tk.TreeBuffer.FormatterFn
---@field expand_char string?
---@field collapse_char string?
---@field icon_hl string?
---@field indent_string string?
---@field collapsible boolean?  -- whether nodes can be expanded/collapsed (default true)

---@class tomltasks.tk.TreeBuffer
---@field private _filetype string?
---@field private _formatter tomltasks.tk.TreeBuffer.FormatterFn
---@field private _expand_char string
---@field private _collapse_char string
---@field private _icon_hl string
---@field private _indent_string string
---@field private _expand_padding string
---@field private _indent_cache table<integer, string>
---@field private _on_selection tomltasks.tk.Signal<fun(id:any,data:any)>
---@field private _on_toggle tomltasks.tk.Signal<fun(id:any,data:any,expanded:boolean)>
---@field private _bufnr integer
---@field private _ns_id integer
---@field private _tree tomltasks.tk.Tree
---@field private _flat_ids any[]
---@field private _id_to_idx table<any, integer>
---@field private _collapsible boolean
local TreeBuffer = {}
TreeBuffer.__index = TreeBuffer

---@param opts tomltasks.tk.TreeBuffer.Opts
---@return tomltasks.tk.TreeBuffer
function TreeBuffer.new(opts)
    local indent_str = opts.indent_string or "  "
    local expand_char = opts.expand_char or "▶"
    local indent_cache = {}
    for i = 0, 20 do
        indent_cache[i] = string.rep(indent_str, i)
    end
    return setmetatable({
        _filetype       = opts.filetype,
        _formatter      = opts.formatter,
        _expand_char    = expand_char,
        _collapse_char  = opts.collapse_char or "▼",
        _icon_hl        = opts.icon_hl or "FoldColumn",
        _indent_string  = indent_str,
        _expand_padding = string.rep(" ", vim.fn.strdisplaywidth(expand_char)) .. " ",
        _indent_cache   = indent_cache,
        _on_selection   = Signal.new(), ---@type tomltasks.tk.Signal<fun(id:any,data:any)>
        _on_toggle      = Signal.new(), ---@type tomltasks.tk.Signal<fun(id:any,data:any,expanded:boolean)>
        _bufnr          = -1,
        _ns_id          = -1,
        _tree           = Tree.new(),
        _flat_ids       = {}, ---@type any[]
        _id_to_idx      = {}, ---@type table<any, integer>
        _collapsible    = opts.collapsible ~= false,
    }, TreeBuffer)
end

---@param item tomltasks.tk.TreeBuffer.ItemDef
---@return tomltasks.tk.TreeBuffer.ItemData
local function _to_itemdata(item)
    return { userdata = item.data, expandable = item.expandable, expanded = item.expanded }
end

---@param id any
---@param data tomltasks.tk.TreeBuffer.ItemData
---@return tomltasks.tk.TreeBuffer.Item
local function _to_item(id, data)
    return { id = id, data = data.userdata, expandable = data.expandable, expanded = data.expanded }
end

---@param tree tomltasks.tk.Tree
---@param starting_id any?  -- nil = whole tree
---@return tomltasks.tk.Tree.FlatNode[]
local function _flatten(tree, starting_id)
    local out = {}
    local function visit(id, data, depth)
        out[#out + 1] = { id = id, data = data, depth = depth }
        return data.expanded
    end
    if starting_id == nil then
        tree:walk_tree(visit)
    else
        tree:walk_node(starting_id, visit)
    end
    return out
end

---@param tree tomltasks.tk.Tree
---@param starting_id any?  -- nil = whole tree
---@return integer
local function _tree_size(tree, starting_id)
    local n = 0
    local function visit(_, data, _)
        n = n + 1
        return data.expanded
    end
    if starting_id == nil then
        tree:walk_tree(visit)
    else
        tree:walk_node(starting_id, visit)
    end
    return n
end

---@return integer
function TreeBuffer:get_bufnr()
    return self._bufnr
end

---@param on_deleted function
---@return integer bufnr, boolean created
function TreeBuffer:create_buffer(on_deleted)
    if self._bufnr and self._bufnr ~= -1 then
        return self._bufnr, false
    end

    self._bufnr = uiutil.create_scratch_buffer(false, {
        buftype      = "nofile",
        filetype     = self._filetype or "neotoolkit-tree",
        modifiable   = false,
        swapfile     = false,
        undolevels   = -1,
        spelloptions = "noplainbuffer",
    }, function()
        self._bufnr = -1
        on_deleted()
    end)
    self._ns_id = vim.api.nvim_create_namespace("TreeBuffer_" .. self._bufnr)

    self:_full_render()

    local function on_enter()
        local id, data = self:_get_cur_item()
        if not id or not data then return end
        if self._collapsible and (data.expandable or self._tree:have_children(id)) then
            self:toggle_expand(id)
        else
            self._on_selection:emit(id, data.userdata)
        end
    end

    local keymaps = {
        ["<CR>"]          = { "Expand/collapse or select", on_enter },
        ["<2-LeftMouse>"] = { "Expand/collapse or select", on_enter },
    }

    if self._collapsible then
        keymaps["zo"] = { "Expand node", function()
            local id = self:_get_cur_item()
            if id then self:expand(id) end
        end }
        keymaps["zc"] = { "Collapse node", function()
            local id = self:_get_cur_item()
            if id then self:collapse(id) end
        end }
        keymaps["za"] = { "Toggle node", function()
            local id = self:_get_cur_item()
            if id then self:toggle_expand(id) end
        end }
        keymaps["zO"] = { "Expand all under cursor", function()
            local id = self:_get_cur_item()
            if id then self:expand_all(id) end
        end }
        keymaps["zC"] = { "Collapse all under cursor", function()
            local id = self:_get_cur_item()
            if id then self:collapse_all(id) end
        end }
    end

    assert(self._bufnr > 0)
    for key, map in pairs(keymaps) do
        vim.keymap.set("n", key, map[2], { buffer = self._bufnr, desc = map[1] })
    end

    return self._bufnr, true
end

---@param callbacks { on_selection?: fun(id:any,data:any), on_toggle?: fun(id:any,data:any,expanded:boolean) }
---@return { cancel: fun() }
function TreeBuffer:subscribe(callbacks)
    if callbacks.on_selection then self._on_selection:subscribe(callbacks.on_selection) end
    if callbacks.on_toggle then self._on_toggle:subscribe(callbacks.on_toggle) end
    return {
        cancel = function()
            if callbacks.on_selection then self._on_selection:unsubscribe(callbacks.on_selection) end
            if callbacks.on_toggle then self._on_toggle:unsubscribe(callbacks.on_toggle) end
        end,
    }
end

---@private
---@param flatnode tomltasks.tk.Tree.FlatNode
---@param row integer
---@return string line, table hl_calls, table extmarks
function TreeBuffer:_render_node(flatnode, row)
    local id, data, depth = flatnode.id, flatnode.data, flatnode.depth
    local indent = self._indent_cache[depth] or string.rep(self._indent_string, depth)
    local prefix
    if self._collapsible then
        local expandable = data.expandable or self._tree:have_children(id)
        local icon = expandable and (data.expanded and self._collapse_char or self._expand_char) or ""
        prefix = icon ~= "" and (indent .. icon .. " ") or (indent .. self._expand_padding)
    else
        prefix = indent
    end

    local text_chunks, virt, line_hl = self._formatter(id, data.userdata, data.expanded)
    local line = prefix
    local col = #prefix
    local hl_calls = {}

    for _, chunk in ipairs(text_chunks) do
        local txt, hl = chunk[1], chunk[2]
        txt = (txt or ""):gsub("\n", "↵")
        local len = #txt
        if len > 0 then
            if hl then
                hl_calls[#hl_calls + 1] = { hl = hl, row = row, s_col = col, e_col = col + len }
            end
            line = line .. txt
            col = col + len
        end
    end

    local extmarks = {}
    if line_hl then
        extmarks[#extmarks + 1] = { row, 0, { line_hl_group = line_hl } }
    end
    if virt and #virt > 0 then
        extmarks[#extmarks + 1] = { row, 0, { virt_text = virt, hl_mode = "combine" } }
    end

    return line, hl_calls, extmarks
end

---@private
function TreeBuffer:_full_render()
    local buf = self._bufnr
    if buf <= 0 or not vim.api.nvim_buf_is_loaded(buf) then return end

    local lines, hl_calls, extmarks = {}, {}, {}
    self._flat_ids = {}
    self._id_to_idx = {}

    for _, flatnode in ipairs(_flatten(self._tree, nil)) do
        local row = #lines
        local line, hls, exts = self:_render_node(flatnode, row)
        lines[#lines + 1] = line
        self._flat_ids[#self._flat_ids + 1] = flatnode.id
        self._id_to_idx[flatnode.id] = #self._flat_ids
        for _, h in ipairs(hls) do hl_calls[#hl_calls + 1] = h end
        for _, e in ipairs(exts) do extmarks[#extmarks + 1] = e end
    end

    vim.api.nvim_buf_clear_namespace(buf, self._ns_id, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    self:_apply_metadata(buf, hl_calls, extmarks)
end

---@private
---@param start_idx integer
---@param old_size integer
---@param new_flat tomltasks.tk.Tree.FlatNode[]
function TreeBuffer:_render_range(start_idx, old_size, new_flat)
    local buf = self._bufnr
    if buf <= 0 or not vim.api.nvim_buf_is_loaded(buf) then return end

    local start_row = start_idx - 1
    local new_lines, new_ids, hl_calls, extmarks = {}, {}, {}, {}

    for i, flatnode in ipairs(new_flat) do
        local row = start_row + i - 1
        local line, hls, exts = self:_render_node(flatnode, row)
        new_lines[#new_lines + 1] = line
        new_ids[#new_ids + 1] = flatnode.id
        for _, h in ipairs(hls) do hl_calls[#hl_calls + 1] = h end
        for _, e in ipairs(exts) do extmarks[#extmarks + 1] = e end
    end

    vim.api.nvim_buf_clear_namespace(buf, self._ns_id, start_row, start_row + old_size)

    local end_row = start_row + old_size
    if old_size == 0 and #self._flat_ids == 0 then end_row = -1 end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, new_lines)
    vim.bo[buf].modifiable = false

    for i = 0, old_size - 1 do
        local old_id = self._flat_ids[start_idx + i]
        if old_id ~= nil then self._id_to_idx[old_id] = nil end
    end
    local new_size = #new_ids
    local total = #self._flat_ids
    local delta = new_size - old_size
    if delta > 0 then
        for i = total, start_idx + old_size, -1 do
            self._flat_ids[i + delta] = self._flat_ids[i]
        end
    elseif delta < 0 then
        for i = start_idx + old_size, total do
            self._flat_ids[i + delta] = self._flat_ids[i]
        end
        for i = total + delta + 1, total do self._flat_ids[i] = nil end
    end
    for i, id in ipairs(new_ids) do
        self._flat_ids[start_idx + i - 1] = id
    end
    for i = start_idx, #self._flat_ids do
        local id = self._flat_ids[i]
        if id ~= nil then self._id_to_idx[id] = i end
    end

    self:_apply_metadata(buf, hl_calls, extmarks)
    self:_fix_viewport()
end

---@private
function TreeBuffer:_fix_viewport()
    local winid = self:get_winid()
    local buf = self._bufnr
    if winid <= 0 or buf <= 0 then return end
    local line_count = vim.api.nvim_buf_line_count(buf)
    local win_height = vim.api.nvim_win_get_height(winid)
    vim.api.nvim_win_call(winid, function()
        local view = vim.fn.winsaveview()
        if (view.topline + win_height - 1) > line_count then
            local new_topline = math.max(1, line_count - win_height + 1)
            if new_topline ~= view.topline then
                vim.fn.winrestview({ topline = new_topline })
            end
        end
    end)
end

---@private
---@param id any
---@param data tomltasks.tk.TreeBuffer.ItemData?
function TreeBuffer:_render_line(id, data)
    data = data or self._tree:get_data(id)
    assert(data, "failed to render line, invalid data")
    local idx = self._id_to_idx[id]
    if idx then
        self:_render_range(idx, 1, { { id = id, data = data, depth = self._tree:get_depth(id) } })
    end
end

---@private
---@param buf integer
---@param hl_calls table
---@param extmarks table
function TreeBuffer:_apply_metadata(buf, hl_calls, extmarks)
    for _, h in ipairs(hl_calls) do
        vim.api.nvim_buf_set_extmark(buf, self._ns_id, h.row, h.s_col, {
            end_col = h.e_col, hl_group = h.hl,
        })
    end
    for _, d in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, self._ns_id, d[1], d[2], d[3])
    end
end

---@return integer  window id, -1 if not found
function TreeBuffer:get_winid()
    local buf = self._bufnr
    if buf <= 0 then return -1 end
    if vim.api.nvim_get_current_buf() == buf then
        return vim.api.nvim_get_current_win()
    end
    return vim.fn.bufwinid(buf)
end

---@private
---@return any?, tomltasks.tk.TreeBuffer.ItemData?
function TreeBuffer:_get_cur_item()
    local winid = self:get_winid()
    if winid <= 0 then return end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local id = self._flat_ids[cursor[1]]
    if not id then return end
    return id, self._tree:get_data(id)
end

---@return tomltasks.tk.TreeBuffer.Item?
function TreeBuffer:get_cursor_item()
    local id, data = self:_get_cur_item()
    if not id or not data then return nil end
    return _to_item(id, data)
end

---@param row integer 1-based buffer line number
---@return tomltasks.tk.TreeBuffer.Item?
function TreeBuffer:get_item_at_row(row)
    local id = self._flat_ids[row]
    if not id then return nil end
    local data = self._tree:get_data(id)
    if not data then return nil end
    return _to_item(id, data)
end

---@return boolean
function TreeBuffer:set_cursor_by_id(id)
    local winid = self:get_winid()
    if winid <= 0 then return false end
    local idx = self._id_to_idx[id]
    if not idx then return false end
    local ok = pcall(vim.api.nvim_win_set_cursor, winid, { idx, 0 })
    return ok
end

---@return tomltasks.tk.TreeBuffer.Item?
function TreeBuffer:get_item(id)
    local data = self._tree:get_data(id)
    if not data then return nil end
    return _to_item(id, data)
end

---@return any?
function TreeBuffer:get_parent_id(id)
    return self._tree:get_parent_id(id)
end

---@return tomltasks.tk.TreeBuffer.Item[]
function TreeBuffer:get_children(parent_id)
    local items = {}
    for _, ti in ipairs(self._tree:get_children(parent_id)) do
        items[#items + 1] = _to_item(ti.id, ti.data)
    end
    return items
end

---@return any[]
function TreeBuffer:get_children_ids(parent_id)
    return self._tree:get_children_ids(parent_id)
end

---@param id any
---@return boolean
function TreeBuffer:have_item(id)
    return self._tree:have_item(id)
end

---@param id any
---@return boolean
function TreeBuffer:have_children(id)
    return self._tree:have_children(id)
end

function TreeBuffer:clear_items()
    self._tree = Tree.new()
    self._flat_ids = {}
    self._id_to_idx = {}
    self:_full_render()
end

---@param parent_id any  -- nil for root
---@param children tomltasks.tk.TreeBuffer.ItemDef[]
---@return boolean
function TreeBuffer:set_children(parent_id, children)
    if parent_id and not self._tree:have_item(parent_id) then return false end

    local old_visible_size = parent_id and _tree_size(self._tree, parent_id) or nil

    local baseitems = {}
    for _, c in ipairs(children) do
        baseitems[#baseitems + 1] = { id = c.id, data = _to_itemdata(c) }
    end
    self._tree:set_children(parent_id, baseitems)

    if self._bufnr > 0 then
        if parent_id == nil then
            self:_full_render()
        else
            local parent_idx = self._id_to_idx[parent_id]
            if parent_idx then
                local base_depth = self._tree:get_depth(parent_id)
                local new_flat = _flatten(self._tree, parent_id)
                for _, node in ipairs(new_flat) do
                    node.depth = base_depth + node.depth
                end
                self:_render_range(parent_idx, old_visible_size, new_flat)
            end
        end
    end
    return true
end

---@param id any
function TreeBuffer:remove_children(id)
    self:set_children(id, {})
end

---@param parent_id any  -- nil for root
---@param item tomltasks.tk.TreeBuffer.ItemDef
---@return boolean
function TreeBuffer:add_item(parent_id, item)
    if parent_id and not self._tree:have_item(parent_id) then return false end
    local item_data = _to_itemdata(item)
    self._tree:add_item(parent_id, item.id, item_data)

    if self._bufnr > 0 then
        if parent_id == nil then
            local node = { id = item.id, data = item_data, depth = 0 }
            self:_render_range(#self._flat_ids + 1, 0, { node })
        else
            local parent_idx = self._id_to_idx[parent_id]
            if parent_idx then
                local parent_data = self._tree:get_data(parent_id)
                self:_render_line(parent_id, parent_data)
                if parent_data and parent_data.expanded then
                    local subtree_size = _tree_size(self._tree, parent_id)
                    local node = { id = item.id, data = item_data, depth = self._tree:get_depth(item.id) }
                    self:_render_range(parent_idx + subtree_size - 1, 0, { node })
                end
            end
        end
    end
    return true
end

---@param reference_id any
---@param item tomltasks.tk.TreeBuffer.ItemDef
---@param before boolean  true to insert before reference, false to insert after
---@return boolean
function TreeBuffer:add_sibling(reference_id, item, before)
    if not self._tree:have_item(reference_id) then return false end
    local item_data = _to_itemdata(item)
    self._tree:add_sibling(reference_id, item.id, item_data, before)

    if self._bufnr > 0 then
        local ref_idx = self._id_to_idx[reference_id]
        if ref_idx then
            local insert_idx = before and ref_idx or (ref_idx + _tree_size(self._tree, reference_id))
            local node = { id = item.id, data = item_data, depth = self._tree:get_depth(item.id) }
            self:_render_range(insert_idx, 0, { node })
        end
    end
    return true
end

---@param id any
---@return boolean
function TreeBuffer:remove_item(id)
    if not self._tree:have_item(id) then return false end
    local parent_id = self._tree:get_parent_id(id)
    local visible_size = _tree_size(self._tree, id)
    self._tree:remove_item(id)
    local idx = self._id_to_idx[id]
    if idx then
        self:_render_range(idx, visible_size, {})
        if parent_id ~= nil then self:_render_line(parent_id) end
    end
    return true
end

---@param id any
---@param data any
---@return boolean
function TreeBuffer:set_item_data(id, data)
    local base_data = self._tree:get_data(id)
    if not base_data then return false end
    base_data.userdata = data
    self:_render_line(id, base_data)
    return true
end

---@param id any
---@param expandable boolean
---@return boolean
function TreeBuffer:set_item_expandable(id, expandable)
    local base_data = self._tree:get_data(id)
    if not base_data then return false end
    if expandable ~= base_data.expandable then
        base_data.expandable = expandable
        self:_render_line(id, base_data)
    end
    return true
end

---@param id any
---@return boolean
function TreeBuffer:refresh_item(id)
    local data = self._tree:get_data(id)
    if not data then return false end
    self:_render_line(id, data)
    return true
end

function TreeBuffer:toggle_expand(id)
    local data = self._tree:get_data(id)
    if not data then return end
    if data.expanded then self:collapse(id) else self:expand(id) end
end

function TreeBuffer:expand(id)
    local data = self._tree:get_data(id)
    if not data or data.expanded or not (data.expandable or self._tree:have_children(id)) then return end
    data.expanded = true
    local idx = self._id_to_idx[id]
    if idx then
        local base_depth = self._tree:get_depth(id)
        local new_flat = _flatten(self._tree, id)
        for _, node in ipairs(new_flat) do node.depth = base_depth + node.depth end
        self:_render_range(idx, 1, new_flat)
    end
    self._on_toggle:emit(id, data.userdata, true)
end

function TreeBuffer:collapse(id)
    local data = self._tree:get_data(id)
    if not data or not data.expanded then return end
    local visible_size = _tree_size(self._tree, id)
    data.expanded = false
    local idx = self._id_to_idx[id]
    if idx then
        self:_render_range(idx, visible_size, { { id = id, data = data, depth = self._tree:get_depth(id) } })
    end
    self._on_toggle:emit(id, data.userdata, false)
end

function TreeBuffer:expand_all(id)
    local data = self._tree:get_data(id)
    if not data then return end
    if not data.expanded and (data.expandable or self._tree:have_children(id)) then
        self:expand(id)
    end
    for _, child in ipairs(self._tree:get_children(id)) do
        self:expand_all(child.id)
    end
end

function TreeBuffer:collapse_all(id)
    local data = self._tree:get_data(id)
    if not data then return end
    if data.expanded then self:collapse(id) end
    local function reset(node_id)
        for _, child in ipairs(self._tree:get_children(node_id)) do
            local child_data = self._tree:get_data(child.id)
            if child_data then child_data.expanded = false end
            reset(child.id)
        end
    end
    reset(id)
end

---@return any?
function TreeBuffer:get_item_data(id)
    local data = self._tree:get_data(id)
    return data and data.userdata or nil
end

---@return tomltasks.tk.TreeBuffer.Item[]
function TreeBuffer:get_items()
    local items = {}
    for _, ti in ipairs(self._tree:get_items()) do
        items[#items + 1] = _to_item(ti.id, ti.data)
    end
    return items
end

---@return tomltasks.tk.TreeBuffer.Item[]
function TreeBuffer:get_roots()
    local items = {}
    for _, ti in ipairs(self._tree:get_roots()) do
        items[#items + 1] = _to_item(ti.id, ti.data)
    end
    return items
end

---@return tomltasks.tk.TreeBuffer.Item?
function TreeBuffer:get_parent_item(id)
    local par_id = self._tree:get_parent_id(id)
    if not par_id then return nil end
    local data = self._tree:get_data(par_id)
    if not data then return nil end
    return _to_item(par_id, data)
end

---@param winid integer
---@return tomltasks.tk.TreeBuffer.Item[]
function TreeBuffer:get_visible_items(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then return {} end
    if vim.api.nvim_win_get_buf(winid) ~= self._bufnr then return {} end
    local items = {}
    for i = vim.fn.line("w0", winid), vim.fn.line("w$", winid) do
        local id = self._flat_ids[i]
        if id then
            local data = self._tree:get_data(id)
            if data then items[#items + 1] = _to_item(id, data) end
        end
    end
    return items
end

return TreeBuffer
