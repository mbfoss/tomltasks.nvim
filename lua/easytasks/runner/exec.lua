--- Task execution engine.
--- Handles TOML loading, dependency resolution, coroutine scheduling,
--- and task state tracking.
local async        = require("easytasks.util.async")
local Signal       = require("easytasks.util.Signal")
local parser       = require("easytasks.toml.parser")
local decoder      = require("easytasks.toml.decoder")
local task_types   = require("easytasks.types")
local resolver     = require("easytasks.runner.resolver")
local notify       = require("easytasks.ui")
local log          = require("easytasks.util.log")

---@class easytasks.TaskTemplate
---@field label string  shown in vim.ui.select
---@field task  table   the template data to encode and insert

---@class easytasks.TaskTypeDef
---@field run       fun(task: table, ctx: easytasks.RunCtx, on_done: fun(ok: boolean)): fun()
---@field dispose   (fun(bufnrs: easytasks.BufEntry[]))?  optional cleanup called when the run is disposed
---@field schema    table?
---@field templates (easytasks.TaskTemplate[]|(fun(): easytasks.TaskTemplate[]))?

---@class easytasks.BufEntry
---@field bufnr    integer
---@field label    string
---@field priority integer  higher = shown preferentially when added (default 0)

---@class easytasks.ProgressEvent
---@field time    integer  unix timestamp
---@field message string

---@class easytasks.RunProgress
---@field start_time integer              unix timestamp set when the run begins
---@field stop_time  integer?             unix timestamp set when the run reaches a terminal state
---@field events     easytasks.ProgressEvent[]

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
---@field progress       easytasks.RunProgress
---@field bufnrs         easytasks.BufEntry[]
---@field cancel         fun()?
---@field stop_requested boolean?
---@field done           easytasks.util.Signal<fun()>
---@field ephemeral      boolean?

---@class easytasks.exec
local M            = {}

---@type table<string, easytasks.RunEntry>
local _running     = {}
local _run_counter = 0


---@type easytasks.util.Signal<fun(run_id: string, entry: easytasks.RunEntry)>
local _on_state_change = Signal.new()

---@type easytasks.util.Signal<fun(run_id: string)>
local _on_dispose = Signal.new()

local function gen_run_id(task_name)
    _run_counter = _run_counter + 1
    return task_name .. "#" .. _run_counter
end


---@param fn fun(run_id: string, entry: easytasks.RunEntry)
---@return fun() cancel
function M.on_state_change(fn) return _on_state_change:subscribe(fn) end

---@param fn fun(run_id: string)
---@return fun() cancel
function M.on_dispose(fn) return _on_dispose:subscribe(fn) end

local function notify_change(run_id)
    local entry = _running[run_id]
    if entry then _on_state_change:emit(run_id, entry) end
end

---@return table<string, easytasks.RunEntry>
function M.get_all()
    return vim.tbl_extend("force", {}, _running)
end

-- ─── TOML loading ────────────────────────────────────────────────────────────

