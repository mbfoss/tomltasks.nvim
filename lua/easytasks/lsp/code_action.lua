local M          = {}

local Cst        = require("easytasks.toml.Cst")
local encoder    = require("easytasks.toml.encoder")
local async      = require("easytasks.util.async")
local _notify    = require("easytasks.ui")
local K          = Cst.Kind

local kind_names = {}
for name, v in pairs(K) do kind_names[v] = name end

--------------------------------------------------------------------------------
-- Dump helpers
--------------------------------------------------------------------------------

local function dump_cst_to_string(cst)
    local lines = { "# --- Easytasks TOML CST Dump ---", "#" }
    if not cst or type(cst.walk) ~= "function" then
        table.insert(lines, "# No valid CST instance found.")
    else
        cst:walk(function(id, data, depth)
            local indent = string.rep("  ", depth or 0)
            local kind   = kind_names[data.kind] or ("Kind#" .. tostring(data.kind))
            local info   = string.format("# %s* [%s] id:%s tag:%s", indent, kind, id, data.tag)
            if data.range then
                info = info .. string.format(" (%d,%d)->(%d,%d)",
                    data.range[1], data.range[2], data.range[3], data.range[4])
            end
            if data.text then info = info .. string.format(" text:%q", data.text) end
            if data.value ~= nil then info = info .. string.format(" val:%s", tostring(data.value)) end
            table.insert(lines, info)
            return true
        end)
    end
    return table.concat(lines, "\n") .. "\n"
end

local function serialize_val(val, depth)
    depth = depth or 0
    local indent = string.rep("  ", depth)
    if type(val) == "table" then
        local parts = { "{\n" }
        for k, v in pairs(val) do
            local ks = type(k) == "string" and string.format("[%q]", k) or string.format("[%s]", tostring(k))
            table.insert(parts, string.format("%s  %s = %s,\n", indent, ks, serialize_val(v, depth + 1)))
        end
        table.insert(parts, indent .. "}")
        return table.concat(parts)
    elseif type(val) == "string" then
        return string.format("%q", val)
    else
        return tostring(val)
    end
end

local function dump_decoder_to_string(data)
    local lines = { "# --- Easytasks TOML Decoded Data Dump ---", "#" }
    if not data then
        table.insert(lines, "# No decoded data available.")
    else
        for line in serialize_val(data):gmatch("[^\r\n]+") do
            table.insert(lines, "# " .. line)
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

