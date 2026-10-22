-- runs under headless nvim against a throwaway git repo: the :Differ panel, its
-- staging keys, and how it drives and tears down the diff beside it
local git_src = require("differ.git")
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local V1 = helpers.V1
local fresh_repo = helpers.fresh_repo
local file_line = helpers.file_line
local view_in_origin = helpers.view_in_origin
local open_panel = helpers.open_panel
local confirming = helpers.confirming
local worktree = helpers.worktree

describe(":Differ panel", function()
    local Panel = require("differ.panel")

    -- 1-based line of the file row for `path` (optionally pinned to a staged/unstaged
    -- section), located via the panel's meta so tests don't hardcode header offsets

    -- the View driven by the panel, read without moving focus (which the focus-steal
    -- assertions below depend on): it lives in the origin window
    local function view_at(p)
        return require("differ.view").for_buf(vim.api.nvim_win_get_buf(p.origin_win))
    end

    -- the section content only: strip the 3-line header (root/help/blank) and the
    -- 3-line footer (blank/"Showing changes for:"/rev) so assertions don't depend on
    -- the temp-dir path or the HEAD sha
    local function body(p)
        assert.are.equal("Help: g?", p.lines[2]) -- header present
        assert.are.equal("Showing changes for:", p.lines[#p.lines - 1]) -- footer present
        return vim.list_slice(p.lines, 4, #p.lines - 3)
    end

    it("opens the default panel; bare :Differ re-opens, :Differ panel toggles", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- modified, not staged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        assert.is_not_nil(p)
        assert.is_true(p:is_open())
        -- empty Staged/Untracked sections are dropped, leaving one Unstaged section.
        -- the +/- counts aren't in the text: they're a right-aligned virt_text extmark
        assert.are.same({ "Unstaged (1)", "M a.lua" }, body(p))

        -- a bare :Differ over a live session just (re)opens; it never toggles shut
        git_src.panel({})
        assert.are.equal(p, Panel.current())
        assert.is_true(p:is_open())

        -- :Differ panel (opts.toggle) is the explicit hide/show gesture
        git_src.panel({ toggle = true }) -- hides the sidebar; the session stays alive
        assert.are.equal(p, Panel.current())
        assert.is_false(p:is_open())
        git_src.panel({ toggle = true }) -- shows it again
        assert.is_true(p:is_open())

        -- `:Differ panel <pos>` reveals a hidden sidebar at the requested edge
        git_src.panel({ toggle = true }) -- hide
        require("differ.command").panel("left")
        assert.is_true(p:is_open())
        assert.are.equal("left", p.position)

        -- a bare :Differ reveals a hidden sidebar too (show, not toggle)
        git_src.panel({ toggle = true }) -- hide
        assert.is_false(p:is_open())
        git_src.panel({})
        assert.is_true(p:is_open())

        require("differ.git").close() -- :Differ close ends the session
        assert.is_nil(Panel.current())
    end)

    it("steps ]f / [f from the diff while the sidebar is hidden", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua modified, unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua modified, unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true }) -- lands on a.lua (the origin file)
        local p = Panel.current()
        assert.are.equal(file_line(p, "a.lua"), p.selected_row)

        git_src.panel({ toggle = true }) -- hide the sidebar; the diff view + session stay alive
        assert.is_false(p:is_open())

        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        v:step_file("next") -- ]f with no sidebar window to read the cursor from
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(file_line(p, "z.lua"), p.selected_row)
        assert.is_false(p:is_open()) -- still hidden; stepping didn't reopen it

        v:step_file("prev") -- [f back to a.lua
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(file_line(p, "a.lua"), p.selected_row)

        require("differ.git").close()
    end)

    it("the panel winbar reports the cursor's file position", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua modified, unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua modified, unstaged
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        local winbar = require("differ.ui.winbar")
        vim.g.statusline_winid = p.winid
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        assert.is_truthy(winbar.panel():find("file 1/2", 1, true))
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "z.lua"), 0 })
        assert.is_truthy(winbar.panel():find("file 2/2", 1, true))
        vim.g.statusline_winid = nil
        p:close()
    end)

    it("runs the session in its own tabpage and returns to the origin tab on close", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local origin_tab = vim.api.nvim_get_current_tabpage()
        local origin_buf = vim.api.nvim_get_current_buf()
        local ntabs = #vim.api.nvim_list_tabpages()

        git_src.panel({ open_first = true })
        -- the diff opened in a fresh tabpage; the invoking tab is untouched
        assert.are.equal(ntabs + 1, #vim.api.nvim_list_tabpages())
        assert.are_not.equal(origin_tab, vim.api.nvim_get_current_tabpage())
        assert.matches("differ://", vim.api.nvim_buf_get_name(0))

        require("differ.git").close()
        -- back in the origin tab, original buffer intact, the session tab dropped
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages())
        assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(origin_buf, vim.api.nvim_get_current_buf())
    end)

    it("ends the session and carries the file out when navigated into the diff window", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/elsewhere.lua", "return 99\n")
        vim.cmd.edit(root .. "/a.lua")
        local origin_tab = vim.api.nvim_get_current_tabpage()
        local ntabs = #vim.api.nvim_list_tabpages()

        git_src.panel({ open_first = true })
        local other = vim.fn.bufadd(root .. "/elsewhere.lua")
        vim.fn.bufload(other)
        local diff_win = vim.api.nvim_get_current_win() -- open_first leaves us in the diff
        vim.api.nvim_win_set_buf(diff_win, other) -- a picker / :edit into the diff window
        vim.wait(500, function()
            return Panel.current() == nil
        end)
        assert.is_nil(Panel.current()) -- the whole session tore down
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages()) -- session tab dropped
        assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage()) -- back in origin tab
        assert.are.equal("elsewhere.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    end)

    it("ends the session and carries the file out when navigated into the panel window", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/elsewhere.lua", "return 99\n")
        vim.cmd.edit(root .. "/a.lua")
        local origin_tab = vim.api.nvim_get_current_tabpage()
        local ntabs = #vim.api.nvim_list_tabpages()

        git_src.panel({ open_first = true })
        local p = Panel.current()
        local other = vim.fn.bufadd(root .. "/elsewhere.lua")
        vim.fn.bufload(other)
        vim.api.nvim_win_set_buf(p.winid, other) -- a picker / :edit into the panel window
        vim.wait(500, function()
            return Panel.current() == nil
        end)
        assert.is_nil(Panel.current()) -- the whole session tore down
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages()) -- session tab dropped
        assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal("elsewhere.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    end)

    it("keeps the session alive when the panel sidebar is merely toggled off", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ open_first = true })
        local p = Panel.current()
        git_src.panel({ toggle = true }) -- toggle hides the sidebar (closes the panel window)
        vim.wait(100) -- give any (wrongly) scheduled teardown a chance to fire
        assert.are.equal(p, Panel.current()) -- still the same live session
        require("differ.git").close()
    end)

    it("opens the real file in the origin tab on jump-to-file (gofile)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local origin_tab = vim.api.nvim_get_current_tabpage()
        local ntabs = #vim.api.nvim_list_tabpages()

        git_src.panel({ open_first = true })
        require("differ").jump_to_file()
        -- the session tab is gone and we're back in the origin tab on the real file
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages())
        assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal("a.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    end)

    it("carries the diff cursor's column to the real file on jump-to-file", function()
        local root = fresh_repo()
        -- add a long line so a non-zero column is meaningful; line 2 is new-side only
        write(root .. "/a.lua", "local x = 1\nlocal answer = 42\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ open_first = true })
        local col = require("differ.view").current().columns[1]
        local brow
        for i, l in ipairs(col.map.lines) do
            if l.new == 2 then -- buffer row of new-side line 2
                brow = i
                break
            end
        end
        assert.is_not_nil(brow)
        vim.api.nvim_win_set_cursor(col.winid, { brow, 6 }) -- the "a" of "answer"
        require("differ").jump_to_file()

        assert.are.equal("a.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
        assert.are.same({ 2, 6 }, vim.api.nvim_win_get_cursor(0)) -- exact line + column
    end)

    it("binds f/b quarter-scroll in the panel window too", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.bufnr, "n")) do
            lhs[m.lhs] = true
        end
        assert.is_true(lhs["f"])
        assert.is_true(lhs["b"])
        -- invoking must not error (regression: the method was shadowed by the field)
        p:scroll("down")
        p:scroll("up")
        p:close()
    end)

    it("groups staged / unstaged / untracked into sections with counts", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged modify of a.lua
        write(root .. "/z.lua", "local z = 9\n")
        git(root, "add", "z.lua") -- staged add
        write(root .. "/u.lua", "untracked\n") -- untracked
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        assert.are.same({
            "Staged (1)",
            "A z.lua",
            "Unstaged (1)",
            "M a.lua",
            "Untracked (1)",
            "? u.lua",
        }, body(p))
        p:close()
    end)

    it("re-sources one View in place as files are selected", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged modify (Unstaged)
        write(root .. "/z.lua", "local z = 9\n")
        git(root, "add", "z.lua") -- staged add (Staged)
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "z.lua"), 0 }) -- staged: HEAD vs index
        p:select()
        local diff_buf = vim.api.nvim_win_get_buf(p.origin_win)
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 }) -- unstaged: index vs worktree
        p:select()
        -- same window + buffer: the View was re-sourced, not recreated
        assert.are.equal(diff_buf, vim.api.nvim_win_get_buf(p.origin_win))
        p:close()
    end)

    -- the change set surviving isn't enough: if the file the diff was on is the one
    -- that went clean, the window is left on a diff of a file that matches HEAD, and
    -- every later refresh walks into the same dead end (active_entry never moves on)
    it(
        "hands the diff to a surviving change when its own file goes clean outside differ",
        function()
            local root = fresh_repo()
            write(root .. "/a.lua", "local x = 2\nreturn x\n")
            write(root .. "/keep.lua", "kept\n") -- a survivor the diff should land on
            vim.cmd.edit(root .. "/a.lua")

            local p = open_panel()
            assert.are.equal("a.lua", view_at(p).model.path)

            git(root, "checkout", "HEAD", "--", "a.lua") -- only the shown file goes clean
            vim.api.nvim_set_current_win(p.winid) -- reviewing from the sidebar
            p.on_external_change()

            assert.are.equal(p, Panel.current()) -- keep.lua survives, so the session does
            assert.are.equal("keep.lua", view_at(p).model.path)
            -- the refresh isn't user-driven, so it must not yank focus into the diff
            assert.are.equal(p.winid, vim.api.nvim_get_current_win())
            p:close()
        end
    )

    -- R is the manual counterpart of the watcher, pressed precisely because something
    -- changed outside differ, so it has to re-source the diff and not just the list: a
    -- list-only reload re-baselines the change signature, which would then stop the
    -- watcher from ever catching the diff up
    it("R re-sources the diff, not just the file list", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        assert.are.equal(1, #view_at(p).model.hunks)

        write(root .. "/a.lua", "local x = 2\nreturn x\nlocal y = 3\n") -- edited outside
        vim.api.nvim_set_current_win(p.winid)
        vim.api.nvim_feedkeys("R", "x", false)

        assert.are.equal(2, #view_at(p).model.hunks) -- the diff picked the edit up
        p:close()
    end)

    -- the panel refreshes on any of these: regaining focus, an in-nvim `:!`, or a
    -- terminal git UI (lazygit) closing in a float (TermClose/TermLeave)
    for _, ev in ipairs({ "FocusGained", "ShellCmdPost", "TermClose", "TermLeave" }) do
        it("refreshes on " .. ev .. " so external git changes appear", function()
            local root = fresh_repo()
            write(root .. "/a.lua", "local x = 2\nreturn x\n")
            write(root .. "/keep.lua", "kept\n") -- survives the commit, so the session does too
            vim.cmd.edit(root .. "/a.lua")

            git_src.panel({})
            local p = Panel.current()
            assert.is_not_nil(file_line(p, "a.lua")) -- listed as modified

            git(root, "commit", "-q", "-am", "external change") -- committed outside differ
            -- scoped to the panel's group so the headless harness's own TermClose
            -- handler stays out of it
            vim.api.nvim_exec_autocmds(ev, { group = p.augroup })
            vim.wait(200, function() -- the refresh is scheduled, so let it run
                return file_line(p, "a.lua") == nil
            end)

            assert.is_nil(file_line(p, "a.lua")) -- the panel picked up the clean state
            p:close()
        end)
    end

    it("refresh after close is a no-op, not a crash on the deleted buffer", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        p:close()
        -- a debounced watcher / queued autocmd refresh can land after close; it must
        -- bail rather than render into the wiped buffer
        assert.has_no.errors(function()
            p:refresh()
        end)
    end)

    it("guards a stale entry: selecting a now-clean file refreshes, no blank view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/keep.lua", "kept\n") -- a survivor, so the refresh doesn't end the session
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        local origin_buf = vim.api.nvim_win_get_buf(p.origin_win)
        git(root, "checkout", "HEAD", "--", "a.lua") -- revert outside differ → stale entry

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        p:select()
        -- no diff opened: the origin window still shows its original buffer
        assert.are.equal(origin_buf, vim.api.nvim_win_get_buf(p.origin_win))
        assert.is_nil(file_line(p, "a.lua")) -- and the stale entry is gone after refresh
        p:close()
    end)

    it("opens a pure rename's diff instead of reporting no changes", function()
        local root = fresh_repo()
        -- a staged rename with no content edit: old and new sides are identical, so
        -- the file diffs to zero hunks but is still a real change worth showing
        git(root, "mv", "a.lua", "b.lua")
        vim.cmd.edit(root .. "/b.lua")

        git_src.panel({})
        local p = Panel.current()
        local origin_buf = vim.api.nvim_win_get_buf(p.origin_win)

        local before = #_G.notifs
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", true), 0 })
        p:select()

        -- the diff opened (a new differ:// buffer replaced the origin buffer)...
        assert.are_not.equal(origin_buf, vim.api.nvim_win_get_buf(p.origin_win))
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.is_not_nil(v)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal(V1, v.model.old_text) -- a.lua @ HEAD
        assert.are.equal(V1, v.model.new_text) -- b.lua @ index (identical)
        -- ...and no "no changes for b.lua" notification fired
        for i = before + 1, #_G.notifs do
            assert.is_nil((_G.notifs[i].msg or ""):find("no changes", 1, true))
        end
        p:close()
    end)

    it("open_first skips content-less renames and lands on the first real change", function()
        local root = fresh_repo()
        write(root .. "/keep.lua", "keep\n") -- an untouched tracked file to open from
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "keep.lua", "z.lua")
        git(root, "commit", "-q", "-am", "more files")
        git(root, "mv", "a.lua", "renamed.lua") -- staged pure rename, zero content delta
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua modified in the worktree (real change)
        -- open from keep.lua: it's in the repo (so the root resolves) but not in the
        -- change set, so open_first falls through to its first-changed pick
        vim.cmd.edit(root .. "/keep.lua")

        git_src.panel({ open_first = true })
        local p = Panel.current()
        -- the rename is the first listed file, but it's staged and z.lua isn't: the
        -- landing wants the first thing left to review, whatever the rename diffs to
        assert.are.equal(file_line(p, "z.lua"), p.selected_row)
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.is_not_nil(v)
        assert.are.equal("z.lua", v.model.path)
        require("differ.git").close()
    end)

    -- with nothing unstaged the landing falls back to the first file, and a rename is
    -- one: it diffs to nothing but still stages, unstages and discards, so opening past
    -- it would start the session with work already out of sight
    it("open_first lands on a content-less rename when nothing is unstaged", function()
        local root = fresh_repo()
        write(root .. "/keep.lua", "keep\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "keep.lua", "z.lua")
        git(root, "commit", "-q", "-am", "more files")
        git(root, "mv", "a.lua", "renamed.lua") -- staged pure rename, sorts first
        write(root .. "/z.lua", "z1x\nz2\n")
        git(root, "add", "z.lua") -- staged too, so nothing is left unstaged
        vim.cmd.edit(root .. "/keep.lua")

        git_src.panel({ open_first = true })
        local p = Panel.current()

        assert.are.equal(file_line(p, "renamed.lua"), p.selected_row)
        require("differ.git").close()
    end)

    it("diffs a staged entry HEAD↔index and an unstaged entry index↔worktree", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- staged outright
        git(root, "add", "a.lua")
        write(root .. "/b.lua", "two\n") -- unstaged only
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", true), 0 })
        p:select()
        local v = view_in_origin(p)
        assert.are.equal(V1, v.model.old_text) -- HEAD
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- index

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", false), 0 })
        p:select()
        v = view_in_origin(p)
        assert.are.equal("one\n", v.model.old_text) -- index
        assert.are.equal("two\n", v.model.new_text) -- worktree
        p:close()
    end)

    -- a file modified in the index and again in the worktree takes one row, not two,
    -- and that row diffs HEAD↔worktree so the whole change reads at once
    it("gives an MM file one Partial row diffing HEAD↔worktree", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "local x = 2\nreturn x + 1\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        assert.is_nil(file_line(p, "a.lua", true)) -- no Staged row
        local rows = 0
        for _, m in ipairs(p.meta) do
            if m.kind == "file" and m.entry.path == "a.lua" then
                rows = rows + 1
                assert.are.equal("MM", m.entry.x .. m.entry.y)
            end
        end
        assert.are.equal(1, rows)

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", false), 0 })
        p:select()
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.are.equal(V1, v.model.old_text) -- HEAD
        assert.are.equal("local x = 2\nreturn x + 1\n", v.model.new_text) -- worktree
        p:close()
    end)
end)

describe(":Differ panel staging (slice C)", function()
    local Panel = require("differ.panel")

    -- the FileEntry for `path`, optionally pinned to staged/unstaged, via the panel
    -- meta (which is rebuilt by refresh after each op)
    local function entry_of(p, path, staged)
        for _, m in ipairs(p.meta) do
            if
                m.kind == "file"
                and m.entry.path == path
                and (staged == nil or (m.entry.y == " ") == staged)
            then
                return m.entry
            end
        end
    end
    local function keymaps(p)
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.bufnr, "n")) do
            lhs[m.lhs] = true
        end
        return lhs
    end
    -- 1-based line of the dir row whose full path is `dir_path`
    local function dir_line(p, dir_path)
        for i, m in ipairs(p.meta) do
            if m.kind == "dir" and m.dir_path == dir_path then
                return i
            end
        end
    end
    -- 1-based line of the section header whose title is `title`
    local function header_line(p, title)
        for i, m in ipairs(p.meta) do
            if m.kind == "header" and m.title == title then
                return i
            end
        end
    end

    it("stages and unstages the file under the cursor", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged modify
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        assert.is_not_nil(entry_of(p, "a.lua", false)) -- starts unstaged

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", false), 0 })
        p:stage_op("stage")
        assert.is_not_nil(entry_of(p, "a.lua", true)) -- now staged
        assert.is_nil(entry_of(p, "a.lua", false))

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", true), 0 })
        p:stage_op("unstage")
        assert.is_not_nil(entry_of(p, "a.lua", false)) -- back to unstaged
        p:close()
    end)

    it("stages and unstages all", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- modified
        write(root .. "/b.lua", "new\n") -- untracked
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()

        p:stage_op("stage_all")
        assert.is_not_nil(entry_of(p, "a.lua", true))
        assert.is_not_nil(entry_of(p, "b.lua", true)) -- untracked got added too

        p:stage_op("unstage_all")
        assert.is_nil(entry_of(p, "a.lua", true))
        p:close()
    end)

    -- run `fn` with vim.fn.confirm answering `choice`, returning every prompt shown
    local function prompts_of(choice, fn)
        local orig, shown = vim.fn.confirm, {}
        vim.fn.confirm = function(msg)
            shown[#shown + 1] = msg
            return choice
        end
        local ok, err = pcall(fn)
        vim.fn.confirm = orig
        assert(ok, err)
        return shown
    end

    it("u on a row whose staged blob is held nowhere else asks first", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        os.remove(root .. "/a.lua") -- MD: the index alone holds the edit
        write(root .. "/z.lua", "z\n")
        vim.cmd.edit(root .. "/z.lua")
        git_src.panel({})
        local p = Panel.current()
        local staged = git(root, "rev-parse", ":a.lua")

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        local shown = prompts_of(2, function()
            p:stage_op("unstage")
        end)
        assert.are.equal(1, #shown)
        assert.matches("Unstage a.lua%?", shown[1])
        assert.are.equal(staged, git(root, "rev-parse", ":a.lua")) -- declined: kept

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        prompts_of(1, function()
            p:stage_op("unstage")
        end)
        assert.are.equal(" D a.lua\n", (git(root, "status", "--porcelain=v1", "--", "a.lua")))
        p:close()
    end)

    it("u on a partly staged row asks only when the file lost staged lines", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "local x = 2\nreturn x\nprint(x)\n") -- keeps the staged line
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        assert.are.same(
            {},
            prompts_of(2, function()
                p:stage_op("unstage")
            end)
        )
        assert.are.equal(" M a.lua\n", (git(root, "status", "--porcelain=v1", "--", "a.lua")))

        git(root, "add", "a.lua")
        write(root .. "/a.lua", "local x = 3\nreturn x\n") -- overwrites the staged line
        p:refresh()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        local shown = prompts_of(2, function()
            p:stage_op("unstage")
        end)
        assert.are.equal(1, #shown)
        assert.are.equal("MM a.lua\n", (git(root, "status", "--porcelain=v1", "--", "a.lua")))
        p:close()
    end)

    it("u on a directory asks once, naming only the files that lose content", function()
        local root = fresh_repo()
        vim.fn.mkdir(root .. "/src", "p")
        write(root .. "/src/gone.lua", "g\n")
        write(root .. "/src/kept.lua", "k\n")
        git(root, "add", "src")
        git(root, "commit", "-q", "-m", "src")
        write(root .. "/src/gone.lua", "g2\n")
        write(root .. "/src/kept.lua", "k2\n")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "-A")
        os.remove(root .. "/src/gone.lua") -- MD
        write(root .. "/src/kept.lua", "k2\nmore\n") -- MM, staged line still on disk
        write(root .. "/a.lua", "local x = 2\nreturn x\nmore\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        local before = git(root, "ls-files", "-s")

        vim.api.nvim_win_set_cursor(p.winid, { assert(dir_line(p, "src")), 0 })
        local shown = prompts_of(2, function()
            p:stage_op("unstage")
        end)
        assert.are.equal(1, #shown)
        assert.are.equal(
            "Unstage these files? Staged changes in src/gone.lua will be lost.",
            shown[1]
        )
        assert.is_nil(shown[1]:find("kept", 1, true))
        assert.are.equal(before, git(root, "ls-files", "-s")) -- declined: nothing moved

        vim.api.nvim_win_set_cursor(p.winid, { assert(dir_line(p, "src")), 0 })
        prompts_of(1, function()
            p:stage_op("unstage")
        end)
        local status = git(root, "status", "--porcelain=v1")
        assert.matches(" D src/gone.lua", status, 1, true)
        assert.matches(" M src/kept.lua", status, 1, true)
        assert.matches("MM a.lua", status, 1, true) -- outside the directory: untouched
        p:close()
    end)

    it("U asks once before dropping staged content nothing else holds", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/b.lua", "b\n")
        git(root, "add", "-A")
        os.remove(root .. "/a.lua")
        vim.cmd.edit(root .. "/b.lua")
        git_src.panel({})
        local p = Panel.current()
        local before = git(root, "ls-files", "-s")

        local shown = prompts_of(2, function()
            p:stage_op("unstage_all")
        end)
        assert.are.equal(1, #shown)
        assert.are.equal("Unstage these files? Staged changes in a.lua will be lost.", shown[1])
        assert.are.equal(before, git(root, "ls-files", "-s"))

        prompts_of(1, function()
            p:stage_op("unstage_all")
        end)
        local status = git(root, "status", "--porcelain=v1")
        assert.matches(" D a.lua", status, 1, true)
        assert.matches("?? b.lua", status, 1, true)
        p:close()
    end)

    it("s on an add deleted on disk asks before dropping the staged add", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "c\n")
        git(root, "add", "c.lua")
        os.remove(root .. "/c.lua") -- AD: the index alone holds the add
        write(root .. "/z.lua", "z\n")
        vim.cmd.edit(root .. "/z.lua")
        git_src.panel({})
        local p = Panel.current()
        local staged = git(root, "rev-parse", ":c.lua")

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "c.lua"), 0 })
        local shown = prompts_of(2, function()
            p:stage_op("stage")
        end)
        assert.are.same({ "Stage the deletion of c.lua? The staged file will be lost." }, shown)
        assert.are.equal(staged, git(root, "rev-parse", ":c.lua")) -- declined: kept

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "c.lua"), 0 })
        prompts_of(1, function()
            p:stage_op("stage")
        end)
        assert.are.equal("", (git(root, "status", "--porcelain=v1", "--", "c.lua")))
        p:close()
    end)

    it("S asks once before staging an add deleted on disk", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "c\n")
        git(root, "add", "c.lua")
        os.remove(root .. "/c.lua")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        local before = git(root, "ls-files", "-s")

        local shown = prompts_of(2, function()
            p:stage_op("stage_all")
        end)
        assert.are.equal(1, #shown)
        assert.are.equal("Stage these files? Staged changes in c.lua will be lost.", shown[1])
        assert.are.equal(before, git(root, "ls-files", "-s")) -- declined: nothing moved

        prompts_of(1, function()
            p:stage_op("stage_all")
        end)
        local status = git(root, "status", "--porcelain=v1")
        assert.is_nil(status:find("c.lua", 1, true))
        assert.matches("M  a.lua", status, 1, true)
        p:close()
    end)

    it("s on an edit deleted on disk asks only when nothing else holds the edit", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        git(root, "update-index", "--chmod=+x", "b.lua")
        os.remove(root .. "/b.lua") -- MD whose blob HEAD still has
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        os.remove(root .. "/a.lua") -- MD with a new blob
        write(root .. "/z.lua", "z\n")
        vim.cmd.edit(root .. "/z.lua")
        git_src.panel({})
        local p = Panel.current()

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua"), 0 })
        assert.are.same(
            {},
            prompts_of(2, function()
                p:stage_op("stage")
            end)
        )
        assert.are.equal("D  b.lua\n", (git(root, "status", "--porcelain=v1", "--", "b.lua")))

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        local shown = prompts_of(2, function()
            p:stage_op("stage")
        end)
        assert.are.same({ "Stage the deletion of a.lua? The staged file will be lost." }, shown)
        assert.are.equal("MD a.lua\n", (git(root, "status", "--porcelain=v1", "--", "a.lua")))
        p:close()
    end)

    it("s on a rename deleted on disk asks only when the rename carried an edit", function()
        local root = fresh_repo()
        git(root, "mv", "a.lua", "b.lua")
        os.remove(root .. "/b.lua") -- RD whose blob HEAD still has at a.lua
        write(root .. "/z.lua", "z\n")
        vim.cmd.edit(root .. "/z.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua"), 0 })
        assert.are.same(
            {},
            prompts_of(2, function()
                p:stage_op("stage")
            end)
        )
        p:close()

        root = fresh_repo()
        git(root, "mv", "a.lua", "b.lua")
        write(root .. "/b.lua", V1 .. "more\n")
        git(root, "add", "b.lua")
        os.remove(root .. "/b.lua") -- RD with an edit only the index holds
        assert.matches("^RD", git(root, "status", "--porcelain=v1"))
        write(root .. "/z.lua", "z\n")
        vim.cmd.edit(root .. "/z.lua")
        git_src.panel({})
        p = Panel.current()
        local before = git(root, "ls-files", "-s")
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua"), 0 })
        local shown = prompts_of(2, function()
            p:stage_op("stage")
        end)
        assert.are.same({ "Stage the deletion of b.lua? The staged file will be lost." }, shown)
        assert.are.equal(before, git(root, "ls-files", "-s"))
        p:close()
    end)

    it("s on a typechange deleted on disk asks first", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "z\n")
        local link = vim.trim(git(root, "hash-object", "-w", "z.lua"))
        git(root, "update-index", "--cacheinfo", "120000," .. link .. ",a.lua")
        os.remove(root .. "/a.lua") -- TD: the index alone holds the symlink
        assert.matches("TD a.lua", git(root, "status", "--porcelain=v1"), 1, true)
        vim.cmd.edit(root .. "/z.lua")
        git_src.panel({})
        local p = Panel.current()
        local before = git(root, "ls-files", "-s")
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        local shown = prompts_of(2, function()
            p:stage_op("stage")
        end)
        assert.are.same({ "Stage the deletion of a.lua? The staged file will be lost." }, shown)
        assert.are.equal(before, git(root, "ls-files", "-s"))
        p:close()
    end)

    it("s on a plain unstaged row stages without asking", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        assert.are.same(
            {},
            prompts_of(2, function()
                p:stage_op("stage")
            end)
        )
        assert.are.equal("M  a.lua\n", (git(root, "status", "--porcelain=v1", "--", "a.lua")))
        p:close()
    end)

    it("discards a tracked file back to HEAD (after confirm)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })

        local prompt = confirming(1, function()
            p:discard()
        end)

        assert.are.equal("Discard changes to a.lua?", prompt)
        assert.is_nil(entry_of(p, "a.lua")) -- no longer a change
        assert.are.equal(V1, table.concat(vim.fn.readfile(root .. "/a.lua"), "\n") .. "\n")
        -- the file's own buffer is reloaded too, not left showing the discarded edit
        local filebuf = vim.fn.bufnr(root .. "/a.lua")
        assert.are.equal(
            V1,
            table.concat(vim.api.nvim_buf_get_lines(filebuf, 0, -1, false), "\n") .. "\n"
        )
        p:close()
    end)

    it("leaves a deletion kept on disk staged on s", function()
        local root = fresh_repo()
        git(root, "rm", "-q", "--cached", "a.lua")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        p:stage_op("stage")
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("D  a.lua\n?? a.lua\n", status)
    end)

    it("does nothing on s over a staged deletion", function()
        local root = fresh_repo()
        git(root, "rm", "-q", "a.lua")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/b.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        _G.notifs = {}
        p:stage_op("stage")
        local failed = vim.tbl_filter(function(n)
            return n.msg:find("failed", 1, true) ~= nil
        end, _G.notifs)
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        p:close()
        assert.are.same({}, failed)
        assert.are.equal("D  a.lua\n", status)
    end)

    it("brings a staged edit whose file was deleted back as staged on X", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "edited\n")
        git(root, "add", "a.lua")
        os.remove(root .. "/a.lua")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/b.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        local prompt = confirming(1, function()
            p:discard()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        p:close()
        assert.are.equal("Restore a.lua as staged?", prompt)
        assert.are.equal("M  a.lua\n", status)
        assert.are.same({ "edited" }, vim.fn.readfile(root .. "/a.lua"))
    end)

    it("refuses X on a submodule rather than claiming to move its checkout", function()
        local root = fresh_repo()
        local sub = root .. "/sub"
        vim.fn.mkdir(sub, "p")
        git(sub, "init", "-q")
        git(sub, "commit", "-q", "--allow-empty", "-m", "one")
        git(root, "add", "sub")
        git(root, "commit", "-q", "-m", "sub")
        git(sub, "commit", "-q", "--allow-empty", "-m", "two")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "sub"), 0 })
        _G.notifs = {}
        local prompt = confirming(1, function()
            p:discard()
        end)
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: discard skipped: X can't move the checkout inside the submodule sub",
            said
        )
        assert.are.equal(" M sub\n", status)
    end)

    it("refuses X on a deletion kept on disk before asking", function()
        local root = fresh_repo()
        git(root, "rm", "-q", "--cached", "a.lua")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        _G.notifs = {}
        local prompt = confirming(1, function()
            p:discard()
        end)
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: discard skipped: X would overwrite a.lua on disk; u unstages the deletion instead",
            said
        )
        assert.are.equal("D  a.lua\n?? a.lua\n", status)
        assert.are.equal("local x = 2\nreturn x\n", worktree(root, "a.lua"))
    end)

    it("discards an untracked file by deleting it", function()
        local root = fresh_repo()
        write(root .. "/u.lua", "untracked\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "u.lua"), 0 })

        confirming(1, function()
            p:discard()
        end)

        assert.are.equal(0, vim.fn.filereadable(root .. "/u.lua"))
        p:close()
    end)

    -- confirm() drains scheduled callbacks while it blocks, so the entry's status can
    -- move under the prompt. an untracked file staged from outside is the sharp case:
    -- the "?" branch deletes it while the index keeps the add
    it("refuses to discard a file whose status moved under the prompt", function()
        local root = fresh_repo()
        write(root .. "/u.lua", "untracked\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "u.lua"), 0 })

        _G.notifs = {}
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            git(root, "add", "u.lua") -- "?" -> a staged add, from outside differ
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.are.equal(1, vim.fn.filereadable(root .. "/u.lua"))
        -- and the index still has the add, so the two can't disagree
        assert.are.equal("untracked\n", git(root, "show", ":u.lua"))
        assert.is_truthy(_G.notifs[#_G.notifs].msg:find("discard skipped: u.lua", 1, true))
        p:close()
    end)

    it("stages and unstages every file under a directory row", function()
        local root = fresh_repo()
        -- two files under src/, plus a sibling at the root so src/ stays a foldable
        -- dir row (a sole common prefix 2+ deep would be stripped to a subtitle)
        vim.fn.mkdir(root .. "/src", "p")
        write(root .. "/src/a.lua", "a\n")
        write(root .. "/src/b.lua", "b\n")
        write(root .. "/top.lua", "t\n")
        vim.cmd.edit(root .. "/top.lua")
        git_src.panel({})
        local p = Panel.current()
        assert.is_not_nil(entry_of(p, "src/a.lua", false))
        assert.is_not_nil(entry_of(p, "src/b.lua", false))

        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })
        p:stage_op("stage")
        assert.is_not_nil(entry_of(p, "src/a.lua", true)) -- both files staged
        assert.is_not_nil(entry_of(p, "src/b.lua", true))
        assert.is_nil(entry_of(p, "top.lua", true)) -- the sibling is untouched

        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })
        p:stage_op("unstage")
        assert.is_not_nil(entry_of(p, "src/a.lua", false)) -- both back to unstaged
        assert.is_not_nil(entry_of(p, "src/b.lua", false))
        p:close()
    end)

    it("unstages a whole section from its header (deep prefix stripped, no dir row)", function()
        local root = fresh_repo()
        -- every staged file shares a 2+-level prefix, so the tree strips it to a
        -- header subtitle and emits no dir row: the header is the only group target
        vim.fn.mkdir(root .. "/lua/panel", "p")
        write(root .. "/lua/panel/init.lua", "i\n")
        write(root .. "/lua/panel/render.lua", "r\n")
        git(root, "add", "lua/panel/init.lua", "lua/panel/render.lua")
        write(root .. "/loose.lua", "l\n") -- an unstaged file so the panel isn't all-staged
        vim.cmd.edit(root .. "/loose.lua")
        git_src.panel({})
        local p = Panel.current()
        assert.is_nil(dir_line(p, "lua/panel")) -- confirm: prefix stripped, no dir row
        assert.is_not_nil(entry_of(p, "lua/panel/init.lua", true))

        vim.api.nvim_win_set_cursor(p.winid, { header_line(p, "Staged"), 0 })
        p:stage_op("unstage")
        assert.is_nil(entry_of(p, "lua/panel/init.lua", true)) -- whole section unstaged
        assert.is_nil(entry_of(p, "lua/panel/render.lua", true))
        assert.is_not_nil(entry_of(p, "lua/panel/init.lua", false))
        p:close()
    end)

    it("discards every file under a directory row (after confirm)", function()
        local root = fresh_repo()
        vim.fn.mkdir(root .. "/src", "p")
        write(root .. "/src/a.lua", "a\n")
        write(root .. "/src/b.lua", "b\n")
        write(root .. "/top.lua", "t\n")
        vim.cmd.edit(root .. "/top.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })

        local prompt = confirming(1, function()
            p:discard()
        end)

        assert.are.equal("Discard changes to src/a.lua, src/b.lua?", prompt)
        assert.are.equal(0, vim.fn.filereadable(root .. "/src/a.lua")) -- both deleted
        assert.are.equal(0, vim.fn.filereadable(root .. "/src/b.lua"))
        assert.are.equal(1, vim.fn.filereadable(root .. "/top.lua")) -- sibling kept
        p:close()
    end)

    it("names the first three files in a directory row's X prompt", function()
        local root = fresh_repo()
        vim.fn.mkdir(root .. "/src", "p")
        for _, name in ipairs({ "a", "b", "c", "d", "e" }) do
            write(root .. "/src/" .. name .. ".lua", name .. "\n")
        end
        write(root .. "/top.lua", "t\n")
        vim.cmd.edit(root .. "/top.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })

        local prompt = confirming(2, function()
            p:discard()
        end)

        p:close()
        assert.are.equal("Discard changes to src/a.lua, src/b.lua, src/c.lua, +2 more?", prompt)
        assert.are.equal(1, vim.fn.filereadable(root .. "/src/a.lua")) -- declined
    end)

    it("skips a kept deletion under a section header and discards the rest", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        git(root, "rm", "-q", "--cached", "a.lua")
        write(root .. "/b.lua", "edited\n")
        git(root, "add", "b.lua")
        vim.cmd.edit(root .. "/b.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { header_line(p, "Staged"), 0 })
        _G.notifs = {}

        local prompt = confirming(1, function()
            p:discard()
        end)

        local said = (_G.notifs[#_G.notifs] or {}).msg
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("Discard changes to b.lua?", prompt)
        assert.are.equal(
            "differ: discard skipped: X would overwrite a.lua on disk; u unstages the deletion instead",
            said
        )
        assert.are.equal("D  a.lua\n?? a.lua\n", status)
        assert.are.equal("b\n", worktree(root, "b.lua"))
    end)

    it("skips a submodule under a directory row and discards the rest", function()
        local root = fresh_repo()
        local sub = root .. "/src/sub"
        vim.fn.mkdir(sub, "p")
        write(root .. "/src/edit.lua", "edit\n")
        git(sub, "init", "-q")
        git(sub, "commit", "-q", "--allow-empty", "-m", "one")
        git(root, "add", "src")
        git(root, "commit", "-q", "-m", "src")
        git(sub, "commit", "-q", "--allow-empty", "-m", "two")
        write(root .. "/src/edit.lua", "edited\n")
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- keeps src/ a dir row
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })
        _G.notifs = {}

        local prompt = confirming(1, function()
            p:discard()
        end)

        local said = (_G.notifs[#_G.notifs] or {}).msg
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("Discard changes to src/edit.lua?", prompt)
        assert.are.equal(
            "differ: discard skipped: X can't move the checkout inside the submodule src/sub",
            said
        )
        assert.are.equal(" M a.lua\n M src/sub\n", status)
        assert.are.equal("edit\n", worktree(root, "src/edit.lua"))
    end)

    it("discards a worktree rename beside a submodule under a directory row", function()
        local root = fresh_repo()
        local sub = root .. "/src/sub"
        vim.fn.mkdir(sub, "p")
        write(root .. "/b.lua", "b\n")
        git(sub, "init", "-q")
        git(sub, "commit", "-q", "--allow-empty", "-m", "one")
        git(root, "add", "src", "b.lua")
        git(root, "commit", "-q", "-m", "src")
        git(sub, "commit", "-q", "--allow-empty", "-m", "two")
        os.rename(root .. "/a.lua", root .. "/src/moved.lua")
        git(root, "add", "-N", "src/moved.lua")
        write(root .. "/b.lua", "edited\n") -- keeps src/ a dir row
        vim.cmd.edit(root .. "/b.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })
        _G.notifs = {}

        local prompt = confirming(1, function()
            p:discard()
        end)

        local said = (_G.notifs[#_G.notifs] or {}).msg
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("Discard changes to src/moved.lua (restoring a.lua)?", prompt)
        assert.are.equal(
            "differ: discard skipped: X can't move the checkout inside the submodule src/sub",
            said
        )
        assert.are.equal(" M b.lua\n M src/sub\n", status)
    end)

    it("refuses X on a section with no prompt when every file is refused", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        git(root, "rm", "-q", "--cached", "a.lua", "b.lua")
        local before = git(root, "status", "--porcelain=v1")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { header_line(p, "Staged"), 0 })
        _G.notifs = {}

        local prompt = confirming(1, function()
            p:discard()
        end)

        local said = (_G.notifs[#_G.notifs] or {}).msg
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: discard skipped: X would overwrite a.lua on disk; u unstages the deletion instead\n"
                .. "differ: discard skipped: X would overwrite b.lua on disk; u unstages the deletion instead",
            said
        )
        assert.are.equal(before, status)
    end)

    it("binds staging keys for the worktree source", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        local lhs = keymaps(p)
        for _, k in ipairs({ "s", "u", "S", "U", "X", "R" }) do
            assert.is_true(lhs[k])
        end
        p:close()
    end)

    it("does not bind staging keys for a rev-pair source", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "commit", "-q", "-am", "edit")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = "HEAD~1..HEAD" })
        local p = Panel.current()
        local lhs = keymaps(p)
        assert.is_nil(lhs["s"])
        assert.is_nil(lhs["X"])
        p:close()
    end)

    it("honours a disabled panel action from setup config (keymaps)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        require("differ").setup({ keymaps = { panel = { discard = false } } })
        git_src.panel({})
        local p = Panel.current()
        local lhs = keymaps(p)
        assert.is_nil(lhs["X"]) -- discard disabled
        assert.is_true(lhs["s"]) -- other staging keys unaffected
        p:close()
        require("differ").setup({}) -- restore defaults for the rest of the suite
    end)
end)

describe(":Differ panel <-> diff wiring", function()
    local Panel = require("differ.panel")

    it("opens with the cursor in the diff window, not the panel", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.are.equal(p.origin_win, vim.api.nvim_get_current_win()) -- in the diff
        assert.are_not.equal(p.winid, vim.api.nvim_get_current_win())
        p:close()
    end)

    it("binds ]c/[c in the panel, driving the diff view's hunk nav", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two hunks
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()

        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.bufnr, "n")) do
            lhs[m.lhs] = true
        end
        assert.is_true(lhs["]c"])
        assert.is_true(lhs["[c"])

        -- from the panel, ]c moves the diff window's cursor to the next hunk
        vim.api.nvim_set_current_win(p.winid)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        require("differ").goto_hunk("next")
        assert.are.equal(9, vim.api.nvim_win_get_cursor(p.origin_win)[1]) -- second hunk
        p:close()
    end)

    it("gofile works from the panel, acting on the driven view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        vim.api.nvim_set_current_win(p.winid) -- focus the panel
        assert.is_not_nil(require("differ").active_view())

        require("differ").jump_to_file()
        local cur = vim.api.nvim_get_current_buf()
        assert.are.equal("a.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur), ":t"))
        assert.are.equal("", vim.bo[cur].buftype) -- the real file
        assert.is_nil(Panel.current()) -- the whole session was torn down
    end)
end)

describe(":Differ (open_first)", function()
    local Panel = require("differ.panel")

    -- p:select returns focus to the panel, so the View lives in the origin window

    it("opens the panel and the first file's diff (DiffviewOpen-style)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        assert.is_not_nil(p)
        local v = view_in_origin(p)
        assert.is_not_nil(v)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(V1, v.model.old_text) -- index (nothing staged) == HEAD
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- worktree
        -- the default footer is the HEAD commit (a 40-char hex sha)
        assert.are.equal("Showing changes for:", p.lines[#p.lines - 1])
        local sha = p.lines[#p.lines]
        assert.are.equal(40, #sha)
        assert.is_truthy(sha:match("^%x+$"))
        p:close()
    end)

    it("populates gitsigns status vars on the diff buffer for the statusline", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- one changed line
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        local buf = vim.api.nvim_win_get_buf(p.origin_win)
        local dict = vim.b[buf].gitsigns_status_dict
        assert.is_not_nil(dict)
        assert.are.equal(1, dict.changed) -- "1" -> "2" is a single changed line
        assert.are.equal(0, dict.added)
        assert.are.equal(0, dict.removed)
        assert.are.equal("main", vim.b[buf].gitsigns_head)
        p:close()
    end)

    it("resolves a merge-base (three-dot) against the working tree", function()
        local root = fresh_repo()
        -- diverge: branch off main, commit a change on the branch, then edit further
        git(root, "checkout", "-q", "-b", "feature")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "commit", "-q", "-am", "feature change")
        write(root .. "/a.lua", "local x = 3\nreturn x\n") -- uncommitted on top
        vim.cmd.edit(root .. "/a.lua")

        -- main... => merge-base(main, HEAD) [the init commit, V1] vs worktree [V3]
        git_src.panel({ rev = "main...", open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.is_not_nil(v)
        assert.are.equal(V1, v.model.old_text)
        assert.are.equal("local x = 3\nreturn x\n", v.model.new_text)
        assert.are.equal("main...", v.model.old_rev)
        p:close()
    end)

    it("]f from the diff window steps the panel selection, keeping focus in the diff", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged
        write(root .. "/z.lua", "local z = 9\n")
        git(root, "add", "z.lua") -- staged -> two files in the set
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        vim.api.nvim_set_current_win(p.origin_win) -- emulate cursor in the diff window
        local v = require("differ.view").current()
        local first = v.model.path

        v:step_file("next")
        -- focus stayed in the diff window (not bounced to the panel)
        assert.are.equal(p.origin_win, vim.api.nvim_get_current_win())
        -- and the one view re-sourced to a different file
        assert.are_not.equal(first, require("differ.view").current().model.path)
        p:close()
    end)

    it("]f / [f wrap past the ends of the file list", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged (sorts last)
        write(root .. "/z.lua", "local z = 9\n")
        git(root, "add", "z.lua") -- staged (sorts first)
        vim.cmd.edit(root .. "/a.lua") -- open on a.lua, the last file

        local p = open_panel()
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.are.equal("a.lua", v.model.path)

        _G.notifs = {}
        v:step_file("next") -- ]f past the last file wraps to the first
        assert.are.equal("z.lua", require("differ.view").current().model.path)
        assert.are.equal("differ: wrapped to the first file", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)

        _G.notifs = {}
        v:step_file("prev") -- [f past the first wraps back to the last
        assert.are.equal("a.lua", require("differ.view").current().model.path)
        assert.are.equal("differ: wrapped to the last file", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)
        p:close()
    end)

    it("git.close tears down the panel and the diff view it drives", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.is_true(p:is_open())
        assert.is_true(v:is_open())

        git_src.close()
        assert.is_nil(Panel.current()) -- panel gone
        assert.is_false(v:is_open()) -- on_close closed the driven view
    end)
end)

-- a panel and a history are tracked by independent singletons in their own tabs, so an
-- opener that only superseded its own kind left the other stacked underneath. `:Differ log`
-- over a live `:Differ base` panel then needed two `:Differ close`s (the first closed the
-- stale panel, the second the visible history)
describe(":Differ session supersession (cross-kind)", function()
    local Panel = require("differ.panel")
    local History = require("differ.history")

    it("`:Differ log` supersedes a live panel, so one git.close ends the session", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua") -- the origin buffer; supersede returns focus here so
        local ntabs = #vim.api.nvim_list_tabpages() -- range history resolves this repo by anchor

        git_src.panel({ rev = {}, open_first = true }) -- the base/worktree panel
        assert.is_not_nil(Panel.current())

        git_src.range_history({ range = "HEAD" }) -- `:Differ log` on top
        assert.is_nil(Panel.current()) -- superseded, not stacked
        assert.is_not_nil(History.current()) -- exactly the history remains
        assert.are.equal(ntabs + 1, #vim.api.nvim_list_tabpages()) -- one session tab, never two

        git_src.close() -- a single :Differ close ends it
        assert.is_nil(History.current())
        assert.is_nil(Panel.current())
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages()) -- session tab dropped
    end)

    it("`:Differ log <file>` also supersedes a live panel", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        assert.is_not_nil(Panel.current())

        git_src.history({ path = root .. "/a.lua" }) -- explicit path: repo resolves unambiguously
        assert.is_nil(Panel.current()) -- superseded
        assert.is_not_nil(History.current())

        git_src.close()
        assert.is_nil(History.current())
    end)
end)

-- :q on the diff window is the most natural way to leave a session, and it means the
-- window is already gone when the panel's on_close runs. the teardown has to happen
-- anyway, or every cycle strands a buffer holding a whole DiffModel, the armed
-- WinClosed autocmd, and the canonical differ:// name the next session wants
describe("git session teardown after :q on the diff", function()
    local function differ_bufs()
        local n = 0
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if
                vim.api.nvim_buf_is_valid(b)
                and vim.api.nvim_buf_get_name(b):find("differ://", 1, true)
            then
                n = n + 1
            end
        end
        return n
    end

    local function viewclose_autocmds()
        local n = 0
        for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "WinClosed" })) do
            if
                type(a.group_name) == "string" and a.group_name:find("differ.viewclose", 1, true)
            then
                n = n + 1
            end
        end
        return n
    end

    it("leaks no buffers or autocmds across repeated open/:q cycles", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        git(root, "add", "a.lua")
        git(root, "commit", "-q", "-am", "seed")
        write(root .. "/a.lua", "1x\n2\n")
        vim.cmd.edit(root .. "/a.lua")

        local bufs_before, aus_before = differ_bufs(), viewclose_autocmds()

        for _ = 1, 3 do
            git_src.panel({ rev = {}, open_first = true })
            local v = require("differ.view").current()
            assert.is_not_nil(v)
            local win = v.columns[1].winid
            assert.is_true(vim.api.nvim_win_is_valid(win))

            -- the gesture: the window is gone before on_close runs. nvim_win_close
            -- rather than :quit, which would take headless nvim down with it
            vim.api.nvim_win_close(win, false)
            require("differ.git").close()
        end

        assert.are.equal(bufs_before, differ_bufs())
        assert.are.equal(aus_before, viewclose_autocmds())
    end)
end)

-- a change that diffs to no lines still opens a diff view (the session's anchor) on
-- a notice naming the reason, rather than refusing the selection and re-notifying
describe(":Differ panel (zero-hunk entries)", function()
    local Panel = require("differ.panel")

    local function open_only_entry(root)
        git_src.panel({ open_first = true })
        local p = assert(Panel.current())
        vim.api.nvim_set_current_win(p.origin_win)
        return p, require("differ.view").current()
    end

    it("opens a mode-only change on a notice naming both modes", function()
        local root = fresh_repo()
        git(root, "config", "core.fileMode", "true")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/a.lua", 493)) -- 0755
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_only_entry(root)
        assert.is_not_nil(v)
        assert.are.equal("Mode changed 100644 → 100755", v.model.notice)
        assert.are.same(
            { "Mode changed 100644 → 100755" },
            vim.api.nvim_buf_get_lines(v.columns[1].bufnr, 0, -1, false)
        )
        p:close()
    end)

    it("opens an empty untracked file on a notice", function()
        local root = fresh_repo()
        write(root .. "/empty.txt", "")
        vim.cmd.edit(root .. "/empty.txt")

        local p, v = open_only_entry(root)
        assert.is_not_nil(v)
        assert.are.equal("empty.txt", v.model.path)
        assert.are.equal("Empty file", v.model.notice)
        p:close()
    end)

    it("opens a final-newline-only change on its last line", function()
        local root = fresh_repo()
        write(root .. "/a.lua", V1:sub(1, -2)) -- same content, no trailing newline
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_only_entry(root)
        local hunks, notice = v.model.hunks, v.model.notice
        p:close()
        assert.are.equal(1, #hunks)
        assert.are.same(hunks[1].old_lines, hunks[1].new_lines)
        assert.is_nil(notice)
    end)

    it("names a moved submodule pointer, which reads empty on both sides", function()
        local root = fresh_repo()
        -- the submodule's own repo lives outside root, so it adds no untracked entry
        local sub = vim.fn.tempname()
        vim.fn.mkdir(sub, "p")
        git(sub, "init", "-q")
        write(sub .. "/f", "one\n")
        git(sub, "add", "f")
        git(sub, "commit", "-q", "-m", "one")

        git(root, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "mod")
        git(root, "commit", "-q", "-m", "add submodule")
        write(root .. "/mod/f", "two\n") -- move the pointer: commit inside the submodule
        git(root .. "/mod", "commit", "-q", "-am", "two")
        vim.cmd.edit(root .. "/a.lua") -- put the session's origin inside this repo

        local p, v = open_only_entry(root)
        assert.is_not_nil(v)
        assert.are.equal("mod", v.model.path)
        -- `git show :mod` fails on a gitlink, so the model has no content either side
        assert.are.equal("", v.model.old_text)
        assert.are.equal("", v.model.new_text)
        assert.are.equal("Submodule commit changed", v.model.notice)
        p:close()
    end)

    it("still refuses a stale entry, so the list re-sources instead", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = assert(Panel.current())

        -- commit the change behind the panel's back: its entry now diffs to nothing
        git(root, "commit", "-qam", "outside")
        -- on_select is what the panel calls on <CR>; false is "stale, re-source"
        assert.is_false(p.on_select({ path = "a.lua", status = "M", staged = false }))
        if Panel.current() then
            p:close() -- the refresh may have emptied the list and ended the session
        end
    end)
end)
