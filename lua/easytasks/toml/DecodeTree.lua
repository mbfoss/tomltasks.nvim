-- easytasks/toml/DecodeTree.lua

local Tree = require("easytasks.util.Tree")
local vu   = require("easytasks.toml.validatorutils")

---@class easytasks.toml.DecodeNodeData
---@field key    string        path segment ("/" for root, unescaped for all others)
---@field range  integer[]?    {r1,c1,r2,c2} source range, nil if not in document
---@field schema table?        resolved schema fragment for this path
---@field errors string[]      validation error messages at this path

---@class easytasks.toml.DecodeTree
---@field _tree       easytasks.util.Tree
---@field _path_to_id table<string, integer>
---@field _id_seq     integer
local DecodeTree = {}
DecodeTree.__index = DecodeTree

---@return easytasks.toml.DecodeTree
function DecodeTree.new()
    local self = setmetatable({}, DecodeTree)
    self._tree       = Tree.new()
    self._path_to_id = {}
    self._id_seq     = 0
    self._id_seq     = self._id_seq + 1
    self._tree:add_item(nil, self._id_seq, { key = "/", range = nil, schema = nil, errors = {} })
    self._path_to_id["/"] = self._id_seq
    return self
end

---@private
---@return integer
function DecodeTree:_next_id()
    self._id_seq = self._id_seq + 1
    return self._id_seq
end

-- Ensure a path exists in the tree, creating ancestor nodes as needed.
-- If the node already exists its range is updated; otherwise it is created.
---@param path  string
---@param range integer[]?
function DecodeTree:set_range(path, range)
    local id = self._path_to_id[path]
    if id then
        self._tree:get_data(id).range = range
        return
    end

    if path == "/" then return end  -- root always exists from new()

    local parts       = vu.split_path(path)
    local key         = parts[#parts]
    local parent_path = #parts > 1
        and vu.join_path_parts(vim.list_slice(parts, 1, #parts - 1))
        or "/"

    if not self._path_to_id[parent_path] then
        self:set_range(parent_path, nil)
    end

    local new_id = self:_next_id()
    self._tree:add_item(self._path_to_id[parent_path], new_id,
        { key = key, range = range, schema = nil, errors = {} })
    self._path_to_id[path] = new_id
end

---@param path   string
---@param schema table  stored as a reference — callers may mutate to merge
function DecodeTree:set_schema(path, schema)
    local id = self._path_to_id[path]
    if id then
        self._tree:get_data(id).schema = schema
    end
end

---@param path string
---@param msg  string
function DecodeTree:add_error(path, msg)
    local id = self._path_to_id[path]
    if id then
        table.insert(self._tree:get_data(id).errors, msg)
    end
end

---@param path string
---@return table?
function DecodeTree:get_schema(path)
    local id = self._path_to_id[path]
    return id and self._tree:get_data(id).schema or nil
end

---@param path string
---@return integer[]?
function DecodeTree:range_of(path)
    local id = self._path_to_id[path]
    return id and self._tree:get_data(id).range or nil
end

---@param row integer  0-indexed
---@param col integer  0-indexed
---@return string?  JSON Pointer of the deepest node whose range contains (row, col)
function DecodeTree:pos_to_path(row, col)
    local best_id, best_depth = nil, -1
    self._tree:walk_tree(function(id, data, depth)
        local r = data.range
        if r then
            local after_start = row > r[1] or (row == r[1] and col >= r[2])
            local before_end  = row < r[3] or (row == r[3] and col <= r[4])
            if after_start and before_end and depth > best_depth then
                best_depth = depth
                best_id    = id
            end
        end
        return true
    end)
    return best_id and self:_path_of(best_id) or nil
end

-- Iterate every validation error in the tree.
---@param fn fun(range: integer[]?, msg: string)
function DecodeTree:each_error(fn)
    self._tree:walk_tree(function(_, data, _)
        for _, msg in ipairs(data.errors) do
            fn(data.range, msg)
        end
        return true
    end)
end

---@private
---@param id integer
---@return string
function DecodeTree:_path_of(id)
    local parts   = {}
    local current = id
    while current do
        local data = self._tree:get_data(current)
        if data.key ~= "/" then
            table.insert(parts, 1, data.key)
        end
        current = self._tree:get_parent_id(current)
    end
    if #parts == 0 then return "/" end
    return vu.join_path_parts(parts)
end

return DecodeTree
