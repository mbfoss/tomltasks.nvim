local timer = require('tomltasks.tk.timer')

---@class tomltasks.tk.Spinner
---@field frames string[]
---@field interval integer
---@diagnostic disable-next-line: undefined-doc-name
---@field cancel_timer fun()?
---@field frame integer
---@field running boolean
---@field on_update fun(frame:string, index:integer)?


local _default_frames = {
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
}


---@alias tomltasks.tk.SpinnerOpts {frames?:string[], interval?:integer, on_update?:fun(frame:string, index:integer)}

---@class tomltasks.tk.Spinner
---@field new fun(self:tomltasks.tk.Spinner,opts:tomltasks.tk.SpinnerOpts):tomltasks.tk.Spinner
local Spinner = {}
Spinner.__index = Spinner

function Spinner:new(...)
    local obj = setmetatable({}, self)
    if obj.init then obj:init(...) end
    return obj
end

---@param opts tomltasks.tk.SpinnerOpts?
function Spinner:init(opts)
    opts = opts or {}
    self.frames = opts.frames or _default_frames
    self.interval = opts.interval or 80
    self.cancel_timer = nil
    self.frame = 1
    self.running = false
    self.on_update = opts.on_update
end

function Spinner:start()
    if self.running then
        return
    end
    self.running = true
    self.cancel_timer = timer.every(self.interval, function()
        if not self.running then return end
        local frame = self.frames[self.frame]
        if self.on_update then self.on_update(frame, self.frame) end
        self.frame = (self.frame % #self.frames) + 1
    end)
end

function Spinner:stop()
    if not self.running then
        return
    end
    self.running = false
    if self.cancel_timer then self.cancel_timer() end
end

return Spinner
