-- the in-progress operation (merge, rebase, am, cherry-pick, revert): detected from the
-- git dir, labelled for the panel, and continued, skipped or aborted in the background.
-- git never gets a terminal here, so it never gets a real editor either: a plain run
-- commits the message git prepared, an edited one hands git the user's text

local exec = require("differ.git.exec")

local M = {}

-- operations with a --skip
---@type table<string, true>
M.SKIPPABLE = { rebase = true, am = true, ["cherry-pick"] = true, revert = true }

---@param path string
---@return string|nil
local function read(path)
    local fd = io.open(path, "rb")
    if not fd then
        return nil
    end
    local text = fd:read("*a")
    fd:close()
    return text
end

---@param root string
---@return string|nil
local function git_dir(root)
    return require("differ.git").git_dir(root)
end

-- git-dir markers of the operations with a `--continue`, checked in order: a rebase
-- replaying a merge or a pick also writes MERGE_HEAD/CHERRY_PICK_HEAD, and `git am` shares
-- rebase-apply/
local OPERATION_MARKERS = {
    { "rebase-merge", "rebase" },
    { "rebase-apply/applying", "am" },
    { "rebase-apply", "rebase" },
    { "MERGE_HEAD", "merge" },
    { "CHERRY_PICK_HEAD", "cherry-pick" },
    { "REVERT_HEAD", "revert" },
}

-- the verb on sequencer/todo's first line: a cherry-pick or revert range whose stopped
-- commit was committed by hand leaves only sequencer/
local SEQUENCER_VERBS = { pick = "cherry-pick", p = "cherry-pick", revert = "revert" }

-- the in-progress operation that has a `--continue`; nil for conflicts left by one that
-- doesn't (stash pop, checkout -m)
---@param root string
---@return "merge"|"rebase"|"am"|"cherry-pick"|"revert"|nil
function M.current(root)
    local dir = git_dir(root)
    if not dir then
        return nil
    end
    for _, marker in ipairs(OPERATION_MARKERS) do
        if vim.uv.fs_stat(dir .. "/" .. marker[1]) then
            return marker[2]
        end
    end
    local todo = read(dir .. "/sequencer/todo")
    local verb = todo and todo:match("^(%S+)")
    if not verb then
        return nil
    end
    return SEQUENCER_VERBS[verb]
end

-- name-rev walks history, which takes hundreds of ms in a large repo, and the panel asks
-- on every refresh while the named commit only changes once per operation step
---@type { key: string, name: string }|nil
local last_name

-- a commit as `git name-rev` names it (`topic`, `main~1`), else its short sha
---@param root string
---@param sha string
---@return string
local function commit_name(root, sha)
    local key = root .. "\0" .. sha
    if last_name and last_name.key == key then
        return last_name.name
    end
    local out = exec.git({ "name-rev", "--name-only", "--no-undefined", sha }, root)
    last_name = { key = key, name = out and exec.chomp(out) or sha:sub(1, 7) }
    return last_name.name
end

-- the first line of a git-dir state file, or nil when it isn't there
---@param dir string
---@param file string
---@return string|nil
local function state_line(dir, file)
    local data = read(dir .. "/" .. file)
    return data and data:match("^[^\n]*") or nil
end

---@param root string
---@param dir string
---@return string
local function rebase_detail(root, dir)
    local state = vim.uv.fs_stat(dir .. "/rebase-merge") and "rebase-merge" or "rebase-apply"
    local detail = ""
    local branch = state_line(dir, state .. "/head-name")
    if branch then
        detail = " " .. branch:gsub("^refs/heads/", "")
    end
    local onto = state_line(dir, state .. "/onto")
    if onto then
        detail = detail .. " onto " .. commit_name(root, onto)
    end
    return detail
end

local OPERATION_HEADS = {
    merge = { "MERGE_HEAD", "merging" },
    ["cherry-pick"] = { "CHERRY_PICK_HEAD", "cherry-picking" },
    revert = { "REVERT_HEAD", "reverting" },
}

---@param root string
---@param dir string
---@param op "merge"|"rebase"|"am"|"cherry-pick"|"revert"
---@return string verb, string detail
local function operation_parts(root, dir, op)
    if op == "rebase" then
        return "rebasing", rebase_detail(root, dir)
    end
    local target = require("differ.git").head_branch(root)
    local into = target and (" → " .. target) or ""
    if op == "am" then
        local at, last = state_line(dir, "rebase-apply/next"), state_line(dir, "rebase-apply/last")
        if not (at and last) then
            return "applying patches", into
        end
        return ("applying patch %s/%s"):format(at, last), into
    end
    local file, verb = unpack(OPERATION_HEADS[op])
    local sha = state_line(dir, file)
    if not sha then
        return verb, into
    end
    return verb, " " .. commit_name(root, sha) .. into
end

