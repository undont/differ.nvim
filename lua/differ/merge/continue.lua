-- :Differ continue: a picker over the in-progress operation's continue, skip and abort

local exec = require("differ.git.exec")
local git_op = require("differ.git.operation")
local plural = require("differ.util.text").plural

local M = {}

local notify = exec.notify

-- the repo the command acts on: a merge session's, else the current file's or cwd's
---@return string|nil
local function target_root()
    local s = require("differ.merge").current()
    if s then
        return s.root
    end
    return require("differ.git").repo_root()
end

-- say how the run left the repo
---@param root string
---@param op string
---@param action string
---@param ok boolean
---@param output string
local function report(root, op, action, ok, output)
    local git = require("differ.git")
    local now = git.operation(root)
    if ok and not now then
        if action == "abort" then
            return notify(op .. " aborted")
        end
        return notify(op .. " finished")
    end
    local conflicted = git.conflicted(root)
    if now and #conflicted > 0 then
        return notify(("%s stopped on %s"):format(op, plural(#conflicted, "conflicted file")))
    end
    if ok then
        return notify(op .. " continued")
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
    git_op.run(root, op, action, function(ok, output)
        running = nil
        report(root, op, action, ok, output)
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

---@param prompt string
---@return boolean
local function confirm(prompt)
    return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

---@class differ.merge.ContinueEntry
---@field label string
---@field run fun()

---@param root string
---@param op "merge"|"rebase"|"am"|"cherry-pick"|"revert"
---@return differ.merge.ContinueEntry[]
local function entries(root, op)
    local list = {
        {
            label = "continue",
            run = function()
                if resolved(root) then
                    run(root, op, "continue", true)
                end
            end,
        },
    }
    -- git am never asks for a message
    if op ~= "am" then
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

-- the picker, continue first
function M.pick()
    if refuse_while_running() then
        return
    end
    local root = target_root()
    local op = root and require("differ.git").operation(root)
    if not root or not op then
        return notify("no merge, rebase, cherry-pick, revert or am in progress")
    end
    vim.ui.select(entries(root, op), {
        prompt = op .. " options",
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

return M
