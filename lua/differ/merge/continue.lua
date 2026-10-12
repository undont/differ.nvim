-- :Differ continue: a picker over the in-progress operation's continue, skip and abort,
-- and the scratch buffer an edited commit message is written from

local exec = require("differ.git.exec")
local git_op = require("differ.git.operation")

local M = {}

local notify = exec.notify

---@param n integer
---@param noun string
---@return string
local function plural(n, noun)
    if n == 1 then
        return "1 " .. noun
    end
    return ("%d %ss"):format(n, noun)
end

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

---@param root string
---@param op string
---@param action "continue"|"skip"|"abort"
---@param opts { message?: string }|nil
local function run(root, op, action, opts)
    local merge = require("differ.merge")
    merge.hold()
    git_op.run(root, op, action, opts, function(ok, output)
        report(root, op, action, ok, output)
        merge.after_operation(root)
    end)
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

-- a scratch buffer holding the prepared message; :w continues with what it holds, closing
-- it unwritten cancels
---@param root string
---@param op string
---@param text string
local function edit_message(root, op, text)
    local name = ("differ://%s-message"):format(op)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
        local wins = vim.fn.win_findbuf(existing)
        if #wins > 0 then
            return vim.api.nvim_set_current_win(wins[1])
        end
        vim.api.nvim_buf_delete(existing, { force = true })
    end
    vim.cmd("botright 12new")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(vim.trim(text), "\n"))
    vim.bo[buf].modified = false
    vim.bo[buf].filetype = "gitcommit"
    vim.wo.winbar = ("%s message · :w continues, close to cancel"):format(op)
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            local message = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            vim.bo[buf].modified = false
            vim.schedule(function()
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end)
            if resolved(root) then
                run(root, op, "continue", { message = message .. "\n" })
            end
        end,
    })
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
                    run(root, op, "continue")
                end
            end,
        },
    }
    local message = git_op.prepared_message(root, op)
    if message then
        list[#list + 1] = {
            label = "continue and edit the message",
            run = function()
                if resolved(root) then
                    edit_message(root, op, message)
                end
            end,
        }
    end
    if git_op.SKIPPABLE[op] then
        list[#list + 1] = {
            label = "skip",
            run = function()
                run(root, op, "skip")
            end,
        }
    end
    list[#list + 1] = {
        label = "abort",
        run = function()
            local prompt = ("Abort the %s? Resolutions so far are lost."):format(op)
            if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
                run(root, op, "abort")
            end
        end,
    }
    list[#list + 1] = { label = "cancel", run = function() end }
    return list
end

-- whether the current repo has an operation the picker can act on
---@return boolean
function M.in_progress()
    local root = target_root()
    return root ~= nil and require("differ.git").operation(root) ~= nil
end

-- the picker, continue first
function M.pick()
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
        if choice then
            choice.run()
        end
    end)
end

return M
