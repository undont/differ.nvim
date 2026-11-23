-- runs under headless nvim against a throwaway git repo: visual s / u / X on a
-- line selection of the diff
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local fresh_repo = helpers.fresh_repo
local file_line = helpers.file_line
local view_in_origin = helpers.view_in_origin
local open_panel = helpers.open_panel
local confirming = helpers.confirming
local indexed = helpers.indexed
local worktree = helpers.worktree
local committed = helpers.committed
local staged_as = helpers.staged_as
local twelve = helpers.twelve
local hunk_line = helpers.hunk_line
local stage_behind = helpers.stage_behind
local paths = helpers.paths

describe(":Differ diff hunk staging", function()
    local Panel = require("differ.panel")

    -- select buffer rows `first`..`last` of `col` and press `keys` (s or u)
    local function visual(col, first, last, keys)
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { first, 0 })
        vim.api.nvim_feedkeys(("V%dG%s"):format(last, keys), "mx", false)
    end
    local function last_said()
        return (_G.notifs[#_G.notifs] or {}).msg or ""
    end

    it("visual s in split takes both halves of a row, and s takes the rest", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_layout()
        assert.are.equal(2, #v.columns)

        local row = v.columns[1].map.from_old[3]
        assert.are.equal(row, v.columns[2].map.from_new[3])
        visual(v.columns[2], row, row, "s")
        assert.are.equal("1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        assert.are.equal("partial", v:_hunk_state(1))

        visual(v.columns[2], row, row, "s")
        assert.is_truthy(last_said():find("already staged", 1, true))
        assert.are.equal("1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))

        v:stage_hunk()
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    it("visual s in stacked can take the added line alone", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.are.equal(1, #v.columns)

        local col = v.columns[1]
        local row = col.map.from_new[3]
        visual(col, row, row, "s")
        assert.are.equal("1\n2\n3\n3x\n4\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        assert.are.equal("partial", v:_hunk_state(1))
        p:close()
    end)

    it("visual u gives back part of a staged hunk", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\n2\n3x\n4x\n5\n6\n7\n8\n9y\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.are.equal("staged", v:_hunk_state(1))

        v:toggle_layout()
        local row = v.columns[1].map.from_old[4]
        visual(v.columns[1], row, row, "u")
        assert.are.equal("1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        assert.are.equal("partial", v:_hunk_state(1))
        assert.are.equal("unstaged", v:_hunk_state(2))
        p:close()
    end)

    it("visual s on a file that stages whole says so and stages nothing", function()
        local root = fresh_repo()
        vim.uv.fs_symlink("a.lua", root .. "/link")
        vim.cmd.edit(root .. "/link")
        local p, v = open_panel()
        assert.are.equal("link", v.model.path)

        local col = v.columns[1]
        visual(col, 1, #col.map.lines, "s")
        assert.is_truthy(last_said():find("stages whole", 1, true))
        assert.are.equal("", git(root, "ls-files", "--", "link"))
        p:close()
    end)

    it("visual X in split reverts both halves of a row", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_layout()

        local row = v.columns[1].map.from_old[3]
        local prompt = confirming(1, function()
            visual(v.columns[2], row, row, "X")
        end)
        assert.are.equal("Revert 2 lines in a.lua?", prompt)
        assert.are.equal("1\n2\n3\n4x\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
        assert.are.equal(committed(root, "a.lua"), indexed(root, "a.lua"))
        assert.are.equal(worktree(root, "a.lua"), v.model.new_text)
        assert.are.equal(1, #v.model.hunks)
        p:close()
    end)

    it("visual X in stacked can put back the deleted line alone", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        local row = col.map.from_old[3]
        confirming(1, function()
            visual(col, row, row, "X")
        end)
        assert.are.equal("1\n2\n3\n3x\n4\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
        assert.are.equal(committed(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    it("visual X drops a selected staged line from the index and the file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.are.equal("partial", v:_hunk_state(1))
        v:toggle_layout()

        local row = v.columns[1].map.from_old[3]
        confirming(1, function()
            visual(v.columns[2], row, row, "X")
        end)
        assert.are.equal("1\n2\n3\n4x\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
        assert.are.equal(committed(root, "a.lua"), indexed(root, "a.lua"))
        assert.are.equal("unstaged", v:_hunk_state(1))
        p:close()
    end)

    it("visual X reverts a selection across two hunks", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2x\n3\n4\n5\n6\n7\n8\n9x\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.are.equal(2, #v.model.hunks)

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_old[2], col.map.from_old[9], "X")
        end)
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8\n9\n9x\n10\n", worktree(root, "a.lua"))
        assert.are.equal(1, #v.model.hunks)
        p:close()
    end)

    -- the diff is -b / +b +c, so c alone goes with the newline b gained
    it("visual X on the line after an unterminated last line keeps b's newline", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb")
        git(root, "add", "a.lua")
        git(root, "commit", "-q", "-m", "unterminated")
        write(root .. "/a.lua", "a\nb\nc")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        local row = col.map.from_new[3]
        confirming(1, function()
            visual(col, row, row, "X")
        end)
        assert.are.equal("a\nb\n", worktree(root, "a.lua"))
        assert.are.equal("a\nb", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual X drops the selected lines from an untracked file", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo\nthree\n")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_new[2], col.map.from_new[2], "X")
        end)
        assert.are.equal("Revert 1 line in new.lua?", prompt)
        assert.are.equal("one\nthree\n", worktree(root, "new.lua"))
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
        p:close()
    end)

    it("visual s on an untracked file stages the selected lines alone", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo\nthree\n")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "s")
        assert.are.equal("two\n", indexed(root, "new.lua"))
        assert.are.equal("one\ntwo\nthree\n", worktree(root, "new.lua"))
        assert.are.equal("100644", git(root, "ls-files", "-s", "--", "new.lua"):match("^%d+"))
        p:close()
    end)

    it(
        "visual s on an untracked file retargets onto the add, where visual u takes lines back",
        function()
            local root = fresh_repo()
            write(root .. "/new.lua", "one\ntwo\nthree\n")
            vim.cmd.edit(root .. "/new.lua")
            local p, v = open_panel()

            local col = v.columns[1]
            visual(col, col.map.from_new[1], col.map.from_new[2], "s")
            assert.are.equal("one\ntwo\n", indexed(root, "new.lua"))
            vim.wait(500, function() -- the retarget runs on a schedule
                return not v.staging.whole_file
            end)
            assert.is_falsy(v.staging.whole_file)
            assert.are.equal("partial", v:_hunk_state(1))

            col = v.columns[1]
            visual(col, col.map.from_new[1], col.map.from_new[1], "u")
            assert.are.equal("two\n", indexed(root, "new.lua"))
            p:close()
        end
    )

    it("visual s on an untracked file keeps the file's executable bit", function()
        local root = fresh_repo()
        write(root .. "/run.sh", "one\ntwo\nthree\n")
        vim.uv.fs_chmod(root .. "/run.sh", tonumber("755", 8))
        vim.cmd.edit(root .. "/run.sh")
        local p, v = open_panel()

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "s")
        assert.are.equal("two\n", indexed(root, "run.sh"))
        assert.are.equal("100755", git(root, "ls-files", "-s", "--", "run.sh"):match("^%d+"))
        p:close()
    end)

    it("visual u on an untracked file has nothing to unstage", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo\nthree\n")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "u")
        assert.is_truthy(last_said():find("already unstaged", 1, true))
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
        p:close()
    end)

    it("visual s on an untracked file edited under the view re-reads and stages nothing", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo\nthree\n")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        write(root .. "/new.lua", "one\ntwo\nthree\nfour\n")

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "s")
        assert.is_truthy(last_said():find("re-reading", 1, true))
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
        p:close()
    end)

    it("visual s on an untracked file's last line keeps it without a newline", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "s")
        assert.are.equal("two", indexed(root, "new.lua"))
        p:close()
    end)

    it("visual X on an untracked file edited under the view re-reads and drops nothing", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo\nthree\n")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        write(root .. "/new.lua", "one\ntwo\nthree\nfour\n")

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_new[2], col.map.from_new[2], "X")
        end)
        assert.is_nil(prompt)
        assert.is_truthy(last_said():find("re-reading", 1, true))
        assert.are.equal("one\ntwo\nthree\nfour\n", worktree(root, "new.lua"))
        p:close()
    end)

    -- each change X takes whole, with no lines of its own to revert
    for _, case in ipairs({
        {
            what = "a deleted file",
            said = "a deleted file has no lines to revert",
            change = function(root)
                os.remove(root .. "/a.lua")
            end,
        },
        {
            what = "a mode change",
            said = "a mode change has no lines to revert",
            change = function(root)
                vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
            end,
        },
        {
            what = "a binary file",
            said = "a binary file has no lines to revert",
            change = function(root)
                write(root .. "/a.lua", "\0bin\0two\n")
            end,
        },
    }) do
        it(("visual X on %s says why it reverts whole"):format(case.what), function()
            local root = fresh_repo()
            write(root .. "/keep.lua", "keep\n") -- an untouched file to open the panel from
            git(root, "add", "keep.lua")
            write(root .. "/a.lua", "\0bin\0one\n")
            git(root, "commit", "-q", "-am", "binary base")
            if case.what ~= "a binary file" then
                write(root .. "/a.lua", "one\ntwo\n")
                git(root, "commit", "-q", "-am", "text base")
            end
            case.change(root)
            vim.cmd.edit(root .. "/keep.lua")
            local p, v = open_panel()

            local col = v.columns[1]
            local prompt = confirming(1, function()
                visual(col, 1, 1, "X")
            end)
            assert.is_nil(prompt)
            assert.is_truthy(last_said():find(case.said, 1, true))
            p:close()
        end)
    end

    local function link(root, path, target)
        os.remove(root .. "/" .. path)
        vim.uv.fs_symlink(target, root .. "/" .. path)
    end
    -- rows that stage whole in each view: s / u / X on a selection name the kind of
    -- row, refuse before any prompt and write nothing
    for _, case in ipairs({
        {
            view = "diff",
            what = "a file gone from disk",
            said = "a file gone from disk has no lines to revert; X deletes the staged file",
            change = function(root)
                git(root, "add", "a.lua")
                os.remove(root .. "/a.lua")
            end,
            added = true,
        },
        {
            view = "diff",
            what = "a type change",
            said = "a type change has no lines to revert; X resets it to HEAD",
            change = function(root)
                link(root, "a.lua", "keep.lua")
            end,
        },
        {
            view = "diff",
            what = "a symlink",
            said = "a symlink has no lines to revert; X deletes the file",
            change = function(root)
                link(root, "a.lua", "keep.lua")
                git(root, "add", "a.lua")
            end,
            added = true,
        },
        {
            view = "diff",
            what = "a symlink",
            said = "a symlink has no lines to revert; X deletes the file",
            change = function(root)
                link(root, "a.lua", "keep.lua")
            end,
            added = true,
            untracked = true,
        },
        {
            view = "dw",
            what = "a type change",
            said = "a type change has no lines to revert; X resets it to the index",
            change = function(root)
                git(root, "add", "a.lua")
                link(root, "a.lua", "keep.lua")
            end,
        },
        {
            view = "dw",
            what = "a binary file",
            said = "a binary file has no lines to revert; X resets it to the index",
            change = function(root)
                git(root, "add", "a.lua")
                write(root .. "/a.lua", "\0bin\0two\n")
            end,
        },
        {
            view = "ds",
            what = "a deleted file",
            said = "a deleted file has no lines to revert; X restores the file",
            change = function(root)
                git(root, "rm", "-q", "a.lua")
            end,
            committed = true,
        },
        {
            view = "ds",
            what = "a file gone from disk",
            said = "a file gone from disk has no lines to revert; X deletes the staged file",
            change = function(root)
                git(root, "add", "a.lua")
                os.remove(root .. "/a.lua")
            end,
            added = true,
        },
        {
            view = "ds",
            what = "a mode change",
            said = "a mode change has no lines to revert; X resets it to HEAD",
            change = function(root)
                vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
                git(root, "add", "a.lua")
            end,
            committed = true,
        },
        {
            view = "ds",
            what = "a type change",
            said = "a type change has no lines to revert; X resets it to HEAD",
            change = function(root)
                link(root, "a.lua", "keep.lua")
                git(root, "add", "a.lua")
            end,
            committed = true,
        },
        {
            view = "ds",
            what = "a symlink",
            said = "a symlink has no lines to revert; X deletes the file",
            change = function(root)
                link(root, "a.lua", "keep.lua")
                git(root, "add", "a.lua")
            end,
            added = true,
        },
    }) do
        local row = case.what
        if case.untracked then
            row = "an untracked symlink"
        end
        it(("visual s / u / X in %s on %s say why"):format(case.view, row), function()
            local root = fresh_repo()
            write(root .. "/keep.lua", "keep\n")
            git(root, "add", "keep.lua")
            if case.added then
                git(root, "rm", "-q", "--cached", "a.lua")
                git(root, "commit", "-q", "-m", "keep only")
            else
                write(root .. "/a.lua", "one\ntwo\n")
                git(root, "commit", "-q", "-am", "base")
                if not case.committed and case.view ~= "diff" then
                    write(root .. "/a.lua", "one\ntwo\nstaged\n") -- dw needs a staged change
                end
            end
            if case.added and not case.untracked and case.view ~= "ds" then
                write(root .. "/a.lua", "added\n")
            end
            case.change(root)
            vim.cmd.edit(root .. "/keep.lua")
            local p, v = open_panel()
            if case.view == "dw" then
                v:toggle_local()
                v = view_in_origin(p)
                assert.are.equal("LOCAL", v.staging.badge)
            elseif case.view == "ds" then
                v:toggle_commit_preview()
                v = view_in_origin(p)
            end
            assert.are.equal("a.lua", v.model.path)
            local before = git(root, "status", "--porcelain=v2") .. git(root, "ls-files", "-s")

            local col = v.columns[#v.columns]
            local said = {}
            local prompt = confirming(1, function()
                for _, key in ipairs({ "s", "u", "X" }) do
                    visual(col, 1, math.max(1, #col.map.lines), key)
                    said[key] = last_said()
                end
            end)
            local after = git(root, "status", "--porcelain=v2") .. git(root, "ls-files", "-s")
            p:close()
            local stages = ("differ: %s stages whole, not by line"):format(case.what)
            assert.are.same({ s = stages, u = stages, X = "differ: " .. case.said }, said)
            assert.is_nil(prompt)
            assert.are.equal(before, after)
        end)
    end

    -- lines 3 and 4 staged, then `work` on disk. putting 3 back leaves the index
    -- changing a line between hunks
    ---@param root string
    ---@param work string
    ---@return differ.Panel, differ.View
    local function put_back(root, work)
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", work)
        vim.cmd.edit(root .. "/a.lua")
        return open_panel()
    end

    it("visual X reverts lines a hidden staged change elsewhere leaves alone", function()
        local root = fresh_repo()
        local p, v = put_back(root, "1\n2\n3\n4\n5\n6\n7\n8\n9y\n10\n")
        assert.is_true(v.staging.hidden)

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[9], col.map.from_new[9], "X")
        end)
        assert.are.equal("Revert 2 lines in a.lua?", prompt)
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
        assert.are.equal("1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual u on lines a hidden staged change leaves alone has nothing to unstage", function()
        local root = fresh_repo()
        local p, v = put_back(root, "1\n2\n3\n4\n5\n6\n7\n8\n9y\n10\n")

        local col = v.columns[1]
        visual(col, col.map.from_old[9], col.map.from_new[9], "u")
        assert.is_truthy(last_said():find("already unstaged", 1, true))
        assert.are.equal("1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual s stages lines a hidden staged change elsewhere leaves alone", function()
        local root = fresh_repo()
        local p, v = put_back(root, "1\n2\n3\n4\n5\n6\n7\n8\n9y\n10\n")

        local col = v.columns[1]
        visual(col, col.map.from_old[9], col.map.from_new[9], "s")
        assert.are.equal("1\n2\n3x\n4x\n5\n6\n7\n8\n9y\n10\n", indexed(root, "a.lua"))
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8\n9y\n10\n", worktree(root, "a.lua"))
        p:close()
    end)

    it("visual s refuses a hunk a hidden staged change meets", function()
        local root = fresh_repo()
        local p, v = put_back(root, "1\n2\n3\n4y\n5\n6\n7\n8\n9\n10\n")

        local col = v.columns[1]
        visual(col, col.map.from_old[4], col.map.from_new[4], "s")
        assert.is_truthy(last_said():find("holds staged content it can't show", 1, true))
        assert.are.equal("1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- a 100-line rewrite of o1..o100 to n1..n100 between 3 and 4, `index` and `work`
    -- written around it
    local function rewritten(index, work)
        local root = fresh_repo()
        local olds, news = {}, {}
        for k = 1, 100 do
            olds[k], news[k] = "o" .. k, "n" .. k
        end
        local old, new = table.concat(olds, "\n"), table.concat(news, "\n")
        write(root .. "/a.lua", "1\n2\n3\n" .. old .. "\n4\n5\n6\n")
        git(root, "commit", "-q", "-am", "long")
        local function filled(text)
            return (text:gsub("OLD", old):gsub("NEW", new))
        end
        write(root .. "/a.lua", filled(index))
        git(root, "add", "a.lua")
        write(root .. "/a.lua", filled(work))
        vim.cmd.edit(root .. "/a.lua")
        return root
    end

    -- the rewrite makes the file too big to read, and a staged 5q the worktree has
    -- undone keeps the index from cutting into blocks
    local function unread_repo()
        return rewritten("1\n2\n3\nOLD\n4\n5q\n6\n", "1\n2x\n3\nNEW\n4\n5\n6\n")
    end

    it("visual s refuses lines in a file too big to read", function()
        local root = unread_repo()
        local p, v = open_panel()
        local before = indexed(root, "a.lua")

        local col = v.columns[1]
        visual(col, col.map.from_old[2], col.map.from_new[2], "s")
        assert.are.equal(
            "differ: this file's changes are too big to stage by line here; stage them from dw",
            last_said()
        )
        assert.are.equal(before, indexed(root, "a.lua"))
        p:close()
    end)

    it("visual X refuses before the prompt in a file too big to read", function()
        local root = unread_repo()
        local p, v = open_panel()
        local before = worktree(root, "a.lua")

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[2], col.map.from_new[2], "X")
        end)
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: this file's changes are too big to revert by line here",
            last_said()
        )
        assert.are.equal(before, worktree(root, "a.lua"))
        p:close()
    end)

    it("hunk s and X refuse in a file too big to read", function()
        local root = unread_repo()
        local p, v = open_panel()
        local index, work = indexed(root, "a.lua"), worktree(root, "a.lua")

        local col = v.columns[1]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:stage_hunk()
        assert.are.equal(
            "differ: this file's changes are too big to stage a hunk here; stage it from dw",
            last_said()
        )
        local prompt = confirming(1, function()
            v:revert_hunk()
        end)
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: this file's changes are too big to revert a hunk here",
            last_said()
        )
        assert.are.equal(index, indexed(root, "a.lua"))
        assert.are.equal(work, worktree(root, "a.lua"))
        p:close()
    end)

    -- the index cuts into blocks, 2y hidden in the first, but the rewrite is still too big
    -- to read
    it("visual s and X refuse a file too big to read whose index cuts into blocks", function()
        local root = rewritten("1\n2y\n3\nOLD\n4\n5\n6\n", "1\n2x\n3\nNEW\n4\n5x\n6\n")
        local p, v = open_panel()
        local index, work = indexed(root, "a.lua"), worktree(root, "a.lua")

        local col = v.columns[1]
        visual(col, col.map.from_old[105], col.map.from_new[105], "s")
        assert.are.equal(
            "differ: this file's changes are too big to stage by line here; stage them from dw",
            last_said()
        )
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[105], col.map.from_new[105], "X")
        end)
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: this file's changes are too big to revert by line here",
            last_said()
        )
        assert.are.equal(index, indexed(root, "a.lua"))
        assert.are.equal(work, worktree(root, "a.lua"))
        p:close()
    end)

    it("dw stages lines of a file too big to read in the union view", function()
        local root = unread_repo()
        local p = open_panel()
        view_in_origin(p):toggle_local()
        local v = view_in_origin(p)

        local col = v.columns[1]
        visual(col, col.map.from_old[2], col.map.from_new[2], "s")
        assert.are.equal("1\n2x\n3\n", indexed(root, "a.lua"):sub(1, 7))
        p:close()
    end)

    -- staged whole, the index cuts into the worktree's blocks, so the file reads
    it("visual s says a fully staged rewrite is already staged", function()
        local root = rewritten("1\n2x\n3\nNEW\n4\n5\n6\n", "1\n2x\n3\nNEW\n4\n5\n6\n")
        local p, v = open_panel()
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")

        local col = v.columns[1]
        visual(col, col.map.from_old[2], col.map.from_new[2], "s")
        assert.are.equal("M  a.lua\n", status)
        assert.are.equal("differ: these lines are already staged", last_said())
        p:close()
    end)

    it("visual u says an unstaged rewrite is already unstaged", function()
        local root = rewritten("1\n2\n3\nOLD\n4\n5\n6\n", "1\n2x\n3\nNEW\n4\n5\n6\n")
        local p, v = open_panel()
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")

        local col = v.columns[1]
        visual(col, col.map.from_old[2], col.map.from_new[2], "u")
        assert.are.equal(" M a.lua\n", status)
        assert.are.equal("differ: these lines are already unstaged", last_said())
        p:close()
    end)

    -- 2x staged and on disk, 5q staged and undone
    local function unread_staged_repo()
        return rewritten("1\n2x\n3\nOLD\n4\n5q\n6\n", "1\n2x\n3\nNEW\n4\n5\n6\n")
    end

    it("visual u and hunk u refuse in a file too big to read", function()
        local root = unread_staged_repo()
        local p, v = open_panel()
        local before = indexed(root, "a.lua")

        local col = v.columns[1]
        visual(col, col.map.from_old[2], col.map.from_new[2], "u")
        assert.are.equal(
            "differ: this file's changes are too big to unstage by line here; unstage them from ds",
            last_said()
        )
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        assert.are.equal(
            "differ: this file's changes are too big to unstage a hunk here; unstage it from ds",
            last_said()
        )
        assert.are.equal(before, indexed(root, "a.lua"))
        p:close()
    end)

    it("ds unstages lines of a file too big to read in the union view", function()
        local root = unread_staged_repo()
        local p = open_panel()
        view_in_origin(p):toggle_commit_preview()
        local v = view_in_origin(p)

        local col = v.columns[1]
        visual(col, col.map.from_old[2], col.map.from_new[2], "u")
        assert.are.equal("1\n2\n3\n", indexed(root, "a.lua"):sub(1, 6))
        p:close()
    end)

    -- HEAD a d d, index a x3 d, worktree a x3 c x5: the unequal hunk's block keeps the
    -- index's x3 above its d
    local function reorder_repo()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nd\nd\n")
        git(root, "commit", "-q", "-am", "repeats")
        write(root .. "/a.lua", "a\nx3\nd\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "a\nx3\nc\nx5\n")
        vim.cmd.edit(root .. "/a.lua")
        return root
    end

    it("visual s stages lines after the index's own, in its order", function()
        local root = reorder_repo()
        local p, v = open_panel()

        local col = v.columns[1]
        visual(col, col.map.from_new[3], col.map.from_new[4], "s")
        assert.are.equal("a\nx3\nd\nc\nx5\n", indexed(root, "a.lua"))
        assert.are.equal("a\nx3\nc\nx5\n", worktree(root, "a.lua"))
        p:close()
    end)

    it("visual u leaves the index's order on lines it doesn't hold", function()
        local root = reorder_repo()
        local p, v = open_panel()

        local col = v.columns[1]
        visual(col, col.map.from_new[3], col.map.from_new[4], "u")
        assert.is_truthy(last_said():find("already unstaged", 1, true))
        assert.are.equal("a\nx3\nd\n", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual X reverts lines the index doesn't hold, leaving its order", function()
        local root = reorder_repo()
        local p, v = open_panel()

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_new[3], col.map.from_new[4], "X")
        end)
        assert.are.equal("Revert 2 lines in a.lua?", prompt)
        assert.are.equal("a\nx3\nd\n", indexed(root, "a.lua"))
        assert.are.equal("a\nx3\n", worktree(root, "a.lua"))
        p:close()
    end)

    -- the restored file has two l18 lines in a row: the diff may mark either as added
    it("visual X reverts among identical lines the diff can pair either way", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "l23\nl2\nl1\nl18\nl31\n")
        git(root, "commit", "-q", "-am", "base")
        write(root .. "/a.lua", "l23\nl2\nl18\nl31\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "l23\nl2\nl18\nl18\nl31\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[3], col.map.from_old[3], "X")
        end)
        assert.are.equal("Revert 1 line in a.lua?", prompt)
        assert.are.equal("l23\nl2\nl1\nl18\nl18\nl31\n", worktree(root, "a.lua"))
        assert.are.equal(committed(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    -- x7 is unstaged already, and the index holds l33 above l12
    it("visual u leaves a held line above a kept one where the index has it", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "l14\nl12\nl9\nl29\n")
        git(root, "commit", "-q", "-am", "base")
        write(root .. "/a.lua", "l14\nl33\nl12\nl9\nl29\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "l14\nl33\nx7\nl9\nl29\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        visual(col, col.map.from_new[3], col.map.from_new[3], "u")
        assert.is_truthy(last_said():find("already unstaged", 1, true))
        assert.are.equal("l14\nl33\nl12\nl9\nl29\n", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual X refuses before the prompt on a hunk a hidden staged change meets", function()
        local root = fresh_repo()
        local p, v = put_back(root, "1\n2\n3\n4y\n5\n6\n7\n8\n9\n10\n")

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[4], col.map.from_new[4], "X")
        end)
        assert.is_nil(prompt)
        assert.is_truthy(last_said():find("holds staged content it can't show", 1, true))
        assert.are.equal("1\n2\n3\n4y\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
        assert.are.equal("1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- repeated lines let the index cut against the hunks more than one way, with
    -- nothing hidden: X takes the cut the view draws
    it("visual X on repeated lines reverts where the view reads them", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\na\nc\n")
        git(root, "commit", "-q", "-am", "repeats")
        write(root .. "/a.lua", "a\nb\na\nc\nc\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "a\nb\nc\nc\nb\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.is_nil(v.staging.hidden)

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, 1, #col.map.lines, "X")
        end)
        assert.are.equal("Revert 3 lines in a.lua?", prompt)
        assert.are.equal("a\nb\na\nc\n", worktree(root, "a.lua"))
        assert.are.equal("a\nb\na\nc\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- line 3 staged as 3x, then edited again on disk to 3y, with `work` on disk after it
    ---@param root string
    ---@param work? string
    ---@return differ.Panel, differ.View
    local function in_dw(root, work)
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", work or "1\n2\n3y\n4\n5\n6\n7\n8\n9y\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_local()
        return p, view_in_origin(p)
    end

    it("visual X in dw puts the selected lines back to the index's text on disk", function()
        local root = fresh_repo()
        local p, v = in_dw(root)
        assert.are.equal("LOCAL", v.staging.badge)

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[9], col.map.from_new[9], "X")
        end)
        assert.are.equal("Revert 2 lines in a.lua?", prompt)
        assert.are.equal("1\n2\n3y\n4\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
        assert.are.equal("1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    it(
        "visual X in dw refuses before the prompt when the file would read back as others",
        function()
            local root = fresh_repo()
            write(root .. "/a.lua", "a\nb\n")
            git(root, "commit", "-q", "-am", "base")
            write(root .. "/a.lua", "a\nb\na\n")
            git(root, "add", "a.lua")
            write(root .. "/a.lua", "x\na\n")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()
            v:toggle_local()
            v = view_in_origin(p)

            local col = v.columns[1]
            local prompt = confirming(1, function()
                visual(col, col.map.from_new[1], col.map.from_new[1], "X")
            end)
            assert.is_nil(prompt)
            assert.is_truthy(last_said():find("without changing others", 1, true))
            assert.are.equal("x\na\n", worktree(root, "a.lua"))
            p:close()
        end
    )

    it("visual X in dw on a file edited under the view re-reads and reverts nothing", function()
        local root = fresh_repo()
        local p, v = in_dw(root)
        write(root .. "/a.lua", "1\n2\n3y\n4\n5\n6\n7\n8z\n9y\n10\n")

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[9], col.map.from_new[9], "X")
        end)
        assert.is_nil(prompt)
        assert.is_truthy(last_said():find("re-reading", 1, true))
        assert.are.equal("1\n2\n3y\n4\n5\n6\n7\n8z\n9y\n10\n", worktree(root, "a.lua"))
        p:close()
    end)

    it("visual s in dw stages the selected row and re-reads the rest", function()
        local root, p =
            staged_as("1\n2\n3\n4\n5\n6\n7\n", "1\nA\nB\nC\nD\nE\n7\n", "1\nA2\n3\n4\nD2\nE2\n7\n")
        local v = view_in_origin(p)
        v:toggle_local()
        v = view_in_origin(p)
        v:toggle_layout()
        assert.are.equal("LOCAL", v.staging.badge)

        local row = v.columns[1].map.from_old[2]
        assert.are.equal(row, v.columns[2].map.from_new[2])
        visual(v.columns[2], row, row, "s")
        assert.are.equal("1\nA2\nB\nC\nD\nE\n7\n", indexed(root, "a.lua"))
        vim.wait(500, function() -- the re-read runs on a schedule
            return v.model.old_text == indexed(root, "a.lua")
        end)
        assert.are.equal("LOCAL", v.staging.badge)
        assert.are.equal("1\nA2\nB\nC\nD\nE\n7\n", v.model.old_text)
        assert.are.equal("unstaged", v:_hunk_state(1))
        p:close()
    end)

    it("visual s in dw refuses lines that would read back as others", function()
        local root, p = staged_as("c\n", "c\nc\na", "c\nb\nb\nc")
        local v = view_in_origin(p)
        v:toggle_local()
        v = view_in_origin(p)

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "s")
        assert.is_truthy(last_said():find("without changing others", 1, true))
        assert.are.equal("c\nc\na", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual s in dw refuses an index staged outside since it opened", function()
        local root, p =
            staged_as("1\n2\n3\n4\n5\n6\n7\n", "1\nA\nB\nC\nD\nE\n7\n", "1\nA2\n3\n4\nD2\nE2\n7\n")
        local v = view_in_origin(p)
        v:toggle_local()
        v = view_in_origin(p)
        stage_behind(root, "1\nA\nB\nC\nD\nE\n7x\n")

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "s")
        assert.is_truthy(last_said():find("re-reading", 1, true))
        assert.are.equal("1\nA\nB\nC\nD\nE\n7x\n", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual s in dw after s on a hunk keeps that hunk staged", function()
        local root, p =
            staged_as(twelve({}), twelve({ "1x" }), twelve({ "1x", [3] = "3x", [12] = "12x" }))
        local v = view_in_origin(p)
        v:toggle_local()
        v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)
        local col = v.columns[1]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:stage_hunk()

        visual(col, col.map.from_new[12], col.map.from_new[12], "s")
        assert.are.equal(twelve({ "1x", [3] = "3x" }) .. "12x\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- 1x staged and then put back to 1 in the worktree: the local hunk undoing it is `!`
    it("visual u in dw on a ! hunk refuses and says which key drops it", function()
        local root, p = staged_as(twelve({}), twelve({ "1x" }), twelve({ [12] = "12x" }))
        local v = view_in_origin(p)
        v:toggle_local()
        v = view_in_origin(p)
        assert.are.same({ 1 }, v.staging.hidden_in)

        local col = v.columns[1]
        visual(col, col.map.from_old[1], col.map.from_new[1], "u")
        assert.are.equal(
            "differ: this hunk holds staged content it can't show; u unstages the whole hunk",
            last_said()
        )
        assert.are.equal(twelve({ "1x" }), indexed(root, "a.lua"))
        p:close()
    end)

    it("visual u in ds unstages the selected row and re-reads the rest", function()
        local root, p =
            staged_as("1\n2\n3\n4\n5\n6\n7\n", "1\nA\nB\nC\nD\nE\n7\n", "1\nA\nB\nC\nD\nE\n7\n")
        local v = view_in_origin(p)
        v:toggle_commit_preview()
        v = view_in_origin(p)
        v:toggle_layout()
        assert.are.equal("STAGED", v.staging.badge)

        local row = v.columns[1].map.from_old[2]
        assert.are.equal(row, v.columns[2].map.from_new[2])
        visual(v.columns[2], row, row, "u")
        assert.are.equal("1\n2\nB\nC\nD\nE\n7\n", indexed(root, "a.lua"))
        assert.are.equal("1\nA\nB\nC\nD\nE\n7\n", worktree(root, "a.lua"))
        vim.wait(500, function() -- the re-read runs on a schedule
            return v.model.new_text == indexed(root, "a.lua")
        end)
        assert.are.equal("STAGED", v.staging.badge)
        assert.are.equal("1\n2\nB\nC\nD\nE\n7\n", v.model.new_text)
        assert.are.equal("staged", v:_hunk_state(1))
        p:close()
    end)

    it("visual u in ds refuses lines it can't take out alone", function()
        local root, p = staged_as("a\na\na\n", "a\nb\na\na\n", "a\nb\na\na\n")
        local v = view_in_origin(p)
        v:toggle_commit_preview()
        v = view_in_origin(p)

        local col = v.columns[1]
        visual(col, col.map.from_old[1], col.map.from_new[1], "u")
        assert.is_truthy(last_said():find("without changing others", 1, true))
        assert.are.equal("a\nb\na\na\n", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual u in ds refuses an index staged outside since it opened", function()
        local root, p =
            staged_as("1\n2\n3\n4\n5\n6\n7\n", "1\nA\nB\nC\nD\nE\n7\n", "1\nA\nB\nC\nD\nE\n7\n")
        local v = view_in_origin(p)
        v:toggle_commit_preview()
        v = view_in_origin(p)
        stage_behind(root, "1\nA\nB\nC\nD\nE\n7x\n")

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "u")
        assert.is_truthy(last_said():find("re-reading", 1, true))
        assert.are.equal("1\nA\nB\nC\nD\nE\n7x\n", indexed(root, "a.lua"))
        p:close()
    end)

    it("visual s in ds after u on a hunk stages lines of it back", function()
        local root, p =
            staged_as(twelve({}), twelve({ "1x", [12] = "12x" }), twelve({ "1x", [12] = "12x" }))
        local v = view_in_origin(p)
        v:toggle_commit_preview()
        v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)
        local col = v.columns[1]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        assert.are.equal(twelve({ [12] = "12x" }), indexed(root, "a.lua"))

        visual(col, col.map.from_old[1], col.map.from_new[1], "s")
        assert.are.equal(twelve({ "1x", [12] = "12x" }), indexed(root, "a.lua"))
        p:close()
    end)

    -- 1x staged and then put back to 1 in the worktree: unstaging it loses 1x
    it("visual u in ds refuses lines the file no longer holds, before any prompt", function()
        local root, p =
            staged_as(twelve({}), twelve({ "1x", [12] = "12x" }), twelve({ [12] = "12x" }))
        local v = view_in_origin(p)
        v:toggle_commit_preview()
        v = view_in_origin(p)

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[1], col.map.from_new[1], "u")
        end)
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: unstaging these lines would drop staged content the file doesn't have; u unstages the whole hunk",
            last_said()
        )
        assert.are.equal(twelve({ "1x", [12] = "12x" }), indexed(root, "a.lua"))

        visual(col, col.map.from_old[12], col.map.from_new[12], "u")
        assert.are.equal(twelve({ "1x" }), indexed(root, "a.lua"))
        p:close()
    end)

    it(
        "visual u in ds takes out a staged line the file still has, beside one it changed",
        function()
            local root, p = staged_as("x\n", "A\nB\nC\n", "A\nB\nC2\n")
            local v = view_in_origin(p)
            v:toggle_commit_preview()
            v = view_in_origin(p)

            local col = v.columns[1]
            visual(col, col.map.from_new[3], col.map.from_new[3], "u")
            assert.are.equal(
                "differ: unstaging these lines would drop staged content the file doesn't have; u unstages the whole hunk",
                last_said()
            )
            assert.are.equal("A\nB\nC\n", indexed(root, "a.lua"))

            visual(col, col.map.from_new[1], col.map.from_new[1], "u")
            assert.are.equal("B\nC\n", indexed(root, "a.lua"))
            assert.are.equal("A\nB\nC2\n", worktree(root, "a.lua"))
            p:close()
        end
    )

    -- the commit preview of a staged_as repo
    local function ds_of(p)
        local v = view_in_origin(p)
        v:toggle_commit_preview()
        return view_in_origin(p)
    end

    it("visual X in ds drops the selected row from the index and the file", function()
        local root, p =
            staged_as("1\n2\n3\n4\n5\n6\n7\n", "1\nA\nB\nC\nD\nE\n7\n", "1\nA\nB\nC\nD\nE\n7\n")
        local v = ds_of(p)
        v:toggle_layout()

        local row = v.columns[1].map.from_old[2]
        local prompt = confirming(1, function()
            visual(v.columns[2], row, row, "X")
        end)
        assert.are.equal("Revert 2 lines in a.lua?", prompt)
        assert.are.equal("1\n2\nB\nC\nD\nE\n7\n", indexed(root, "a.lua"))
        assert.are.equal("1\n2\nB\nC\nD\nE\n7\n", worktree(root, "a.lua"))
        vim.wait(500, function() -- the re-read runs on a schedule
            return v.model.new_text == indexed(root, "a.lua")
        end)
        assert.are.equal("1\n2\nB\nC\nD\nE\n7\n", v.model.new_text)
        assert.are.equal("STAGED", v.staging.badge)
        p:close()
    end)

    -- the file has a line of its own above the selected hunk
    it("visual X in ds reverts the file where its own edits have moved the lines", function()
        local root, p = staged_as(
            twelve({}),
            twelve({ "1x", [12] = "12x" }),
            twelve({ "1x", [6] = "6\nnew", [12] = "12x" })
        )
        local v = ds_of(p)

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_old[12], col.map.from_new[12], "X")
        end)
        assert.are.equal(twelve({ "1x" }), indexed(root, "a.lua"))
        assert.are.equal(twelve({ "1x", [6] = "6\nnew" }), worktree(root, "a.lua"))
        p:close()
    end)

    -- 1x staged and then put back to 1 in the worktree: X takes it out of the index only
    it("visual X in ds moves only the index where the file already put the lines back", function()
        local root, p =
            staged_as(twelve({}), twelve({ "1x", [12] = "12x" }), twelve({ [12] = "12x" }))
        local v = ds_of(p)

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_old[1], col.map.from_new[12], "X")
        end)
        assert.are.equal("Revert 4 lines in a.lua?", prompt)
        assert.are.equal(twelve({}), indexed(root, "a.lua"))
        assert.are.equal(twelve({}), worktree(root, "a.lua"))
        p:close()
    end)

    it("visual X in ds refuses lines the file has changed, before any prompt", function()
        local root, p = staged_as("x\n", "A\nB\nC\n", "A\nB\nC2\n")
        local v = ds_of(p)

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_new[3], col.map.from_new[3], "X")
        end)
        assert.is_nil(prompt)
        assert.are.equal("differ: the file has changed these lines: nothing reverted", last_said())
        assert.are.equal("A\nB\nC\n", indexed(root, "a.lua"))
        assert.are.equal("A\nB\nC2\n", worktree(root, "a.lua"))

        confirming(1, function()
            visual(col, col.map.from_new[1], col.map.from_new[1], "X")
        end)
        assert.are.equal("B\nC\n", indexed(root, "a.lua"))
        assert.are.equal("B\nC2\n", worktree(root, "a.lua"))
        p:close()
    end)

    it(
        "visual X in ds refuses an index staged outside since it opened, before any prompt",
        function()
            local root, p =
                staged_as("1\n2\n3\n4\n5\n6\n7\n", "1\nA\nB\nC\nD\nE\n7\n", "1\nA\nB\nC\nD\nE\n7\n")
            local v = ds_of(p)
            stage_behind(root, "1\nA\nB\nC\nD\nE\n7x\n")

            local col = v.columns[1]
            local prompt = confirming(1, function()
                visual(col, col.map.from_old[2], col.map.from_new[2], "X")
            end)
            assert.is_nil(prompt)
            assert.is_truthy(last_said():find("re-reading", 1, true))
            assert.are.equal("1\nA\nB\nC\nD\nE\n7x\n", indexed(root, "a.lua"))
            assert.are.equal("1\nA\nB\nC\nD\nE\n7\n", worktree(root, "a.lua"))
            p:close()
        end
    )

    it("visual X in ds after u on the hunk reverts only the file", function()
        local root, p =
            staged_as(twelve({}), twelve({ "1x", [12] = "12x" }), twelve({ "1x", [12] = "12x" }))
        local v = ds_of(p)
        local col = v.columns[1]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        assert.are.equal(twelve({ [12] = "12x" }), indexed(root, "a.lua"))

        confirming(1, function()
            visual(col, col.map.from_old[1], col.map.from_new[1], "X")
        end)
        assert.are.equal(twelve({ [12] = "12x" }), indexed(root, "a.lua"))
        assert.are.equal(twelve({ [12] = "12x" }), worktree(root, "a.lua"))
        p:close()
    end)

    -- the file has a line of its own, so a.lua stays listed as unstaged
    local function drifted()
        return staged_as(
            twelve({}),
            twelve({ "1x", [12] = "12x" }),
            twelve({ "1x", [6] = "6\nnew", [12] = "12x" })
        )
    end
    local function said(msg)
        for _, n in ipairs(_G.notifs) do
            if n.msg == msg then
                return true
            end
        end
        return false
    end

    it("visual X in ds over every staged line hands back every change", function()
        local root, p = drifted()
        local v = ds_of(p)
        _G.notifs = {}

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_old[1], col.map.from_new[12], "X")
        end)
        assert.are.equal(twelve({}), indexed(root, "a.lua"))
        assert.are.equal(twelve({ [6] = "6\nnew" }), worktree(root, "a.lua"))
        vim.wait(500, function()
            return view_in_origin(p).staging.badge == nil
        end)
        v = view_in_origin(p)
        assert.is_nil(v.staging.badge)
        assert.are.equal(twelve({ [6] = "6\nnew" }), v.model.new_text)
        assert.is_true(said("differ: nothing staged: back to every change"))
        assert.is_truthy(file_line(p, "a.lua", false))
        p:close()
    end)

    it("visual X in ds over every staged line moves on to the next staged file", function()
        local root, p = drifted()
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        local v = ds_of(p)

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_old[1], col.map.from_new[12], "X")
        end)
        vim.wait(500, function()
            return view_in_origin(p).model.path == "b.lua"
        end)
        v = view_in_origin(p)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("STAGED", v.staging.badge)
        assert.are.same({ "b.lua" }, paths(p))
        p:close()
    end)

    it(
        "visual X in ds on the last staged lines after u on a hunk hands back every change",
        function()
            local root, p = drifted()
            local v = ds_of(p)
            local col = v.columns[1]
            vim.api.nvim_set_current_win(col.winid)
            vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
            v:unstage_hunk()
            _G.notifs = {}

            confirming(1, function()
                visual(col, col.map.from_old[12], col.map.from_new[12], "X")
            end)
            assert.are.equal(twelve({}), indexed(root, "a.lua"))
            assert.are.equal(twelve({ "1x", [6] = "6\nnew" }), worktree(root, "a.lua"))
            vim.wait(500, function()
                return view_in_origin(p).staging.badge == nil
            end)
            assert.is_nil(view_in_origin(p).staging.badge)
            assert.is_true(said("differ: nothing staged: back to every change"))
            p:close()
        end
    )

    local function added_in_ds(index, work)
        local root = fresh_repo()
        write(root .. "/new.lua", index)
        git(root, "add", "new.lua")
        write(root .. "/new.lua", work)
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        return root, p, view_in_origin(p)
    end

    it("visual u in ds takes lines out of an added file", function()
        local root, p, v = added_in_ds("1\n2\n3\n", "1\n2\n3\n")
        assert.is_falsy(v:_whole_file())

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "u")
        assert.are.equal("1\n3\n", indexed(root, "new.lua"))
        assert.are.equal("1\n2\n3\n", worktree(root, "new.lua"))
        p:close()
    end)

    it("visual u in ds on all of an added file takes it out of the index", function()
        local root, p, v = added_in_ds("1\n2\n3\n", "1\n2\n3\n")

        local col = v.columns[1]
        visual(col, col.map.from_new[1], col.map.from_new[3], "u")
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
        assert.are.equal("1\n2\n3\n", worktree(root, "new.lua"))
        p:close()
    end)

    -- staged executable, then chmod -x on disk: emptying the add would lose the mode
    local function added_exec_in_ds(content)
        local root = fresh_repo()
        git(root, "config", "core.fileMode", "true")
        write(root .. "/new.lua", content)
        assert((vim.uv or vim.loop).fs_chmod(root .. "/new.lua", 493))
        git(root, "add", "new.lua")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/new.lua", 420))
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        return root, p, view_in_origin(p)
    end

    it("visual u in ds refuses to empty an add whose mode disk has undone", function()
        local root, p, v = added_exec_in_ds("1\n2\n3\n")

        local col = v.columns[1]
        visual(col, col.map.from_new[1], col.map.from_new[3], "u")
        assert.are.equal(
            "differ: unstaging these lines would drop staged content the file doesn't have; u unstages the whole hunk",
            last_said()
        )
        assert.matches("^100755", git(root, "ls-files", "-s", "--", "new.lua"))
        p:close()
    end)

    it("visual u in ds takes some lines out of an add whose mode disk has undone", function()
        local root, p, v = added_exec_in_ds("1\n2\n3\n")

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "u")
        assert.are.equal("1\n3\n", indexed(root, "new.lua"))
        assert.matches("^100755", git(root, "ls-files", "-s", "--", "new.lua"))
        p:close()
    end)

    it("visual u refuses to empty an add whose mode disk has undone", function()
        local root = fresh_repo()
        git(root, "config", "core.fileMode", "true")
        write(root .. "/new.lua", "1\n2\n3\n")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/new.lua", 493))
        git(root, "add", "new.lua")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/new.lua", 420))
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_new[1], col.map.from_new[3], "u")
        end)
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: unstaging these lines would drop staged content the file doesn't have; u unstages the whole hunk",
            last_said()
        )
        assert.matches("^100755", git(root, "ls-files", "-s", "--", "new.lua"))
        p:close()
    end)

    it("visual u in ds refuses added lines the file no longer holds", function()
        local root, p, v = added_in_ds("1\n2\n3\n", "1\n3\n")

        local col = v.columns[1]
        visual(col, col.map.from_new[2], col.map.from_new[2], "u")
        assert.is_truthy(last_said():find("drop staged content the file doesn't have", 1, true))
        assert.are.equal("1\n2\n3\n", indexed(root, "new.lua"))
        p:close()
    end)

    it(
        "visual X in ds drops the selected lines of an added file from the index and the file",
        function()
            local root, p, v = added_in_ds("1\n2\n3\n", "1\n2\n3\n4\n")

            local col = v.columns[1]
            local prompt = confirming(1, function()
                visual(col, col.map.from_new[2], col.map.from_new[2], "X")
            end)
            assert.are.equal("Revert 1 line in new.lua?", prompt)
            assert.are.equal("1\n3\n", indexed(root, "new.lua"))
            assert.are.equal("1\n3\n4\n", worktree(root, "new.lua"))
            p:close()
        end
    )

    it("visual X in ds on all of an added file takes it out of the index and empties it", function()
        local root, p, v = added_in_ds("1\n2\n3\n", "1\n2\n3\n")

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_new[1], col.map.from_new[3], "X")
        end)
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
        assert.are.equal("", table.concat(vim.fn.readfile(root .. "/new.lua"), "\n"))
        p:close()
    end)

    it("visual X in ds refuses added lines the file has changed, before any prompt", function()
        local root, p, v = added_in_ds("1\n2\n3\n", "1\n2x\n3\n")

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_new[2], col.map.from_new[2], "X")
        end)
        assert.is_nil(prompt)
        assert.are.equal("differ: the file has changed these lines: nothing reverted", last_said())
        assert.are.equal("1\n2\n3\n", indexed(root, "new.lua"))
        assert.are.equal("1\n2x\n3\n", worktree(root, "new.lua"))
        p:close()
    end)

    it("visual X in ds empties an add whose mode disk has undone", function()
        local root, p, v = added_exec_in_ds("1\n2\n3\n")

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_new[1], col.map.from_new[3], "X")
        end)
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
        p:close()
    end)

    -- an add drawn HEAD<->worktree, staged as `index`
    local function added(index, work)
        local root = fresh_repo()
        write(root .. "/new.lua", index)
        git(root, "add", "new.lua")
        write(root .. "/new.lua", work)
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        return root, p, v
    end

    it("visual X on an added file drops a staged line from the index and the file", function()
        local root, p, v = added("1\n2\n3\n", "1\n2\n3\n4\n")

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_new[2], col.map.from_new[2], "X")
        end)
        assert.are.equal("1\n3\n", indexed(root, "new.lua"))
        assert.are.equal("1\n3\n4\n", worktree(root, "new.lua"))
        p:close()
    end)

    it("visual X on all of an added file takes it out of the index and empties it", function()
        local root, p, v = added("1\n2\n3\n", "1\n2\n3\n4\n")

        local col = v.columns[1]
        local prompt = confirming(1, function()
            visual(col, col.map.from_new[1], col.map.from_new[4], "X")
        end)
        assert.are.equal("Revert 4 lines in new.lua?", prompt)
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
        assert.are.equal("", table.concat(vim.fn.readfile(root .. "/new.lua"), "\n"))
        p:close()
    end)

    -- the panel rows listing `path`, as "<section> <x><y>"
    local function rows_of(p, path)
        local out = {}
        for _, sec in ipairs(p.sections) do
            for _, e in ipairs(sec.entries) do
                if e.path == path then
                    out[#out + 1] = ("%s %s%s"):format(sec.title, e.x or "", e.y or "")
                end
            end
        end
        return out
    end
    -- wait for the view in the origin window to satisfy `pred`, and return it
    local function settled_view(p, pred)
        vim.wait(1000, function()
            return pred(view_in_origin(p))
        end)
        return view_in_origin(p)
    end

    it("visual u in ds on all of the only staged add hands back every change", function()
        local _, p, v = added_in_ds("1\n2\n3\n", "1\n2\n3\n")
        _G.notifs = {}

        local col = v.columns[1]
        visual(col, col.map.from_new[1], col.map.from_new[3], "u")
        v = settled_view(p, function(sv)
            return sv.staging.badge == nil
        end)
        assert.is_nil(v.staging.badge)
        assert.are.equal("new.lua", v.model.path)
        assert.are.equal("1\n2\n3\n", v.model.new_text)
        assert.is_true(said("differ: nothing staged: back to every change"))
        assert.are.same({ "Untracked ??" }, rows_of(p, "new.lua"))
        p:close()
    end)

    it("visual u in ds on all of an add moves on to the next staged file", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        write(root .. "/new.lua", "1\n2\n3\n")
        git(root, "add", "new.lua")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        v = view_in_origin(p)
        assert.are.equal("new.lua", v.model.path)

        local col = v.columns[1]
        visual(col, col.map.from_new[1], col.map.from_new[3], "u")
        v = settled_view(p, function(sv)
            return sv.model.path == "b.lua"
        end)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("STAGED", v.staging.badge)
        assert.are.same({ "b.lua" }, paths(p))
        p:close()
    end)

    it("visual X in ds on all of the only staged add hands back every change", function()
        local root, p, v = added_in_ds("1\n2\n3\n", "1\n2\n3\n")
        _G.notifs = {}

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_new[1], col.map.from_new[3], "X")
        end)
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
        v = settled_view(p, function(sv)
            return sv.staging.badge == nil
        end)
        assert.is_nil(v.staging.badge)
        assert.is_true(said("differ: nothing staged: back to every change"))
        assert.are.same({ "Untracked ??" }, rows_of(p, "new.lua"))
        p:close()
    end)

    it("visual X in ds on all of an add moves on to the next staged file", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        write(root .. "/new.lua", "1\n2\n3\n")
        git(root, "add", "new.lua")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        v = view_in_origin(p)
        assert.are.equal("new.lua", v.model.path)

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_new[1], col.map.from_new[3], "X")
        end)
        v = settled_view(p, function(sv)
            return sv.model.path == "b.lua"
        end)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("STAGED", v.staging.badge)
        assert.are.same({ "b.lua" }, paths(p))
        p:close()
    end)

    it("visual X on all of an added file retargets onto the emptied untracked file", function()
        local _, p, v = added("1\n2\n3\n", "1\n2\n3\n")

        local col = v.columns[1]
        local added_staging = v.staging
        confirming(1, function()
            visual(col, col.map.from_new[1], col.map.from_new[3], "X")
        end)
        v = settled_view(p, function(sv)
            return sv.staging ~= added_staging
        end)
        assert.are.equal("new.lua", v.model.path)
        assert.is_true(v.staging.whole_file)
        assert.are.equal("unstaged", v.staging.initial)
        assert.are.equal("", v.model.new_text)
        assert.are.equal(0, #v.model.hunks)
        assert.are.same({ "Untracked ??" }, rows_of(p, "new.lua"))
        p:close()
    end)

    it(
        "visual u on the only staged lines of an add retargets back onto the untracked file",
        function()
            local root = fresh_repo()
            write(root .. "/new.lua", "one\ntwo\nthree\n")
            vim.cmd.edit(root .. "/new.lua")
            local p, v = open_panel()
            local col = v.columns[1]
            visual(col, col.map.from_new[2], col.map.from_new[2], "s")
            v = settled_view(p, function(sv)
                return not sv.staging.whole_file and sv:_hunk_state(1) == "partial"
            end)
            assert.are.same({ "Partial AM" }, rows_of(p, "new.lua"))

            col = v.columns[1]
            local added_staging = v.staging
            visual(col, col.map.from_new[2], col.map.from_new[2], "u")
            assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
            v = settled_view(p, function(sv)
                return sv.staging ~= added_staging
            end)
            assert.are.same({ "Untracked ??" }, rows_of(p, "new.lua"))
            assert.are.equal("unstaged", v:_hunk_state(1))

            -- the untracked file's own staging: s creates the index entry again
            col = v.columns[1]
            visual(col, col.map.from_new[1], col.map.from_new[1], "s")
            assert.are.equal("one\n", indexed(root, "new.lua"))
            p:close()
        end
    )

    -- the +/- the commit preview's panel lists for `path`
    local function staged_counts(p, path)
        for _, e in ipairs(p.sections[1].entries) do
            if e.path == path then
                return { e.additions, e.deletions }
            end
        end
    end

    it("visual u in ds on some lines updates the panel's counts and keeps the view", function()
        local root, p =
            staged_as(twelve({}), twelve({ "1x", [12] = "12x" }), twelve({ "1x", [12] = "12x" }))
        local v = ds_of(p)
        assert.are.same({ 2, 2 }, staged_counts(p, "a.lua"))

        local col = v.columns[1]
        visual(col, col.map.from_old[1], col.map.from_new[1], "u")
        assert.are.equal(twelve({ [12] = "12x" }), indexed(root, "a.lua"))
        v = settled_view(p, function(sv)
            return sv.model.new_text == twelve({ [12] = "12x" })
        end)
        assert.are.equal("STAGED", v.staging.badge)
        assert.are.equal("a.lua", v.model.path)
        assert.are.same({ 1, 1 }, staged_counts(p, "a.lua"))
        p:close()
    end)

    it("visual X in ds on some lines updates the panel's counts and keeps the view", function()
        local root, p =
            staged_as(twelve({}), twelve({ "1x", [12] = "12x" }), twelve({ "1x", [12] = "12x" }))
        local v = ds_of(p)

        local col = v.columns[1]
        confirming(1, function()
            visual(col, col.map.from_old[1], col.map.from_new[1], "X")
        end)
        assert.are.equal(twelve({ [12] = "12x" }), indexed(root, "a.lua"))
        v = settled_view(p, function(sv)
            return sv.model.new_text == twelve({ [12] = "12x" })
        end)
        assert.are.equal("STAGED", v.staging.badge)
        assert.are.equal("a.lua", v.model.path)
        assert.are.same({ 1, 1 }, staged_counts(p, "a.lua"))
        p:close()
    end)

    -- a real confirm reads typeahead, so a queued key would answer it
    it("visual X asks in normal mode with nothing left in typeahead", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        local row = col.map.from_new[3]
        local mode, pending
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            mode = vim.api.nvim_get_mode().mode
            pending = vim.fn.getcharstr(0)
            return 1
        end
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { row, 0 })
        -- `!`: without it the `x` flag queues an <Esc> of its own
        local ok, err = pcall(vim.api.nvim_feedkeys, ("V%dGX"):format(row), "mx!", false)
        vim.fn.confirm = orig
        assert(ok, err)

        assert.are.equal("n", mode)
        assert.are.equal("", pending)
        assert.are.equal("1\n2\n4\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
        p:close()
    end)

    it("visual X reverts nothing when the diff is re-read under the prompt", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()

        local col = v.columns[1]
        local row = col.map.from_new[3]
        local edited = "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10y\n"
        local asked_on, swapped = v.model, false
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            write(root .. "/a.lua", edited)
            p:refresh()
            vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
            p:select()
            swapped = v.model ~= asked_on
            return 1
        end
        local ok, err = pcall(visual, col, row, row, "X")
        vim.fn.confirm = orig
        assert(ok, err)

        assert.is_true(swapped)
        assert.are.equal(edited, worktree(root, "a.lua"))
        assert.is_truthy(last_said():find("nothing was changed", 1, true))
        p:close()
    end)

    describe("on a last line and its ending", function()
        local function on_disk(root)
            local f = assert(io.open(root .. "/a.lua", "rb"))
            local text = f:read("*a")
            f:close()
            return text
        end

        it("visual u on one row of a newline change says why and unstages nothing", function()
            local root = fresh_repo()
            write(root .. "/a.lua", "a\nb")
            git(root, "add", "a.lua")
            git(root, "commit", "-q", "-m", "unterminated")
            write(root .. "/a.lua", "a\nb\n")
            git(root, "add", "a.lua")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()

            local col = v.columns[1]
            local row = col.map.from_new[2]
            visual(col, row, row, "u")
            assert.is_truthy(last_said():find("are one change; select both rows", 1, true))
            assert.are.equal("a\nb\n", indexed(root, "a.lua"))
            p:close()
        end)

        -- HEAD b, index and worktree b e: b's missing newline can't come back above e
        it("visual u on b's newline change alone says why and unstages nothing", function()
            local root = fresh_repo()
            write(root .. "/a.lua", "b")
            git(root, "add", "a.lua")
            git(root, "commit", "-q", "-m", "unterminated")
            write(root .. "/a.lua", "b\ne\n")
            git(root, "add", "a.lua")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()

            local col = v.columns[1]
            visual(col, col.map.from_old[1], col.map.from_new[1], "u")
            assert.is_truthy(
                last_said():find(
                    "unstaging these lines would leave a line with no newline above others; select the lines after it too",
                    1,
                    true
                )
            )
            assert.are.equal("b\ne\n", indexed(root, "a.lua"))
            p:close()
        end)

        -- HEAD and index b, worktree b e: e can't be staged after b's missing newline
        it("visual s on a line after the unterminated last line says why", function()
            local root = fresh_repo()
            write(root .. "/a.lua", "b")
            git(root, "add", "a.lua")
            git(root, "commit", "-q", "-m", "unterminated")
            write(root .. "/a.lua", "b\ne\n")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()

            local col = v.columns[1]
            local row = col.map.from_new[2]
            visual(col, row, row, "s")
            assert.is_truthy(
                last_said():find(
                    "staging these lines would leave a line with no newline above others; select its newline change too",
                    1,
                    true
                )
            )
            assert.are.equal("b", indexed(root, "a.lua"))
            p:close()
        end)

        -- HEAD a b c, worktree a b unterminated: c can't come back after b
        it(
            "visual X on a line after the unterminated last line refuses before the prompt",
            function()
                local root = fresh_repo()
                write(root .. "/a.lua", "a\nb\nc\n")
                git(root, "add", "a.lua")
                git(root, "commit", "-q", "-m", "three lines")
                write(root .. "/a.lua", "a\nb")
                vim.cmd.edit(root .. "/a.lua")
                local p, v = open_panel()

                local col = v.columns[1]
                local row = col.map.from_old[3]
                local prompt = confirming(1, function()
                    visual(col, row, row, "X")
                end)
                assert.is_nil(prompt)
                assert.is_truthy(
                    last_said():find(
                        "reverting these lines would leave a line with no newline above others; select its newline change too",
                        1,
                        true
                    )
                )
                assert.are.equal("a\nb", on_disk(root))
                p:close()
            end
        )

        it("visual X in dw on one row of a newline change refuses before the prompt", function()
            local root = fresh_repo()
            write(root .. "/a.lua", "a\nb")
            git(root, "add", "a.lua")
            git(root, "commit", "-q", "-m", "unterminated")
            write(root .. "/a.lua", "a\nb\n")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()
            v:toggle_local()
            v = view_in_origin(p)

            local col = v.columns[1]
            local row = col.map.from_new[2]
            local prompt = confirming(1, function()
                visual(col, row, row, "X")
            end)
            assert.is_nil(prompt)
            assert.is_truthy(last_said():find("are one change; select both rows", 1, true))
            assert.are.equal("a\nb\n", on_disk(root))
            p:close()
        end)
    end)
end)