---@param toml_path string
---@return table<string,table>?, string[]?, string?
local function load_tasks(toml_path)
    log.debug("load_tasks: %s", toml_path)
    local lines = vim.fn.readfile(toml_path)
    if not lines then return nil, nil, "cannot read " .. toml_path end
    local text    = table.concat(lines, "\n") .. "\n"
    local parsed  = parser.parse(text)
    local decoded = decoder.decode(parsed.cst)
    if not decoded.data or not decoded.data.tasks then
        log.warn("load_tasks: no tasks table in %s", toml_path)
        return nil, nil, "no tasks table in " .. toml_path
    end
    local by_name = {}
    local ordered = {} ---@type string[]
    for _, task in ipairs(decoded.data.tasks) do
        if task.name and not by_name[task.name] then
            by_name[task.name] = task
            table.insert(ordered, task.name)
        end
    end
    log.debug("load_tasks: loaded %d tasks", #ordered)
    return by_name, ordered, nil
end

-- ─── Dependency validation ───────────────────────────────────────────────────

---@param name   string
---@param tasks  table<string,table>
---@param seen   table<string,boolean>
---@return string?  missing dependency name, or nil if all deps exist
local function find_missing_dep(name, tasks, seen)
    if seen[name] then return nil end
    seen[name] = true
    local task = tasks[name]
    if not task then return name end
    if type(task.depends_on) == "table" then
        for _, dep in ipairs(task.depends_on) do
            local missing = find_missing_dep(dep, tasks, seen)
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
local function find_cycle(name, tasks, visited, stack)
    if stack[name] then return name end
    if visited[name] then return nil end
    visited[name] = true
    stack[name]   = true
    local task    = tasks[name]
    if task and type(task.depends_on) == "table" then
        for _, dep in ipairs(task.depends_on) do
            local cycle = find_cycle(dep, tasks, visited, stack)
            if cycle then return name .. " → " .. cycle end
        end
    end
    stack[name] = false
    return nil
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
local function run_task_coro(name, tasks, run_id, ephemeral)
    log.debug("run_task_coro: enter name=%s run_id=%s", name, tostring(run_id))
    local task = tasks[name]
    if not task then
        log.error("run_task_coro: unknown task %s", name)
        notify.notify_error("unknown task: " .. name)
        return false
    end

    ---@type easytasks.RunEntry
    local entry
    if run_id then
        log.debug("run_task_coro: reusing entry for run_id=%s", run_id)
        entry                     = _running[run_id]
        entry.state               = "running"
        entry.waiting_for         = nil
        entry.progress.start_time = os.time()
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

        run_id = gen_run_id(name)
        log.debug("run_task_coro: new run_id=%s", run_id)
        entry = {
            task_name = name,
            task_type = task.type,
            state     = "running",
            bufnrs    = {},
            done      = Signal.new(),
            ephemeral = ephemeral or nil,
            progress  = { start_time = os.time(), events = {} },
        }
        _running[run_id] = entry
    end
    notify_change(run_id)

    local function event(msg)
        log.info("event [%s]: %s", run_id, msg)
        table.insert(entry.progress.events, { time = os.time(), message = msg })
        notify_change(run_id)
    end

    local function finish(state)
        log.info("run_task_coro: finish run_id=%s state=%s", run_id, state)
        entry.state              = state
        entry.progress.stop_time = os.time()
        entry.done:emit()
        notify_change(run_id)
        return state == "ok"
    end

    -- ── depends_on ──────────────────────────────────────────────────────────
    local deps = type(task.depends_on) == "table" and task.depends_on or {}
    if #deps > 0 then
        log.debug("run_task_coro: [%s] waiting for deps=%s order=%s",
            run_id, table.concat(deps, ","), tostring(task.depends_order))
        entry.state       = "waiting"
        entry.waiting_for = deps
        notify_change(run_id)

        local deps_ok
        if task.depends_order == "parallel" then
            log.debug("run_task_coro: [%s] launching %d deps in parallel", run_id, #deps)
            local fns = vim.tbl_map(function(dep_name)
                return function() return run_task_coro(dep_name, tasks) end
            end, deps)
            local results = async.wait_all(fns)
            log.debug("run_task_coro: [%s] parallel deps returned", run_id)
            deps_ok = true
            for i, r in ipairs(results) do
                if not r.ok or not r.result then
                    deps_ok = false
                    event("dependency '" .. deps[i] .. "' failed")
                end
            end
        else
            deps_ok = true
            for _, dep_name in ipairs(deps) do
                log.debug("run_task_coro: [%s] serial dep %s start", run_id, dep_name)
                local r = async.wait_one(function() return run_task_coro(dep_name, tasks) end)
                log.debug("run_task_coro: [%s] serial dep %s done ok=%s result=%s",
                    run_id, dep_name, tostring(r.ok), tostring(r.result))
                if not r.ok or not r.result then
                    deps_ok = false
                    event("dependency '" .. dep_name .. "' failed")
                    break
                end
            end
        end

        if not deps_ok then
            log.warn("run_task_coro: [%s] deps failed", run_id)
            return finish("failed")
        end

        log.debug("run_task_coro: [%s] all deps ok, resuming", run_id)
        entry.state       = "running"
        entry.waiting_for = nil
        notify_change(run_id)
    end

    -- ── stop check (may have been requested while waiting for deps) ──────────
    if entry.stop_requested then
        log.info("run_task_coro: [%s] stop_requested after deps", run_id)
        return finish("stopped")
    end

    -- ── macro resolution ─────────────────────────────────────────────────────
    log.debug("run_task_coro: [%s] resolving macros", run_id)
    local macro_ok, resolved = coroutine.yield(function(waker)
        resolver.resolve_macros(task, { task = task, tasks = tasks }, function(ok, result, err)
            waker(ok, ok and result or err)
        end)
    end)
    if not macro_ok then
        log.warn("run_task_coro: [%s] macro error: %s", run_id, tostring(resolved))
        event("macro error: " .. tostring(resolved))
        return finish("failed")
    end
    task = resolved
    event("resolved task:\n" .. require("easytasks.toml.encoder").encode(task))

    -- ── type-specific run ────────────────────────────────────────────────────
    local type_def = task_types.get(task.type)
    if not type_def then
        log.error("run_task_coro: [%s] unknown task type %s", run_id, tostring(task.type))
        event("unknown task type: " .. tostring(task.type))
        return finish("failed")
    end

    log.debug("run_task_coro: [%s] calling type_def.run type=%s", run_id, tostring(task.type))
    ---@type easytasks.RunCtx
    local ctx = {
        tasks     = tasks,
        report    = function(message) event(message) end,
        add_bufnr = function(bufnr, label, priority)
            if not label then
                label = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
            end
            log.debug("run_task_coro: [%s] add_bufnr bufnr=%d label=%s priority=%s",
                run_id, bufnr, tostring(label), tostring(priority))
            table.insert(entry.bufnrs, { bufnr = bufnr, label = label, priority = priority or 0 })
            notify_change(run_id)
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
                    notify_change(run_id)
                end,
            })
        end,
    }

    local ok = coroutine.yield(function(waker)
        local settled = false
        local cancel = type_def.run(task, ctx, function(result)
            if settled then return end
            settled = true
            waker(result)
        end)
        assert(type(cancel) == "function",
            "task type '" .. tostring(task.type) .. "' run() must return a cancel function")
        log.debug("run_task_coro: [%s] cancel fn registered", run_id)
        entry.cancel = cancel
    end)
    log.debug("run_task_coro: [%s] type_def.run returned ok=%s", run_id, tostring(ok))

    if entry.stop_requested then
        log.info("run_task_coro: [%s] stop_requested after run", run_id)
        return finish("stopped")
    end
    return finish(ok and "ok" or "failed")
