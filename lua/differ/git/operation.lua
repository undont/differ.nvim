-- the in-progress operation (merge, rebase, am, cherry-pick, revert): detected from the
-- git dir, labelled for the panel, and continued, skipped or aborted in the background.
-- git's editor is git/editor.lua's shim, which opens each commit message in this nvim

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
-- on every refresh while the named commits only change once per operation step
---@type table<string, string>
local names = {}

-- a commit as `git name-rev` names it (`topic`, `main~1`), else its short sha
---@param root string
---@param sha string
---@return string
local function commit_name(root, sha)
    local key = root .. "\0" .. sha
    if not names[key] then
        local out = exec.git({ "name-rev", "--name-only", "--no-undefined", sha }, root)
        names[key] = out and exec.chomp(out) or sha:sub(1, 7)
    end
    return names[key]
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

-- the commit each operation's theirs side comes from; during a rebase, the one being replayed
local THEIRS_HEADS = {
    merge = "MERGE_HEAD",
    rebase = "REBASE_HEAD",
    ["cherry-pick"] = "CHERRY_PICK_HEAD",
    revert = "REVERT_HEAD",
}

-- the name of the commit a conflict's theirs side comes from, as git's markers label it
-- (a revert's theirs is the reverted commit's parent). nil for am, which applies a patch
---@param root string
---@return string|nil
function M.theirs_name(root)
    local op = M.current(root)
    local file = op and THEIRS_HEADS[op]
    if not file then
        return nil
    end
    local sha = state_line(assert(git_dir(root)), file)
    if not sha then
        return nil
    end
    if op == "revert" then
        return "parent of " .. commit_name(root, sha)
    end
    return commit_name(root, sha)
end

-- todo lines whose message git commits without asking, conflicts aside: a pick, and a
-- merge that reuses its message with -C (-c or no flag asks)
local KEEPS_MESSAGE = { "^pick ", "^p ", "^merge %-C ", "^m %-C " }

---@param line string
---@return boolean
local function keeps_message(line)
    for _, pattern in ipairs(KEEPS_MESSAGE) do
        if line:match(pattern) then
            return true
        end
    end
    return false
end

-- what identifies the stop git is on: HEAD, plus a rebase's step. nil when the commit it
-- stopped on is one whose message the todo asks to edit (a reword, squash, fixup, or a
-- merge without -C)
---@param root string
---@return string|nil
function M.stop(root)
    local head = require("differ.git").head_sha(root) or ""
    local dir = git_dir(root)
    if not dir then
        return head
    end
    local done = read(dir .. "/rebase-merge/done")
    if not done then
        return head
    end
    if not keeps_message(vim.trim(done):match("([^\n]*)$")) then
        return nil
    end
    return head .. " " .. (state_line(dir, "rebase-merge/msgnum") or "")
end

-- the terminal buffers git runs in, and their float titles
---@type table<integer, string>
local floats = {}

---@param buf integer
---@param title string
---@return integer
local function open_float(buf, title)
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    return require("differ.util.win").open_centred(buf, width, height, { title = title })
end

-- reopen the float of terminal buffer `buf` when nothing shows it
---@param buf integer
function M.show(buf)
    local title = floats[buf]
    if not title or vim.fn.bufwinid(buf) ~= -1 then
        return
    end
    open_float(buf, title)
end

-- run `cmd` in a floating terminal: git edits a cherry-pick or revert message only on a
-- tty, and a signing prompt needs one to draw on. gpg reads the commit from a pipe, so
-- GPG_TTY has to name the float's pty or pinentry gets none. hiding or deleting the float
-- stops git, unless the commit message is showing in its place
---@param root string
---@param cmd string[]
---@param accept boolean
---@param on_exit fun(ok: boolean, output: string)
local function in_float(root, cmd, accept, on_exit)
    local buf = vim.api.nvim_create_buf(false, true)
    local stop = accept and M.stop(root)
    if stop then
        vim.b[buf].differ_accept = { root = root, stop = stop }
    end
    floats[buf] = " git " .. cmd[#exec.GIT + 1] .. " "
    local win = open_float(buf, floats[buf])
    local argv = vim.list_extend({ "sh", "-c", 'GPG_TTY=$(tty) exec "$@"', "sh" }, cmd)
    local job = vim.fn.jobstart(argv, {
        term = true,
        cwd = root,
        env = require("differ.git.editor").env(buf),
        on_exit = function(_, code)
            vim.schedule(function()
                floats[buf] = nil
                local lines = {}
                if vim.api.nvim_buf_is_valid(buf) then
                    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                end
                for _, shown in ipairs(vim.fn.win_findbuf(buf)) do
                    vim.api.nvim_win_close(shown, true)
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
        floats[buf] = nil
        vim.api.nvim_win_close(win, true)
        return on_exit(false, "couldn't start git in a terminal")
    end
    vim.api.nvim_create_autocmd({ "BufHidden", "BufUnload" }, {
        buffer = buf,
        callback = function(ev)
            if ev.event == "BufHidden" and vim.b[buf].differ_message then
                return
            end
            vim.fn.jobstop(job)
            return true
        end,
    })
    vim.cmd.startinsert()
end

-- run `cmd` detached and off the main loop, with no editor: an abort never commits
---@param root string
---@param cmd string[]
---@param on_exit fun(ok: boolean, output: string)
local function in_background(root, cmd, on_exit)
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
        env = { GIT_EDITOR = "false" },
    }, done)
    if not ok then
        done({ code = -1, stderr = tostring(err) })
    end
end

-- run `git <op> --<action>`; `on_exit` gets whether it exited 0 and what it printed. a
-- continue or skip runs in the float, where git asks for each commit message through
-- git/editor.lua as it would in a terminal, a later reword or squash in a rebase included.
-- `accept` commits the stopped commit's message as it stands, where `M.stop` allows it
---@param root string
---@param op "merge"|"rebase"|"am"|"cherry-pick"|"revert"
---@param action "continue"|"skip"|"abort"
---@param on_exit fun(ok: boolean, output: string)
---@param accept boolean|nil
function M.run(root, op, action, on_exit, accept)
    local cmd = vim.list_extend(vim.list_extend({}, exec.GIT), { op, "--" .. action })
    if action == "abort" then
        return in_background(root, cmd, on_exit)
    end
    in_float(root, cmd, accept == true, on_exit)
end

return M
