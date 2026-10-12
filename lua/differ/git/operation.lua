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

---@param root string
---@return boolean
local function signing(root)
    return vim.trim(exec.git({ "config", "--type=bool", "commit.gpgsign" }, root) or "") == "true"
end

-- run `cmd` in a floating terminal so a signing prompt has a tty to draw on. gpg reads
-- the commit from a pipe, so GPG_TTY has to name the float's pty or pinentry gets none
---@param root string
---@param cmd string[]
---@param editor string
---@param on_exit fun(ok: boolean, output: string)
local function spawn_float(root, cmd, editor, on_exit)
    local buf = vim.api.nvim_create_buf(false, true)
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " git " .. cmd[#exec.GIT + 1] .. " ",
    })
    local argv = vim.list_extend({ "sh", "-c", 'GPG_TTY=$(tty) exec "$@"', "sh" }, cmd)
    local job = vim.fn.jobstart(argv, {
        term = true,
        cwd = root,
        env = { GIT_EDITOR = editor },
        on_exit = function(_, code)
            vim.schedule(function()
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_close(win, true)
                end
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
                -- drop the terminal's "[Process exited n]" line
                local text = vim.trim(table.concat(lines, "\n"))
                local output = text:gsub("%s*%[Process exited %d+%]$", "")
                on_exit(code == 0, output)
            end)
        end,
    })
    if job <= 0 then
        vim.api.nvim_win_close(win, true)
        return on_exit(false, "couldn't start git in a terminal")
    end
    vim.cmd.startinsert()
end

-- spawn git with `editor` as its editor, off the main loop; `on_exit` gets whether it
-- exited 0 and what it printed. detached: with no controlling terminal a prompt (a curses
-- pinentry) fails rather than drawing over nvim. with signing on it runs in a float
---@param root string
---@param args string[]
---@param editor string
---@param on_exit fun(ok: boolean, output: string)
local function spawn(root, args, editor, on_exit)
    local cmd = vim.list_extend(vim.list_extend({}, exec.GIT), args)
    if signing(root) then
        return spawn_float(root, cmd, editor, on_exit)
    end
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
