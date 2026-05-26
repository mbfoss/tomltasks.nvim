--- Task execution engine.
--- Handles TOML loading, dependency resolution, coroutine scheduling,
--- and task state tracking.
local async      = require("easytasks.util.async")
local Signal     = require("easytasks.util.Signal")
local parser     = require("easytasks.toml.parser")
local decoder    = require("easytasks.toml.decoder")
local task_types = require("easytasks.types")

---@class easytasks.TaskTemplate
---@field label string  shown in vim.ui.select
---@field task  table   the template data to encode and insert

---@class easytasks.TaskTypeDef
---@field run       fun(task: table, ctx: easytasks.RunCtx): boolean
---@field schema    table?
---@field templates (easytasks.TaskTemplate[]|(fun(): easytasks.TaskTemplate[]))?

---@class easytasks.RunCtx
---@field tasks     table<string,table>
---@field set_bufnr fun(bufnr: integer)  register an output buffer for this task (optional)

---@class easytasks.exec
local M = {}

---@alias easytasks.TaskState "idle"|"running"|"ok"|"failed"

---@class easytasks.RunEntry
---@field state   easytasks.TaskState
---@field bufnr   integer?
---@field job_ids integer[]

---@type table<string, easytasks.RunEntry>
local running = {}

--- Fires with (name: string, entry: easytasks.RunEntry) on every state change.
---@type easytasks.util.Signal<fun(name: string, entry: easytasks.RunEntry)>
local _on_state_change = Signal.new()

---@param fn fun(name: string, entry: easytasks.RunEntry)
function M.subscribe(fn)
    _on_state_change:subscribe(fn)
end

---@param fn fun(name: string, entry: easytasks.RunEntry)
function M.unsubscribe(fn)
    _on_state_change:unsubscribe(fn)
end

---@param name string
local function notify(name)
    local entry = running[name]
    if not entry then return end
    _on_state_change:emit(name, entry)
end

--- Return a snapshot of all run entries indexed by task name.
---@return table<string, easytasks.RunEntry>
function M.get_all()
    return vim.tbl_extend("force", {}, running)
end

-- ─── TOML loading ────────────────────────────────────────────────────────────

--- Read and decode a tasks TOML file.
--- Returns a name-indexed lookup table of task configs, or nil + error string.
---@param toml_path string
---@return table<string,table>?, string?
local function load_tasks(toml_path)
    local lines = vim.fn.readfile(toml_path)
    if not lines then
        return nil, "cannot read " .. toml_path
    end
    local text    = table.concat(lines, "\n") .. "\n"
    local parsed  = parser.parse(text)
    local decoded = decoder.decode(parsed.cst)

    if not decoded.data or not decoded.data.tasks then
        return nil, "no tasks table in " .. toml_path
    end

    local by_name = {}
    for _, task in ipairs(decoded.data.tasks) do
        if task.name then
            by_name[task.name] = task
        end
    end
    return by_name, nil
end

-- ─── Cycle detection ─────────────────────────────────────────────────────────

---@param name string
---@param tasks table<string,table>
---@param visited table<string,boolean>
---@param stack table<string,boolean>
---@return string?  cycle description, or nil
local function find_cycle(name, tasks, visited, stack)
    if stack[name] then return name end
    if visited[name] then return nil end
    visited[name] = true
    stack[name]   = true
    local task = tasks[name]
    if task and type(task.depends_on) == "table" then
        for _, dep in ipairs(task.depends_on) do
            local cycle = find_cycle(dep, tasks, visited, stack)
            if cycle then
                return name .. " → " .. cycle
            end
        end
    end
    stack[name] = false
    return nil
end

-- ─── Core execution ──────────────────────────────────────────────────────────

