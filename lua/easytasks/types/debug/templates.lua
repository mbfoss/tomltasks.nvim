local ordered = require("easytasks.util.table_util").ordered

---@type easytasks.TaskTemplate[]{
return {
    -- ── LLDB ──────────────────────────────────────────────────────────────────
    {
        label = "Launch (LLDB)",
        task  = ordered({
            name         = "debug",
            type         = "debug",
            adapter      = "lldb",
            request      = "launch",
            request_args = ordered({ program = "a.out", args = {} }, { "program", "args" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },
    {
        label = "Attach process (LLDB)",
        task  = ordered({
            name       = "debug-attach",
            type       = "debug",
            adapter    = "lldb",
            request    = "attach",
            process_id = "${select-pid}",
        }, { "name", "type", "adapter", "request", "process_id" }),
    },

    -- ── CodeLLDB ──────────────────────────────────────────────────────────────
    {
        label = "Launch (CodeLLDB)",
        task  = ordered({
            name         = "debug",
            type         = "debug",
            adapter      = "codelldb",
            request      = "launch",
            request_args = ordered({ program = "${workspaceFolder}/target/debug/app", args = {} }, { "program", "args" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },
    {
        label = "Attach process (CodeLLDB)",
        task  = ordered({
            name       = "debug-attach",
            type       = "debug",
            adapter    = "codelldb",
            request    = "attach",
            process_id = "${select-pid}",
        }, { "name", "type", "adapter", "request", "process_id" }),
    },

    -- ── GDB ───────────────────────────────────────────────────────────────────
    {
        label = "Launch (GDB)",
        task  = ordered({
            name         = "debug",
            type         = "debug",
            adapter      = "gdb",
            request      = "launch",
            request_args = ordered({ program = "a.out", args = {} }, { "program", "args" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },
    {
        label = "Attach process (GDB)",
        task  = ordered({
            name       = "debug-attach",
            type       = "debug",
            adapter    = "gdb",
            request    = "attach",
            process_id = "${select-pid}",
        }, { "name", "type", "adapter", "request", "request_args" }),
    },

    -- ── Python ────────────────────────────────────────────────────────────────
    {
        label = "Debug Python file (debugpy)",
        task  = ordered({
            name         = "debug-python",
            type         = "debug",
            adapter      = "debugpy",
            request      = "launch",
            request_args = ordered({
                justMyCode = false,
                console    = "integratedTerminal",
            }, { "justMyCode", "console" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },
    {
        label = "Debug Python module (debugpy-module)",
        task  = ordered({
            name    = "debug-python-module",
            type    = "debug",
            adapter = "debugpy-module",
            request = "launch",
        }, { "name", "type", "adapter", "request" }),
    },

    -- ── Go ────────────────────────────────────────────────────────────────────
    {
        label = "Debug Go (delve)",
        task  = ordered({
            name         = "debug-go",
            type         = "debug",
            adapter      = "delve",
            request      = "launch",
            request_args = ordered({ mode = "debug", args = {} }, { "mode", "args" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },
    {
        label = "Attach Go process (delve)",
        task  = ordered({
            name         = "debug-go-attach",
            type         = "debug",
            adapter      = "delve",
            request      = "attach",
            request_args = ordered({ processId = 0 }, { "processId" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },

    -- ── JavaScript / TypeScript ───────────────────────────────────────────────
    {
        label = "Debug Node.js (js-debug)",
        task  = ordered({
            name         = "debug-node",
            type         = "debug",
            adapter      = "js-debug",
            request      = "launch",
            request_args = ordered({
                program    = "${workspaceFolder}/index.js",
                args       = {},
                sourceMaps = true,
            }, { "program", "args", "sourceMaps" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },
    {
        label = "Attach Node.js process (js-debug)",
        task  = ordered({
            name         = "debug-node-attach",
            type         = "debug",
            adapter      = "js-debug",
            request      = "attach",
            request_args = ordered({ port = 9229 }, { "port" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },

    -- ── Bash ──────────────────────────────────────────────────────────────────
    {
        label = "Debug Bash script (bash-debug-adapter)",
        task  = ordered({
            name         = "debug-bash",
            type         = "debug",
            adapter      = "bash-debug-adapter",
            request      = "launch",
            request_args = ordered({ program = "${workspaceFolder}/script.sh", args = {} }, { "program", "args" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },

    -- ── PHP ───────────────────────────────────────────────────────────────────
    {
        label = "Debug PHP (php-debug-adapter)",
        task  = ordered({
            name         = "debug-php",
            type         = "debug",
            adapter      = "php-debug-adapter",
            request      = "launch",
            request_args = ordered({ port = 9003 }, { "port" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },

    -- ── .NET ──────────────────────────────────────────────────────────────────
    {
        label = "Debug .NET (netcoredbg)",
        task  = ordered({
            name         = "debug-dotnet",
            type         = "debug",
            adapter      = "netcoredbg",
            request      = "launch",
            request_args = ordered({ program = "${workspaceFolder}/bin/Debug/net8.0/app.dll" }, { "program" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },
    {
        label = "Attach .NET process (netcoredbg)",
        task  = ordered({
            name         = "debug-dotnet-attach",
            type         = "debug",
            adapter      = "netcoredbg",
            request      = "attach",
            request_args = ordered({ processId = 0 }, { "processId" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },

    -- ── Java ──────────────────────────────────────────────────────────────────
    {
        label = "Attach Java process (java-debug-server)",
        task  = ordered({
            name         = "debug-java",
            type         = "debug",
            adapter      = "java-debug-server",
            request      = "attach",
            request_args = ordered({ host = "127.0.0.1", port = 5005 }, { "host", "port" }),
        }, { "name", "type", "adapter", "request", "request_args" }),
    },

    -- ── Lua ───────────────────────────────────────────────────────────────────
    {
        label = "Debug Lua (local-lua-debugger)",
        task  = ordered({
            name    = "debug-lua",
            type    = "debug",
            adapter = "local-lua-debugger",
            request = "launch",
        }, { "name", "type", "adapter", "request" }),
    },

    -- ── Remote DAP server ─────────────────────────────────────────────────────
    {
        label = "Attach remote DAP server",
        task  = ordered({
            name    = "debug-remote",
            type    = "debug",
            adapter = "remote",
            request = "attach",
            host    = "127.0.0.1",
            port    = 0
        }, { "name", "type", "adapter", "request", "host", "port" }),
    },
}
