--- Task execution engine.
--- Handles Lua task-file loading, dependency resolution, coroutine scheduling,
--- and task state tracking.
local async        = require("easytasks.util.async")
local Signal       = require("easytasks.util.Signal")
local task_types   = require("easytasks.types")
local resolver     = require("easytasks.runner.resolver")
local notify       = require("easytasks.ui")
local save_buffers = require("easytasks.util.save_buffers")
local project      = require("easytasks.project")

---@alias easytasks.RunFn fun(task: table, ctx: easytasks.RunCtx, on_done: fun(ok: boolean)): fun()
---@alias easytasks.DisposeFn fun(bufnrs: easytasks.BufEntry[])
---@
---@class easytasks.TaskTypeDef
---@field start     easytasks.RunFn
---@field dispose   easytasks.DisposeFn?  optional cleanup called when the run is disposed
---@field validate  (fun(task: table): boolean, string?)?  optional run-time validation
---@field templates (easytasks.TaskTemplate[]|(fun(): easytasks.TaskTemplate[]))?

---@class easytasks.BufEntry
---@field bufnr    integer
---@field label    string
---@field priority integer  higher = shown preferentially when added (default 0)

---@class easytasks.ProgressEvent
---@field time    integer  unix timestamp
---@field message string

---@class easytasks.RunCtx
---@field tasks      table<string,table>
---@field add_bufnr  fun(bufnr: integer, label?: string, priority?: integer)
---@field report     fun(message: string)

---@alias easytasks.TaskState "idle"|"running"|"waiting"|"ok"|"failed"|"stopped"

---@class easytasks.RunEntry
---@field task_name      string
---@field task_type      string?
---@field state          easytasks.TaskState
---@field waiting_for    string[]?
---@field reports        easytasks.ProgressEvent[]
---@field bufnrs         easytasks.BufEntry[]
---@field cancel         fun()?
---@field stop_requested boolean?
---@field done           easytasks.util.Signal<fun()>
---@field ephemeral      boolean?
---@field is_shell       boolean?  panel-only standalone shell tab, not a real task run

---@class easytasks.exec
local M            = {}

---@type table<string, easytasks.RunEntry>
local _running     = {}
local _run_counter = 0


---@type easytasks.util.Signal<fun(run_id: string, entry: easytasks.RunEntry)>
local _on_state_change = Signal.new()

---@type easytasks.util.Signal<fun(run_id: string, event: easytasks.ProgressEvent)>
local _on_report = Signal.new()

---@type easytasks.util.Signal<fun(run_id: string)>
local _on_dispose = Signal.new()

local function _gen_run_id(task_name)
    _run_counter = _run_counter + 1
    return task_name .. "#" .. _run_counter
end


---@param fn fun(run_id: string, entry: easytasks.RunEntry)
---@return fun() cancel
function M.on_state_change(fn) return _on_state_change:subscribe(fn) end

---@param fn fun(run_id: string, event: easytasks.ProgressEvent)
---@return fun() cancel
function M.on_report(fn) return _on_report:subscribe(fn) end

---@param fn fun(run_id: string)
---@return fun() cancel
function M.on_dispose(fn) return _on_dispose:subscribe(fn) end

local function _notify_state(run_id)
    local entry = _running[run_id]
    if entry then _on_state_change:emit(run_id, entry) end
end

---@param run_id string
---@param event  easytasks.ProgressEvent
local function _notify_report(run_id, event)
    _on_report:emit(run_id, event)
end

---@param run_id  string
---@param message string
local function _append_report(run_id, message)
    local entry = _running[run_id]
    if not entry then return end
    local ev = { time = os.time(), message = message }
    table.insert(entry.reports, ev)
    _notify_report(run_id, ev)
end

---@return table<string, easytasks.RunEntry>
function M.get_all()
    return vim.tbl_extend("force", {}, _running)
end

-- ─── Lua task-file loading ─────────────────────────────────────────────────────

--- Build the restricted `easytasks` table injected as a global into a tasks
--- file: just the authoring surface (`types`, `expand`), not lifecycle or
--- extension-point methods (`setup`, `enable`, `register_task_type`, …) that
--- belong in the user's init.lua via `require("easytasks")`.
---@return easytasks.TasksFileGlobal
local function _tasks_file_global()
    local easytasks = require("easytasks")
    return { types = easytasks.types, expand = easytasks.expand }
