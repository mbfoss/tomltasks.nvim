-- easytasks/toml/DecodeTree.lua

local Tree         = require("easytasks.util.Tree")
local vu           = require("easytasks.toml.validator_util")

---@class easytasks.toml.DecodeNodeData
---@field key    string        path segment (unescaped)
---@field ranges integer[][]   list of {r1,c1,r2,c2} source ranges (one per segment/occurrence)
---@field schema table?        resolved schema fragment for this path

---@class easytasks.toml.PosIndexEntry
---@field r1    integer
---@field c1    integer
---@field r2    integer
---@field c2    integer
---@field id    integer
---@field depth integer

---@class easytasks.toml.DecodeTree
---@field _tree        easytasks.util.Tree
---@field _root_id     integer
---@field _id_seq      integer
---@field _pos_index   easytasks.toml.PosIndexEntry[]   flat sorted list, built lazily
---@field _index_dirty boolean
local DecodeTree   = {}
DecodeTree.__index = DecodeTree

---@return easytasks.toml.DecodeTree
function DecodeTree.new()
    local self    = setmetatable({}, DecodeTree)
    self._tree    = Tree.new()
    self._id_seq  = 0
    self._id_seq  = self._id_seq + 1
    self._root_id = self._id_seq
    self._tree:add_item(nil, self._id_seq, { key = "", ranges = {}, schema = nil })
    self._pos_index   = {}
    self._index_dirty = false
    return self
end

---@private
---@return integer
function DecodeTree:_next_id()
    self._id_seq = self._id_seq + 1
    return self._id_seq
end

---@return integer
function DecodeTree:root_id()
    return self._root_id
end

-- Find an immediate child of parent_id whose key matches; returns nil if absent.
---@param parent_id integer?
---@param key string
---@return integer?
function DecodeTree:get_child_id(parent_id, key)
    if not parent_id then return nil end
    for child_id, data in self._tree:iter_children(parent_id) do
        if data.key == key then return child_id end
    end
    return nil
end

-- Add a new child node under parent_id; returns its id.
---@param parent_id integer
---@param key string
---@param range integer[]?
---@return integer
function DecodeTree:add_child(parent_id, key, range)
    local id = self:_next_id()
    self._tree:add_item(parent_id, id, { key = key, ranges = range and { range } or {}, schema = nil })
    self._index_dirty = true
    return id
end

-- Append a range to an existing node's range list.
---@param id integer
---@param range integer[]?
function DecodeTree:add_range_by_id(id, range)
    if range then
        local data = self._tree:get_data(id)
        data.ranges[#data.ranges + 1] = range
        self._index_dirty = true
    end
end

---@param path string
---@return integer[][]
function DecodeTree:ranges_of(path)
    local id = self:_find_id(path)
    return id and self._tree:get_data(id).ranges or {}
end

-- Convenience: returns the first range for a path, or nil.
---@param path string
---@return integer[]?
function DecodeTree:range_of(path)
    local ranges = self:ranges_of(path)
    return ranges[1]
end

---@param handler fun(id:any, data:any, depth:number):boolean?
function DecodeTree:walk_tree(handler)
    return self._tree:walk_tree(handler)
end

--------------------------------------------------------------------------------
-- Position index
--------------------------------------------------------------------------------

---@private
-- Rebuild the flat sorted position index from the tree.
-- Entries are sorted by (r1, c1); depth reflects tree depth so that the deepest
-- (most specific) containing node wins on lookup.
function DecodeTree:_rebuild_index()
    if not self._index_dirty then return end

    local entries = {}
    self._tree:walk_tree(function(id, data, depth)
        if id ~= self._root_id and data.ranges then
            for _, r in ipairs(data.ranges) do
                entries[#entries + 1] = {
                    r1 = r[1],
                    c1 = r[2],
                    r2 = r[3],
                    c2 = r[4],
                    id = id,
                    depth = depth,
                }
            end
        end
        return true
    end)

    table.sort(entries, function(a, b)
        if a.r1 ~= b.r1 then return a.r1 < b.r1 end
        return a.c1 < b.c1
    end)

    self._pos_index   = entries
    self._index_dirty = false
end

---@private
-- Binary search: returns the index of the rightmost entry whose start ≤ (row, col).
-- Returns 0 if no such entry exists.
---@param row integer
---@param col integer
---@return integer
function DecodeTree:_bsearch_start(row, col)
    local idx = self._pos_index
    local lo, hi, found = 1, #idx, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local e   = idx[mid]
        if e.r1 < row or (e.r1 == row and e.c1 <= col) then
            found = mid
            lo    = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

---@param row integer  0-indexed
---@param col integer  0-indexed
---@return integer?  id of the deepest node whose range contains (row, col)
function DecodeTree:pos_to_id(row, col)
    self:_rebuild_index()

    local hi = self:_bsearch_start(row, col)
    if hi == 0 then return nil end

    local best_id, best_depth = nil, -1
    for i = hi, 1, -1 do
        local e = self._pos_index[i]
        if (row > e.r1 or (row == e.r1 and col >= e.c1))
            and (row < e.r2 or (row == e.r2 and col <= e.c2)) then
            if e.depth > best_depth then
                best_depth = e.depth
                best_id    = e.id
            end
        end
    end

    return best_id
end

---@param row integer  0-indexed
---@param col integer  0-indexed
---@return string?  JSON Pointer of the deepest node whose range contains (row, col)
function DecodeTree:pos_to_path(row, col)
    local id = self:pos_to_id(row, col)
    return id and self:path_of(id) or nil
end

---@param id integer
---@return integer?
function DecodeTree:get_parent_id(id)
    return self._tree:get_parent_id(id)
end

---@param id integer
function DecodeTree:mark_as_key_node(id)
    local data = self._tree:get_data(id)
    if data then data.is_key_node = true end
end

---@param id integer
---@return boolean
function DecodeTree:is_key_node(id)
    local data = self._tree:get_data(id)
    return data ~= nil and data.is_key_node == true
end

--------------------------------------------------------------------------------
-- Path utilities
--------------------------------------------------------------------------------

-- Reconstruct the JSON Pointer path for a node by walking up to root.
---@param id integer
---@return string
function DecodeTree:path_of(id)
    return self:_path_of(id)
end

---@private
---@param id integer
---@return string
function DecodeTree:_path_of(id)
    local parts   = {}
    local current = id
    while current ~= self._root_id do
        local data = self._tree:get_data(current)
        table.insert(parts, 1, data.key)
        current = self._tree:get_parent_id(current)
    end
    if #parts == 0 then return "" end
    return vu.join_path_parts(parts)
end

-- Descend the tree by path segments; returns nil if any segment is missing.
-- Used only by range_of for path-based external callers.
---@private
---@param path string
---@return integer?
function DecodeTree:_find_id(path)
    if path == "" then return self._root_id end
    local current_id = self._root_id
    for _, part in ipairs(vu.split_path(path)) do
        local found
        for id, data in self._tree:iter_children(current_id) do
            if data.key == part then
                found = id
                break
            end
        end
        if not found then return nil end
        current_id = found
    end
    return current_id
end

return DecodeTree
