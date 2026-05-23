-- easytasks/toml/NodeKind.lua

---@enum easytasks.toml.NodeKind
local NodeKind = {
    Literal                      = 1,
    Array                        = 2,
    InlineTable                  = 3,
    KeyValuePair                 = 4,
    TableSection                 = 5,
    ArrayOfTablesSection         = 6,
    PartialTableSection          = 7,
    PartialArrayOfTablesSection  = 8,
    Comment                      = 9,
}

return NodeKind