--- Run a single task (and its dependencies) as a coroutine.
--- Must be called from within a coroutine (via async.go).
---@param name  string
---@param tasks table<string,table>
---@return boolean ok
local function run_task_coro(name, tasks)
    local task = tasks[name]
    if not task then
        vim.notify("[easytasks] unknown task: " .. name, vim.log.levels.ERROR)
        return false
    end

    if not running[name] then
        running[name] = { state = "running", job_ids = {} }
        notify(name)
    end

    local entry = running[name]

    -- ── depends_on ──────────────────────────────────────────────────────────
    local deps = type(task.depends_on) == "table" and task.depends_on or {}
    if #deps > 0 then
        if task.depends_order == "parallel" then
            local fns = vim.tbl_map(function(dep_name)
                return function() return run_task_coro(dep_name, tasks) end
            end, deps)
            local results = async.wait_all(fns)
            for _, r in ipairs(results) do
                if not r.ok or not r.result then
                    entry.state = "failed"
                    notify(name)
                    return false
                end
            end
        else
            for _, dep_name in ipairs(deps) do
                local ok = run_task_coro(dep_name, tasks)
                if not ok then
                    entry.state = "failed"
                    notify(name)
                    return false
                end
            end
        end
    end

    -- ── type-specific run ────────────────────────────────────────────────────
    local type_def = task_types.get_all()[task.type]
    if not type_def then
        vim.notify("[easytasks] unknown task type: " .. tostring(task.type), vim.log.levels.ERROR)
        entry.state = "failed"
        notify(name)
        return false
    end

    ---@type easytasks.RunCtx
    local ctx = {
        tasks     = tasks,
        set_bufnr = function(bufnr) entry.bufnr = bufnr end,
    }

    local ok = type_def.run(task, ctx)
    entry.state = ok and "ok" or "failed"
    notify(name)
    return ok
end

-- ─── Public ──────────────────────────────────────────────────────────────────

--- Run `task_name` from the given TOML file.
---@param task_name string
---@param toml_path string
function M.run(task_name, toml_path)

    local tasks, err = load_tasks(toml_path)
    if not tasks then
        vim.notify("[easytasks] " .. (err or "load error"), vim.log.levels.ERROR)
        return
    end

    local task = tasks[task_name]
    if not task then
        vim.notify("[easytasks] task not found: " .. task_name, vim.log.levels.ERROR)
        return
    end

    -- if_running check
    local entry = running[task_name]
    if entry and entry.state == "running" then
        local policy = task.if_running or "refuse"
        if policy == "refuse" then
            vim.notify("[easytasks] task already running: " .. task_name, vim.log.levels.WARN)
            return
        end
        -- "parallel": fall through and start a new execution
        -- "restart": would stop the old one first (deferred — treated as parallel for now)
    end

    -- cycle check
    local cycle = find_cycle(task_name, tasks, {}, {})
    if cycle then
        vim.notify("[easytasks] dependency cycle: " .. cycle, vim.log.levels.ERROR)
        return
    end

    ---@type easytasks.RunEntry
    running[task_name] = { state = "running", job_ids = {} }
    notify(task_name)

    vim.notify("[easytasks] starting: " .. task_name, vim.log.levels.INFO)

    async.go(function()
        return run_task_coro(task_name, tasks)
    end, function(co_ok, result)
        local final_entry = running[task_name]
        if final_entry then
            if not co_ok then
                final_entry.state = "failed"
                notify(task_name)
                vim.notify("[easytasks] error: " .. task_name .. ": " .. tostring(result), vim.log.levels.ERROR)
            else
                final_entry.state = result and "ok" or "failed"
                notify(task_name)
                if result then
                    vim.notify("[easytasks] done: " .. task_name, vim.log.levels.INFO)
                else
                    vim.notify("[easytasks] failed: " .. task_name, vim.log.levels.WARN)
                end
            end
        end
    end)
end

--- Return the ordered list of task names from a TOML file, or nil + error.
---@param toml_path string
---@return string[]?, string?
function M.list(toml_path)
    local tasks, err = load_tasks(toml_path)
    if not tasks then return nil, err end
    local names = vim.tbl_keys(tasks)
    table.sort(names)
    return names
end

--- Stop a running task by killing its jobs.
--- Note: dep tasks that were started in parallel are not individually tracked here;
--- killing jobs of the top-level task is sufficient for process tasks.
---@param task_name string
function M.stop(task_name)
    local entry = running[task_name]
    if not entry then return end
    for _, jid in ipairs(entry.job_ids) do
        vim.fn.jobstop(jid)
    end
    entry.state = "idle"
    notify(task_name)
end

--- Return the current state of a task.
---@param task_name string
---@return easytasks.TaskState
function M.state(task_name)
    local entry = running[task_name]
    return entry and entry.state or "idle"
end

return M