end

--- Load and execute a Lua tasks file, returning its task definitions.
--- The file is re-read on every call (never cached) so edits take effect.
--- The returned value may be either a map of name → task, or an array of tasks
--- that each carry their own `name`. Map keys win as the task name; for array
--- entries the explicit `name` field is required.
---@param path string
---@return table<string,table>?  by_name
---@return string[]?             ordered
---@return string?               err
local function _load_tasks(path)
    local short = vim.fn.fnamemodify(path, ":~:.")
    local chunk, load_err = loadfile(path)
    if not chunk then
        return nil, nil, short .. ": " .. tostring(load_err)
    end
    -- Expose `easytasks` as a global inside the tasks file only, so authors can
    -- write `easytasks.types.run { … }` without a `require`. Falls back to the
    -- real globals (`vim`, `require`, …) for everything else; nested `require`s
    -- made from within the tasks file get the standard global env, not this one.
    setfenv(chunk, setmetatable({ easytasks = _tasks_file_global() }, { __index = _G }))
    local ok, result = pcall(chunk)
    if not ok then
        return nil, nil, short .. ": " .. tostring(result)
    end
    if type(result) ~= "table" then
        return nil, nil, short .. ": tasks file must return a table, got " .. type(result)
    end

    local by_name = {}            ---@type table<string,table>
    local ordered = {}            ---@type string[]

    -- Array part first (preserves declared order); each needs an explicit name.
    for i, task in ipairs(result) do
        if type(task) ~= "table" then
            return nil, nil, ("%s: task #%d is a %s, expected a table"):format(short, i, type(task))
        end
        local name = task.name
        if type(name) ~= "string" or name == "" then
            return nil, nil, ("%s: task #%d has no `name`"):format(short, i)
        end
        if not by_name[name] then
            by_name[name] = task
            ordered[#ordered + 1] = name
        end
    end

    -- Map part: the key is the task name. Sorted for stable presentation.
    local map_names = {}
    for key, task in pairs(result) do
        if type(key) == "string" then
            if type(task) ~= "table" then
                return nil, nil, ("%s: task '%s' is a %s, expected a table"):format(short, key, type(task))
            end
            task.name = task.name or key
            if not by_name[task.name] then
                map_names[#map_names + 1] = task.name
                by_name[task.name] = task
            end
        end
    end
    table.sort(map_names)
    vim.list_extend(ordered, map_names)

    if #ordered == 0 then
        return nil, nil, short .. ": no tasks defined"
    end
    return by_name, ordered, nil
end

-- ─── Dependency validation ───────────────────────────────────────────────────

---@param name   string
---@param tasks  table<string,table>
---@param seen   table<string,boolean>
---@return string?  missing dependency name, or nil if all deps exist
local function _find_missing_dep(name, tasks, seen)
    if seen[name] then return nil end
    seen[name] = true
    local task = tasks[name]
    if not task then return name end
    if type(task.depends_on) == "table" then
        for _, dep in ipairs(task.depends_on) do
            local missing = _find_missing_dep(dep, tasks, seen)
            if missing then return missing end
        end
    end
    return nil
end

-- ─── Cycle detection ─────────────────────────────────────────────────────────

---@param name    string
---@param tasks   table<string,table>
---@param visited table<string,boolean>
---@param stack   table<string,boolean>
---@return string?
local function _find_cycle(name, tasks, visited, stack)
    if stack[name] then return name end
    if visited[name] then return nil end
    visited[name] = true
    stack[name]   = true
    local task    = tasks[name]
    if task and type(task.depends_on) == "table" then
        for _, dep in ipairs(task.depends_on) do
            local cycle = _find_cycle(dep, tasks, visited, stack)
            if cycle then return name .. " → " .. cycle end
        end
    end
    stack[name] = false
    return nil
end

-- ─── save_buffers ──────────────────────────────────────────────────────────────

--- Normalize a task's `save_buffers` field into a SaveBuffersConfig, or nil if
--- saving is disabled. Accepts `true` (save all) or `{ include, exclude }`.
---@param value any
---@return easytasks.SaveBuffersConfig?
local function _save_buffers_config(value)
    if value == true then
        return { include_globs = {}, exclude_globs = {} }
    elseif type(value) == "table" then
        return {
            include_globs  = value.include or {},
            exclude_globs  = value.exclude or {},
            include_hidden = value.include_hidden or false,
        }
    end
    return nil
end

--- Save modified project buffers for a task if it opted in, reporting which
--- files were saved. No-op when not in a project or nothing matched.
---@param task   table
---@param report fun(message: string)
local function _save_buffers_for(task, report)
    local sb_config = _save_buffers_config(task.save_buffers)
    if not sb_config then return end
    local root = project.find_root()
    if not root then return end
    local n, paths = save_buffers.save(root, sb_config)
    if n == 0 then return end
    local lines = { ("saved %d file%s:"):format(n, n == 1 and "" or "s") }
    for i = 1, math.min(n, 5) do lines[#lines + 1] = "  " .. paths[i] end
    if n > 5 then lines[#lines + 1] = ("  … and %d more"):format(n - 5) end
    report(table.concat(lines, "\n"))
end

-- ─── Core execution ──────────────────────────────────────────────────────────

--- Run a single task (and its dependencies) as a coroutine.
--- Always creates and fully owns its RunEntry — entry is created synchronously
--- before the first yield, so it is visible to callers immediately.
--- Must be called from within a coroutine (via async.go).
---@param name      string
---@param tasks     table<string,table>
---@param run_id?   string   pre-existing run_id to reuse (e.g. a waiting entry)
---@param ephemeral boolean?
---@return boolean ok
local function _run_task_coro(name, tasks, run_id, ephemeral)
    local task = tasks[name]
    if not task then
        notify.notify_error("unknown task: " .. name)
        return false
    end

    ---@type easytasks.RunEntry
    local entry
    if run_id then
        entry             = _running[run_id]
        entry.state       = "running"
        entry.waiting_for = nil
    else
        local to_dispose = {}
        for rid, e in pairs(_running) do
            if e.task_name == name and not e.ephemeral
                and e.state ~= "running" and e.state ~= "waiting"
            then
                table.insert(to_dispose, rid)
            end
        end
        for _, rid in ipairs(to_dispose) do M.dispose(rid) end

        run_id = _gen_run_id(name)
        entry = {
            task_name = name,
            task_type = task.type,
            state     = "running",
            bufnrs    = {},
            done      = Signal.new(),
            ephemeral = ephemeral or nil,
            reports   = {},
        }
        _running[run_id] = entry
    end
    _notify_state(run_id)
    _append_report(run_id, "started")

    local function finish(state)
        entry.state = state
        entry.done:emit()
        _notify_state(run_id)
        _append_report(run_id, state)
        return state == "ok"
    end

    -- ── depends_on ──────────────────────────────────────────────────────────
    local deps = type(task.depends_on) == "table" and task.depends_on or {}
    if #deps > 0 then
        entry.state       = "waiting"
        entry.waiting_for = deps
        _notify_state(run_id)
        _append_report(run_id, "waiting for: " .. table.concat(deps, ", "))

        local deps_ok
        if task.depends_order == "parallel" then
            local fns = vim.tbl_map(function(dep_name)
                return function() return _run_task_coro(dep_name, tasks) end
            end, deps)
            local results = async.wait_all(fns)
            deps_ok = true
            for i, r in ipairs(results) do
                if not r.ok or not r.result then
                    deps_ok = false
                    _append_report(run_id, "dependency '" .. deps[i] .. "' failed")
                end
            end
        else
            deps_ok = true
            for _, dep_name in ipairs(deps) do
                local r = async.wait_one(function() return _run_task_coro(dep_name, tasks) end)
                if not r.ok or not r.result then
                    deps_ok = false
                    _append_report(run_id, "dependency '" .. dep_name .. "' failed")
                    break
                end
            end
        end

        if not deps_ok then
            return finish("failed")
        end

        entry.state       = "running"
        entry.waiting_for = nil
        _notify_state(run_id)
        _append_report(run_id, "dependencies resolved")
    end

    -- ── stop check (may have been requested while waiting for deps) ──────────
    if entry.stop_requested then
        return finish("stopped")
    end

    -- ── value resolution (function-valued fields) ────────────────────────────
    local resolve_ok, resolved = coroutine.yield(function(waker)
        resolver.resolve_values(task, { task = task, tasks = tasks }, function(ok, result, err)
            waker(ok, ok and result or err)
        end)
    end)
    if not resolve_ok then
        _append_report(run_id, "value error: " .. tostring(resolved))
        return finish("failed")
    end
    task = resolved
    _append_report(run_id, "resolved task:\n" .. vim.inspect(task))

    -- ── type-specific run ────────────────────────────────────────────────────
    local type_def = task_types.get(task.type)
    if not type_def then
        _append_report(run_id, "unknown task type: " .. tostring(task.type))
        return finish("failed")
    end

    if type_def.validate then
        local valid, verr = type_def.validate(task)
        if not valid then
            _append_report(run_id, "invalid task: " .. tostring(verr))
            return finish("failed")
        end
    end

    -- Save buffers immediately before this task's own effective run (after its
    -- dependencies have completed). A dependency that needs saving sets its own
    -- save_buffers flag.
    _save_buffers_for(task, function(msg) _append_report(run_id, msg) end)

    ---@type easytasks.RunCtx
    local ctx = {
        tasks     = tasks,
        report    = function(msg) _append_report(run_id, msg) end,
        add_bufnr = function(bufnr, label, priority)
            if not label then
                label = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
            end
            table.insert(entry.bufnrs, { bufnr = bufnr, label = label, priority = priority or 0 })
            _notify_state(run_id)
            vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
                buffer   = bufnr,
                once     = true,
                callback = function()
                    for i, be in ipairs(entry.bufnrs) do
                        if be.bufnr == bufnr then
                            table.remove(entry.bufnrs, i)
                            break
                        end
                    end
                    _notify_state(run_id)
                end,
            })
        end,
    }

    local ok = coroutine.yield(function(waker)
        local settled = false
        local cancel = type_def.start(task, ctx, function(result)
            if settled then return end
            settled = true
            waker(result)
        end)
        assert(type(cancel) == "function",
            "task type '" .. tostring(task.type) .. "' start() must return a cancel function")
        entry.cancel = cancel
    end)

    if entry.stop_requested then
        return finish("stopped")
    end
    return finish(ok and "ok" or "failed")
end

-- ─── Internal launch ─────────────────────────────────────────────────────────

--- Create a terminal failed RunEntry visible in the status panel.
---@param task_name string
---@param message   string
local function _fail_immediately(task_name, message)
    local run_id     = _gen_run_id(task_name)
    _running[run_id] = {
        task_name = task_name,
        state     = "failed",
        bufnrs    = {},
        done      = Signal.new(),
        reports   = {},
    }
    _running[run_id].done:emit()
    _notify_state(run_id)
    _append_report(run_id, message)
end

--- `run_task_coro` creates its entry synchronously before its first yield,
--- so the entry is live before launch returns.
---@param task_name string
---@param tasks     table<string,table>
---@param run_id?   string   pre-existing run_id to reuse (e.g. a waiting entry)
---@param ephemeral boolean?
local function _launch(task_name, tasks, run_id, ephemeral)
    async.go(function()
        return _run_task_coro(task_name, tasks, run_id, ephemeral)
    end, function(co_ok, result)
        if co_ok then return end
        local msg    = "coroutine error: " .. tostring(result)
        local orphan = false
        -- coroutine itself threw — mark any orphaned running entry as failed
        for rid, entry in pairs(_running) do
            if entry.task_name == task_name
                and (entry.state == "running" or entry.state == "waiting") then
                orphan      = true
                entry.state = "failed"
                entry.done:emit()
                _notify_state(rid)
                _append_report(rid, msg)
            end
        end
        if not orphan then _fail_immediately(task_name, msg) end
    end)
end

-- ─── Public ──────────────────────────────────────────────────────────────────

---@param task_name string
---@param path string
function M.run(task_name, path)
    local tasks, _, err = _load_tasks(path)
    if not tasks then
        _fail_immediately(task_name, err or "load error")
        return
    end

    local task = tasks[task_name]
    if not task then
        _fail_immediately(task_name, "task not found: " .. task_name)
        return
    end

    local missing = _find_missing_dep(task_name, tasks, {})
    if missing then
        _fail_immediately(task_name, "unknown dependency: " .. missing)
        return
    end

    local cycle = _find_cycle(task_name, tasks, {}, {})
    if cycle then
        _fail_immediately(task_name, "dependency cycle: " .. cycle)
        return
    end

    -- Collect any currently-active non-ephemeral runs for this task
    local active_signals = {}
    for _, e in pairs(_running) do
        if e.task_name == task_name and not e.ephemeral
            and (e.state == "running" or e.state == "waiting") then
            table.insert(active_signals, e.done)
        end
    end
    local is_running = #active_signals > 0

    if not is_running then
        _launch(task_name, tasks)
        return
    end

    local policy = task.if_running or "refuse"

    if policy == "refuse" then
        notify.notify_warning("task already running: " .. task_name)
    elseif policy == "parallel" then
        _launch(task_name, tasks)
    elseif policy == "wait" then
        local run_id = _gen_run_id(task_name)
        _running[run_id] = {
            task_name = task_name,
            state     = "waiting",
            bufnrs    = {},
            done      = Signal.new(),
            reports   = {},
        }
        _notify_state(run_id)

        local fns = vim.tbl_map(function(sig)
            return function() async.wait_signal(sig) end
        end, active_signals)

        async.go(function() async.wait_all(fns) end, function()
            _launch(task_name, tasks, run_id)
        end)
    elseif policy == "restart" then
        M.stop(task_name)

        local fns = vim.tbl_map(function(sig)
            return function() async.wait_signal(sig) end
        end, active_signals)

        async.go(function()
            if #fns > 0 then async.wait_all(fns) end
        end, function()
            _launch(task_name, tasks)
        end)
    end
end

--- Run a task whose definition is supplied inline, not from a TOML file.
---@param task_name string
---@param task_def  table  task data (same shape as a decoded TOML task entry)
function M.run_ephemeral(task_name, task_def)
    task_def.name = task_name
    _launch(task_name, { [task_name] = task_def }, nil, true)
end

---@param path string
---@return string[]? ordered
---@return table<string,table>? by_name
---@return string? err
function M.list(path)
    local by_name, ordered, err = _load_tasks(path)
    return ordered, by_name, err
end

--- Stop all active instances of a task.
---@param task_name string
function M.stop(task_name)
    local count = 0
    for _, entry in pairs(_running) do
        if entry.task_name == task_name and not entry.ephemeral
            and (entry.state == "running" or entry.state == "waiting") then
            entry.stop_requested = true
            if entry.cancel then
                entry.cancel()
            end
            count = count + 1
        end
    end
end

--- Dispose a finished run: invoke the type's dispose hook (if any), delete all
--- tracked buffers, remove the entry from state, and emit the dispose signal.
--- Returns false + error string if the run is still active.
---@param run_id string
---@return boolean ok, string? err
function M.dispose(run_id)
    local entry = _running[run_id]
    if not entry then return false, "run not found: " .. run_id end
    local s = entry.state
    if s == "running" or s == "waiting" then
        return false, "task is still active; stop it first"
    end

    -- Remove from state and notify subscribers first so the status panel can
    -- switch away from the buffer synchronously before we delete it.
    _running[run_id] = nil
    _on_dispose:emit(run_id)

    local type_def = entry.task_type and task_types.get(entry.task_type)
    if type_def and type_def.dispose then
        pcall(type_def.dispose, entry.bufnrs)
    else
        for _, be in ipairs(entry.bufnrs) do
            if vim.api.nvim_buf_is_valid(be.bufnr) then
                pcall(vim.api.nvim_buf_delete, be.bufnr, { force = true })
            end
        end
    end
    return true
end

--- Return the state of the most recent run for a task, or "idle" if none.
---@param task_name string
---@return easytasks.TaskState
function M.state(task_name)
    local best_n = -1
    local result = "idle" ---@type easytasks.TaskState
    for id, entry in pairs(_running) do
        if entry.task_name == task_name and not entry.ephemeral then
            if entry.state == "running" or entry.state == "waiting" then
                return "running"
            end
            local n = tonumber(id:match("#(%d+)$")) or 0
            if n > best_n then
                best_n = n
                result = entry.state
            end
        end
    end
    return result
end

return M
