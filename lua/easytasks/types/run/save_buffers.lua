local M = {}

---@class easytasks.SaveBuffersConfig
---@field include_globs string[]
---@field exclude_globs string[]

---@param root string
---@param path string
local function _is_inside_folder(root, path)
    if path == root then return true end
    for parent in vim.fs.parents(path) do
        if parent == root then return true end
    end
    return false
end

---@param root string
---@param path string
local function _is_hidden_in_project(root, path)
    if vim.fs.basename(path):sub(1, 1) == "." then return true end
    for parent in vim.fs.parents(path) do
        if parent == root then return false end
        if vim.fs.basename(parent):sub(1, 1) == "." then return true end
    end
    return true
end

---@param path string
---@param regexes vim.regex[]
---@return boolean
local function _matches_any(path, regexes)
    for _, re in ipairs(regexes) do
        if re:match_str(path) then return true end
    end
    return false
end

---@param globs string[]
---@return vim.regex[]
local function _compile_globs(globs)
    local out = {}
    for _, g in ipairs(globs) do
        out[#out + 1] = vim.regex(vim.fn.glob2regpat(g))
    end
    return out
end

--- Save all modified buffers that belong to project_root, filtered by config globs.
--- Hidden files (dotfiles or files under hidden directories) are always skipped.
--- Empty include_globs means include all; empty exclude_globs means exclude nothing.
---@param project_root string
---@param config easytasks.SaveBuffersConfig
---@return integer saved, string[] paths
function M.save(project_root, config)
    local root = vim.fs.normalize(project_root)
    ---@diagnostic disable-next-line: undefined-field
    local real_root = vim.uv.fs_realpath(root)
    if not real_root then return 0, {} end

    local inc_re = _compile_globs(config.include_globs)
    local exc_re = _compile_globs(config.exclude_globs)
    local saved, saved_paths = 0, {}

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if not vim.api.nvim_buf_is_loaded(bufnr)
            or not vim.bo[bufnr].buflisted
            or vim.bo[bufnr].buftype ~= ""
            or not vim.bo[bufnr].modified
        then
            goto continue
        end

        local bname = vim.api.nvim_buf_get_name(bufnr)
        if bname == "" then goto continue end

        local norm_path = vim.fs.normalize(vim.fn.fnamemodify(bname, ":p"))
        ---@diagnostic disable-next-line: undefined-field
        local real_path = vim.uv.fs_realpath(norm_path)
        if not real_path then goto continue end

        if not _is_inside_folder(real_root, real_path) then goto continue end
        if _is_hidden_in_project(real_root, real_path) then goto continue end

        if #inc_re > 0 and not _matches_any(norm_path, inc_re) then goto continue end
        if #exc_re > 0 and _matches_any(norm_path, exc_re) then goto continue end

        local ok = pcall(function()
            vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent update") end)
        end)
        if ok then
            saved = saved + 1
            saved_paths[#saved_paths + 1] = vim.fs.basename(norm_path)
        end

        ::continue::
    end

    return saved, saved_paths
end

return M
