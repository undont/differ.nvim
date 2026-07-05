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

-- a repo where merging `feature` into `main` conflicts on f.txt (both changed line 2)
local function conflict_repo()
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
    git(root, "merge", "feature") -- conflicts: exit non-zero, expected
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

    it("shows the base column under diff3_mixed", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff3_mixed" })
        assert.are.equal(4, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("closes cleanly", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        merge.close()
        assert.is_nil(merge.current())
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
