-- easytasks/toml/Ast.lua

local Tree = require("easytasks.util.Tree")

---@class easytasks.toml.Date
---@field year integer?
---@field month integer?
---@field day integer?
---@field hour integer?
---@field min integer?
---@field sec number?
---@field zone integer?

---@class easytasks.toml.Token
---@field value any
---@field range easytasks.toml.Range

---@class easytasks.toml.KeyRef
---@field value string
---@field range easytasks.toml.Range

---@class easytasks.toml.Pair
---@field key easytasks.toml.KeyRef
---@field value easytasks.toml.ValueNode?

---@class easytasks.toml.LiteralNode
---@field kind easytasks.toml.NodeKind
---@field token easytasks.toml.Token
---@field range easytasks.toml.Range

---@class easytasks.toml.ArrayNode
---@field kind easytasks.toml.NodeKind
---@field items easytasks.toml.ValueNode[]
---@field range easytasks.toml.Range

---@class easytasks.toml.InlineTableNode
---@field kind easytasks.toml.NodeKind
---@field pairs easytasks.toml.Pair[]
---@field range easytasks.toml.Range

---@alias easytasks.toml.ValueNode easytasks.toml.LiteralNode|easytasks.toml.ArrayNode|easytasks.toml.InlineTableNode

---@class easytasks.toml.KeyValuePairNode
---@field kind easytasks.toml.NodeKind
---@field key easytasks.toml.KeyRef
---@field value easytasks.toml.ValueNode
---@field trailing_comment string?
---@field range easytasks.toml.Range

---@class easytasks.toml.TableSectionNode
---@field kind easytasks.toml.NodeKind
---@field keys easytasks.toml.KeyRef[]
---@field trailing_comment string?
---@field range easytasks.toml.Range

---@class easytasks.toml.ArrayOfTablesSectionNode
---@field kind easytasks.toml.NodeKind
---@field keys easytasks.toml.KeyRef[]
---@field trailing_comment string?
---@field range easytasks.toml.Range

---@class easytasks.toml.CommentNode
---@field kind easytasks.toml.NodeKind
---@field text string
---@field range easytasks.toml.Range

---@alias easytasks.toml.AstNode
---| easytasks.toml.KeyValuePairNode
---| easytasks.toml.TableSectionNode
---| easytasks.toml.ArrayOfTablesSectionNode
---| easytasks.toml.CommentNode

---@class easytasks.toml.NodeAtResult
---@field id integer
---@field node easytasks.toml.AstNode

---@class easytasks.toml.Ast : easytasks.util.Tree
---@field _tree easytasks.util.Tree
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
