local M = {}

---@class tomltasks.tk.extmarks.MarkInfo
---@field id number
---@field file string
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field opts vim.api.keyset.set_extmark
---@field user_data any
---@field source "live"|"stored"

---@class tomltasks.tk.extmarks.MarkData
---@field id number
---@field ns number
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field opts vim.api.keyset.set_extmark
---@field user_data any

---@alias tomltasks.tk.extmarks.ById table<number, tomltasks.tk.extmarks.MarkData>
---@alias tomltasks.tk.extmarks.ByFile table<string, tomltasks.tk.extmarks.ById>

---@class tomltasks.tk.extmarks.GroupData
---@field ns number
---@field byfile tomltasks.tk.extmarks.ByFile
---@field id_to_file table<number, string>

---@class tomltasks.tk.extmarks.GroupInfo
---@field priority number
---@field data tomltasks.tk.extmarks.GroupData

---@type table<string, tomltasks.tk.extmarks.GroupInfo>
local _defined_groups = {}
local _autocmds_registered = false

local function _normalize_file(file)
    return vim.fn.fnamemodify(file, ":p")
end

---@param file string
---@return integer
local function _get_loaded_bufnr(file)
    local bufnr = vim.fn.bufnr(file, false)
    return (bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)) and bufnr or -1
end

---@param bufnr integer
---@param mark tomltasks.tk.extmarks.MarkData
local function _set_extmark(bufnr, mark)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count == 0 then return end

    local lnum = math.max(1, math.min(mark.lnum, line_count))
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, true)[1] or ""
    local col = math.max(0, math.min(mark.col, #line))

    mark.lnum, mark.col = lnum, col

    assert(type(mark.id) == "number")
    local id = vim.api.nvim_buf_set_extmark(bufnr, mark.ns, lnum - 1, col, mark.opts)
    assert(id == mark.id)
end

---@param bufnr integer
---@param ns integer
local function _clear_buf_namespace(bufnr, ns)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

---@param bufnr integer
---@param group string
local function _apply_buffer_extmarks(bufnr, group)
    local group_info = _defined_groups[group]
    assert(group_info)

    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end
    file = _normalize_file(file)

    local group_data = group_info.data
    local file_data = group_data.byfile[file]
    if not file_data then return end

    for _, mark in pairs(file_data) do
        _set_extmark(bufnr, mark)
    end
end

---@param bufnr number
local function _sync_file_extmarks(bufnr)
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end
    file = _normalize_file(file)

    for _, group_info in pairs(_defined_groups) do
        local group_data = group_info.data
        local file_table = group_data.byfile[file]
        if not file_table then
            goto continue
        end

        local is_set = vim.api.nvim_buf_get_extmarks(
            bufnr,
            group_data.ns,
            0,
            -1,
            { details = false }
        )

        for _, m in ipairs(is_set) do
            local id, row, col = m[1], m[2], m[3]
            local mark = file_table[id]
            if mark then
                mark.lnum = row + 1
                mark.col = col
            end
        end

        ::continue::
    end
end

---@param augroup_name string  unique name chosen by the caller
local function _register_autocmds(augroup_name)
    if _autocmds_registered then return end
    _autocmds_registered = true

    local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = augroup,
        callback = function(ev)
            for group in pairs(_defined_groups) do
                _apply_buffer_extmarks(ev.buf, group)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(ev) _sync_file_extmarks(ev.buf) end,
    })
    vim.api.nvim_create_autocmd("BufUnload", {
        group = augroup,
        callback = function(ev) _sync_file_extmarks(ev.buf) end,
    })
end

---@param id number
---@param file string
---@param lnum number        -- 1-based
---@param col number        -- 0-based
---@param group_info tomltasks.tk.extmarks.GroupInfo
---@param opts vim.api.keyset.set_extmark
---@param user_data any
---@see vim.api.nvim_buf_set_extmark
local function _set_file_extmark(id, file, lnum, col, group_info, opts, user_data)
    assert(lnum >= 1, "lnum must be 1-based")

    file = _normalize_file(file)
    local bufnr = _get_loaded_bufnr(file)

    local group_data = group_info.data
    local old_file = group_data.id_to_file[id]
    if old_file then
        local old_bufnr = _get_loaded_bufnr(old_file)
        if old_bufnr >= 0 then
            vim.api.nvim_buf_del_extmark(old_bufnr, group_data.ns, id)
        end
    end

    group_data.id_to_file[id] = file
    group_data.byfile[file] = group_data.byfile[file] or {}

    ---@type tomltasks.tk.extmarks.MarkData
    local mark = {
        id = id,
        ns = group_data.ns,
        lnum = lnum,
        col = col,
        opts = vim.tbl_extend("force", {
            id = id,
            priority = group_info.priority,
        }, opts or {}),
        user_data = user_data,
    }

    group_data.byfile[file][id] = mark

    if bufnr >= 0 then
        _set_extmark(bufnr, mark)
    end
