-- easytasks/toml/Ast.lua

local Tree = require("easytasks.util.Tree")

---@class easytasks.toml.Ast : easytasks.util.Tree
---@field _tree         easytasks.util.Tree
---@field add_item      fun(self: easytasks.toml.Ast, parent_id: any|nil, id: any, data: any)
---@field have_children fun(self: easytasks.toml.Ast, id: any): boolean
---@field get_roots     fun(self: easytasks.toml.Ast): easytasks.util.Tree.Item[]
---@field get_children  fun(self: easytasks.toml.Ast, parent_id: any): easytasks.util.Tree.Item[]
---@field get_data      fun(self: easytasks.toml.Ast, id: any): any
---@field get_parent_id fun(self: easytasks.toml.Ast, id: any): any|nil
---@field walk_tree     fun(self: easytasks.toml.Ast, handler: fun(id: any, data: any, depth: integer): boolean?)
local Ast = {}

Ast.__index = function(self, key)
    local own = rawget(Ast, key)
    if own ~= nil then return own end
    local v = self._tree[key]
    if type(v) == "function" then
        return function(s, ...) return v(s._tree, ...) end
    end
    return v
end

---@return easytasks.toml.Ast
function Ast.new()
    return setmetatable({ _tree = Tree.new() }, Ast)
end

---@param r integer
---@param c integer
---@param range easytasks.toml.Range
---@return boolean
local function pos_in_range(r, c, range)
    local sr, sc, er, ec = range[1], range[2], range[3], range[4]
    if r < sr or r > er then return false end
    if r == sr and c < sc then return false end
    if r == er and c > ec then return false end
    return true
end

---@param r integer
---@param c integer
---@return easytasks.toml.NodeAtResult?
function Ast:node_at(r, c)
    local function bsearch_match(items)
        local lo, hi = 1, #items
        local found = nil
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local range = items[mid].data and items[mid].data.range
            if range then
                if range[1] < r or (range[1] == r and range[2] <= c) then
                    found = mid
                    lo = mid + 1
                else
                    hi = mid - 1
                end
            else
                lo = mid + 1
            end
        end
        if not found then return nil end
        local item = items[found]
        local range = item.data and item.data.range
        if not range or not pos_in_range(r, c, range) then return nil end
        return item
    end

    local function descend(items)
        if not items or #items == 0 then return nil end
        local item = bsearch_match(items)
        if not item then return nil end
        if self._tree:have_children(item.id) then
            local deeper = descend(self._tree:get_children(item.id))
            if deeper then return deeper end
        end
        return { id = item.id, node = item.data }
    end

    return descend(self._tree:get_roots())
end

return Ast
