-- runs under headless nvim against a throwaway git repo: exercises the local git
-- source end-to-end (content reads, changed-file listing, rename handling,
-- merge-base resolution, and the :Differ picker building a correct DiffModel)
local git_src = require("differ.git")
local rev = require("differ.git.rev")

-- run git in `cwd`, asserting success. identity is pinned inline so commits work
-- in CI without a global gitconfig
local function git(cwd, ...)
    local args =
        { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    local res = vim.system(args, { cwd = cwd, text = true }):wait()
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

-- a fresh repo with one committed file (a.lua = V1) on `main`
local V1 = "local x = 1\nreturn x\n"
local function fresh_repo()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", V1)
    git(root, "add", "a.lua")
    git(root, "commit", "-q", "-m", "init")
    return root
end

describe("git.read / changed_files", function()
    it("reads the committed version and the worktree version", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- uncommitted edit

        local head = { kind = "rev", rev = "HEAD", label = "HEAD" }
        local wt = { kind = "worktree", label = "WORKTREE" }
        assert.are.equal(V1, git_src.read(head, root, "a.lua"))
        assert.are.equal("local x = 2\nreturn x\n", git_src.read(wt, root, "a.lua"))
    end)

    it("returns nil for a path absent on a side (add/delete)", function()
        local root = fresh_repo()
        local head = { kind = "rev", rev = "HEAD", label = "HEAD" }
        assert.is_nil(git_src.read(head, root, "never.lua"))
    end)

    it("lists changed files for the default uncommitted source", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        local files = git_src.changed_files(rev.source({}), root)
        assert.are.same({ { status = "M", path = "a.lua" } }, files)
    end)
end)

describe("git.open_file", function()
    it("reads the rename's old side from previous_path", function()
        local root = fresh_repo()
        git(root, "mv", "a.lua", "b.lua")
        write(root .. "/b.lua", "local x = 2\nreturn x\n")
        git(root, "commit", "-q", "-am", "rename + edit")

        local source = assert(git_src.resolve(rev.source({ "HEAD~1", "HEAD" }), root))
        local v = git_src.open_file(
            source,
            root,
            { status = "R", path = "b.lua", previous_path = "a.lua" }
        )
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal(V1, v.model.old_text) -- a.lua @ HEAD~1
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- b.lua @ HEAD
        v:close()
    end)
end)

describe(":Differ panel", function()
    local Panel = require("differ.panel")

    -- 1-based line of the file row for `path` (optionally pinned to a staged/unstaged
    -- section), located via the panel's meta so tests don't hardcode header offsets
    local function file_line(p, path, staged)
        for i, m in ipairs(p.meta) do
            if
                m.kind == "file"
                and m.entry.path == path
                and (staged == nil or m.entry.staged == staged)
            then
                return i
            end
        end
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

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
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

    -- the panel refreshes on any of these: regaining focus, an in-nvim `:!`, or a
    -- terminal git UI (lazygit) closing in a float (TermClose/TermLeave)
    for _, ev in ipairs({ "FocusGained", "ShellCmdPost", "TermClose", "TermLeave" }) do
        it("refreshes on " .. ev .. " so external git changes appear", function()
            local root = fresh_repo()
            write(root .. "/a.lua", "local x = 2\nreturn x\n")
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
        -- the rename is the first listed file (Staged section), but it diffs to nothing;
        -- the landing skips it for z.lua, the first entry with real content
        assert.are.equal(file_line(p, "z.lua"), p.selected_row)
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.is_not_nil(v)
        assert.are.equal("z.lua", v.model.path)
        require("differ.git").close()
    end)

    it("diffs a staged entry HEAD↔index and an unstaged entry index↔worktree", function()
        local root = fresh_repo()
        -- stage one version of a.lua, then edit further in the worktree
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "local x = 3\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        -- p:select returns focus to the panel, so look the View up via the origin
        -- window's buffer (View.current keys off the focused buffer)
        local function view_in_origin()
            vim.api.nvim_set_current_win(p.origin_win)
            return require("differ.view").current()
        end
        -- a.lua is "MM": it appears in both the Staged and Unstaged sections
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", true), 0 })
        p:select()
        local v = view_in_origin()
        assert.are.equal(V1, v.model.old_text) -- HEAD
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- index

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", false), 0 })
        p:select()
        v = view_in_origin()
        assert.are.equal("local x = 2\nreturn x\n", v.model.old_text) -- index
        assert.are.equal("local x = 3\nreturn x\n", v.model.new_text) -- worktree
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
                and (staged == nil or m.entry.staged == staged)
            then
                return m.entry
            end
        end
    end
    local function file_line(p, path, staged)
        for i, m in ipairs(p.meta) do
            if
                m.kind == "file"
                and m.entry.path == path
                and (staged == nil or m.entry.staged == staged)
            then
                return i
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

    it("discards a tracked file back to HEAD (after confirm)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })

        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.is_nil(entry_of(p, "a.lua")) -- no longer a change
        assert.are.equal(V1, table.concat(vim.fn.readfile(root .. "/a.lua"), "\n") .. "\n")
        p:close()
    end)

    it("discards an untracked file by deleting it", function()
        local root = fresh_repo()
        write(root .. "/u.lua", "untracked\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "u.lua"), 0 })

        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.are.equal(0, vim.fn.filereadable(root .. "/u.lua"))
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

        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.are.equal(0, vim.fn.filereadable(root .. "/src/a.lua")) -- both deleted
        assert.are.equal(0, vim.fn.filereadable(root .. "/src/b.lua"))
        assert.are.equal(1, vim.fn.filereadable(root .. "/top.lua")) -- sibling kept
        p:close()
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

describe(":Differ diff hunk staging", function()
    local Panel = require("differ.panel")

    -- p:select returns focus to the panel, so the View lives in the origin window
    local function view_in_origin(p)
        vim.api.nvim_set_current_win(p.origin_win)
        return require("differ.view").current()
    end
    -- the staged (index) content of `path`
    local function indexed(root, path)
        return git(root, "show", ":" .. path)
    end
    local function worktree(root, path)
        return table.concat(vim.fn.readfile(root .. "/" .. path), "\n") .. "\n"
    end
    local function keymaps(bufnr)
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
            lhs[m.lhs] = true
        end
        return lhs
    end

    it("stages one hunk in place: index updated, worktree kept, diff stays frozen", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two far-apart edits
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("unstaged", v.staging.initial) -- index↔worktree opens unstaged
        assert.are.equal(2, #v.model.hunks) -- two distinct hunks (lines 1 and 8)
        local before = vim.api.nvim_buf_get_lines(v.columns[1].bufnr, 0, -1, false)

        -- cursor on the first hunk (buffer line 1), stage it
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()

        -- the first edit is in the index; the second isn't; the worktree keeps both
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8\n", indexed(root, "a.lua"))
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8x\n", worktree(root, "a.lua"))
        -- the diff didn't vanish or re-source: same hunks, same buffer, hunk 1 marked
        assert.are.equal(2, #v.model.hunks)
        assert.are.same(before, vim.api.nvim_buf_get_lines(v.columns[1].bufnr, 0, -1, false))
        assert.is_true(v.staged_hunks[1])
        assert.is_nil(v.staged_hunks[2])
        p:close()
    end)

    it("unstages a staged hunk in place, then re-stages it", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- whole change staged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("staged", v.staging.initial) -- a staged (HEAD↔index) diff
        assert.is_true(v.staged_hunks[1]) -- opens marked staged
        assert.are.equal("local x = 2\nreturn x\n", indexed(root, "a.lua"))

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:unstage_hunk()
        assert.are.equal(V1, indexed(root, "a.lua")) -- index reverted to HEAD
        assert.is_false(v.staged_hunks[1]) -- now marked unstaged, still visible

        v:stage_hunk() -- u then s on the same hunk: the mark toggles back
        assert.are.equal("local x = 2\nreturn x\n", indexed(root, "a.lua"))
        assert.is_true(v.staged_hunks[1])
        p:close()
    end)

    it("stages an untracked file as one whole-file hunk instead of warning", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "alpha\nbeta\n") -- untracked, the only change
        vim.cmd.edit(root .. "/new.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.is_not_nil(v.staging) -- a new file now offers (whole-file) staging
        assert.are.equal("unstaged", v.staging.initial)
        assert.are.equal(1, #v.model.hunks) -- empty<->content is a single hunk

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()
        assert.are.equal("alpha\nbeta\n", indexed(root, "new.lua")) -- whole file staged
        assert.is_true(v.staged_hunks[1])

        v:unstage_hunk() -- u back: leaves the index, untracked again
        assert.is_false(v.staged_hunks[1])
        local porc = vim.system(
            { "git", "status", "--porcelain", "--", "new.lua" },
            { cwd = root, text = true }
        )
            :wait().stdout
        assert.are.equal("?? new.lua\n", porc)
        p:close()
    end)

    it("re-sources the open diff on an external change, not just the panel list", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua modified
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text)

        -- outside differ: edit the viewed file further, and change git state (stage a
        -- second file) so the signature moves and the refresh fires
        write(root .. "/a.lua", "local x = 99\nreturn x\n")
        write(root .. "/b.lua", "new\n")
        git(root, "add", "b.lua")
        vim.api.nvim_exec_autocmds("FocusGained", { group = p.augroup })
        vim.wait(200, function()
            return v.model.new_text == "local x = 99\nreturn x\n"
        end)

        assert.are.equal("local x = 99\nreturn x\n", v.model.new_text) -- diff re-sourced
        p:close()
    end)

    it("opens on the current file, snapping to the hunk nearest the cursor", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n") -- hunks at lines 1 and 10
        write(root .. "/m.lua", "new\n")
        git(root, "add", "m.lua") -- a staged file that sorts ahead of a.lua

        vim.cmd.edit(root .. "/a.lua")
        vim.api.nvim_win_set_cursor(0, { 10, 0 }) -- near the second hunk

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)

        -- opened a.lua (the current file) though m.lua sorts first in the list
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n", v.model.new_text)
        -- and snapped to the second hunk (nearest the cursor), not the first
        local col = v.columns[#v.columns]
        local row = vim.api.nvim_win_get_cursor(col.winid)[1]
        assert.are.equal(2, col.map.lines[row].hunk)
        p:close()
    end)

    it("re-sources on a worktree-only edit (no status change) via the signature", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua modified
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)

        -- edit only the worktree (status stays " M"): the content-aware signature still
        -- moves, so the diff re-sources where the old HEAD+status signature would miss it
        write(root .. "/a.lua", "local x = 12345\nreturn x\n")
        vim.api.nvim_exec_autocmds("FocusGained", { group = p.augroup })
        vim.wait(200, function()
            return v.model.new_text == "local x = 12345\nreturn x\n"
        end)

        assert.are.equal("local x = 12345\nreturn x\n", v.model.new_text)
        p:close()
    end)

    it("follows a file to its staged side when staged wholesale outside differ", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua modified, unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("unstaged", v.staging.initial) -- viewing the unstaged side

        git(root, "add", "a.lua") -- stage the whole file in "lazygit"
        vim.api.nvim_exec_autocmds("FocusGained", { group = p.augroup })
        vim.wait(200, function()
            return v.staging.initial == "staged"
        end)

        -- the diff followed the file to its staged side rather than going blank
        assert.are.equal("staged", v.staging.initial)
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- HEAD↔index
        p:close()
    end)

    it("offsets later hunks by earlier staged ones (line-count shift)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\nc\nd\n")
        git(root, "commit", "-q", "-am", "abcd")
        -- hunk 1 inserts two lines (changes the line count); hunk 2 edits d
        write(root .. "/a.lua", "a\nINS1\nINS2\nb\nc\nD\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 2, 0 }) -- the insertion hunk
        v:stage_hunk()
        assert.are.equal("a\nINS1\nINS2\nb\nc\nd\n", indexed(root, "a.lua"))

        -- staging hunk 2 now must shift past the +2 lines hunk 1 added, or git apply
        -- would reject the patch (its frozen line numbers are two short)
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 6, 0 }) -- the d -> D hunk
        v:stage_hunk()
        assert.are.equal("a\nINS1\nINS2\nb\nc\nD\n", indexed(root, "a.lua"))
        p:close()
    end)

    it("lands the cursor on the first hunk, not the leading context", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n")
        git(root, "commit", "-q", "-am", "six")
        write(root .. "/a.lua", "1\n2\n3\nX\n5\n6\n") -- only line 4 changes
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        local cur = vim.api.nvim_win_get_cursor(p.origin_win)[1]
        assert.is_not_nil(v.columns[1].map.lines[cur].hunk) -- on a hunk, not context
        assert.are.equal(v:_first_review_line(v.columns[1]), cur)
        p:close()
    end)

    it("lands on the first unstaged hunk, skipping staged ones", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- hunks at lines 1 and 8
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(1, v:_first_review_line(v.columns[1])) -- both unstaged -> hunk 1

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk() -- stage hunk 1; the next place to review is hunk 2 (buffer line 9)
        assert.are.equal(9, v:_first_review_line(v.columns[1]))
        p:close()
    end)

    it("df on a staged diff unstages the file and re-sources to its worktree view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n")
        git(root, "commit", "-q", "-am", "base")
        write(root .. "/a.lua", "1x\n2\n3\n") -- modify
        git(root, "add", "a.lua") -- and stage it (fully staged: worktree == index)
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("INDEX", v.model.new_rev) -- opens on the staged HEAD<->index diff

        v:edit_file() -- flow C: unstage + re-source to index<->worktree
        assert.are.equal("WORKTREE", v.model.new_rev) -- the diff now reflects the worktree
        assert.is_truthy(v.edit_win) -- and the editable window opened
        local staged = git(root, "diff", "--cached", "--name-only") or ""
        assert.is_nil(staged:find("a.lua", 1, true)) -- a.lua is no longer staged
        p:close()
    end)

    it("reviews hunk-by-hunk: s stages then advances, stepping to the next file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- a.lua: two hunks
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)
        -- opened from new-file line 1 (the "1" -> "1x" change), so it lands on that
        -- line's new-side row (row 2, under the deleted old "1"), not the hunk's top
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.origin_win)[1]) -- on hunk 1

        v:stage_hunk() -- stage hunk 1; cursor stays put, marked
        assert.is_true(v.staged_hunks[1])
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.origin_win)[1])

        v:stage_hunk() -- second s: advance to hunk 2 (buffer line 9)
        assert.are.equal(9, vim.api.nvim_win_get_cursor(p.origin_win)[1])

        v:stage_hunk() -- stage hunk 2
        assert.is_true(v.staged_hunks[2])

        v:stage_hunk() -- second s on the last hunk: step to the next file
        assert.are.equal("z.lua", v.model.path)
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        p:close()
    end)

    it("reviews backward: u unstages then retreats, stepping to the previous file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- a.lua: two hunks
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        git(root, "add", "a.lua", "z.lua") -- stage both: a staged (HEAD↔index) review
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        v:step_file("next") -- move forward to z.lua (the last file)
        assert.are.equal("z.lua", v.model.path)

        v:unstage_hunk() -- unstage z.lua's hunk; cursor stays, now unstaged
        assert.is_false(v.staged_hunks[1])

        v:unstage_hunk() -- second u: no earlier hunk -> step back to a.lua's last hunk
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(9, vim.api.nvim_win_get_cursor(p.origin_win)[1]) -- last hunk start
        p:close()
    end)

    it("stages and unstages every hunk with S / U", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\nc\nd\n")
        git(root, "commit", "-q", "-am", "abcd")
        -- an insertion plus a later edit: two hunks, line-count-shifting
        write(root .. "/a.lua", "a\nINS1\nINS2\nb\nc\nD\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)

        v:stage_all() -- both hunks into the index in one go
        assert.are.equal("a\nINS1\nINS2\nb\nc\nD\n", indexed(root, "a.lua"))
        assert.is_true(v.staged_hunks[1])
        assert.is_true(v.staged_hunks[2])

        v:unstage_all() -- back out of the index entirely
        assert.are.equal("a\nb\nc\nd\n", indexed(root, "a.lua")) -- == HEAD
        assert.is_false(v.staged_hunks[1])
        assert.is_false(v.staged_hunks[2])
        p:close()
    end)

    it("S steps to the next file when every hunk is already staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        v:stage_all() -- a.lua now fully staged; we stay put
        assert.are.equal("a.lua", v.model.path)
        v:stage_all() -- nothing left to stage: step to z.lua
        assert.are.equal("z.lua", v.model.path)
        p:close()
    end)

    it("U steps back a file when nothing is staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        v:step_file("next") -- to z.lua (the last file), nothing staged
        assert.are.equal("z.lua", v.model.path)

        v:unstage_all() -- nothing staged here: step back to a.lua, on its last hunk
        assert.are.equal("a.lua", v.model.path)
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        p:close()
    end)

    it("review stepping stops at the list ends, but ]f / [f still wrap", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk, left unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, left unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        -- u / U at the first file with nothing staged: stay put, no wrap to the last
        v:unstage_hunk()
        assert.are.equal("a.lua", v.model.path)
        v:unstage_all()
        assert.are.equal("a.lua", v.model.path)

        v:step_file("next") -- ]f to z.lua (the last file)
        assert.are.equal("z.lua", v.model.path)
        v:step_file("next", false) -- review-style step: no wrap off the last file
        assert.are.equal("z.lua", v.model.path)
        v:step_file("next") -- ]f / [f: wraps to the first
        assert.are.equal("a.lua", v.model.path)
        p:close()
    end)

    it("]c / [c flow into the next / previous file at the boundary hunks", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        v:goto_hunk("next") -- past a.lua's only (last) hunk: flow into z.lua
        assert.are.equal("z.lua", v.model.path)
        -- lands on a real hunk row in the file it stepped into, not just anywhere in it
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        v:goto_hunk("prev") -- before z.lua's only (first) hunk: flow back into a.lua
        assert.are.equal("a.lua", v.model.path)
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        p:close()
    end)

    it("]c flowing forward lands on the new file's first hunk, not line 1", function()
        -- z.lua mirrors a file with a long header before its first real change: 30
        -- lines of context, a small hunk, more context, then a second hunk near the
        -- end. a hunk-at-line-1 fixture can't tell "landed on the first hunk" apart
        -- from "cursor just carried over from wherever it was" -- this one can.
        local root = fresh_repo()
        local base = {}
        for i = 1, 30 do
            base[#base + 1] = "ctx" .. i
        end
        base[#base + 1] = "OLD_A"
        for i = 31, 60 do
            base[#base + 1] = "ctx" .. i
        end
        base[#base + 1] = "OLD_B"
        write(root .. "/z.lua", table.concat(base, "\n") .. "\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")

        local changed = vim.deepcopy(base)
        changed[31] = "NEW_A"
        changed[#changed] = "NEW_B"
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk near the top
        write(root .. "/z.lua", table.concat(changed, "\n") .. "\n") -- z.lua: two hunks
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        v:goto_hunk("next") -- past a.lua's only hunk: flow into z.lua
        assert.are.equal("z.lua", v.model.path)
        local first = v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]]
        assert.are.equal(1, first and first.hunk) -- z.lua's first hunk, not a leftover cursor row

        v:goto_hunk("next") -- z.lua's second hunk, not a skip out to a (nonexistent) next file
        assert.are.equal("z.lua", v.model.path)
        local second = v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]]
        assert.are.equal(2, second and second.hunk)
        p:close()
    end)

    it("binds s/u/S/U in the diff window for a worktree source, not a rev-pair", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local lhs = keymaps(view_in_origin(p).columns[1].bufnr)
        for _, k in ipairs({ "s", "u", "S", "U" }) do
            assert.is_true(lhs[k])
        end
        p:close()

        git(root, "commit", "-q", "-am", "edit") -- now a clean worktree
        git_src.panel({ rev = "HEAD~1..HEAD", open_first = true })
        local p2 = Panel.current()
        local lhs2 = keymaps(view_in_origin(p2).columns[1].bufnr)
        assert.is_nil(lhs2["s"]) -- rev-pair sources aren't stageable
        assert.is_nil(lhs2["u"])
        assert.is_nil(lhs2["S"])
        assert.is_nil(lhs2["U"])
        p2:close()
    end)

    it("binds df only on a worktree-vs-base source, not a `<rev>↔worktree` open", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        -- default `:Differ` is HEAD↔worktree (uncommitted): df is bound
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        assert.is_true(keymaps(view_in_origin(p).columns[1].bufnr)["df"])
        p:close()

        -- commit so the worktree is clean, then `:Differ HEAD~1` is <rev>↔worktree:
        -- it folds in committed history, so edit-in-review must be off (df unbound)
        git(root, "commit", "-q", "-am", "edit")
        git_src.panel({ rev = "HEAD~1", open_first = true })
        local p2 = Panel.current()
        local v2 = view_in_origin(p2)
        assert.are.equal("WORKTREE", v2.model.new_rev) -- new side is the worktree...
        assert.are.equal("HEAD~1", v2.model.old_rev) -- ...but the base is an older rev
        assert.is_nil(keymaps(v2.columns[1].bufnr)["df"])
        assert.is_false(v2:_editable_source())
        p2:close()
    end)
end)

describe(":Differ panel <-> diff wiring", function()
    local Panel = require("differ.panel")

    it("opens with the cursor in the diff window, not the panel", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
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
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()

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
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
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
    local function view_in_origin(p)
        vim.api.nvim_set_current_win(p.origin_win)
        return require("differ.view").current()
    end

    it("opens the panel and the first file's diff (DiffviewOpen-style)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
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

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
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

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
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

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.are.equal("a.lua", v.model.path)

        v:step_file("next") -- ]f past the last file wraps to the first
        assert.are.equal("z.lua", require("differ.view").current().model.path)
        v:step_file("prev") -- [f past the first wraps back to the last
        assert.are.equal("a.lua", require("differ.view").current().model.path)
        p:close()
    end)

    it("git.close tears down the panel and the diff view it drives", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.is_true(p:is_open())
        assert.is_true(v:is_open())

        git_src.close()
        assert.is_nil(Panel.current()) -- panel gone
        assert.is_false(v:is_open()) -- on_close closed the driven view
    end)
end)
