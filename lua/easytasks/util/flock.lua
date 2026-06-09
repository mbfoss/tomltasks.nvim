local ffi = require("ffi")
local bit = require("bit")

if ffi.os == "Windows" then
    ffi.cdef [[
        typedef void* HANDLE;
        typedef uint32_t DWORD;
        typedef struct _OVERLAPPED {
            uintptr_t Internal; uintptr_t InternalHigh;
            union { struct { DWORD Offset; DWORD OffsetHigh; }; void* Pointer; };
            HANDLE hEvent;
        } OVERLAPPED;

        int LockFileEx(HANDLE hFile, DWORD dwFlags, DWORD dwRes, DWORD nLow, DWORD nHigh, OVERLAPPED* lpOver);
        int UnlockFileEx(HANDLE hFile, DWORD dwRes, DWORD nLow, DWORD nHigh, OVERLAPPED* lpOver);
        HANDLE _get_osfhandle(int fd);
        int _fileno(struct FILE* stream);
    ]]
else
    ffi.cdef [[
        int flock(int fd, int operation);
        int fileno(struct FILE* stream);
    ]]
end

local M = {}

local _LOCKS   = {} ---@type table<string, file*>
local _LOCK_EX  = 2
local _LOCK_NB  = 4
local _LOCK_UN  = 8
local _WIN_LOCK_EX = 0x00000002
local _WIN_LOCK_NB = 0x00000001

---@param path string
---@return string
local function _normalize(path)
    return vim.fn.fnamemodify(path, ":p")
end

---@param file file*
---@return integer
local function _get_fd(file)
    local c_file = ffi.cast("struct FILE*", file)
    return ffi.os == "Windows" and ffi.C._fileno(c_file) or ffi.C.fileno(c_file)
end

---@param path string
local function _create_if_missing(path)
    ---@diagnostic disable-next-line: undefined-field
    local fd = vim.uv.fs_open(path, "wx", 420)
    ---@diagnostic disable-next-line: undefined-field
    if fd then vim.uv.fs_close(fd) end
end

--- Acquire an exclusive non-blocking lock on `path`.
--- Returns true on success, or false + optional error message + PID of holder.
---@param path string
---@return boolean ok
---@return string? err
---@return string? holder_pid
function M.lock(path)
    local abs = _normalize(path)
    if _LOCKS[abs] then return false, "already locked by this instance" end

    _create_if_missing(abs)
    local file, err = io.open(abs, "r+")
    if not file then return false, err or "failed to open lock file" end

    local fd      = _get_fd(file)
    local success = false

    if ffi.os == "Windows" then
        local handle     = ffi.C._get_osfhandle(fd)
        local overlapped = ffi.new("OVERLAPPED", { 0 })
        success = ffi.C.LockFileEx(handle, bit.bor(_WIN_LOCK_EX, _WIN_LOCK_NB), 0, 1, 0, overlapped) ~= 0
    else
        success = ffi.C.flock(fd, bit.bor(_LOCK_EX, _LOCK_NB)) == 0
    end

    if success then
        _LOCKS[abs] = file
        file:write(tostring(vim.fn.getpid()) .. "\n")
        file:flush()
        return true
    else
        local pid = tostring(file:read("*n"))
        file:close()
        return false, "lock held by another process", pid
    end
end

--- Release the lock on `path` and remove the lock file.
---@param path string
---@return boolean
function M.unlock(path)
    local abs  = _normalize(path)
    local file = _LOCKS[abs]
    if not file then return false end

    if io.type(file) == "file" then
        local fd = _get_fd(file)
        if ffi.os == "Windows" then
            local handle     = ffi.C._get_osfhandle(fd)
            local overlapped = ffi.new("OVERLAPPED", { 0 })
            ffi.C.UnlockFileEx(handle, 0, 1, 0, overlapped)
        else
            ffi.C.flock(fd, _LOCK_UN)
        end
        file:close()
    end

    _LOCKS[abs] = nil
    pcall(os.remove, abs)
    return true
end

return M
