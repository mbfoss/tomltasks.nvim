local M = {}

---@enum easytasks.toml.NodeKind
M.NodeKind = {
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

local days_in_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function is_leap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

---@param y integer
---@param mo integer
---@param d integer
---@return string|nil
function M.validate_date(y, mo, d)
    if mo < 1 or mo > 12 then return "month out of range" end
    local max_d = days_in_month[mo]
    if mo == 2 and is_leap(y) then max_d = 29 end
    if d < 1 or d > max_d then return "day out of range" end
end

---@param h integer
---@param mi integer
---@param sec number
---@return string|nil
function M.validate_time(h, mi, sec)
    if h < 0 or h > 23 then return "hour out of range" end
    if mi < 0 or mi > 59 then return "minute out of range" end
    if sec < 0 or sec > 60 then return "second out of range" end
end

return M