-- the in-progress operation in lazygit's form (`(merging) topic → main`, `(rebasing) topic
-- onto main`), or nil when there's none
---@param root string
---@return string|nil
function M.label(root)
    local op = M.current(root)
    if not op then
        return nil
    end
    local dir = assert(git_dir(root))
    local verb, detail = operation_parts(root, dir, op)
    return ("(%s)%s"):format(verb, detail)
end

-- the message the operation's next commit starts from, or nil when its --continue never
-- opens an editor (am, an apply-backend rebase)
---@param root string
---@param op string
---@return string|nil
function M.prepared_message(root, op)
    local dir = git_dir(root)
    if not dir or op == "am" then
        return nil
    end
    local path = dir .. "/MERGE_MSG"
    if op == "rebase" then
        path = dir .. "/rebase-merge/message"
    end
    return read(path)
end

-- the sequencer's saved `-S`: `gpg-sign = <key>` in sequencer/opts, the key empty for a
-- bare -S. nil when the run doesn't sign
---@param dir string
---@return string|nil
local function sequencer_sign(dir)
    local opts = read(dir .. "/sequencer/opts")
    local key = opts and opts:match("\n%s*gpg%-sign = ([^\n]*)")
    if not key then
        return nil
    end
    return "-S" .. key
end

-- whether git's next commit signs: commit.gpgsign, or a rebase or cherry-pick/revert range
-- started with -S
---@param root string
---@return boolean
local function signing(root)
    if vim.trim(exec.git({ "config", "--type=bool", "commit.gpgsign" }, root) or "") == "true" then
        return true
    end
    local dir = git_dir(root)
    if not dir then
        return false
    end
    return vim.uv.fs_stat(dir .. "/rebase-merge/gpg_sign_opt") ~= nil
        or vim.uv.fs_stat(dir .. "/rebase-apply/gpg_sign_opt") ~= nil
        or sequencer_sign(dir) ~= nil
end

-- run `cmd` in a floating terminal so a signing prompt has a tty to draw on. gpg reads
-- the commit from a pipe, so GPG_TTY has to name the float's pty or pinentry gets none.
-- hiding or deleting the float stops git
---@param root string
---@param cmd string[]
---@param editor string
---@param on_exit fun(ok: boolean, output: string)
local function spawn_float(root, cmd, editor, on_exit)
    local buf = vim.api.nvim_create_buf(false, true)
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    local win = require("differ.util.win").open_centred(buf, width, height, {
        title = " git " .. cmd[#exec.GIT + 1] .. " ",
    })
    local argv = vim.list_extend({ "sh", "-c", 'GPG_TTY=$(tty) exec "$@"', "sh" }, cmd)
    local job = vim.fn.jobstart(argv, {
        term = true,
        cwd = root,
        env = { GIT_EDITOR = editor },
        on_exit = function(_, code)
            vim.schedule(function()
                local lines = {}
                if vim.api.nvim_buf_is_valid(buf) then
                    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                end
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_close(win, true)
                end
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
                -- drop the terminal's "[Process exited n]" line
                local text = vim.trim(table.concat(lines, "\n"))
                local output = text:gsub("%s*%[Process exited %d+%]$", "")
                if output == "" and code ~= 0 then
                    output = "the terminal was closed"
                end
                on_exit(code == 0, output)
            end)
        end,
    })
    if job <= 0 then
        vim.api.nvim_win_close(win, true)
        return on_exit(false, "couldn't start git in a terminal")
    end
    vim.api.nvim_create_autocmd({ "BufHidden", "BufUnload" }, {
        buffer = buf,
        once = true,
        callback = function()
            vim.fn.jobstop(job)
        end,
    })
    vim.cmd.startinsert()
end

-- spawn git with `editor` as its editor, off the main loop; `on_exit` gets whether it
-- exited 0 and what it printed. detached: with no controlling terminal a prompt (a curses
-- pinentry) fails rather than drawing over nvim. `float` runs it in a terminal instead
---@param root string
---@param args string[]
---@param editor string
---@param float boolean
---@param on_exit fun(ok: boolean, output: string)
local function spawn(root, args, editor, float, on_exit)
    local cmd = vim.list_extend(vim.list_extend({}, exec.GIT), args)
    if float then
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

-- commit `msgfile` by hand, then let a cherry-pick or revert range go on. their sequencer
-- keeps its saved message past `--continue --edit`, and a merge's editor would overwrite
-- what prepare-commit-msg added
---@param root string
---@param op string
---@param msgfile string
---@param float boolean
---@param on_exit fun(ok: boolean, output: string)
local function commit_then_continue(root, op, msgfile, float, on_exit)
    local dir = git_dir(root)
    local args = { "commit", "-q", "--cleanup=strip", "-F", msgfile }
    local sign = dir and sequencer_sign(dir)
    if sign then
        table.insert(args, 2, sign)
    end
    spawn(root, args, "true", float, function(ok, output)
        os.remove(msgfile)
        if not ok or op == "merge" or not (dir and vim.uv.fs_stat(dir .. "/sequencer")) then
            return on_exit(ok, output)
        end
        spawn(root, { op, "--continue" }, "true", float, on_exit)
    end)
end

-- run `git <op> --<action>`, never opening an editor. a continue commits git's prepared
-- message, or `opts.message` in its place. an abort never signs, so it never needs the float
---@param root string
---@param op "merge"|"rebase"|"am"|"cherry-pick"|"revert"
---@param action "continue"|"skip"|"abort"
---@param opts { message?: string }|nil
---@param on_exit fun(ok: boolean, output: string)
function M.run(root, op, action, opts, on_exit)
    local float = action ~= "abort" and signing(root)
    local message = opts and opts.message
    if not (message and action == "continue") then
        return spawn(root, { op, "--" .. action }, "true", float, on_exit)
    end
    local msgfile = vim.fn.tempname()
    local fd = assert(io.open(msgfile, "wb"))
    fd:write(message)
    fd:close()
    if op ~= "rebase" then
        return commit_then_continue(root, op, msgfile, float, on_exit)
    end
    -- a rebase commit made by hand loses the picked commit's author, so git commits it,
    -- with the shell running the editor and the file to edit appended
    spawn(
        root,
        { op, "--continue" },
        "cp " .. vim.fn.shellescape(msgfile),
        float,
        function(ok, output)
            os.remove(msgfile)
            on_exit(ok, output)
        end
    )
end

return M
