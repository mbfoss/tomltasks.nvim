--- Task execution engine.
--- Handles TOML loading, dependency resolution, coroutine scheduling,
--- and task state tracking.
local async        = require("easytasks.util.async")
local Signal       = require("easytasks.util.Signal")
local parser       = require("easytasks.toml.parser")
local decoder      = require("easytasks.toml.decoder")
local task_types   = require("easytasks.types")
local _notify      = require("easytasks.ui")

---@class easytasks.TaskTemplate
---@field label string  shown in vim.ui.select
---@field task  table   the template data to encode and insert

---@class easytasks.TaskTypeDef
---@field run       fun(task: table, ctx: easytasks.RunCtx): boolean
---@field schema    table?
---@field templates (easytasks.TaskTemplate[]|(fun(): easytasks.TaskTemplate[]))?

---@class easytasks.BufEntry
---@field bufnr integer
---@field label string

---@class easytasks.RunCtx
---@field tasks      table<string,table>
---@field add_bufnr  fun(bufnr: integer, label?: string)  register an output buffer for this run
---@field add_job_id fun(job_id: integer)                 register a job so it can be stopped

---@class easytasks.exec
local M            = {}

---@alias easytasks.TaskState "idle"|"running"|"ok"|"failed"|"stopped"

---@class easytasks.RunEntry
---@field task_name      string
---@field state          easytasks.TaskState
---@field bufnrs         easytasks.BufEntry[]
---@field job_ids        integer[]
---@field stop_requested boolean?
---@field done           easytasks.util.Signal<fun()>  fires once when the run reaches a terminal state

---@type table<string, easytasks.RunEntry>  run_id → entry
local _running     = {}

local _run_counter = 0

local function _gen_run_id(task_name)
    _run_counter = _run_counter + 1
    return task_name .. "#" .. _run_counter
end

--- Fires with (run_id: string, entry: easytasks.RunEntry) on every state change.
---@type easytasks.util.Signal<fun(run_id: string, entry: easytasks.RunEntry)>
local _on_state_change = Signal.new()

---@param fn fun(run_id: string, entry: easytasks.RunEntry)
function M.subscribe(fn)
    _on_state_change:subscribe(fn)
end

---@param fn fun(run_id: string, entry: easytasks.RunEntry)
function M.unsubscribe(fn)
    _on_state_change:unsubscribe(fn)
end

---@param run_id string
local function notify(run_id)
    local entry = _running[run_id]
    if not entry then return end
    _on_state_change:emit(run_id, entry)
end

--- Return a snapshot of all run entries indexed by run_id.
---@return table<string, easytasks.RunEntry>
function M.get_all()
    return vim.tbl_extend("force", {}, _running)
end

-- ─── TOML loading ────────────────────────────────────────────────────────────

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
---@return string?
local function find_cycle(name, tasks, visited, stack)
    if stack[name] then return name end
    if visited[name] then return nil end
    visited[name] = true
    stack[name]   = true
    local task    = tasks[name]
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
--- `run_id` is provided by the caller for the top-level task so the entry is
--- already visible before the coroutine body runs; dep tasks generate their own.
---@param name   string
---@param tasks  table<string,table>
---@param run_id string?
---@return boolean ok
local function run_task_coro(name, tasks, run_id)
    local task = tasks[name]
    if not task then
        _notify.notify_error("unknown task: " .. name)
        return false
    end

    if not run_id then
        run_id = _gen_run_id(name)
        _running[run_id] = { task_name = name, state = "running", bufnrs = {}, job_ids = {}, done = Signal.new() }
        notify(run_id)
    end

    local entry = _running[run_id]

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
                    notify(run_id)
                    return false
                end
            end
        else
            for _, dep_name in ipairs(deps) do
                local ok = run_task_coro(dep_name, tasks)
                if not ok then
                    entry.state = "failed"
                    notify(run_id)
                    return false
                end
            end
        end
    end

    -- ── type-specific run ────────────────────────────────────────────────────
    local type_def = task_types.get_all()[task.type]
    if not type_def then
        _notify.notify_error("unknown task type: " .. tostring(task.type))
        entry.state = "failed"
        notify(run_id)
        return false
    end

    ---@type easytasks.RunCtx
    local ctx = {
        tasks      = tasks,
        add_bufnr  = function(bufnr, label)
            table.insert(entry.bufnrs, { bufnr = bufnr, label = label or "output" })
            notify(run_id)
            vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
                buffer  = bufnr,
                once    = true,
                callback = function()
                    for i, be in ipairs(entry.bufnrs) do
                        if be.bufnr == bufnr then
                            table.remove(entry.bufnrs, i)
                            break
                        end
                    end
                    notify(run_id)
                end,
            })
        end,
        add_job_id = function(job_id)
            table.insert(entry.job_ids, job_id)
        end,
    }

    local ok = type_def.run(task, ctx)
    entry.state = ok and "ok" or "failed"
    notify(run_id)
    return ok
