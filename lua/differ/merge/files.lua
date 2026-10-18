-- the merge tool's conflicted files: progress as they are staged, ]f/[f between them, and
-- closing the session once git moves on without it

local notify = require("differ.git.exec").notify

local M = {}

-- conflicted paths the merge tool can't open (added by one side, deleted by both, a symlink)
---@param relpaths string[]
function M.report_unopenable(relpaths)
    notify(
        ("%s can't be opened in the merge tool: resolve with git add/rm"):format(
            table.concat(relpaths, ", ")
        ),
        vim.log.levels.WARN
    )
end

-- the first conflicted path the merge tool can open, with its model
---@param root string
---@param conflicted string[]
---@return string|nil relpath, differ.MergeModel|nil model
function M.first_openable(root, conflicted)
    local build = require("differ.merge.model").build
    for _, relpath in ipairs(conflicted) do
        local model = build(root, relpath, nil)
        if model then
            return relpath, model
        end
    end
    return nil, nil
end

-- mark this file resolved in the same tick as the index write, so the git-dir watcher
-- doesn't read it as resolved outside the session, and name the conflicts left that only
-- git add/rm can resolve
---@param s differ.MergeSession
function M.mark_staged(s)
    s.staged = true
    local conflicted = require("differ.git").conflicted(s.root)
    s.left = #conflicted
    if #conflicted > 0 and not M.first_openable(s.root, conflicted) then
        M.report_unopenable(conflicted)
    end
end

-- the next/prev file in the session's list that is still conflicted and builds, wrapping
-- past the ends. staged files drop out of `conflicted`; unopenable ones fail the build
---@param s differ.MergeSession
---@param conflicted string[]
---@param direction "next"|"prev"
---@return string|nil relpath, differ.MergeModel|nil model, boolean wrapped
local function find_file(s, conflicted, direction)
    local build = require("differ.merge.model").build
    local n, from = #s.files, s.file_index
    local step = 1
    if direction == "prev" then
        step = -1
    end
    for k = 1, n - 1 do
        local i = (from - 1 + k * step) % n + 1
        local relpath = s.files[i]
        if vim.tbl_contains(conflicted, relpath) then
            local model = build(s.root, relpath, nil)
            if model then
                return relpath, model, (step == 1 and i < from) or (step == -1 and i > from)
            end
        end
    end
    return nil, nil, false
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
    local relpath, model, wrapped = find_file(s, conflicted, direction)
    if not relpath then
        local others = vim.tbl_filter(function(p)
            return p ~= s.path
        end, conflicted)
        if #conflicted == 0 and s.operation then
            return notify(
                "no conflicted files left: " .. require("differ.merge.continue").hint(s.keymaps)
            )
        end
        if #conflicted == 0 then
            return notify("no conflicted files left")
        end
        if #others == 0 then
            return notify("no other conflicted file")
        end
        return M.report_unopenable(others)
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
    if s.staged or vim.tbl_contains(conflicted, s.path) then
        return nil, nil
    end
    -- what git staged is the file on disk, which the buffer may not match
    local ok, lines = pcall(vim.fn.readfile, s.root .. "/" .. s.path)
    if not ok then
        lines = {}
    end
    local conflict = require("differ.git.conflict")
    if #conflict.parse(lines) > 0 or conflict.reformatted(lines) then
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
