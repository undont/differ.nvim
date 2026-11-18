-- the merge tool's conflicted files: progress as they are resolved, ]f/[f between them, and
-- closing the session once git moves on without it

local notify = require("differ.git.exec").notify

local M = {}

-- the model for a conflicted `relpath`, else nil after warning why it won't open
---@param root string
---@param relpath string
---@return differ.MergeModel|nil
function M.build_or_warn(root, relpath)
    local model, err = require("differ.merge.model").build(root, relpath, nil)
    if not model then
        notify(assert(err), vim.log.levels.WARN)
    end
    return model
end

-- mark this file resolved in the same tick as the index write, so the git-dir watcher
-- doesn't read it as resolved outside the session. with no operation the resolution stays
-- unstaged: the reset puts the index entry back to HEAD's, leaving the worktree file as the
-- resolution
---@param s differ.MergeSession
function M.mark_resolved(s)
    s.resolved = true
    local git = require("differ.git")
    if not s.operation then
        git.unstage(s.root, s.path)
    end
    s.left = #git.conflicted(s.root)
end

-- the next/prev file in the session's list that is still conflicted and builds, wrapping
-- past the ends and warning for each one that won't build. staged files drop out of
-- `conflicted`
---@param s differ.MergeSession
---@param conflicted string[]
---@param direction "next"|"prev"
---@return string|nil relpath, differ.MergeModel|nil model, boolean wrapped, boolean skipped
local function find_file(s, conflicted, direction)
    local n, from = #s.files, s.file_index
    local step = 1
    if direction == "prev" then
        step = -1
    end
    local skipped = false
    for k = 1, n - 1 do
        local i = (from - 1 + k * step) % n + 1
        local relpath = s.files[i]
        if vim.tbl_contains(conflicted, relpath) then
            local model = M.build_or_warn(s.root, relpath)
            if model then
                local wrapped = (step == 1 and i < from) or (step == -1 and i > from)
                return relpath, model, wrapped, skipped
            end
            skipped = true
        end
    end
    return nil, nil, false, skipped
end

-- ]f/[f: settle the result, then open the next/prev conflicted file in the session layout
---@param direction "next"|"prev"
function M.step(direction)
    local merge = require("differ.merge")
    local s = merge._live_session()
    if not s or not merge.settle() then
        return
    end
    local conflicted = require("differ.git").conflicted(s.root)
    local relpath, model, wrapped, skipped = find_file(s, conflicted, direction)
    if skipped and not relpath then
        return
    end
    if not relpath then
        if #conflicted == 0 and s.operation then
            return notify(
                "no conflicted files left: " .. require("differ.merge.continue").hint(s.keymaps)
            )
        end
        if #conflicted == 0 then
            return notify("no conflicted files left")
        end
        return notify("no other conflicted file")
    end
    if wrapped and direction == "next" then
        notify("wrapped to the first conflicted file")
    elseif wrapped then
        notify("wrapped to the last conflicted file")
    end
    merge._lay_out(s.root, relpath, assert(model), s.layout, s.files)
end

-- why the session no longer matches git, or nil: HEAD or the operation changed (a
-- --continue, --abort or skip), or this file was resolved by something other than the session
---@param s differ.MergeSession
---@param conflicted string[]
---@return string|nil msg, integer|nil level
local function stale_reason(s, conflicted)
    local git = require("differ.git")
    if git.head_sha(s.root) ~= s.head or git.operation(s.root) ~= s.operation then
        return "git moved on outside the merge tool", vim.log.levels.INFO
    end
    if s.resolved or vim.tbl_contains(conflicted, s.path) then
        return nil, nil
    end
    -- what git staged is the file on disk, which the buffer may not match
    local ok, lines = pcall(vim.fn.readfile, s.root .. "/" .. s.path)
    if not ok then
        lines = {}
    end
    local conflict = require("differ.git.conflict")
    local size = s.marker_size
    local orphans = conflict.orphans(lines, size)
    if
        #conflict.parse(lines, size) > 0
        or #conflict.markers(lines, orphans, {}, s.content_markers) > 0
        or conflict.reformatted(lines)
    then
        return s.path .. " was staged with conflict markers outside the merge tool",
            vim.log.levels.WARN
    end
    return s.path .. " was resolved outside the merge tool", vim.log.levels.INFO
end

-- the git dir changed: refresh the files left, and close once the session is stale
---@param this differ.MergeSession
function M.on_git_change(this)
    local merge = require("differ.merge")
    -- while :Differ continue runs git, its end decides, not the watcher
    if merge.current() ~= this or require("differ.merge.continue").running() then
        return
    end
    local conflicted = require("differ.git").conflicted(this.root)
    this.left = #conflicted
    local msg, level = stale_reason(this, conflicted)
    if not msg then
        return vim.cmd("redrawstatus!")
    end
    notify(msg, level)
    merge.close()
end

return M