end

-- ─── Internal launch ─────────────────────────────────────────────────────────

---@param task_name string
---@param tasks     table<string,table>
local function _launch(task_name, tasks)
    local run_id = _gen_run_id(task_name)
    ---@type easytasks.RunEntry
    _running[run_id] = { task_name = task_name, state = "running", bufnrs = {}, job_ids = {}, done = Signal.new() }
    notify(run_id)

    async.go(function()
        return run_task_coro(task_name, tasks, run_id)
    end, function(co_ok, result)
        local final_entry = _running[run_id]
        if not final_entry then return end

        if not co_ok then
            final_entry.state = "failed"
            notify(run_id)
            _notify.notify_error("error: " .. task_name .. ": " .. tostring(result))
        elseif final_entry.stop_requested then
            final_entry.state = "stopped"
            notify(run_id)
        else
            final_entry.state = result and "ok" or "failed"
            notify(run_id)
        end

        final_entry.done:emit()
    end)
end

-- ─── Public ──────────────────────────────────────────────────────────────────

---@param task_name string
---@param toml_path string
function M.run(task_name, toml_path)
    local tasks, err = load_tasks(toml_path)
    if not tasks then
        _notify.notify_error(err or "load error")
        return
    end

    local task = tasks[task_name]
    if not task then
        _notify.notify_error("task not found: " .. task_name)
        return
    end

    -- cycle check
    local cycle = find_cycle(task_name, tasks, {}, {})
    if cycle then
        _notify.notify_error("dependency cycle: " .. cycle)
        return
    end

    -- if_running check
    local already_running = false
    for _, e in pairs(_running) do
        if e.task_name == task_name and e.state == "running" then
            already_running = true
            break
        end
    end

    if already_running then
        local policy = task.if_running or "refuse"
        if policy == "refuse" then
            _notify.notify_warning("task already running: " .. task_name)
            return
        elseif policy == "restart" then
            local signals = {}
            for _, e in pairs(_running) do
                if e.task_name == task_name and e.state == "running" then
                    table.insert(signals, e.done)
                end
            end
            M.stop(task_name)
            async.go(function()
                local fns = vim.tbl_map(function(sig)
                    return function() async.wait_signal(sig) end
                end, signals)
                if #fns > 0 then async.wait_all(fns) end
                _launch(task_name, tasks)
            end, function() end)
            return
        end
        -- "parallel": fall through and start a new independent run
    end

    _launch(task_name, tasks)
end

---@param toml_path string
---@return string[]?, string?
function M.list(toml_path)
    local tasks, err = load_tasks(toml_path)
    if not tasks then return nil, err end
    local names = vim.tbl_keys(tasks)
    table.sort(names)
    return names
end

--- Stop all running instances of a task.
---@param task_name string
function M.stop(task_name)
    for _, entry in pairs(_running) do
        if entry.task_name == task_name and entry.state == "running" then
            entry.stop_requested = true
            for _, jid in ipairs(entry.job_ids) do
                vim.fn.jobstop(jid)
            end
        end
    end
end

--- Return the state of the most recent run for a task, or "idle" if none.
---@param task_name string
---@return easytasks.TaskState
function M.state(task_name)
    local result = "idle"
    for _, entry in pairs(_running) do
        if entry.task_name == task_name then
            if entry.state == "running" then return "running" end
            result = entry.state
        end
    end
    return result
end

return M
