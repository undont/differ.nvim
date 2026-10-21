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

describe(":Differ diff hunk staging", function()
    local Panel = require("differ.panel")

    -- a spec that aborts before its p:close() would otherwise leak its panel into every
    -- spec after it, and the count would name them all rather than the one that broke
    after_each(function()
        local open = Panel.current()
        if open then
            open:close()
        end
    end)

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
        write(root .. "/new.lua", "one\ntwo\n")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        assert.are.equal("new.lua", v.model.path)

        local col = v.columns[1]
        visual(col, 1, #col.map.lines, "s")
        assert.is_truthy(last_said():find("stages whole", 1, true))
        assert.are.equal("", git(root, "ls-files", "--", "new.lua"))
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
        assert.is_truthy(last_said():find("can't be staged on their own", 1, true))
        assert.are.equal("1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- the unequal hunk's block rebuilt old lines first would move the index's x3 after
    -- its d: the texts read back as other marks, so nothing is written
    for _, key in ipairs({ "s", "u", "X" }) do
        it(("visual %s refuses lines that would read back as others"):format(key), function()
            local root = fresh_repo()
            write(root .. "/a.lua", "a\nd\nd\n")
            git(root, "commit", "-q", "-am", "repeats")
            write(root .. "/a.lua", "a\nx3\nd\n")
            git(root, "add", "a.lua")
            write(root .. "/a.lua", "a\nx3\nc\nx5\n")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()

            local col = v.columns[1]
            local prompt = confirming(1, function()
                visual(col, col.map.from_new[3], col.map.from_new[4], key)
            end)
            assert.is_nil(prompt)
            assert.is_truthy(last_said():find("without changing others", 1, true))
            assert.are.equal("a\nx3\nd\n", indexed(root, "a.lua"))
            assert.are.equal("a\nx3\nc\nx5\n", worktree(root, "a.lua"))
            p:close()
        end)
    end

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

    -- x7 is unstaged already, and the block rebuilt old lines first would move the
    -- index's l33 after l12
    it("visual u refuses rather than reorder the index", function()
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
        assert.is_truthy(last_said():find("without changing others", 1, true))
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
        assert.is_truthy(last_said():find("only dw shows", 1, true))
        assert.are.equal("1\n2\n3\n4y\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
        assert.are.equal("1\n2\n3x\n4x\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- repeated lines let the index cut against the hunks more than one way, with
    -- nothing hidden
    it("visual X on repeated lines refuses without naming a hidden change", function()
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
        assert.is_nil(prompt)
        assert.is_truthy(last_said():find("can't be reverted on their own", 1, true))
        assert.are.equal("a\nb\nc\nc\nb\n", worktree(root, "a.lua"))
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

    for _, case in ipairs({
        { key = "ds", toggle = "toggle_commit_preview" },
    }) do
        it(("visual X in %s says to go back and reverts nothing"):format(case.key), function()
            local root = fresh_repo()
            write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
            git(root, "commit", "-q", "-am", "ten lines")
            write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
            git(root, "add", "a.lua")
            write(root .. "/a.lua", "1\n2\n3y\n4\n5\n6\n7\n8\n9\n10\n")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()
            v[case.toggle](v)
            v = view_in_origin(p)

            local col = v.columns[1]
            local prompt = confirming(1, function()
                visual(col, 1, #col.map.lines, "X")
            end)
            assert.is_nil(prompt)
            assert.is_truthy(last_said():find(case.key .. " goes back", 1, true))
            assert.are.equal("1\n2\n3y\n4\n5\n6\n7\n8\n9\n10\n", worktree(root, "a.lua"))
            assert.are.equal("1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
            p:close()
        end)
    end

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
end)