end

---@param id number
---@param group_info tomltasks.tk.extmarks.GroupInfo
local function _remove_extmark(id, group_info)
    local group_data = group_info.data

    local file = group_data.id_to_file[id]
    if not file then return end

    group_data.id_to_file[id] = nil

    local file_table = group_data.byfile[file]
    if not file_table then return end

    local bufnr = _get_loaded_bufnr(file)
    if bufnr >= 0 then
        vim.api.nvim_buf_del_extmark(bufnr, group_data.ns, id)
    end

    file_table[id] = nil
end

---@param file string
---@param group_info tomltasks.tk.extmarks.GroupInfo
local function _remove_file_extmarks(file, group_info)
    file = _normalize_file(file)

    local group_data = group_info.data
    local file_table = group_data.byfile[file]
    if not file_table then return end

    for id in pairs(file_table) do
        group_data.id_to_file[id] = nil
    end

    group_data.byfile[file] = nil

    local bufnr = _get_loaded_bufnr(file)
    if bufnr >= 0 then
        _clear_buf_namespace(bufnr, group_data.ns)
    end
end

---@param group_info tomltasks.tk.extmarks.GroupInfo
local function _remove_extmarks(group_info)
    local group_data = group_info.data

    for file in pairs(group_data.byfile) do
        local bufnr = _get_loaded_bufnr(file)
        if bufnr >= 0 then
            _clear_buf_namespace(bufnr, group_data.ns)
        end
    end

    group_data.byfile = {}
    group_data.id_to_file = {}
end

---@param id number
---@param group_info tomltasks.tk.extmarks.GroupInfo
---@return tomltasks.tk.extmarks.MarkInfo?
local function _get_extmark_by_id(id, group_info)
    local group_data = group_info.data
    local file = group_data.id_to_file[id]
    if not file then return nil end

    local mark = (group_data.byfile[file] or {})[id]
    if not mark then return nil end

    return {
        id = mark.id,
        file = file,
        lnum = mark.lnum,
        col = mark.col,
        opts = mark.opts,
        user_data = mark.user_data,
        source = "stored",
    }
end

---@param file string
---@param line number
---@param group_info tomltasks.tk.extmarks.GroupInfo
---@param live boolean
---@return tomltasks.tk.extmarks.MarkInfo?
local function _get_extmark_by_location(file, line, group_info, live)
    assert(type(live) == "boolean")
    assert(line >= 1, "line must be 1-based")

    file = _normalize_file(file)
    local group_data = group_info.data
    local bufnr = live and _get_loaded_bufnr(file) or -1
    if bufnr >= 0 then
        local extmarks = vim.api.nvim_buf_get_extmarks(
            bufnr,
            group_data.ns,
            { line - 1, 0 },
            { line - 1, -1 },
            { details = false }
        )
        if #extmarks == 0 then return nil end
        return _get_extmark_by_id(extmarks[1][1], group_info)
    end

    local file_table = group_data.byfile[file]
    if not file_table then return nil end

    for id, mark in pairs(file_table) do
        if mark.lnum == line then
            return {
                id = id,
                file = file,
                lnum = mark.lnum,
                col = mark.col,
                opts = mark.opts,
                user_data = mark.user_data,
                source = "stored",
            }
        end
    end

    return nil
end

---@param group_info tomltasks.tk.extmarks.GroupInfo
---@param live boolean
---@return tomltasks.tk.extmarks.MarkInfo[]
local function _get_extmarks(group_info, live)
    assert(type(live) == "boolean")

    local group_data = group_info.data
    local result = {}

    for file, file_table in pairs(group_data.byfile) do
        local bufnr = live and _get_loaded_bufnr(file) or -1
        if bufnr >= 0 then
            local items = vim.api.nvim_buf_get_extmarks(bufnr, group_data.ns, 0, -1, { details = false })
            for _, m in ipairs(items) do
                local id, row, col = m[1], m[2], m[3]
                local mark = file_table[id]
                if mark then
                    result[#result + 1] = {
                        id = id,
                        file = file,
                        lnum = row + 1,
                        col = col,
                        opts = mark.opts,
                        user_data = mark.user_data,
                        source = "live",
                    }
                end
            end
        else
            for id, mark in pairs(file_table) do
                result[#result + 1] = {
                    id = id,
                    file = file,
                    lnum = mark.lnum,
                    col = mark.col,
                    opts = mark.opts,
                    user_data = mark.user_data,
                    source = "stored",
                }
            end
        end
    end

    return result
