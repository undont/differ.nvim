-- :Differ continue: a picker over the in-progress operation's continue, skip and abort

local exec = require("differ.git.exec")
local git_op = require("differ.git.operation")
local plural = require("differ.util.text").plural

local M = {}

local notify = exec.notify

-- the repo the command acts on: a merge session's, else the current file's, else a
-- worktree panel's, else cwd's
---@return string|nil
local function target_root()
    local s = require("differ.merge").current()
    if s then
        return s.root
    end
    local git = require("differ.git")
    local file = git.current_file()
    if file then
        local root = git.root(file)
        if root then
            return root
        end
    end
    local panel = require("differ.panel").current()
    if panel and panel.git_root then
        return panel.git_root
    end
    return git.root(vim.fn.getcwd())
end

-- say how the run left the repo
---@param root string
---@param op string
---@param action string
---@param ok boolean
---@param output string
---@param cancelled boolean
local function report(root, op, action, ok, output, cancelled)
    local git = require("differ.git")
    local now = git.operation(root)
    if cancelled and now then
        -- git committed the reword before asking, so nothing was cancelled
        if git_op.reword_kept(root) then
            return
        end
        return notify(("commit cancelled, %s still in progress"):format(op))
    end
    if ok and not now then
        if action == "abort" then
            return notify(op .. " aborted")
        end
        return notify(op .. " finished")
    end
    if ok and now then
        local paused = git_op.paused_at(root)
        if paused then
            notify(("%s stopped at %s"):format(op, paused))
        end
        return
    end
    if now and #git.conflicted(root) > 0 then
        return
    end
    local empty = now and git_op.empty_pick(root)
    if empty then
        -- a cherry-pick's continue refuses an empty pick; a rebase's drops it
        local how = op == "rebase" and "continue to drop it" or "skip to drop it"
        return notify(("%s is empty now: %s"):format(empty, how), vim.log.levels.WARN)
    end
    notify(
        exec.with_stderr(("git %s --%s failed"):format(op, action), output),
        vim.log.levels.ERROR
    )
end

-- the operation of the run in flight; a second run alongside it only gets git's errors
---@type string|nil
local running

---@return boolean
local function refuse_while_running()
    if not running then
        return false
    end
    notify(("git %s is still running"):format(running), vim.log.levels.WARN)
    return true
end

---@param root string
---@param op string
---@param action "continue"|"skip"|"abort"
---@param accept boolean|nil
local function run(root, op, action, accept)
    if refuse_while_running() then
        return
    end
    local merge = require("differ.merge")
    running = op
    git_op.run(root, op, action, function(ok, output, cancelled)
        running = nil
        report(root, op, action, ok, output, cancelled)
        merge.after_operation(root)
    end, accept)
end

-- a continue with files still conflicted only gets git's refusal, so refuse here. the
-- merge tool's open result is saved and staged first
---@param root string
---@return boolean
local function resolved(root)
    if not require("differ.merge").settle() then
        return false
    end
    local left = #require("differ.git").conflicted(root)
    if left == 0 then
        return true
    end
    notify(
        ("%s left: resolve them before continuing"):format(plural(left, "conflicted file")),
        vim.log.levels.WARN
    )
    return false
end

-- the conflicted files left, counting the merge tool's open file by its buffer: the index
-- keeps it conflicted until settle() stages it
---@param root string
---@return integer
local function conflicts_left(root)
    local conflicted = require("differ.git").conflicted(root)
    local s = require("differ.merge").current()
    if not s or s.root ~= root then
        return #conflicted
    end
    local left = #vim.tbl_filter(function(p)
        return p ~= s.path
    end, conflicted)
    if #s.regions > 0 or ((s.deleted or s.binary) and not s.staged) then
        left = left + 1
    end
    return left
end

---@param prompt string
---@return boolean
local function confirm(prompt)
    local yes = vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
    -- the prompt left on screen holds the terminal float's first redraw for seconds
    vim.cmd.redraw()
    return yes
end

---@class differ.merge.ContinueEntry
---@field label string
---@field run fun()

---@param root string
---@param op "merge"|"rebase"|"am"|"cherry-pick"|"revert"
---@param left integer  -- conflicts left: above zero, only skip and abort
---@return differ.merge.ContinueEntry[]
local function entries(root, op, left)
    local list = {}
    if left == 0 then
        list[1] = {
            label = "continue",
            run = function()
                if resolved(root) then
                    run(root, op, "continue", true)
                end
            end,
        }
    end
    -- git am never asks for a message
    if left == 0 and op ~= "am" then
        list[#list + 1] = {
            label = "continue and edit the message",
            run = function()
                if resolved(root) then
                    run(root, op, "continue")
                end
            end,
        }
    end
    if git_op.SKIPPABLE[op] then
        list[#list + 1] = {
            label = "skip",
            run = function()
                if confirm("Skip the commit git stopped on? Its changes are dropped.") then
                    run(root, op, "skip")
                end
            end,
        }
    end
    list[#list + 1] = {
        label = "abort",
        run = function()
            if confirm(("Abort the %s? Resolutions so far are lost."):format(op)) then
                run(root, op, "abort")
            end
        end,
    }
    return list
end

-- whether the current repo has an operation the picker can act on
---@return boolean
function M.in_progress()
    local root = target_root()
    return root ~= nil and require("differ.git").operation(root) ~= nil
end

-- whether a run is in flight
---@return boolean
function M.running()
    return running ~= nil
end

-- how a notify, winbar or panel header names the continue step: the bound key, else the command
---@param km table  -- a resolved surface keymap table
---@return string
function M.hint(km)
    local key = require("differ.ui.help").fmt(km.commit)
    if not key then
        return ":Differ continue"
    end
    return key .. " to continue"
end

---@param root string
---@param op "merge"|"rebase"|"am"|"cherry-pick"|"revert"
---@param left integer
local function show(root, op, left)
    local prompt = op .. " options"
    if left > 0 then
        prompt = ("%s left"):format(plural(left, "conflicted file"))
    end
    vim.ui.select(entries(root, op, left), {
        prompt = prompt,
        format_item = function(entry)
            return entry.label
        end,
    }, function(choice)
        if not choice then
            return
        end
        -- the builtin inputlist calls back mid-prompt, which holds the float's first redraw
        -- for seconds
        vim.schedule(choice.run)
    end)
end

-- the commit key: mid-operation, the picker once every conflict is resolved, skip and
-- abort before then
---@param root string|nil  -- the surface's repo, else the command's
function M.pick_resolved(root)
    if refuse_while_running() then
        return
    end
    root = root or target_root()
    local op = root and require("differ.git").operation(root)
    if not root or not op then
        return notify("no merge, rebase, cherry-pick, revert or am in progress")
    end
    show(root, op, conflicts_left(root))
end

-- the picker, continue first
---@param root string|nil  -- the surface's repo, else the command's
function M.pick(root)
    if refuse_while_running() then
        return
    end
    root = root or target_root()
    local op = root and require("differ.git").operation(root)
    if not root or not op then
        return notify("no merge, rebase, cherry-pick, revert or am in progress")
    end
    show(root, op, 0)
end

return M
