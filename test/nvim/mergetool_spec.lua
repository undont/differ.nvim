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

-- a repo where merging `feature` into `main` conflicts on f.txt (both changed line 2).
-- `style` picks the merge.conflictStyle: nil for git's default, "diff3" to get the
-- ||||||| base marker as well
---@param style string|nil
local function conflict_repo(style)
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
    if style then
        git(root, "-c", "merge.conflictStyle=" .. style, "merge", "feature")
    else
        git(root, "merge", "feature") -- conflicts: exit non-zero, expected
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
-- write-driven advancing through the conflict set
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

local merge_ns = vim.api.nvim_create_namespace("differ.merge")
local flash_ns = vim.api.nvim_create_namespace("differ.merge.flash")

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
        fire(s.result_buf, "differ: take ours")
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")
        assert.are.same({}, require("differ.git").conflicted(root))
    end)

    it("advances to the next conflicted file once one is resolved and written", function()
        local root = conflict_repo_two()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        assert.are.equal("f.txt", s.path)
        fire(s.result_buf, "differ: take ours")
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")
        -- f.txt stages immediately; the deferred advance opens the next conflicted file
        vim.wait(2000, function()
            return merge.current() ~= nil and merge.current().path == "g.txt"
        end)
        assert.are.equal("g.txt", merge.current().path)
        assert.are.same({ "g.txt" }, require("differ.git").conflicted(root))
    end)

    it("reports done and closes the session once the last conflict is written", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        fire(s.result_buf, "differ: take ours")
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")
        vim.wait(2000, function()
            return merge.current() == nil
        end)
        assert.is_nil(merge.current())
        assert.are.same({}, require("differ.git").conflicted(root))
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
        -- resolve the first (auto-advances onto the second), then take base there: the live
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
        fire(s.result_buf, "differ: take ours")
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("silent write")
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