end

---@param file string
---@param group_info tomltasks.tk.extmarks.GroupInfo
---@param live boolean
---@return tomltasks.tk.extmarks.MarkInfo[]
local function _get_file_extmarks(file, group_info, live)
    assert(type(live) == "boolean")

    file = _normalize_file(file)
    local result = {}

    local group_data = group_info.data
    local file_table = group_data.byfile[file]
    if not file_table then return result end

    local bufnr = live and _get_loaded_bufnr(file) or -1
    if bufnr >= 0 then
        local items = vim.api.nvim_buf_get_extmarks(bufnr, group_data.ns, 0, -1, { details = false })
        for _, m in ipairs(items) do
            local id, row, col = m[1], m[2], m[3]
            local mark = file_table[id]
            if mark then
                result[#result + 1] = {
                    id = mark.id,
                    file = file,
                    lnum = row + 1,
                    col = col,
                    opts = mark.opts,
                    user_data = mark.user_data,
                    source = "live",
                }
            end
        end
    else
        for _, mark in pairs(file_table) do
            result[#result + 1] = {
                id = mark.id,
                file = file,
                lnum = mark.lnum,
                col = mark.col,
                opts = mark.opts,
                user_data = mark.user_data,
                source = "stored",
            }
        end
    end

    return result
end

---@param group_info tomltasks.tk.extmarks.GroupInfo
---@param group string
local function _refresh_group(group_info, group)
    local group_data = group_info.data
    for file in pairs(group_data.byfile) do
        local bufnr = _get_loaded_bufnr(file)
        if bufnr >= 0 then
            _clear_buf_namespace(bufnr, group_data.ns)
            _apply_buffer_extmarks(bufnr, group)
        end
    end
end

---@class tomltasks.tk.extmarks.GroupFunctions
---@field set_file_extmark fun(id:number, file:string, lnum:number, col:number, opts:vim.api.keyset.set_extmark, user_data:any)
---@field remove_extmarks fun()
---@field remove_extmark fun(id:number)
---@field remove_file_extmarks fun(file:string)
---@field get_extmark_by_id fun(id:number): tomltasks.tk.extmarks.MarkInfo?
---@field get_extmark_by_location fun(file:string, line:number, live:boolean): tomltasks.tk.extmarks.MarkInfo?
---@field get_extmarks fun(live:boolean): tomltasks.tk.extmarks.MarkInfo[]
---@field get_file_extmarks fun(file:string, live:boolean): tomltasks.tk.extmarks.MarkInfo[]
---@field refresh fun()

---@param group string  unique name; used as the extmark namespace and (on first call) the augroup name
---@param group_opts { priority: number }
---@return tomltasks.tk.extmarks.GroupFunctions
function M.define_group(group, group_opts)
    assert(type(group) == "string", "group (string) required")
    assert(type(group_opts.priority) == "number", "missing opts")
    assert(not _defined_groups[group], "group already defined")

    ---@type tomltasks.tk.extmarks.GroupInfo
    local group_info = {
        priority = group_opts.priority,
        data = {
            ns = vim.api.nvim_create_namespace(group),
            byfile = {},
            id_to_file = {},
        },
    }
    _defined_groups[group] = group_info

    _register_autocmds(group)

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            _apply_buffer_extmarks(bufnr, group)
        end
    end

    ---@type tomltasks.tk.extmarks.GroupFunctions
    return {
        set_file_extmark = function(id, file, lnum, col, opts, user_data)
            _set_file_extmark(id, file, lnum, col, group_info, opts, user_data)
        end,
        remove_extmark = function(id)
            _remove_extmark(id, group_info)
        end,
        remove_file_extmarks = function(file)
            _remove_file_extmarks(file, group_info)
        end,
        remove_extmarks = function()
            _remove_extmarks(group_info)
        end,
        get_extmark_by_id = function(id)
            return _get_extmark_by_id(id, group_info)
        end,
        get_extmark_by_location = function(file, line, live)
            return _get_extmark_by_location(file, line, group_info, live)
        end,
        get_extmarks = function(live)
            return _get_extmarks(group_info, live)
        end,
        get_file_extmarks = function(file, live)
            return _get_file_extmarks(file, group_info, live)
        end,
        refresh = function()
            _refresh_group(group_info, group)
        end,
    }
end

return M