end

-- ─── Internal launch ─────────────────────────────────────────────────────────

--- Create a terminal failed RunEntry visible in the status panel.
---@param task_name string
---@param message   string
local function fail_immediately(task_name, message)
    local run_id     = gen_run_id(task_name)
    local now        = os.time()
    _running[run_id] = {
        task_name = task_name,
        state     = "failed",
        bufnrs    = {},
        done      = Signal.new(),
        progress  = {
            start_time = now,
            stop_time  = now,
            events     = { { time = now, message = message } },
        },
    }
    _running[run_id].done:emit()
    notify_change(run_id)
end

--- `run_task_coro` creates its entry synchronously before its first yield,
--- so the entry is live before launch returns.
---@param task_name string
---@param tasks     table<string,table>
---@param run_id?   string   pre-existing run_id to reuse (e.g. a waiting entry)
---@param ephemeral boolean?
local function launch(task_name, tasks, run_id, ephemeral)
    log.info("launch: task=%s run_id=%s ephemeral=%s", task_name, tostring(run_id), tostring(ephemeral))
    async.go(function()
        return run_task_coro(task_name, tasks, run_id, ephemeral)
    end, function(co_ok, result)
        log.debug("launch: on_done task=%s co_ok=%s result=%s",
            task_name, tostring(co_ok), tostring(result))
        if co_ok then return end
        log.error("launch: coroutine error task=%s: %s", task_name, tostring(result))
        local msg    = "coroutine error: " .. tostring(result)
        local orphan = false
        -- coroutine itself threw — mark any orphaned running entry as failed
        for rid, entry in pairs(_running) do
            if entry.task_name == task_name
                and (entry.state == "running" or entry.state == "waiting") then
                log.warn("launch: orphan entry rid=%s marked failed", rid)
                orphan                   = true
                entry.state              = "failed"
                entry.progress.stop_time = os.time()
                table.insert(entry.progress.events, { time = os.time(), message = msg })
                entry.done:emit()
                notify_change(rid)
            end
        end
        if not orphan then fail_immediately(task_name, msg) end
    end)
