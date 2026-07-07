-- a filesystem watcher for one worktree-status session: fires `on_change` when the
-- git index/HEAD (stage / commit / checkout) or the displayed file's directory
-- changes. it watches directories, not files, so it survives the write-temp-then
-- rename that editors and tools do (which would kill a file-handle watch). events
-- are debounced; `on_change` decides whether anything relevant actually moved (the
-- caller gates on a content-aware signature), so the watcher itself never filters

local uv = vim.uv or vim.loop

local DEBOUNCE_MS = 50

local Watcher = {}
Watcher.__index = Watcher

---@class differ.git.Watcher
---@field on_change fun()
---@field handles table<string, userdata> -- fs_event handles keyed by "git"/"file"
---@field file_dir string|nil
---@field timer userdata|nil
---@field watch_file fun(self: differ.git.Watcher, path: string|nil)
---@field stop fun(self: differ.git.Watcher)

-- start watching `git_dir`; the file watch is attached later via watch_file
---@param opts { git_dir: string, on_change: fun() }
---@return differ.git.Watcher
local function new(opts)
    local self = setmetatable({
        on_change = opts.on_change,
        handles = {},
        file_dir = nil,
        timer = nil,
    }, Watcher)
    self:_watch("git", opts.git_dir)
    return self
end

-- coalesce a burst of events (a save, index.lock churn, a rebase) into one fire
function Watcher:_schedule()
    if not self.timer then
        self.timer = uv.new_timer()
    end
    self.timer:stop()
    self.timer:start(DEBOUNCE_MS, 0, function()
        vim.schedule(self.on_change)
    end)
end

-- (re)watch `dir` under `key`, closing any prior handle for that key
---@param key string
---@param dir string|nil
function Watcher:_watch(key, dir)
    local prev = self.handles[key]
    if prev then
        pcall(function()
            prev:stop()
            prev:close()
        end)
        self.handles[key] = nil
    end
    if not dir then
        return
    end
    local h = uv.new_fs_event()
    if not h then
        return
    end
    local ok = pcall(function()
        h:start(dir, {}, function(err)
            if not err then
                self:_schedule()
            end
        end)
    end)
    if ok then
        self.handles[key] = h
    else
        pcall(function()
            h:close()
        end)
    end
end

-- re-target the file watch to the directory holding `path` (a no-op when the file
-- stays in the same directory, so navigating siblings doesn't re-arm anything)
---@param path string|nil
function Watcher:watch_file(path)
    if not path then
        return
    end
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir == self.file_dir then
        return
    end
    self.file_dir = dir
    self:_watch("file", dir)
end

-- close every handle and the debounce timer
function Watcher:stop()
    if self.timer then
        pcall(function()
            self.timer:stop()
            self.timer:close()
        end)
        self.timer = nil
    end
    for key, h in pairs(self.handles) do
        pcall(function()
            h:stop()
            h:close()
        end)
        self.handles[key] = nil
    end
end

return { new = new }
