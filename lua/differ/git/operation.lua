-- continue, skip or abort the in-progress operation (`git.operation`) in the background.
-- git never gets a terminal here, so it never gets a real editor either: a plain run
-- commits the message git prepared, an edited one hands git the user's text

local exec = require("differ.git.exec")

local M = {}

-- operations with a --skip
---@type table<string, true>
M.SKIPPABLE = { rebase = true, am = true, ["cherry-pick"] = true, revert = true }

-- the message the operation's next commit starts from, or nil when its --continue never
-- opens an editor (am, an apply-backend rebase)
---@param root string
---@param op string
---@return string|nil
function M.prepared_message(root, op)
    local dir = require("differ.git").git_dir(root)
    if not dir or op == "am" then
        return nil
    end
    local path = dir .. "/MERGE_MSG"
    if op == "rebase" then
        path = dir .. "/rebase-merge/message"
    end
    local fd = io.open(path, "rb")
    if not fd then
        return nil
    end
    local text = fd:read("*a")
    fd:close()
    return text
end

-- spawn git with `editor` as its editor, off the main loop; `on_exit` gets whether it
-- exited 0 and what it printed. detached: with no controlling terminal a prompt (a curses
-- pinentry) fails rather than drawing over nvim
---@param root string
---@param args string[]
---@param editor string
---@param on_exit fun(ok: boolean, output: string)
local function spawn(root, args, editor, on_exit)
    local cmd = vim.list_extend(vim.list_extend({}, exec.GIT), args)
    local function done(res)
        local output = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
        vim.schedule(function()
            on_exit(res.code == 0, output)
        end)
    end
    local ok, err = pcall(vim.system, cmd, {
        cwd = root,
        text = true,
        detach = true,
        env = { GIT_EDITOR = editor },
    }, done)
    if not ok then
        done({ code = -1, stderr = tostring(err) })
    end
end

-- cherry-pick and revert keep the message their sequencer saved (`--no-edit` sticks past
-- `--continue --edit`), so commit by hand, then let a multi-commit run go on
---@param root string
---@param op string
---@param msgfile string
---@param on_exit fun(ok: boolean, output: string)
local function commit_then_continue(root, op, msgfile, on_exit)
    spawn(root, { "commit", "-q", "--cleanup=strip", "-F", msgfile }, "true", function(ok, output)
        os.remove(msgfile)
        local dir = require("differ.git").git_dir(root)
        if not ok or not (dir and vim.uv.fs_stat(dir .. "/sequencer")) then
            return on_exit(ok, output)
        end
        spawn(root, { op, "--continue" }, "true", on_exit)
    end)
end

-- run `git <op> --<action>`, never opening an editor. a continue commits git's prepared
-- message, or `opts.message` in its place
---@param root string
---@param op "merge"|"rebase"|"am"|"cherry-pick"|"revert"
---@param action "continue"|"skip"|"abort"
---@param opts { message?: string }|nil
---@param on_exit fun(ok: boolean, output: string)
function M.run(root, op, action, opts, on_exit)
    local message = opts and opts.message
    if not (message and action == "continue") then
        return spawn(root, { op, "--" .. action }, "true", on_exit)
    end
    local msgfile = vim.fn.tempname()
    local fd = assert(io.open(msgfile, "wb"))
    fd:write(message)
    fd:close()
    if op == "cherry-pick" or op == "revert" then
        return commit_then_continue(root, op, msgfile, on_exit)
    end
    -- git runs the editor through the shell with the file to edit appended
    spawn(root, { op, "--continue" }, "cp " .. vim.fn.shellescape(msgfile), function(ok, output)
        os.remove(msgfile)
        on_exit(ok, output)
    end)
end

return M
