-- runs under headless nvim against a throwaway git repo: staging a file that only
-- stages as a unit
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local fresh_repo = helpers.fresh_repo
local view_in_origin = helpers.view_in_origin
local open_panel = helpers.open_panel
local confirming = helpers.confirming

-- a whole-file source (a new or deleted file, a binary one, a change with no lines
-- to show) stages as a unit. the keys act on the file rather than on the hunk under
-- the cursor, which is what used to send them stepping off to another file
describe(":Differ diff whole-file staging", function()
    local Panel = require("differ.panel")

    -- the mode git records for `path` in the index
    local function index_mode(root, path)
        return (git(root, "ls-files", "--stage", "--", path):match("^(%d+)"))
    end
    local function staged_entry(p, path)
        for _, m in ipairs(p.meta) do
            if m.kind == "file" and m.entry.path == path and m.entry.y == " " then
                return m.entry
            end
        end
    end

    it("stages a mode-only change with s instead of stepping to another file", function()
        local root = fresh_repo()
        git(root, "config", "core.fileMode", "true")
        write(root .. "/b.lua", "other\n") -- a second file, to catch a step away
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "two files")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/a.lua", 493))
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(0, #v.model.hunks) -- nothing to put a cursor on
        assert.is_true(v.staging.whole_file)
        assert.are.equal("100644", index_mode(root, "a.lua"))

        v:stage_hunk()

        assert.are.equal("100755", index_mode(root, "a.lua")) -- the mode really staged
        assert.is_not_nil(staged_entry(p, "a.lua"))
        assert.are.equal("a.lua", view_in_origin(p).model.path) -- never stepped away
        p:close()
    end)

    it("unstages a staged mode change with u, which needs its seeded staged state", function()
        local root = fresh_repo()
        git(root, "config", "core.fileMode", "true")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/a.lua", 493))
        git(root, "add", "a.lua") -- stage the mode change: the only entry is staged
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("staged", v:_hunk_state(1)) -- seeded with no hunk behind it
        assert.are.equal("100755", index_mode(root, "a.lua"))

        v:unstage_hunk()

        assert.are.equal("100644", index_mode(root, "a.lua"))
        p:close()
    end)

    it("stages a new file from the old column's filler rows in split layout", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo\n") -- untracked: a pure add
        write(root .. "/b.lua", "other\n") -- a second entry, to catch a step away
        vim.cmd.edit(root .. "/new.lua")

        local p, v = open_panel()
        assert.are.equal("new.lua", v.model.path)
        v:toggle_layout() -- -> split; the old column is all filler
        assert.are.equal(2, #v.columns)

        -- a pure add carries no old lines, so every old-column row is filler; the row
        -- still resolves to the add through the new column
        vim.api.nvim_set_current_win(v.columns[1].winid)
        vim.api.nvim_win_set_cursor(v.columns[1].winid, { 1, 0 })
        assert.are.equal(1, v:_hunk_index_under_cursor())

        v:stage_hunk()

        assert.are.equal("one\ntwo\n", git(root, "show", ":new.lua"))
        assert.is_not_nil(staged_entry(p, "new.lua"))
        p:close()
    end)

    it("advertises the file, not the hunk, in the diff help", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\n")
        vim.cmd.edit(root .. "/new.lua")

        local p, v = open_panel()
        assert.is_true(v.staging.whole_file)
        v:show_help()
        local help_buf = vim.api.nvim_win_get_buf(0)
        local text = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("stage / unstage file", 1, true))
        assert.is_nil(text:find("stage / unstage hunk", 1, true))
        vim.api.nvim_win_close(0, true)
        p:close()
    end)

    -- the commit preview draws a staged mode change as a notice, so there's no hunk
    -- under the cursor for X to find, and the whole-file slot is what it acts on
    it("reverts a zero-hunk commit-preview row with X", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        vim.fn.system({ "chmod", "+x", root .. "/b.lua" })
        git(root, "add", "b.lua")
        vim.cmd.edit(root .. "/b.lua")

        local p, v = open_panel()
        v:toggle_commit_preview()
        v = view_in_origin(p)
        assert.are.equal("STAGED", v.staging.badge)
        assert.are.equal(0, #v.model.hunks)
        confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("", status)
        assert.are.equal("100644", index_mode(root, "b.lua"))
    end)

    -- the preview letters a row by its index side, so discard has to be told which
    -- listing the entry came from or it reads the row as changed under the prompt
    it("reverts a staged rename whose file is gone from the commit preview", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\ntwo\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        git(root, "mv", "b.lua", "c.lua")
        os.remove(root .. "/c.lua")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        assert.is_true(Panel.current():goto_path("c.lua", true))
        local v = view_in_origin(p)
        v:toggle_commit_preview()
        v = view_in_origin(p)
        assert.are.equal(0, #v.model.hunks)
        confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("", status)
    end)

    -- a staged deletion whose file is still on disk untracked: X can't put HEAD's copy
    -- back over it, and says so instead of asking first
    it("refuses X on a kept deletion without prompting", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        git(root, "rm", "-q", "--cached", "b.lua")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        assert.is_true(Panel.current():goto_path("b.lua", true))
        local v = view_in_origin(p)
        assert.is_nil(v.staging.revert)
        local prompt = confirming(1, function()
            v:revert_hunk()
        end)
        local said = _G.notifs[#_G.notifs].msg
        p:close()
        assert.is_nil(prompt)
        assert.is_truthy(said:find("on disk; u unstages the deletion instead", 1, true))
    end)

    -- a file swapped for a symlink has one content hunk but no line-level change to
    -- take, so it stages as a file and X puts HEAD's own kind of file back
    it("stages and reverts a typechange row as a whole file", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "a plain file\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        os.remove(root .. "/b.lua")
        vim.fn.system({ "ln", "-s", "a.lua", root .. "/b.lua" })
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        assert.is_true(Panel.current():goto_path("b.lua", true))
        local v = view_in_origin(p)
        assert.is_true(v.staging.whole_file)
        v:stage_hunk()
        assert.are.equal("120000", index_mode(root, "b.lua"))
        confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("", status)
    end)

    -- b.lua staged as `from` over HEAD's plain file (nil for an add), then swapped on
    -- disk for a symlink: an MT or AT row
    local function typechanged_over_staged(from)
        local root = fresh_repo()
        if from then
            write(root .. "/b.lua", "a plain file\n")
            git(root, "add", "b.lua")
            git(root, "commit", "-q", "-m", "b")
        end
        write(root .. "/b.lua", "staged content\n")
        git(root, "add", "b.lua")
        os.remove(root .. "/b.lua")
        vim.fn.system({ "ln", "-s", "a.lua", root .. "/b.lua" })
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(Panel.current():goto_path("b.lua", true))
        return root, p, view_in_origin(p)
    end

    it("stages an MT row as a whole file", function()
        local root, p, v = typechanged_over_staged(true)
        local before = git(root, "status", "--porcelain=v1", "--", "b.lua")
        assert.is_true(v.staging.whole_file)
        v:stage_hunk()
        p:close()
        assert.are.equal("MT b.lua\n", before)
        assert.are.equal("120000", index_mode(root, "b.lua"))
    end)

    it("reverts an MT row to HEAD's file", function()
        local root, p, v = typechanged_over_staged(true)
        local prompt = confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.is_truthy(prompt)
        assert.are.equal("", status)
    end)

    it("stages an MT row whole from its local view", function()
        local root, p, v = typechanged_over_staged(true)
        v:toggle_local()
        v = view_in_origin(p)
        assert.are.equal("LOCAL", v.staging.badge)
        assert.is_true(v.staging.whole_file)
        v:stage_hunk()
        p:close()
        assert.are.equal("120000", index_mode(root, "b.lua"))
    end)

    it("stages an AT row as a whole file", function()
        local root, p, v = typechanged_over_staged(nil)
        local before = git(root, "status", "--porcelain=v1", "--", "b.lua")
        assert.is_true(v.staging.whole_file)
        v:stage_hunk()
        p:close()
        assert.are.equal("AT b.lua\n", before)
        assert.are.equal("120000", index_mode(root, "b.lua"))
    end)

    it("stages an RT row as a whole file and leaves X to the panel row", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "a plain file\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        git(root, "mv", "b.lua", "c.lua")
        os.remove(root .. "/c.lua")
        vim.fn.system({ "ln", "-s", "a.lua", root .. "/c.lua" })
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        local before = git(root, "status", "--porcelain=v1", "--", "b.lua", "c.lua")
        assert.is_true(Panel.current():goto_path("c.lua", true))
        local v = view_in_origin(p)
        assert.is_true(v.staging.whole_file)
        _G.notifs = {}
        local prompt = confirming(1, function()
            v:revert_hunk()
        end)
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local after_x = git(root, "status", "--porcelain=v1", "--", "b.lua", "c.lua")
        v:stage_hunk()
        local mode = index_mode(root, "c.lua")
        local old = git(root, "ls-files", "--", "b.lua")
        p:close()
        assert.are.equal("RT b.lua -> c.lua\n", before)
        assert.is_nil(prompt)
        assert.are.equal("differ: X on the panel row undoes the move", said)
        assert.are.equal(before, after_x)
        assert.are.equal("120000", mode)
        assert.are.equal("", old)
    end)
end)