end

-- ─── Public ──────────────────────────────────────────────────────────────────

---@param task_name string
---@param toml_path string
function M.run(task_name, toml_path)
    log.info("M.run: task=%s path=%s", task_name, toml_path)
    local tasks, _, err = load_tasks(toml_path)
    if not tasks then
        log.error("M.run: load failed: %s", tostring(err))
        fail_immediately(task_name, err or "load error")
        return
    end

    local task = tasks[task_name]
    if not task then
        log.error("M.run: task not found: %s", task_name)
        fail_immediately(task_name, "task not found: " .. task_name)
        return
    end

    local missing = find_missing_dep(task_name, tasks, {})
    if missing then
        log.error("M.run: missing dependency: %s", missing)
        fail_immediately(task_name, "unknown dependency: " .. missing)
        return
    end

    local cycle = find_cycle(task_name, tasks, {}, {})
    if cycle then
        log.error("M.run: dependency cycle: %s", cycle)
        fail_immediately(task_name, "dependency cycle: " .. cycle)
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
    log.debug("M.run: task=%s is_running=%s active=%d", task_name, tostring(is_running), #active_signals)

    if not is_running then
        launch(task_name, tasks)
        return
    end

    local policy = task.if_running or "refuse"
    log.info("M.run: task=%s already running, policy=%s", task_name, policy)

    if policy == "refuse" then
        notify.notify_warning("task already running: " .. task_name)
    elseif policy == "parallel" then
        launch(task_name, tasks)
    elseif policy == "wait" then
        local run_id = gen_run_id(task_name)
        log.debug("M.run: wait policy run_id=%s waiting on %d signals", run_id, #active_signals)
        _running[run_id] = {
            task_name = task_name,
            state     = "waiting",
            bufnrs    = {},
            done      = Signal.new(),
            progress  = { start_time = os.time(), events = {} },
        }
        notify_change(run_id)

        local fns = vim.tbl_map(function(sig)
            return function() async.wait_signal(sig) end
        end, active_signals)

        async.go(function() async.wait_all(fns) end, function()
            log.debug("M.run: wait policy predecessor done, launching run_id=%s", run_id)
            launch(task_name, tasks, run_id)
        end)
    elseif policy == "restart" then
        log.info("M.run: restart policy, stopping task=%s", task_name)
        M.stop(task_name)

        local fns = vim.tbl_map(function(sig)
            return function() async.wait_signal(sig) end
        end, active_signals)

        async.go(function()
            if #fns > 0 then async.wait_all(fns) end
        end, function()
            log.debug("M.run: restart policy predecessor done, launching task=%s", task_name)
            launch(task_name, tasks)
        end)
    end
end

--- Run a task whose definition is supplied inline, not from a TOML file.
---@param task_name string
---@param task_def  table  task data (same shape as a decoded TOML task entry)
function M.run_ephemeral(task_name, task_def)
    log.info("M.run_ephemeral: task=%s", task_name)
    task_def.name = task_name
    launch(task_name, { [task_name] = task_def }, nil, true)
end

---@param toml_path string
---@return string[]?, string?
function M.list(toml_path)
    local _, ordered, err = load_tasks(toml_path)
    return ordered, err
end

--- Stop all active instances of a task.
---@param task_name string
function M.stop(task_name)
    log.info("M.stop: task=%s", task_name)
    local count = 0
    for _, entry in pairs(_running) do
        if entry.task_name == task_name and not entry.ephemeral
            and (entry.state == "running" or entry.state == "waiting") then
            entry.stop_requested = true
            if entry.cancel then
                log.debug("M.stop: invoking cancel for task=%s", task_name)
                entry.cancel()
            end
            count = count + 1
        end
    end
    log.debug("M.stop: stop_requested on %d entries for task=%s", count, task_name)
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
    log.info("M.dispose: disposed run_id=%s task=%s", run_id, entry.task_name)
    _on_dispose:emit(run_id)

    local type_def = entry.task_type and task_types.get(entry.task_type)
    if type_def and type_def.dispose then
        log.debug("M.dispose: calling type dispose for run_id=%s type=%s", run_id, entry.task_type)
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