local function dump_decode_tree_to_string(decode_tree)
    local lines = { "# --- Easytasks TOML DecodeTree Dump ---", "#" }
    if not decode_tree or type(decode_tree._tree) ~= "table"
        or type(decode_tree._tree.walk_tree) ~= "function" then
        table.insert(lines, "# No valid DecodeTree instance found.")
    else
        decode_tree:walk_tree(function(id, data, depth)
            local indent = string.rep("  ", depth or 0)
            local info   = string.format("# %s* [id:%s] key:%q", indent, tostring(id), tostring(data.key))
            if data.ranges and #data.ranges > 0 then
                local parts = {}
                for _, r in ipairs(data.ranges) do
                    parts[#parts + 1] = string.format("(%d,%d)->(%d,%d)", r[1], r[2], r[3], r[4])
                end
                info = info .. " ranges:[" .. table.concat(parts, ", ") .. "]"
            else
                info = info .. " ranges:[]"
            end
            if data.schema then
                info = info .. string.format(" schema:{type=%s}", tostring(data.schema.type or "?"))
            end
            if data.errors and #data.errors > 0 then
                info = info .. string.format(" errors:[%s]", table.concat(data.errors, "; "))
            end
            table.insert(lines, info)
            return true
        end)
    end
    return table.concat(lines, "\n") .. "\n"
end

local function dump_errors_to_string(parse_results)
    local lines  = { "# --- Easytasks Active Diagnostics Error Dump ---", "#" }
    local errors = parse_results and parse_results.errors or {}
    if #errors == 0 then
        table.insert(lines, "# No active parsing, semantic, or validation errors found.")
    else
        for i, err in ipairs(errors) do
            local range_str = ""
            if err.range then
                range_str = string.format(" (%d,%d)->(%d,%d)",
                    err.range[1], err.range[2], err.range[3], err.range[4])
            end
            table.insert(lines, string.format("# [%d] Error%s: %s",
                i, range_str, err.message or err.err_msg or tostring(err)))
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

--------------------------------------------------------------------------------
-- Template pending registry
--------------------------------------------------------------------------------

---@class easytasks.TemplateActionEntry
---@field bufnr      integer
---@field row        integer   0-indexed cursor row at action creation time
---@field col        integer   0-indexed cursor col at action creation time
---@field kind       "array"|"aot"
---@field type_name  string
---@field templates  easytasks.TaskTemplate[]|(fun(): easytasks.TaskTemplate[])
---@field indent     string   leading whitespace for inline-array items

---@type table<integer, easytasks.TemplateActionEntry>
local _pending     = {}
local _pending_seq = 0

--------------------------------------------------------------------------------
-- Between-tasks detection
--------------------------------------------------------------------------------

-- Returns the indentation of the first inline-table item inside an Array node,
-- falling back to two spaces if none exist yet.
---@param bufnr  integer
---@param cst    easytasks.toml.Cst
---@param arr_id integer
---@return string
local function array_item_indent(bufnr, cst, arr_id)
    for _, vd in cst:iter_values(arr_id) do
        if vd.kind == K.InlineTable then
            local r1   = vd.range[1]
            local line = vim.api.nvim_buf_get_lines(bufnr, r1, r1 + 1, false)[1] or ""
            return line:match("^(%s*)") or "  "
        end
    end
    return "  "
end

-- Determine whether the cursor is in a position where a task template can be
-- inserted.  Returns the insertion kind and the relevant CST node id, or nil.
--
-- "array" → cursor is between items inside the inline tasks array
--           (closest Array/InlineTable ancestor is an Array whose path is ["tasks"])
-- "aot"   → cursor is inside a [[tasks]] AotSection but not inside a KVP
--           (e.g. on the header line, a trailing blank line, or a comment)
---@param cst easytasks.toml.Cst
---@param dt  easytasks.toml.DecodeTree
---@param row integer
---@param col integer
---@return "array"|"aot"|nil
---@return integer?
local function tasks_insertion_ctx(cst, dt, row, col)
    local tok_id = cst:token_at(row, col)

    -- Inline array: the nearest Array/InlineTable ancestor must be an Array.
    -- If InlineTable is closer, we are inside a task item, not between items.
    local anc = cst:ancestor_of_kind(tok_id, K.Array, K.InlineTable)
    if anc and cst:kind(anc) == K.Array then
        local is_tasks = false
        local tag = cst:get_tag(anc)
        if tag then
            local parts = dt:key_parts_of(tag)
            is_tasks = #parts == 1 and parts[1] == "tasks"
        else
            -- Array not yet decoded; fall back to the parent KVP's key text.
            local kvp_id = cst:ancestor_of_kind(anc, K.KeyValuePair)
            if kvp_id then
                local keys = cst:get_keys(kvp_id)
                is_tasks = #keys == 1 and keys[1].value == "tasks"
            end
        end
        if is_tasks then return "array", anc end
    end


    -- AoT: inside a [[tasks]] section body, not inside any key-value pair,
    -- and no KVP in the section starts after the cursor (cursor is at the tail).
    if not cst:ancestor_of_kind(tok_id, K.KeyValuePair) then
        local aot_id = cst:ancestor_of_kind(tok_id, K.AotSection)
        if aot_id then
            local hdr_id = cst:first_child_of_kind(aot_id, K.AotHeader)
            if hdr_id then
                local keys = cst:get_keys(hdr_id)
                if #keys == 1 and keys[1].value == "tasks" then
                    -- Find the direct child of aot_id that contains tok_id,
                    -- then walk forward via next_sibling_id for any KVP.
                    ---@type integer?
                    local anchor = tok_id
                    while anchor and cst:parent_id(anchor) ~= aot_id do
                        anchor = cst:parent_id(anchor)
                    end
                    local kvp_after = false
                    local sib = anchor and cst:next_sibling_id(anchor)
                    while sib do
                        if cst:kind(sib) == K.KeyValuePair then
                            kvp_after = true; break
                        end
                        sib = cst:next_sibling_id(sib)
                    end
                    if not kvp_after then return "aot", aot_id end
                end
            end
        end
    end

    -- Document root: walk up from tok_id; if every node is trivial
    -- (Whitespace, Newline, Comment) or Document, the cursor is floating
    -- at root — covers empty files, blank lines, and comment-only lines.
    local trivial = {
        [K.Whitespace] = true,
        [K.Newline] = true,
        [K.Comment] = true,
        [K.Document] = true,
    }
    ---@type integer?
    local cur, at_root = tok_id, true
    while cur do
        if not trivial[cst:kind(cur)] then
            at_root = false; break
        end
        cur = cst:parent_id(cur)
    end
    if at_root then return "aot", nil end

    return nil
end

--------------------------------------------------------------------------------
-- Template application
--------------------------------------------------------------------------------

---@param entry easytasks.TemplateActionEntry
---@param tmpl  easytasks.TaskTemplate
local function apply_template(entry, tmpl)
    if not vim.api.nvim_buf_is_valid(entry.bufnr) then return end
    vim.api.nvim_win_set_cursor(0, { entry.row + 1, entry.col })

    local lines
    if entry.kind == "array" then
        local encoded = encoder.encode_inline(tmpl.task, { multiline = true, indent = entry.indent })
        lines = vim.split(encoded, "\n", { plain = true })
        lines[#lines] = lines[#lines]
    else
        local block = encoder.encode_aot_entry("tasks", tmpl.task)
        lines = vim.split(block, "\n", { plain = true })
    end
    vim.api.nvim_put(lines, "c", false, true)
end

--------------------------------------------------------------------------------
-- Execute command handler
--------------------------------------------------------------------------------

---@param context  easytasks.LspBufferContext
---@param params   { command: string, arguments?: any[] }
---@param callback fun(err?: lsp.ResponseError, result?: any)
function M.execute_command(context, params, callback)
    if params.command ~= "easytasks/insertTemplate" then
        callback(nil, nil)
        return
    end

    local id    = params.arguments and params.arguments[1]
    local entry = id and _pending[id]
    if not entry then
        callback(nil, nil); return
    end
    _pending[id] = nil -- consume once

    local function show_select(templates)
        if not templates or #templates == 0 then
            _notify.notify_warning("no templates for type: " .. entry.type_name)
            return
        end
        vim.ui.select(
            templates,
            {
                prompt      = "Choose " .. entry.type_name .. " template:",
                format_item = function(item) return item.label end,
            },
            function(choice)
                if choice then
                    vim.schedule(function() apply_template(entry, choice) end)
                end
            end
        )
    end

    if type(entry.templates) == "function" then
        local fn = entry.templates ---@cast fn function
        async.go(fn, function(ok, result)
            if ok then show_select(result --[[@as easytasks.TaskTemplate[] ]]) end
        end)
    else
        show_select(entry.templates --[[@as easytasks.TaskTemplate[] ]])
    end

    callback(nil, nil)
end

--------------------------------------------------------------------------------
-- Handler
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext
---@param params lsp.CodeActionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CodeAction[])
function M.handler(context, params, callback)
    local actions = {}
    local row     = params.range.start.line
    local col     = params.range.start.character

    if not context.cst then
        callback(nil, actions); return
    end

    -- Template actions: only offered between task items
    if context.decode_tree then
        local ins_kind, node_id = tasks_insertion_ctx(
            context.cst, context.decode_tree, row, col)

        if ins_kind then
            local task_types = require("easytasks.types")
            -- Sort by type name so the action order is deterministic
            local type_names = vim.tbl_keys(task_types.get_all())
            table.sort(type_names)
            for _, type_name in ipairs(type_names) do
                local type_def = task_types.get_all()[type_name]
                if type_def.templates then
                    local indent = ""
                    if ins_kind == "array" and node_id then
                        indent = array_item_indent(context.bufnr, context.cst, node_id)
                    end
                    _pending_seq = _pending_seq + 1
                    _pending[_pending_seq] = {
                        bufnr     = context.bufnr,
                        row       = row,
                        col       = col,
                        kind      = ins_kind,
                        type_name = type_name,
                        templates = type_def.templates,
                        indent    = indent,
                    }
                    table.insert(actions, {
                        title   = "Add `" .. type_name .. "` task template",
                        kind    = vim.lsp.protocol.CodeActionKind.RefactorExtract,
                        command = {
                            title     = "Add `" .. type_name .. "` task template",
                            command   = "easytasks/insertTemplate",
                            arguments = { _pending_seq },
                        },
                    })
                end
            end
        end
    end

    -- Debug dump actions (always available when a CST exists)
    local function insert_action(title, text_content)
        table.insert(actions, {
            title = title,
            kind  = vim.lsp.protocol.CodeActionKind.RefactorExtract,
            edit  = {
                changes = {
                    [params.textDocument.uri] = {
                        {
                            range   = {
                                start = { line = row + 1, character = 0 },
                                ["end"] = { line = row + 1, character = 0 }
                            },
                            newText = text_content,
                        }
                    }
                }
            }
        })
    end

    insert_action("Dump Easytasks TOML CST", dump_cst_to_string(context.cst))
    insert_action("Dump Easytasks DecodeTree", dump_decode_tree_to_string(context.decode_tree))
    insert_action("Dump Easytasks Decoded Data", dump_decoder_to_string(
        context.parse_results and context.parse_results.data))
    insert_action("Dump Active Diagnostics Errors", dump_errors_to_string(context.parse_results))

    callback(nil, actions)
end

return M
