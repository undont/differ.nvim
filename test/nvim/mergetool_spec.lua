-- runs under headless nvim against a throwaway repo with a real merge conflict:
-- exercises the slice-2 merge session end-to-end (layout, region highlight, conflict
-- nav). identity is pinned inline so commits work without a global gitconfig

local merge = require("differ.merge")

local function git(cwd, ...)
    local args =
        { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    return vim.system(args, { cwd = cwd, text = true }):wait()
end

local function git_ok(cwd, ...)
    local res = git(cwd, ...)
    assert(
        res.code == 0,
        "git failed: " .. table.concat({ ... }, " ") .. "\n" .. (res.stderr or "")
    )
    return res.stdout
end

local function write(path, content)
    local fd = assert(io.open(path, "wb"))
    fd:write(content)
    fd:close()
end

-- a repo on `main` where `main` and `feature` both changed line 2 of f.txt
local function diverged_repo()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/f.txt", "a\nb\nc\n")
    git_ok(root, "add", "f.txt")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", "a\nTHEIRS\nc\n")
    git_ok(root, "commit", "-q", "-am", "theirs")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/f.txt", "a\nOURS\nc\n")
    git_ok(root, "commit", "-q", "-am", "ours")
    return root
end

-- a repo where merging `feature` into `main` conflicts on f.txt (both changed line 2).
-- `style` picks the merge.conflictStyle: nil for git's default, "diff3" to get the
-- ||||||| base marker as well
---@param style string|nil
local function conflict_repo(style)
    local root = diverged_repo()
    if style then
        git(root, "-c", "merge.conflictStyle=" .. style, "merge", "feature")
    else
        git(root, "merge", "feature") -- conflicts: exit non-zero, expected
    end
    return root
end

-- a diverged repo stopped on f.txt's conflict by `op`, each its own way of replaying one
-- side onto the other; "stash" pops a stash over a conflicting commit, which has no --continue
---@param op "merge"|"rebase"|"rebase-apply"|"am"|"cherry-pick"|"revert"|"stash"
local function operation_repo(op)
    local root = diverged_repo()
    if op == "merge" then
        git(root, "merge", "feature")
    elseif op == "rebase" then
        git_ok(root, "checkout", "-q", "feature")
        git(root, "rebase", "main")
    elseif op == "rebase-apply" then
        git_ok(root, "checkout", "-q", "feature")
        git(root, "rebase", "--apply", "main")
    elseif op == "am" then
        local patch = root .. "/../" .. vim.fn.fnamemodify(root, ":t") .. ".patch"
        write(patch, git_ok(root, "format-patch", "-1", "--stdout", "feature"))
        git(root, "am", "-3", patch)
    elseif op == "cherry-pick" then
        git(root, "cherry-pick", "feature")
    elseif op == "revert" then
        write(root .. "/f.txt", "a\nLATER\nc\n")
        git_ok(root, "commit", "-q", "-am", "later")
        git(root, "revert", "--no-edit", "HEAD~1")
    elseif op == "stash" then
        write(root .. "/f.txt", "a\nSTASHED\nc\n")
        git_ok(root, "stash", "-q")
        git_ok(root, "checkout", "-q", "feature")
        git(root, "stash", "pop")
    end
    return root
end

-- a repo with a single conflict buried in a long file, so the unchanged spans either side
-- are large enough to fold (the small repo's block fills the file and folds nothing)
local function conflict_repo_big()
    local function body(mid)
        local out = {}
        for i = 1, 14 do
            out[#out + 1] = "line" .. i
        end
        out[#out + 1] = mid
        for i = 15, 30 do
            out[#out + 1] = "line" .. i
        end
        return table.concat(out, "\n") .. "\n"
    end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/f.txt", body("base15"))
    git_ok(root, "add", "f.txt")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", body("THEIRS15"))
    git_ok(root, "commit", "-q", "-am", "theirs")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/f.txt", body("OURS15"))
    git_ok(root, "commit", "-q", "-am", "ours")
    git(root, "merge", "feature")
    return root
end

-- a repo with three separate conflicts down one long file, so ]x has to walk and wrap and
-- the last conflict sits near EOF (where a scroll-bound input pane used to drag the result
-- cursor off-target and stall ]x)
local function conflict_repo_multi()
    local function body(a, b, c)
        local out = {}
        for i = 1, 30 do
            if i == 5 then
                out[#out + 1] = a
            elseif i == 15 then
                out[#out + 1] = b
            elseif i == 25 then
                out[#out + 1] = c
            else
                out[#out + 1] = "line" .. i
            end
        end
        return table.concat(out, "\n") .. "\n"
    end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/f.txt", body("base5", "base15", "base25"))
    git_ok(root, "add", "f.txt")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", body("THEIRS5", "THEIRS15", "THEIRS25"))
    git_ok(root, "commit", "-q", "-am", "theirs")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/f.txt", body("OURS5", "OURS15", "OURS25"))
    git_ok(root, "commit", "-q", "-am", "ours")
    git(root, "merge", "feature")
    return root
end

-- a repo where both sides change two spots two unchanged lines apart. ort coalesces them
-- into one conflict block while git merge-file keeps them separate, which is the grouping
-- disagreement base recovery has to map across (a gap of four or more stops coalescing)
local function conflict_repo_coalesced()
    local function body(a, b)
        return table.concat({ a, "pad1", "pad2", b }, "\n") .. "\n"
    end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/f.txt", body("A", "B"))
    git_ok(root, "add", "f.txt")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", body("A_THEIRS", "B_THEIRS"))
    git_ok(root, "commit", "-q", "-am", "theirs")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/f.txt", body("A_OURS", "B_OURS"))
    git_ok(root, "commit", "-q", "-am", "ours")
    git(root, "merge", "feature")
    return root
end

-- a repo where both branches independently add the same path, so the merge carries no `:1:`
-- stage: there is no ancestor for the base pane to show or for take-base to restore
local function conflict_repo_add_add()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/seed.txt", "seed\n")
    git_ok(root, "add", "seed.txt")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", "theirs1\ntheirs2\n")
    git_ok(root, "add", "f.txt")
    git_ok(root, "commit", "-q", "-m", "theirs")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/f.txt", "ours1\nours2\n")
    git_ok(root, "add", "f.txt")
    git_ok(root, "commit", "-q", "-m", "ours")
    git(root, "merge", "feature")
    return root
end

-- a repo where merging `feature` conflicts on TWO files (f.txt then g.txt), to exercise
-- ]f/[f stepping through the conflict set
local function conflict_repo_two()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/f.txt", "a\nb\nc\n")
    write(root .. "/g.txt", "a\nb\nc\n")
    git_ok(root, "add", "f.txt", "g.txt")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", "a\nTHEIRS\nc\n")
    write(root .. "/g.txt", "a\nTHEIRS\nc\n")
    git_ok(root, "commit", "-q", "-am", "theirs")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/f.txt", "a\nOURS\nc\n")
    write(root .. "/g.txt", "a\nOURS\nc\n")
    git_ok(root, "commit", "-q", "-am", "ours")
    git(root, "merge", "feature")
    return root
end

-- a repo where merging `feature` leaves a.txt modify/delete, sorted before a content
-- conflict in each of `files`. `deleter` is the side that deletes it, theirs by default
---@param files string[]
---@param deleter "ours"|"theirs"|nil
local function conflict_repo_modify_delete(files, deleter)
    local root = vim.fn.tempname()
    local function change_a(side)
        if side == (deleter or "theirs") then
            git_ok(root, "rm", "-q", "a.txt")
        else
            write(root .. "/a.txt", side:upper() .. "\n")
        end
    end
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/a.txt", "a\n")
    for _, f in ipairs(files) do
        write(root .. "/" .. f, "a\nb\nc\n")
    end
    git_ok(root, "add", ".")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    change_a("theirs")
    for _, f in ipairs(files) do
        write(root .. "/" .. f, "a\nTHEIRS\nc\n")
    end
    git_ok(root, "commit", "-q", "-am", "theirs")
    git_ok(root, "checkout", "-q", "main")
    change_a("ours")
    for _, f in ipairs(files) do
        write(root .. "/" .. f, "a\nOURS\nc\n")
    end
    git_ok(root, "commit", "-q", "-am", "ours")
    git(root, "merge", "feature")
    return root
end

-- a repo where merging `feature` conflicts on a.bin, a binary file git writes no markers
-- into, sorted before a content conflict in each of `files`
---@param files string[]
local function conflict_repo_binary(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/a.bin", "base\0")
    for _, f in ipairs(files) do
        write(root .. "/" .. f, "a\nb\nc\n")
    end
    git_ok(root, "add", ".")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/a.bin", "theirs\0")
    for _, f in ipairs(files) do
        write(root .. "/" .. f, "a\nTHEIRS\nc\n")
    end
    git_ok(root, "commit", "-q", "-am", "theirs")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/a.bin", "ours\0")
    for _, f in ipairs(files) do
        write(root .. "/" .. f, "a\nOURS\nc\n")
    end
    git_ok(root, "commit", "-q", "-am", "ours")
    git(root, "merge", "feature")
    return root
end

-- winbar text without its %#Group# / %* highlight items
---@param bar string
---@return string
local function plain(bar)
    return (bar:gsub("%%#[^#]*#", ""):gsub("%%%*", ""))
end

local merge_ns = vim.api.nvim_create_namespace("differ.merge")
local flash_ns = vim.api.nvim_create_namespace("differ.merge.flash")

-- open the merge tool on a file no other window shows, from an untracked one beside it
local function open_unshown(root, relpath)
    write(root .. "/untracked.txt", "x\n")
    vim.cmd.edit(root .. "/untracked.txt")
    merge.open({ path = root .. "/" .. relpath })
    return assert(merge.current())
end

-- whether the current window carries none of the merge tool's window dressing
local function assert_undressed()
    assert.are.equal("", vim.api.nvim_get_option_value("winbar", { scope = "local" }))
    for _, opt in ipairs({ "number", "signcolumn", "cursorline", "scrollbind", "foldmethod" }) do
        assert.are.equal(vim.go[opt], vim.wo[opt], opt)
    end
end

describe(":Differ mergetool", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    it("notifies rather than opening when invoked outside a git repository", function()
        require("differ.git") -- warm the require cache before chdir makes it unresolvable
        local outside = vim.fn.tempname()
        vim.fn.mkdir(outside, "p")
        local cwd = vim.fn.getcwd()
        vim.cmd("enew") -- an unnamed scratch buffer, so M.open falls back to cwd
        vim.fn.chdir(outside)
        _G.notifs = {}
        merge.open({})
        vim.fn.chdir(cwd)
        assert.is_nil(merge.current())
        assert.are.equal("differ: not inside a git repository", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.WARN, _G.notifs[1].level)
    end)

    it("opens a session over the conflicted current file", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})

        local s = merge.current()
        assert.is_not_nil(s)
        assert.are.equal("f.txt", s.path)
        -- three windows in the session tab: ours, theirs, result
        assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("shows the markers in the result and highlights the conflict block", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()

        local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        local has_marker = false
        for _, l in ipairs(lines) do
            if l:sub(1, 7) == "<<<<<<<" then
                has_marker = true
            end
        end
        assert.is_true(has_marker)

        local marks = vim.api.nvim_buf_get_extmarks(s.result_buf, merge_ns, 0, -1, {})
        assert.is_true(#marks > 0)
    end)

    it("lands on the first conflict", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        local first = s.regions[1].result_start
        assert.are.equal(first, vim.api.nvim_win_get_cursor(s.result_win)[1])
    end)

    it("shows the base column under diff4", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        assert.are.equal(4, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("closes cleanly", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        merge.close()
        assert.is_nil(merge.current())
    end)

    it("hands the result buffer back without its window options", function()
        local root = conflict_repo()
        open_unshown(root, "f.txt")
        merge.close()
        vim.cmd.edit(root .. "/f.txt")
        assert_undressed()
    end)

    it("leaves q to native macro recording on the editable result buffer", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(s.result_buf, "n")) do
            assert.are_not.equal("q", m.lhs) -- :Differ close ends the session instead
        end
        merge.close()
    end)

    it("widens a short timeoutlen in the result buffer and restores it on close", function()
        local root = conflict_repo()
        local saved = vim.o.timeoutlen
        vim.o.timeoutlen = 200 -- a short which-key-style window the chords can't land in
        vim.cmd.edit(root .. "/f.txt")
        merge.open({}) -- lands in the result buffer, firing the bump
        assert.is_true(vim.o.timeoutlen >= 1000)
        merge.close()
        assert.are.equal(200, vim.o.timeoutlen)
        vim.o.timeoutlen = saved
    end)

    it("never lowers an already-generous timeoutlen", function()
        local root = conflict_repo()
        local saved = vim.o.timeoutlen
        vim.o.timeoutlen = 1500
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        assert.are.equal(1500, vim.o.timeoutlen)
        merge.close()
        assert.are.equal(1500, vim.o.timeoutlen)
        vim.o.timeoutlen = saved
    end)

    it("opens a g? keymap cheatsheet listing the conflict verbs", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()

        local cb
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(s.result_buf, "n")) do
            if m.desc == "differ: keymap help" then
                cb = m.callback
            end
        end
        assert.is_not_nil(cb)

        cb() -- opens the floating cheatsheet
        local float
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(w).relative ~= "" then
                float = w
            end
        end
        assert.is_not_nil(float)
        local txt = table.concat(
            vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false),
            "\n"
        )
        assert.is_true(txt:find("take ours", 1, true) ~= nil)
        assert.is_true(txt:find("next / previous conflict", 1, true) ~= nil)
        vim.api.nvim_win_close(float, true)
    end)

    it("binds conflict nav and g? on the input panes, with a pane-scoped cheatsheet", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()

        local function callback(buf, desc)
            for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
                if m.desc == desc then
                    return m.callback
                end
            end
        end
        for _, buf in ipairs(s.bufs) do
            assert.is_not_nil(callback(buf, "differ: next conflict"))
            assert.is_not_nil(callback(buf, "differ: previous conflict"))
            assert.is_not_nil(callback(buf, "differ: keymap help"))
        end

        local inp = s.inputs[1]
        vim.api.nvim_set_current_win(inp.win)
        vim.api.nvim_win_set_cursor(s.result_win, { 1, 0 })
        callback(s.bufs[1], "differ: next conflict")()
        assert.are.equal(s.regions[1].result_start, vim.api.nvim_win_get_cursor(s.result_win)[1])
        assert.are.equal(inp.win, vim.api.nvim_get_current_win()) -- focus stays on the input

        callback(s.bufs[1], "differ: keymap help")()
        local float
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(w).relative ~= "" then
                float = w
            end
        end
        assert.is_not_nil(float)
        local txt = table.concat(
            vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false),
            "\n"
        )
        assert.is_true(txt:find("next / previous conflict", 1, true) ~= nil)
        assert.is_nil(txt:find("take ours", 1, true))
        assert.is_nil(txt:find("marker line", 1, true))
        vim.api.nvim_win_close(float, true)
    end)

    it("opts the result buffer out of format-on-save and restores it on close", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        assert.is_true(vim.b[s.result_buf].disable_autoformat)
        local buf = s.result_buf
        merge.close()
        assert.is_nil(vim.b[buf].disable_autoformat) -- restored to its prior (unset) value
    end)

    it("disables diagnostics on the result buffer and restores them on close", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local buf = merge.current().result_buf
        local seen = {}
        vim.api.nvim_create_autocmd("DiagnosticChanged", {
            buffer = buf,
            callback = function()
                seen[#seen + 1] = vim.diagnostic.is_enabled({ bufnr = buf })
            end,
        })
        local ns = vim.api.nvim_create_namespace("differ.test.diag")
        vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "x", severity = 1 } })
        assert.is_true(#seen > 0)
        assert.is_false(vim.tbl_contains(seen, true)) -- a later renderer sees them off
        assert.are.same({}, vim.diagnostic.get(buf))
        merge.close()
        assert.is_true(vim.diagnostic.is_enabled({ bufnr = buf }))
    end)
end)

-- fire a buffer-local keymap by its description, so the test doesn't depend on <leader>
local function fire(buf, desc)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.desc == desc and m.callback then
            m.callback()
            return true
        end
    end
    return false
end

local function has_marker(buf)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:sub(1, 7) == "<<<<<<<" then
            return true
        end
    end
    return false
end

local function take_ours_and_write(s)
    fire(s.result_buf, "differ: take ours")
    vim.api.nvim_set_current_win(s.result_win)
    vim.cmd("silent write")
end

-- run `fn`, then wait for the session's git-dir watcher to handle a change
local function after_git_change(s, fn)
    local files = require("differ.merge.files")
    local on_git_change, seen = files.on_git_change, false
    files.on_git_change = function(this)
        if this == s then
            seen = true
        end
        return on_git_change(this)
    end
    local ok, err = pcall(fn)
    local handled = false
    if ok then
        handled = vim.wait(3000, function()
            return seen
        end)
    end
    files.on_git_change = on_git_change
    assert(ok, err)
    assert(handled, "the watcher never handled a change")
end

describe(":Differ mergetool resolution", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    it("takes ours for the conflict under the cursor, stripping the markers", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        assert.is_true(fire(s.result_buf, "differ: take ours"))
        assert.is_false(has_marker(s.result_buf))
        assert.are.same(
            { "a", "OURS", "c" },
            vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        )
    end)

    it("takes both in ours-then-theirs order", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        fire(s.result_buf, "differ: take both")
        assert.are.same(
            { "a", "OURS", "THEIRS", "c" },
            vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        )
    end)

    it("writes and stages once the file is marker-free", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        take_ours_and_write(s)
        assert.are.same({}, require("differ.git").conflicted(root))
    end)

    it("stages and re-stages quietly, leaving progress to the winbar", function()
        local root = conflict_repo_two()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        _G.notifs = {}
        take_ours_and_write(s)
        vim.api.nvim_buf_set_lines(s.result_buf, 0, 0, false, { "extra" })
        vim.cmd("silent write")
        assert.are.same({}, _G.notifs)
        assert.are.same({ "g.txt" }, require("differ.git").conflicted(root))
    end)

    it("doesn't move on when the stage fails", function()
        local root = conflict_repo_two()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        local git_mod = require("differ.git")
        local stage = git_mod.stage
        git_mod.stage = function()
            return false
        end
        local ok, err = pcall(function()
            take_ours_and_write(s)
            -- a marker-free result left unstaged couldn't be reopened, so ]f holds too
            fire(s.result_buf, "differ: next conflicted file")
        end)
        git_mod.stage = stage
        assert(ok, err)
        assert.are.equal(s, merge.current())
        assert.are.same({ "f.txt", "g.txt" }, require("differ.git").conflicted(root))
    end)

    it("reports done once the last conflict is written, staying open", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        _G.notifs = {}
        take_ours_and_write(s)
        assert.are.equal(s, merge.current())
        assert.are.equal(
            "differ: all conflicts resolved: :Differ continue",
            _G.notifs[#_G.notifs].msg
        )
        assert.are.same({}, require("differ.git").conflicted(root))
    end)

    it("names the conflicts it can't open once only those remain, staying open", function()
        local root = conflict_repo_binary({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        _G.notifs = {}
        take_ours_and_write(s)
        assert.are.equal(s, merge.current())
        local last = _G.notifs[#_G.notifs]
        assert.are.equal(
            "differ: a.bin can't be opened in the merge tool: resolve with git add/rm",
            last.msg
        )
        for _, n in ipairs(_G.notifs) do
            assert.is_nil(n.msg:find(":Differ continue", 1, true))
        end
    end)

    it("closes, naming them, when an operation stops only on conflicts it can't open", function()
        local root = conflict_repo_binary({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        git_ok(root, "add", "f.txt")
        _G.notifs = {}
        merge.after_operation(root)
        assert.is_nil(merge.current())
        assert.are.equal(
            "differ: a.bin can't be opened in the merge tool: resolve with git add/rm",
            _G.notifs[#_G.notifs].msg
        )
    end)

    it("says why when asked to open a conflict it can't", function()
        local root = conflict_repo_binary({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        _G.notifs = {}
        merge.open({ path = root .. "/a.bin" })
        assert.is_nil(merge.current())
        assert.are.equal(
            "differ: a.bin can't be opened in the merge tool: resolve with git add/rm",
            _G.notifs[1].msg
        )
        assert.are.equal(vim.log.levels.WARN, _G.notifs[1].level)
    end)

    it("says why when asked to open a conflicted symlink, not its target", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        git_ok(root, "merge", "--abort")
        git_ok(root, "checkout", "-q", "feature")
        vim.uv.fs_symlink("f.txt", root .. "/link.txt")
        git_ok(root, "add", "link.txt")
        git_ok(root, "commit", "-q", "-m", "link theirs")
        git_ok(root, "checkout", "-q", "main")
        vim.uv.fs_symlink("a.txt", root .. "/link.txt")
        git_ok(root, "add", "link.txt")
        git_ok(root, "commit", "-q", "-m", "link ours")
        git(root, "merge", "feature")
        assert.is_true(vim.tbl_contains(require("differ.git").conflicted(root), "link.txt"))
        vim.cmd.edit(root .. "/f.txt")
        _G.notifs = {}
        merge.open({ path = root .. "/link.txt" })
        assert.is_nil(merge.current())
        assert.are.equal(
            "differ: link.txt can't be opened in the merge tool: resolve with git add/rm",
            _G.notifs[1].msg
        )
    end)

    it("does not stage while conflicts remain on write", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write") -- markers still present
        assert.are.same({ "f.txt" }, require("differ.git").conflicted(root))
    end)

    it("refuses to stage when a format-on-save has indented the markers", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        -- stand in for a format_on_save that ignored disable_autoformat: reflow the region so
        -- every marker is indented, which the column-0 parser then can't see as a conflict
        vim.bo[s.result_buf].modifiable = true
        local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        for i, l in ipairs(lines) do
            lines[i] = "    " .. l
        end
        vim.api.nvim_buf_set_lines(s.result_buf, 0, -1, false, lines)
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")
        -- the parser reads zero regions, but the file is still conflicted: not staged
        assert.are.same({ "f.txt" }, require("differ.git").conflicted(root))
    end)

    it("says why ]f stays put once a reformatted save was warned about", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        for i, l in ipairs(lines) do
            lines[i] = "    " .. l
        end
        vim.api.nvim_buf_set_lines(s.result_buf, 0, -1, false, lines)
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")
        _G.notifs = {}
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal(1, #_G.notifs)
        assert.matches(
            "f.txt isn't staged: a formatter changed its conflict markers",
            _G.notifs[1].msg
        )
    end)
end)

-- the located input slab line for a side (the row sync_inputs centres on)
---@param s table
---@param side string
local function input(s, side)
    for _, inp in ipairs(s.inputs) do
        if inp.side == side then
            return inp
        end
    end
end

describe(":Differ mergetool in-progress operation", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    local cases = {
        { "merge", "merge" },
        { "rebase", "rebase" },
        { "rebase-apply", "rebase" },
        { "am", "am" },
        { "cherry-pick", "cherry-pick" },
        { "revert", "revert" },
    }
    for _, case in ipairs(cases) do
        it(("reads %s as %s"):format(case[1], case[2]), function()
            local root = operation_repo(case[1])
            local git_mod = require("differ.git")
            assert.are.same({ "f.txt" }, git_mod.conflicted(root))
            assert.are.equal(case[2], git_mod.operation(root))
        end)
    end

    it("reads no operation for conflicts a stash pop left", function()
        local root = operation_repo("stash")
        local git_mod = require("differ.git")
        assert.are.same({ "f.txt" }, git_mod.conflicted(root))
        assert.is_nil(git_mod.operation(root))
    end)

    ---@param op string
    ---@return string message the last notify
    local function resolve_last(op)
        local root = operation_repo(op)
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        _G.notifs = {}
        take_ours_and_write(s)
        assert.are.equal(s, merge.current())
        return _G.notifs[#_G.notifs].msg
    end

    it("points at :Differ continue once the last file is written", function()
        assert.are.equal("differ: all conflicts resolved: :Differ continue", resolve_last("rebase"))
    end)

    it("reports plain done when no operation is in progress", function()
        assert.are.equal("differ: all conflicts resolved and staged", resolve_last("stash"))
    end)
end)

describe(":Differ mergetool file stepping", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    ---@param root string
    ---@param relpath string
    local function open_at(root, relpath)
        vim.cmd.edit(root .. "/" .. relpath)
        merge.open({})
        return assert(merge.current())
    end

    it("steps to the next conflicted file with ]f, keeping the layout", function()
        local root = conflict_repo_two()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        fire(merge.current().result_buf, "differ: next conflicted file")
        assert.are.equal("g.txt", merge.current().path)
        assert.are.equal("diff4", merge.current().layout)
    end)

    it("wraps past either end, saying so", function()
        local root = conflict_repo_two()
        local s = open_at(root, "g.txt")
        _G.notifs = {}
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal("f.txt", merge.current().path)
        assert.are.equal("differ: wrapped to the first conflicted file", _G.notifs[1].msg)
        _G.notifs = {}
        fire(merge.current().result_buf, "differ: previous conflicted file")
        assert.are.equal("g.txt", merge.current().path)
        assert.are.equal("differ: wrapped to the last conflicted file", _G.notifs[1].msg)
    end)

    it("steps from an input pane too", function()
        local root = conflict_repo_two()
        local s = open_at(root, "f.txt")
        local ours = vim.api.nvim_win_get_buf(input(s, "ours").win)
        fire(ours, "differ: next conflicted file")
        assert.are.equal("g.txt", merge.current().path)
    end)

    it("saves and stages an unwritten resolved result on the way out", function()
        local root = conflict_repo_two()
        local s = open_at(root, "f.txt")
        fire(s.result_buf, "differ: take ours")
        assert.is_true(vim.bo[s.result_buf].modified)
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal("g.txt", merge.current().path)
        assert.is_false(vim.bo[s.result_buf].modified)
        assert.are.same({ "g.txt" }, require("differ.git").conflicted(root))
    end)

    it("saves without staging a result that still has markers, and moves on", function()
        local root = conflict_repo_two()
        local s = open_at(root, "f.txt")
        vim.api.nvim_buf_set_lines(s.result_buf, 0, 0, false, { "extra" })
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal("g.txt", merge.current().path)
        assert.are.equal("extra", vim.fn.readfile(root .. "/f.txt")[1])
        assert.are.same({ "f.txt", "g.txt" }, require("differ.git").conflicted(root))
    end)

    it("skips staged files and ones it can't open", function()
        local root = conflict_repo_binary({ "f.txt", "g.txt", "h.txt" })
        local s = open_at(root, "f.txt")
        assert.are.same({ "a.bin", "f.txt", "g.txt", "h.txt" }, s.files)
        fire(s.result_buf, "differ: next conflicted file") -- f -> g
        local g = merge.current()
        fire(g.result_buf, "differ: take ours")
        fire(g.result_buf, "differ: next conflicted file") -- g staged -> h
        assert.are.equal("h.txt", merge.current().path)
        -- forward from h wraps past a.bin (unopenable) to f, back skips g (staged)
        fire(merge.current().result_buf, "differ: next conflicted file")
        assert.are.equal("f.txt", merge.current().path)
        fire(merge.current().result_buf, "differ: previous conflicted file")
        assert.are.equal("h.txt", merge.current().path)
    end)

    it("names what's left when no other file can be opened", function()
        local root = conflict_repo_binary({ "f.txt" })
        local s = open_at(root, "f.txt")
        _G.notifs = {}
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal(s, merge.current())
        assert.are.equal(
            "differ: a.bin can't be opened in the merge tool: resolve with git add/rm",
            _G.notifs[#_G.notifs].msg
        )
    end)

    it("says so when no conflicted file is left", function()
        local root = conflict_repo()
        local s = open_at(root, "f.txt")
        fire(s.result_buf, "differ: take ours")
        _G.notifs = {}
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal(s, merge.current())
        assert.are.equal(
            "differ: no conflicted files left: :Differ continue",
            _G.notifs[#_G.notifs].msg
        )
    end)

    it("shows file progress in the result winbar", function()
        local root = conflict_repo_two()
        local s = open_at(root, "f.txt")
        vim.g.statusline_winid = s.result_win
        assert.are.equal(
            "RESULT · file 1/2 · conflict 1/1 · 1 unresolved",
            plain(merge.winbar())
        )
        fire(s.result_buf, "differ: take ours")
        assert.are.equal("RESULT · file 1/2 · all resolved · not staged", plain(merge.winbar()))
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")
        assert.are.equal("RESULT · file 1/2 · staged · 1 file left", plain(merge.winbar()))
        fire(s.result_buf, "differ: next conflicted file")
        local g = merge.current()
        vim.g.statusline_winid = g.result_win
        assert.is_truthy(merge.winbar():find("RESULT · file 2/2", 1, true))
        take_ours_and_write(g)
        assert.are.equal(
            "RESULT · file 2/2 · staged · all conflicts resolved · :Differ continue",
            plain(merge.winbar())
        )
    end)

    it("colours the result's index state in the winbar", function()
        local root = conflict_repo_two()
        local s = open_at(root, "f.txt")
        vim.g.statusline_winid = s.result_win
        fire(s.result_buf, "differ: take ours")
        assert.is_truthy(merge.winbar():find("%#differMergeUnstaged#not staged%*", 1, true))
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")
        assert.is_truthy(merge.winbar():find("%#differMergeStaged#staged%*", 1, true))
    end)
end)

describe(":Differ mergetool changes outside the session", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    ---@param root string
    local function open_two(root)
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        return assert(merge.current())
    end

    ---@param msg string
    local function wait_closed_with(msg)
        vim.wait(3000, function()
            return merge.current() == nil
        end)
        assert.is_nil(merge.current())
        local found = false
        for _, n in ipairs(_G.notifs) do
            found = found or n.msg == msg
        end
        assert.is_true(found, msg)
    end

    it("closes once the file is resolved and staged outside it", function()
        local root = conflict_repo_two()
        open_two(root)
        _G.notifs = {}
        write(root .. "/f.txt", "a\nOURS\nc\n")
        git_ok(root, "add", "f.txt")
        wait_closed_with("differ: f.txt was resolved outside the merge tool")
    end)

    it("warns when an outside add stages the conflict markers", function()
        local root = conflict_repo_two()
        open_two(root)
        _G.notifs = {}
        git_ok(root, "add", ".")
        wait_closed_with("differ: f.txt was staged with conflict markers outside the merge tool")
    end)

    it("refreshes the files left when another file is staged outside it", function()
        local root = conflict_repo_two()
        local s = open_two(root)
        assert.are.equal(2, s.left)
        after_git_change(s, function()
            git_ok(root, "add", "g.txt")
        end)
        assert.are.equal(1, s.left)
        assert.are.equal(s, merge.current())
    end)

    it("closes once the operation moves on outside it", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        take_ours_and_write(s)
        _G.notifs = {}
        git_ok(root, "commit", "-q", "--no-edit")
        wait_closed_with("differ: git moved on outside the merge tool")
    end)

    it("stays open through its own stage", function()
        local root = conflict_repo_two()
        local s = open_two(root)
        after_git_change(s, function()
            take_ours_and_write(s)
        end)
        assert.are.equal(s, merge.current())
        assert.are.equal(1, s.left)
        assert.are.same({ "g.txt" }, require("differ.git").conflicted(root))
    end)
end)

describe(":Differ mergetool navigation", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    it("steps marker to marker with ]n and wraps, leaving ]x alone", function()
        local root = conflict_repo_multi()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        local function cur()
            return vim.api.nvim_win_get_cursor(s.result_win)[1]
        end
        -- default conflictStyle: no ||||||| line, so three markers per conflict
        local first = s.regions[1]
        assert.is_nil(first.mark_base)
        assert.are.equal(first.result_start, cur())
        fire(s.result_buf, "differ: next conflict marker")
        assert.are.equal(first.mark_sep, cur())
        fire(s.result_buf, "differ: next conflict marker")
        assert.are.equal(first.result_end, cur())
        fire(s.result_buf, "differ: next conflict marker")
        assert.are.equal(s.regions[2].result_start, cur()) -- straight into the next block

        fire(s.result_buf, "differ: previous conflict marker")
        assert.are.equal(first.result_end, cur())

        vim.api.nvim_win_set_cursor(s.result_win, { s.regions[3].result_end, 0 })
        fire(s.result_buf, "differ: next conflict marker")
        assert.are.equal(first.result_start, cur()) -- wrapped to the first marker
    end)

    it("includes the base marker under diff3", function()
        local root = conflict_repo("diff3")
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        local r = s.regions[1]
        assert.is_not_nil(r.mark_base) -- diff3 adds the ||||||| line
        fire(s.result_buf, "differ: next conflict marker")
        assert.are.equal(r.mark_base, vim.api.nvim_win_get_cursor(s.result_win)[1])
    end)

    it("walks every conflict with ]x and wraps at the end", function()
        local root = conflict_repo_multi()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        assert.are.equal(3, #s.regions)
        local starts = {}
        for _, r in ipairs(s.regions) do
            starts[#starts + 1] = r.result_start
        end
        local function cur()
            return vim.api.nvim_win_get_cursor(s.result_win)[1]
        end
        assert.are.equal(starts[1], cur()) -- landed on the first
        fire(s.result_buf, "differ: next conflict")
        assert.are.equal(starts[2], cur())
        fire(s.result_buf, "differ: next conflict")
        assert.are.equal(starts[3], cur()) -- the one that used to stick the cursor
        fire(s.result_buf, "differ: next conflict")
        assert.are.equal(starts[1], cur()) -- wrapped back to the first
    end)

    it("notifies rather than silently no-opping ]x once every conflict is resolved", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        fire(s.result_buf, "differ: take ours") -- the file's only conflict, now resolved
        assert.are.equal(0, #s.regions)
        _G.notifs = {}
        fire(s.result_buf, "differ: next conflict")
        assert.are.equal("differ: no conflicts remain", _G.notifs[1].msg)
    end)

    it("scroll-binds the merge windows for tandem scrolling", function()
        local root = conflict_repo_multi()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            assert.is_true(vim.wo[win].scrollbind)
        end
    end)

    it("restores scrollbind after centring the inputs (an input zz never drags result)", function()
        local root = conflict_repo_multi()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        -- ]x to the last conflict (the one that used to stick) and back, then confirm the
        -- bind is intact and the result cursor landed where nav put it
        fire(s.result_buf, "differ: next conflict")
        fire(s.result_buf, "differ: next conflict")
        assert.are.equal(s.regions[3].result_start, vim.api.nvim_win_get_cursor(s.result_win)[1])
        assert.is_true(vim.wo[s.result_win].scrollbind)
        for _, inp in ipairs(s.inputs) do
            assert.is_true(vim.wo[inp.win].scrollbind)
        end
    end)

    it("re-parses and survives a hand-edit that shifts the markers", function()
        local root = conflict_repo_multi()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        local before = #s.regions
        -- hand-delete the last conflict and everything after it, leaving the cached regions
        -- pointing past the new EOF
        vim.bo[s.result_buf].modifiable = true
        local last = s.regions[before]
        vim.api.nvim_buf_set_lines(s.result_buf, last.result_start - 1, -1, false, {})
        -- a cursor move before the re-parse must not crash on the now out-of-range ranges
        local ok = pcall(function()
            vim.api.nvim_win_set_cursor(s.result_win, { 1, 0 })
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.result_buf })
        end)
        assert.is_true(ok)
        -- the edit re-parses: one fewer conflict, every region within the buffer
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = s.result_buf })
        assert.are.equal(before - 1, #s.regions)
        local count = vim.api.nvim_buf_line_count(s.result_buf)
        for _, r in ipairs(s.regions) do
            assert.is_true(r.result_end <= count)
        end
    end)

    it("recentres the input panes as the result cursor moves between conflicts", function()
        local root = conflict_repo_multi()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        local ours = input(s, "ours").win
        -- the ours slab lines sit at the conflicting rows 5/15/25 of the stage file
        vim.api.nvim_win_set_cursor(s.result_win, { s.regions[1].result_start + 1, 0 })
        vim.api.nvim_win_call(s.result_win, function()
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.result_buf })
        end)
        assert.are.equal(5, vim.api.nvim_win_get_cursor(ours)[1])
        vim.api.nvim_win_set_cursor(s.result_win, { s.regions[3].result_start + 1, 0 })
        vim.api.nvim_win_call(s.result_win, function()
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.result_buf })
        end)
        assert.are.equal(25, vim.api.nvim_win_get_cursor(ours)[1])
    end)
end)

describe(":Differ mergetool UX", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    it("keeps the raw markers visible and tints the whole region per side", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()

        -- nothing is hidden or overlaid: the result is the file the user edits
        local marks =
            vim.api.nvim_buf_get_extmarks(s.result_buf, merge_ns, 0, -1, { details = true })
        for _, m in ipairs(marks) do
            local d = m[4]
            assert.is_nil(d.conceal)
            assert.is_nil(d.conceal_lines)
            assert.is_nil(d.virt_text)
        end

        -- the marker lines are still real text and carry their section's colour: <<<<<<< (2)
        -- reads as ours, ======= (4) and the closing >>>>>>> (6) as theirs
        local function hl_at(row)
            local m = vim.api.nvim_buf_get_extmarks(
                s.result_buf,
                merge_ns,
                { row - 1, 0 },
                { row - 1, -1 },
                { details = true }
            )
            for _, e in ipairs(m) do
                if e[4].hl_group then
                    return e[4].hl_group
                end
            end
        end
        local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        assert.are.equal("<<<<<<< HEAD", lines[2])
        assert.are.equal("differMergeOursActive", hl_at(2))
        assert.are.equal("differMergeTheirsActive", hl_at(4))
        assert.are.equal("differMergeTheirsActive", hl_at(6))
    end)

    it("colours the section bodies with the per-side groups", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        -- ours body is line 3 (OURS), theirs body line 5 (THEIRS)
        local function hl_at(row)
            local m = vim.api.nvim_buf_get_extmarks(
                s.result_buf,
                merge_ns,
                { row - 1, 0 },
                { row - 1, -1 },
                { details = true }
            )
            for _, e in ipairs(m) do
                if e[4].hl_group then
                    return e[4].hl_group
                end
            end
        end
        -- the active conflict (under the cursor on land) paints at full strength
        assert.are.equal("differMergeOursActive", hl_at(3))
        assert.are.equal("differMergeTheirsActive", hl_at(5))
    end)

    it("sets a winbar on the merge windows", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        assert.is_true(vim.wo[s.result_win].winbar ~= "")
    end)

    it("winbar shows the result counter and the input side labels", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()

        vim.g.statusline_winid = s.result_win
        assert.is_truthy(merge.winbar():match("conflict 1/1"))

        vim.g.statusline_winid = input(s, "ours").win
        assert.are.equal("OURS (HEAD)", merge.winbar())
        vim.g.statusline_winid = input(s, "theirs").win
        assert.are.equal("THEIRS (feature)", merge.winbar())
    end)

    it("syncs the input windows to the active conflict's slab on land", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        -- the ours stage file is a/OURS/c: the slab sits on line 2
        assert.are.equal(2, vim.api.nvim_win_get_cursor(input(s, "ours").win)[1])
        assert.are.equal(2, vim.api.nvim_win_get_cursor(input(s, "theirs").win)[1])
    end)

    it("tracks the active conflict index and emphasises it", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        assert.are.equal(1, s.active_index) -- landed on the only conflict
    end)

    it("lays down latent folds in the result, open by default", function()
        local root = conflict_repo_big()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        vim.api.nvim_win_call(s.result_win, function()
            assert.are.equal(-1, vim.fn.foldclosed(1)) -- open out of the box
            vim.cmd("normal! zM")
            assert.is_true(vim.fn.foldclosed(1) > 0) -- zM collapses the unchanged span
            vim.cmd("normal! zR")
            assert.are.equal(-1, vim.fn.foldclosed(1))
        end)
    end)

    it("flashes the produced lines on a take-this, then clears", function()
        local root = conflict_repo_big()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        assert.is_true(fire(s.result_buf, "differ: take ours"))
        local during = vim.api.nvim_buf_get_extmarks(s.result_buf, flash_ns, 0, -1, {})
        assert.is_true(#during > 0)
        vim.wait(400, function()
            return false
        end)
        local after = vim.api.nvim_buf_get_extmarks(s.result_buf, flash_ns, 0, -1, {})
        assert.are.equal(0, #after)
    end)
end)

describe(":Differ mergetool layout config", function()
    local differ = require("differ")
    local saved

    before_each(function()
        saved = differ.config
        differ.config = require("differ.config").resolve({ merge = { layout = "diff4" } })
    end)

    after_each(function()
        differ.config = saved
        if merge.current() then
            merge.close()
        end
    end)

    it("opens the configured layout when no argument names one", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        assert.are.equal(4, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("lets an explicit layout beat the configured one", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "default" })
        assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))
    end)
end)

describe(":Differ mergetool diff4 base pane", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    it("locates and paints the base pane under the default conflict style", function()
        local root = conflict_repo() -- default merge style: the markers carry no base slab
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        local s = merge.current()
        local base = input(s, "base")
        assert.is_not_nil(base)
        assert.is_true(#base.regions > 0) -- recovered, so the slab is located
        local marks =
            vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(base.win), merge_ns, 0, -1, {})
        assert.is_true(#marks > 0) -- painted, unlike the pre-recovery inert pane
    end)

    it("takes base for the conflict, resolving to the common ancestor", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        local s = merge.current()
        assert.is_true(fire(s.result_buf, "differ: take base"))
        assert.is_false(has_marker(s.result_buf))
        assert.are.same({ "a", "b", "c" }, vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false))
    end)

    it("recovers base across a block ort coalesced but merge-file kept apart", function()
        local root = conflict_repo_coalesced()
        vim.cmd.edit(root .. "/f.txt")
        -- precondition: if a future git stops coalescing here, the mapping this exercises
        -- isn't being exercised at all, so fail loudly rather than passing on the easy path
        local conflict = require("differ.git.conflict")
        local to_lines = require("differ.util.text").to_lines
        local wt = conflict.parse(
            to_lines(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") .. "\n")
        )
        assert.are.equal(1, #wt, "fixture no longer coalesces under ort")
        merge.open({ layout = "diff4" })
        local s = merge.current()
        local base = input(s, "base")
        assert.is_not_nil(base)
        assert.is_true(#base.regions > 0) -- located, so the run mapped across the grouping
    end)

    it("takes base across a coalesced block, interstitials and all", function()
        local root = conflict_repo_coalesced()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        local s = merge.current()
        assert.is_true(fire(s.result_buf, "differ: take base"))
        assert.is_false(has_marker(s.result_buf))
        -- the span, not the two changed lines: the unchanged pads between them come back too
        assert.are.same(
            { "A", "pad1", "pad2", "B" },
            vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        )
    end)

    it("says the base pane has no common ancestor on an add/add conflict", function()
        local root = conflict_repo_add_add()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        local s = merge.current()
        vim.g.statusline_winid = input(s, "base").win
        assert.are.equal("BASE · no common ancestor", merge.winbar())
    end)

    it("refuses take base on an add/add conflict rather than dropping the block", function()
        local root = conflict_repo_add_add()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        local s = merge.current()
        _G.notifs = {}
        assert.is_true(fire(s.result_buf, "differ: take base"))
        assert.is_true(has_marker(s.result_buf)) -- the block survives, nothing spliced
        assert.are.equal("differ: no base version in this conflict", _G.notifs[1].msg)
    end)

    it("says so in the base winbar when a conflict has no recovered slab", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        local s = merge.current()
        vim.g.statusline_winid = input(s, "base").win
        assert.are.equal("BASE", merge.winbar())
        s.base_slabs = {} -- as if the mapping had been too ambiguous to trust here
        assert.are.equal("BASE · none for this conflict", merge.winbar())
    end)

    it("takes the right base on a later conflict after the order map shifts", function()
        local root = conflict_repo_multi() -- three conflicts, base slabs base5/base15/base25
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        local s = merge.current()
        -- resolve the first (the cursor moves onto the second), then take base there: the live
        -- index -> original mapping has shifted, so this proves the lookup follows `order`
        fire(s.result_buf, "differ: take base")
        fire(s.result_buf, "differ: take base")
        local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        assert.is_true(vim.tbl_contains(lines, "base5")) -- first conflict -> its own base
        assert.is_true(vim.tbl_contains(lines, "base15")) -- second -> its base, not base5/base25
        assert.is_true(has_marker(s.result_buf)) -- the third conflict is still open
    end)
end)

-- take-base recovers the ancestor from a slab table keyed by the conflict's *original*
-- index, so the live->original map has to survive anything that changes the region count.
-- when it doesn't, take-base splices a different conflict's ancestor into the file, and
-- :w stages it: wrong bytes in a tracked file with no warning
describe(":Differ mergetool take-base anchoring", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    -- three conflicts in one file, ancestors base5 / base15 / base25, far enough apart that
    -- a mis-mapped slab is unmistakable. default conflictStyle: the markers carry no base,
    -- so take-base goes through the recovered slabs
    local function three_conflict_repo()
        local function body(a, b, c)
            local out = {}
            for i = 1, 4 do
                out[#out + 1] = "line" .. i
            end
            out[#out + 1] = a
            for i = 6, 14 do
                out[#out + 1] = "line" .. i
            end
            out[#out + 1] = b
            for i = 16, 24 do
                out[#out + 1] = "line" .. i
            end
            out[#out + 1] = c
            out[#out + 1] = "tail"
            return table.concat(out, "\n") .. "\n"
        end
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git_ok(root, "init", "-q")
        write(root .. "/f.txt", body("base5", "base15", "base25"))
        git_ok(root, "add", "f.txt")
        git_ok(root, "commit", "-q", "-m", "base")
        git_ok(root, "checkout", "-q", "-b", "feature")
        write(root .. "/f.txt", body("THEIRS5", "THEIRS15", "THEIRS25"))
        git_ok(root, "commit", "-q", "-am", "theirs")
        git_ok(root, "checkout", "-q", "main")
        write(root .. "/f.txt", body("OURS5", "OURS15", "OURS25"))
        git_ok(root, "commit", "-q", "-am", "ours")
        git(root, "merge", "feature")
        return root
    end

    -- the line the cursor must sit on for `region_at` to pick conflict `n` (1-based)
    local function nth_marker_row(buf, n)
        local seen = 0
        for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            if l:sub(1, 7) == "<<<<<<<" then
                seen = seen + 1
                if seen == n then
                    return i
                end
            end
        end
    end

    local function body_of(buf)
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end

    -- hand-resolving an *earlier* conflict changes the region count, which is what
    -- collapses the map; take-base on what is now the first region must still recover
    -- that region's own ancestor
    it("recovers the right ancestor after an earlier conflict is hand-resolved", function()
        local root = three_conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = assert(merge.current())

        -- hand-resolve conflict 1: replace its whole block with OURS5
        local first = nth_marker_row(s.result_buf, 1)
        local last = first
        local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        while lines[last]:sub(1, 7) ~= ">>>>>>>" do
            last = last + 1
        end
        vim.bo[s.result_buf].modifiable = true
        vim.api.nvim_buf_set_lines(s.result_buf, first - 1, last, false, { "OURS5" })

        vim.api.nvim_win_set_cursor(s.result_win, { nth_marker_row(s.result_buf, 1), 0 })
        assert.is_true(fire(s.result_buf, "differ: take base"))

        local out = body_of(s.result_buf)
        assert.is_truthy(out:find("base15", 1, true)) -- its own ancestor
        assert.is_nil(out:find("base5\n", 1, true)) -- not conflict 1's

        -- and through to the index: :w auto-stages once no markers remain, so the wrong
        -- bytes were committable without another gesture
        vim.api.nvim_win_set_cursor(s.result_win, { nth_marker_row(s.result_buf, 1), 0 })
        take_ours_and_write(s)
        local staged = git_ok(root, "show", ":f.txt")
        assert.is_truthy(staged:find("base15", 1, true))
        assert.is_nil(staged:find("base5\n", 1, true))
    end)

    -- no hand-editing at all: two keymap resolves then one undo restores a region, so the
    -- count no longer matches what the splices left behind
    it("recovers the right ancestor after a resolve is undone", function()
        local root = three_conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = assert(merge.current())

        vim.api.nvim_set_current_win(s.result_win)
        vim.api.nvim_win_set_cursor(s.result_win, { nth_marker_row(s.result_buf, 1), 0 })
        fire(s.result_buf, "differ: take ours")
        -- force a new undo block, the way returning to the keyboard between two real
        -- keystrokes does; without it both splices coalesce and one undo reverts both
        vim.api.nvim_buf_call(s.result_buf, function()
            vim.cmd("let &l:undolevels = &l:undolevels")
        end)
        vim.api.nvim_win_set_cursor(s.result_win, { nth_marker_row(s.result_buf, 1), 0 })
        fire(s.result_buf, "differ: take ours")
        vim.cmd("silent undo")

        vim.api.nvim_win_set_cursor(s.result_win, { nth_marker_row(s.result_buf, 1), 0 })
        assert.is_true(fire(s.result_buf, "differ: take base"))

        -- the restored conflict is the middle one, so its ancestor is base15; any other
        -- conflict's ancestor appearing means the map handed back the wrong slab
        local out = body_of(s.result_buf)
        assert.is_truthy(out:find("base15", 1, true))
        assert.is_nil(out:find("base25", 1, true))
        assert.is_nil(out:find("base5\n", 1, true))
    end)
end)

-- the stages are raw blob bytes, so on a CRLF repo each line ends `\r`. nvim strips that
-- into fileformat=dos when it loads the worktree file, so a base slab carrying its own CR
-- makes :w write two — wrong bytes in a tracked file, silently staged
describe(":Differ mergetool take-base on CRLF", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    local function crlf_conflict_repo()
        local function body(mid)
            local out = {}
            for i = 1, 5 do
                out[#out + 1] = "line" .. i
            end
            out[#out + 1] = mid
            out[#out + 1] = "line7"
            return table.concat(out, "\r\n") .. "\r\n"
        end
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git_ok(root, "init", "-q")
        write(root .. "/f.txt", body("base6"))
        git_ok(root, "add", "f.txt")
        git_ok(root, "commit", "-q", "-m", "base")
        git_ok(root, "checkout", "-q", "-b", "feature")
        write(root .. "/f.txt", body("THEIRS6"))
        git_ok(root, "commit", "-q", "-am", "theirs")
        git_ok(root, "checkout", "-q", "main")
        write(root .. "/f.txt", body("OURS6"))
        git_ok(root, "commit", "-q", "-am", "ours")
        git(root, "merge", "feature")
        return root
    end

    local function bytes_of(path)
        local fd = assert(io.open(path, "rb"))
        local data = fd:read("*a")
        fd:close()
        return data
    end

    it("writes one CR per line, not two", function()
        local root = crlf_conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = assert(merge.current())
        assert.are.equal("dos", vim.bo[s.result_buf].fileformat)

        assert.is_true(fire(s.result_buf, "differ: take base"))
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")

        local data = bytes_of(root .. "/f.txt")
        assert.is_nil(data:find("\r\r", 1, true)) -- the doubled CR
        assert.is_truthy(data:find("base6\r\n", 1, true)) -- the ancestor, cleanly terminated
    end)

    it("renders the input panes without a trailing ^M", function()
        local root = crlf_conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff4" })
        local s = assert(merge.current())
        for _, inp in ipairs(s.inputs) do
            local buf = vim.api.nvim_win_get_buf(inp.win)
            for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
                assert.is_nil(line:find("\r", 1, true), inp.side .. " pane carries a CR")
            end
        end
    end)
end)

-- an open/close cycle has to leave nothing behind. the result column is the user's real
-- worktree file, so its extmarks, keymaps and hooks are differ's to take off by hand;
-- and the session has to end when its window does, rather than outliving it
describe(":Differ mergetool teardown", function()
    local NAMESPACES = { "differ.merge", "differ.merge.flash", "differ.merge.anchor" }
    local saved_timeoutlen

    -- nvim_get_autocmds errors on an unknown group and returns {} for an empty one,
    -- so a pcall is the existence check
    local function group_exists(name)
        return (pcall(vim.api.nvim_get_autocmds, { group = name }))
    end

    -- the scratch buffers differ owns, by their differ:// naming
    local function differ_bufs()
        local out = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            local name = vim.api.nvim_buf_get_name(b)
            if vim.api.nvim_buf_is_valid(b) and name:find("differ://", 1, true) then
                out[#out + 1] = name:gsub(".*differ://", "differ://")
            end
        end
        table.sort(out)
        return out
    end

    -- differ.highlights is deliberately process-lifetime (one ColorScheme hook, registered
    -- on first use), so it isn't part of what a session has to give back
    local function differ_autocmds()
        local n = 0
        for _, ac in ipairs(vim.api.nvim_get_autocmds({})) do
            local g = ac.group_name
            if g and g:find("^differ%.") and g ~= "differ.highlights" then
                n = n + 1
            end
        end
        return n
    end

    local function extmark_count(buf)
        local n = 0
        for _, name in ipairs(NAMESPACES) do
            local ns = vim.api.nvim_create_namespace(name)
            n = n + #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
        end
        return n
    end

    local function differ_maps(buf)
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            if (m.desc or ""):find("differ", 1, true) then
                out[#out + 1] = m.lhs
            end
        end
        return out
    end

    before_each(function()
        merge.close() -- a session an earlier case left open
        saved_timeoutlen = vim.o.timeoutlen
    end)

    after_each(function()
        merge.close()
        vim.o.timeoutlen = saved_timeoutlen
    end)

    it("hands the real file back with no extmarks, keymaps or hooks", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        local bufs, autocmds = differ_bufs(), differ_autocmds()

        merge.open({})
        local s = assert(merge.current())
        local buf = s.result_buf
        assert.is_true(#differ_bufs() > #bufs) -- the ours/theirs scratch panes
        assert.is_true(extmark_count(buf) > 0) -- the conflict paint
        assert.is_true(#differ_maps(buf) > 0) -- the conflict chords
        assert.is_true(group_exists("differ.merge." .. buf))

        merge.close()
        assert.are.same(bufs, differ_bufs())
        assert.are.equal(autocmds, differ_autocmds())
        assert.are.equal(0, extmark_count(buf))
        assert.are.same({}, differ_maps(buf))
        assert.is_false(group_exists("differ.merge." .. buf))
        assert.is_false(group_exists("differ.merge.diag." .. buf))
    end)

    it("gives the user's timeoutlen back, and never bumps it again", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        vim.o.timeoutlen = 200 -- a which-key-style short timeout
        merge.open({})
        local buf = assert(merge.current()).result_buf
        vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf }) -- focus the result pane
        assert.are.equal(1000, vim.o.timeoutlen) -- widened for the multi-key chords

        merge.close()
        assert.are.equal(200, vim.o.timeoutlen)
        -- re-entering the file later is not a merge session
        vim.cmd.edit(root .. "/f.txt")
        vim.api.nvim_exec_autocmds("BufEnter", { buffer = vim.api.nvim_get_current_buf() })
        assert.are.equal(200, vim.o.timeoutlen)
    end)

    it("ends the session when its tab closes, rather than stranding it", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        local bufs, autocmds = differ_bufs(), differ_autocmds()
        merge.open({})
        local buf = assert(merge.current()).result_buf

        vim.cmd("tabclose")
        vim.wait(200, function()
            return merge.current() == nil
        end)
        assert.is_nil(merge.current()) -- not a live session aimed at a dead window
        assert.are.same(bufs, differ_bufs())
        assert.are.equal(autocmds, differ_autocmds())
        assert.are.same({}, differ_maps(buf))
    end)

    it("ends the session when the result window closes", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local tabs = #vim.api.nvim_list_tabpages()
        vim.api.nvim_set_current_win(assert(merge.current()).result_win)

        vim.cmd("close")
        vim.wait(200, function()
            return merge.current() == nil
        end)
        assert.is_nil(merge.current())
        assert.are.equal(tabs - 1, #vim.api.nvim_list_tabpages()) -- the session tab went too
    end)

    it("does not raise from a conflict verb once the window is gone", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = assert(merge.current())
        local take_ours
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(s.result_buf, "n")) do
            if (m.desc or "") == "differ: take ours" then
                take_ours = m.callback
            end
        end
        assert.is_truthy(take_ours)
        -- close the window out from under the session without letting the hooks run
        vim.api.nvim_win_close(s.result_win, true)
        assert.is_true(pcall(take_ours)) -- used to raise E5108 on the dead window
        assert.is_nil(merge.current()) -- and takes the session down with it
    end)
end)

-- the merge result column and the `df` edit window load the same real file, so on a
-- conflicted path they share a bufnr and the second g? bind replaces the first
describe("g? over a buffer the merge tool shares", function()
    local git_src = require("differ.git")
    local Panel = require("differ.panel")

    ---@return table view, integer buf
    local function edit_window_over(root)
        vim.cmd.edit(root .. "/f.txt")
        git_src.panel({ rev = {}, open_first = true })
        local p = assert(Panel.current())
        local view = require("differ.view").for_buf(vim.api.nvim_win_get_buf(p.origin_win))
        view:edit_file() -- the df key: the real file in a transient split
        return view, vim.api.nvim_get_current_buf()
    end

    -- the desc of whatever holds g? on `buf`, so a failure names the owner
    ---@return string
    local function help_desc(buf)
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            if m.lhs == "g?" then
                return m.desc or "<no desc>"
            end
        end
        return "<unmapped>"
    end

    after_each(function()
        if merge.current() then
            merge.close()
        end
        local p = Panel.current()
        if p then
            p:close()
        end
    end)

    it("restores the diff session's g? once the merge tool closes", function()
        local root = conflict_repo()
        local _, edit_buf = edit_window_over(root)
        assert.are.equal("differ: keymap help", help_desc(edit_buf))
        local edit_win = vim.api.nvim_get_current_win()

        merge.open({})
        assert.are.equal(edit_buf, assert(merge.current()).result_buf) -- the shared bufnr
        merge.close()

        vim.api.nvim_set_current_win(edit_win) -- focus fires the re-arm
        assert.are.equal("differ: keymap help", help_desc(edit_buf))
    end)

    it("leaves g? to the merge tool while its session is live", function()
        local root = conflict_repo()
        local _, edit_buf = edit_window_over(root)
        local edit_win = vim.api.nvim_get_current_win()

        merge.open({})
        local merge_desc = help_desc(edit_buf)
        vim.api.nvim_set_current_win(edit_win)

        assert.are.equal(merge_desc, help_desc(edit_buf)) -- not stolen back mid-merge
    end)
end)

describe(":Differ mergetool modify/delete", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    local function open_at(root, relpath)
        merge.open({ path = root .. "/" .. relpath })
        return assert(merge.current())
    end

    -- the text of the dim virtual line on a deleted pane, or nil
    local function notice(buf)
        local ns = vim.api.nvim_get_namespaces()["differ.merge.notice"]
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        return marks[1] and marks[1][4].virt_text[1][1]
    end

    local function help_text(s)
        vim.api.nvim_set_current_win(s.result_win)
        fire(s.result_buf, "differ: keymap help")
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(w).relative ~= "" then
                local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
                vim.api.nvim_win_close(w, true)
                return table.concat(lines, "\n")
            end
        end
    end

    it("opens a file theirs deleted, the theirs pane empty and labelled", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        assert.are.equal("theirs", s.deleted)
        assert.are.same({ "OURS" }, vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false))
        local theirs = input(s, "theirs")
        assert.are.equal("deleted in theirs", notice(vim.api.nvim_win_get_buf(theirs.win)))
        assert.is_false(vim.wo[theirs.win].number)
        assert.is_nil(notice(vim.api.nvim_win_get_buf(input(s, "ours").win)))
        assert.are.same(
            { "" },
            vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(theirs.win), 0, -1, false)
        )
        vim.g.statusline_winid = theirs.win
        assert.are.equal("THEIRS · deleted", merge.winbar())
        vim.g.statusline_winid = input(s, "ours").win
        assert.are.equal("OURS (HEAD)", merge.winbar())
        vim.g.statusline_winid = s.result_win
        assert.are.equal("RESULT · file 1/2 · deleted in theirs", plain(merge.winbar()))
    end)

    it("labels the ours pane deleted when ours deleted the file", function()
        local root = conflict_repo_modify_delete({ "f.txt" }, "ours")
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        assert.are.equal("ours", s.deleted)
        vim.g.statusline_winid = input(s, "ours").win
        assert.are.equal("OURS (HEAD) · deleted", merge.winbar())
        vim.g.statusline_winid = input(s, "theirs").win
        assert.are.equal("THEIRS", merge.winbar())
    end)

    it("shows the original in the diff4 base pane", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ path = root .. "/a.txt", layout = "diff4" })
        local base = input(assert(merge.current()), "base")
        assert.are.same(
            { "a" },
            vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(base.win), 0, -1, false)
        )
    end)

    it("lists which take key keeps and which deletes in g?", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local txt = help_text(open_at(root, "a.txt"))
        assert.is_truthy(txt:find("<leader>co%s+keep the file"))
        assert.is_truthy(txt:find("<leader>ct%s+delete the file"))
        assert.is_nil(txt:find("take base", 1, true))
    end)

    it("steps onto a modify/delete file with ]f", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "f.txt")
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal("a.txt", merge.current().path)
    end)

    -- run `fn` with vim.fn.confirm answering `choice` (1 yes, 2 no), returning the prompt
    local function confirming(choice, fn)
        local orig, prompt = vim.fn.confirm, nil
        vim.fn.confirm = function(msg)
            prompt = msg
            return choice
        end
        local ok, err = pcall(fn)
        vim.fn.confirm = orig
        assert(ok, err)
        return prompt
    end

    local function status(root, path)
        return vim.trim(git_ok(root, "status", "--porcelain", "--", path))
    end

    it("keeps the file on taking the side that modified it, staying put", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        _G.notifs = {}
        fire(s.result_buf, "differ: take ours")
        assert.are.equal(s, merge.current())
        assert.are.equal("", status(root, "a.txt")) -- ours is HEAD's version
        assert.are.equal("OURS", vim.fn.readfile(root .. "/a.txt")[1])
        assert.is_true(s.staged)
        vim.g.statusline_winid = s.result_win
        assert.are.equal("RESULT · file 1/2 · staged · 1 file left", plain(merge.winbar()))
    end)

    it("keeps a delete/modify file on taking theirs", function()
        local root = conflict_repo_modify_delete({ "f.txt" }, "ours")
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        fire(s.result_buf, "differ: take theirs")
        assert.are.equal("A  a.txt", status(root, "a.txt"))
        assert.are.equal("THEIRS", vim.fn.readfile(root .. "/a.txt")[1])
    end)

    it("deletes the file on taking the deleting side, once confirmed", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        local real = s.result_buf
        local prompt = confirming(1, function()
            fire(s.result_buf, "differ: take theirs")
        end)
        assert.are.equal("Delete a.txt?", prompt)
        assert.are.equal(s, merge.current())
        assert.are.equal("D  a.txt", status(root, "a.txt"))
        assert.are.equal(0, vim.fn.filereadable(root .. "/a.txt"))
        -- the result window holds an empty scratch buffer, the real one is unloaded
        assert.are_not.equal(real, s.result_buf)
        assert.are.equal(s.result_buf, vim.api.nvim_win_get_buf(s.result_win))
        assert.is_false(vim.api.nvim_buf_is_loaded(real))
        assert.are.equal("a.txt deletion staged", notice(s.result_buf))
        assert.is_false(vim.wo[s.result_win].number)
        vim.g.statusline_winid = s.result_win
        assert.are.equal("RESULT · file 1/2 · deleted · 1 file left", plain(merge.winbar()))
    end)

    it("hands a deleted file's buffer back without its window options", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/a.txt") -- a window outside the session keeps the real buffer
        local s = open_at(root, "a.txt")
        confirming(1, function()
            fire(s.result_buf, "differ: take theirs")
        end)
        merge.close()
        git_ok(root, "checkout", "HEAD", "--", "a.txt")
        vim.cmd("new")
        vim.cmd.edit(root .. "/a.txt")
        assert_undressed()
    end)

    it("deletes a delete/modify file on taking ours", function()
        local root = conflict_repo_modify_delete({ "f.txt" }, "ours")
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        confirming(1, function()
            fire(s.result_buf, "differ: take ours")
        end)
        assert.are.equal("", status(root, "a.txt"))
        assert.are.equal(0, vim.fn.filereadable(root .. "/a.txt"))
    end)

    it("doesn't stage a write of the deleted file from a window outside the session", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/a.txt")
        local s = open_at(root, "a.txt")
        local real = s.result_buf
        confirming(1, function()
            fire(s.result_buf, "differ: take theirs")
        end)
        assert.is_true(vim.api.nvim_buf_is_loaded(real))
        vim.api.nvim_buf_call(real, function()
            vim.cmd("silent write")
        end)
        assert.are.equal("", vim.trim(git_ok(root, "ls-files", "--stage", "--", "a.txt")))
    end)

    it("says there's nothing to write on a :w after the delete", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        confirming(1, function()
            fire(s.result_buf, "differ: take theirs")
        end)
        vim.api.nvim_set_current_win(s.result_win)
        _G.notifs = {}
        vim.cmd("write")
        assert.are.equal("differ: a.txt deletion staged: nothing to write", _G.notifs[1].msg)
        assert.are.equal(0, vim.fn.filereadable(root .. "/a.txt"))
    end)

    it("leaves the file alone when the delete isn't confirmed", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        confirming(2, function()
            fire(s.result_buf, "differ: take theirs")
        end)
        assert.are.equal("UD a.txt", status(root, "a.txt"))
        assert.is_false(s.staged)
    end)

    it("leaves the file conflicted when git rm fails", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        local real = s.result_buf
        local git_mod = require("differ.git")
        local remove = git_mod.remove
        git_mod.remove = function()
            return false
        end
        local ok, err = pcall(confirming, 1, function()
            fire(s.result_buf, "differ: take theirs")
        end)
        git_mod.remove = remove
        assert(ok, err)
        assert.are.equal("UD a.txt", status(root, "a.txt"))
        assert.is_false(s.staged)
        assert.are.equal(real, s.result_buf)
    end)

    it("says why when keeping the file can't write it", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        vim.fn.setfperm(root .. "/a.txt", "r--r--r--")
        _G.notifs = {}
        fire(s.result_buf, "differ: take ours")
        assert.are.equal(vim.log.levels.ERROR, _G.notifs[#_G.notifs].level)
        assert.are.equal("UD a.txt", status(root, "a.txt"))
        assert.is_false(s.staged)
    end)

    it("deletes nothing when the merge tool closed while the prompt was up", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        _G.notifs = {}
        confirming(1, function()
            local confirm = vim.fn.confirm
            vim.fn.confirm = function(msg)
                merge.close()
                return confirm(msg)
            end
            fire(s.result_buf, "differ: take theirs")
        end)
        assert.are.equal(
            "differ: the merge tool closed while the prompt was up; nothing was deleted",
            _G.notifs[#_G.notifs].msg
        )
        assert.are.equal("UD a.txt", status(root, "a.txt"))
        assert.are.equal(1, vim.fn.filereadable(root .. "/a.txt"))
    end)

    it("refuses to delete over unsaved edits", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        vim.api.nvim_buf_set_lines(s.result_buf, 0, -1, false, { "edited" })
        _G.notifs = {}
        local prompt = confirming(1, function()
            fire(s.result_buf, "differ: take theirs")
        end)
        assert.is_nil(prompt)
        assert.are.equal("UD a.txt", status(root, "a.txt"))
        assert.are.equal("differ: unsaved changes: drop them with :e! to delete", _G.notifs[1].msg)
    end)

    it("stays open after a delete while the git-dir watcher catches up", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        after_git_change(s, function()
            confirming(1, function()
                fire(s.result_buf, "differ: take theirs")
            end)
        end)
        assert.are.equal(s, merge.current())
    end)

    it("says base, both and none don't apply", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        for _, desc in ipairs({
            "differ: take base",
            "differ: take both",
            "differ: drop the conflict",
        }) do
            _G.notifs = {}
            fire(s.result_buf, desc)
            assert.are.equal(
                "differ: a modify/delete conflict is kept or deleted: take ours or theirs",
                _G.notifs[1].msg
            )
        end
        assert.are.equal("UD a.txt", status(root, "a.txt"))
    end)

    it("steps past an untouched modify/delete file without keeping it", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal("f.txt", merge.current().path)
        assert.are.equal("UD a.txt", status(root, "a.txt"))
    end)

    it("keeps an edited modify/delete file when stepping past it", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        vim.api.nvim_buf_set_lines(s.result_buf, 0, -1, false, { "edited" })
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal("f.txt", merge.current().path)
        assert.are.equal("M  a.txt", status(root, "a.txt"))
    end)

    it("steps on from a deleted file with ]f", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        confirming(1, function()
            fire(s.result_buf, "differ: take theirs")
        end)
        fire(s.result_buf, "differ: next conflicted file")
        assert.are.equal("f.txt", merge.current().path)
    end)

    for _, case in ipairs({ { "delete", "theirs", "deleted" }, { "keep", "ours", "staged" } }) do
        it("fires the done notify when a " .. case[1] .. " resolves the last conflict", function()
            local root = conflict_repo_modify_delete({ "f.txt" })
            vim.cmd.edit(root .. "/f.txt")
            local s = open_at(root, "f.txt")
            take_ours_and_write(s)
            fire(s.result_buf, "differ: next conflicted file")
            local a = merge.current()
            assert.are.equal("a.txt", a.path)
            _G.notifs = {}
            confirming(1, function()
                fire(a.result_buf, "differ: take " .. case[2])
            end)
            assert.are.equal(
                "differ: all conflicts resolved: :Differ continue",
                _G.notifs[#_G.notifs].msg
            )
            vim.g.statusline_winid = a.result_win
            local bar = "RESULT · file 1/2 · %s · all conflicts resolved · :Differ continue"
            assert.are.equal(bar:format(case[3]), plain(merge.winbar()))
        end)
    end

    it("says a resolved modify/delete file is already resolved", function()
        local root = conflict_repo_modify_delete({ "f.txt" })
        vim.cmd.edit(root .. "/f.txt")
        local s = open_at(root, "a.txt")
        fire(s.result_buf, "differ: take ours")
        _G.notifs = {}
        fire(s.result_buf, "differ: take theirs")
        assert.are.equal("differ: a.txt is already resolved", _G.notifs[1].msg)
        assert.are.equal(1, vim.fn.filereadable(root .. "/a.txt"))
    end)
end)
