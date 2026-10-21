-- runs under headless nvim against a throwaway git repo: X reverting hunks and
-- files from the diff, and where the session lands after
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local V1 = helpers.V1
local fresh_repo = helpers.fresh_repo
local file_line = helpers.file_line
local view_in_origin = helpers.view_in_origin
local open_panel = helpers.open_panel
local confirming = helpers.confirming
local indexed = helpers.indexed
local worktree = helpers.worktree
local committed = helpers.committed
local hunk_line = helpers.hunk_line

describe(":Differ diff hunk staging", function()
    local Panel = require("differ.panel")

    -- on a two-row file X refuses a staged hunk, since reverting only the worktree copy
    -- would leave index and worktree differing the opposite way round. a union row has
    -- both sides in one diff, so it takes them both and the refusal doesn't apply
    it("X on a staged union hunk drops it from the index and the worktree", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n")

        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.are.equal("staged", v:_hunk_state(1))

        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        -- the line-1 change is gone from both sides; the line-10 one is untouched
        assert.are.equal(committed(root, "a.lua"), indexed(root, "a.lua"))
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n", worktree(root, "a.lua"))
        assert.are.equal(1, #v.model.hunks)
        assert.are.equal("unstaged", v:_hunk_state(1)) -- the marks followed the splice
        p:close()
    end)

    it("reverts one hunk from the worktree, leaving the others and the index", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 }) -- the 1 -> 1x hunk
        confirming(1, function()
            v:revert_hunk()
        end)

        -- the first edit is gone from disk, the second survives, the index never moved
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8x\n", worktree(root, "a.lua"))
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8\n", indexed(root, "a.lua"))
        -- the model was spliced, not re-read: one hunk left, and it's the survivor
        assert.are.equal(1, #v.model.hunks)
        assert.are.same({ "8x" }, v.model.hunks[1].new_lines)
        p:close()
    end)

    it("leaves the worktree alone when the confirm is declined", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(2, function() -- "No"
            v:revert_hunk()
        end)

        assert.are.equal("local x = 2\nreturn x\n", worktree(root, "a.lua"))
        assert.are.equal(1, #v.model.hunks)
        p:close()
    end)

    -- confirm() drains scheduled callbacks while it blocks, so a watcher fire can
    -- re-source the view between the prompt and the revert. the stub stands in for that
    -- drain by doing what refresh_external ends at: a set_source under the open prompt
    it("reverts nothing when the same file is re-sourced under the prompt", function()
        local root = fresh_repo()
        local base = {}
        for i = 1, 30 do
            base[i] = ("line%02d"):format(i)
        end
        write(root .. "/a.lua", table.concat(base, "\n") .. "\n")
        git(root, "commit", "-q", "-am", "30 lines")
        local edited = vim.deepcopy(base)
        edited[5], edited[15], edited[25] = "CHANGED05", "CHANGED15", "CHANGED25"
        write(root .. "/a.lua", table.concat(edited, "\n") .. "\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(3, #v.model.hunks)
        local asked_on = v.model

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 }) -- the CHANGED15 hunk

        _G.notifs = {}
        local swapped -- read inside the stub, so it holds however the revert goes on
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            -- the first hunk goes away outside differ, so hunk 2 is now CHANGED25
            local dropped = vim.deepcopy(edited)
            dropped[5] = base[5]
            write(root .. "/a.lua", table.concat(dropped, "\n") .. "\n")
            p:refresh()
            vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
            p:select()
            swapped = v.model ~= asked_on
            return 1
        end
        local ok, err = pcall(function()
            v:revert_hunk()
        end)
        vim.fn.confirm = orig
        assert(ok, err)

        assert.is_true(swapped) -- the re-source landed, so this isn't vacuous
        local after = worktree(root, "a.lua")
        assert.is_not_nil(after:find("CHANGED15", 1, true)) -- the hunk the prompt named
        assert.is_not_nil(after:find("CHANGED25", 1, true)) -- the one index 2 slid onto
        assert.are.equal(
            "differ: the diff changed while the prompt was up; nothing was reverted",
            _G.notifs[#_G.notifs].msg
        )
        p:close()
    end)

    -- when the shown file goes clean mid-prompt the watcher hands the window to another
    -- file, and revert is path-agnostic: it would patch whatever model it was handed
    it("reverts nothing when a different file is re-sourced under the prompt", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "local z = 9\nreturn z\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-m", "add z")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/z.lua", "local z = 99\nreturn z\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })

        _G.notifs = {}
        local swapped_to -- read inside the stub, so it holds however the revert goes on
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "z.lua"), 0 })
            p:select()
            swapped_to = v.model.path
            return 1
        end
        local ok, err = pcall(function()
            v:revert_hunk()
        end)
        vim.fn.confirm = orig
        assert(ok, err)

        assert.are.equal("z.lua", swapped_to) -- the re-source landed
        -- the prompt named a.lua, so z.lua was never in the question
        assert.are.equal("local z = 99\nreturn z\n", worktree(root, "z.lua"))
        assert.are.equal("local x = 2\nreturn x\n", worktree(root, "a.lua"))
        assert.are.equal(
            "differ: the diff changed while the prompt was up; nothing was reverted",
            _G.notifs[#_G.notifs].msg
        )
        p:close()
    end)

    it("reverts a staged hunk out of the index and the worktree together", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        git(root, "add", "a.lua") -- both edits staged; the worktree matches the index
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        -- gone from both sides, so the file has no unstaged residue to clean up
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8x\n", indexed(root, "a.lua"))
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8x\n", worktree(root, "a.lua"))
        assert.are.equal(1, #v.model.hunks)
        p:close()
    end)

    -- the diff has both sides of a hunk staged during the session, so X takes it out of
    -- the index and the worktree together rather than leaving them differing
    it("reverts a hunk staged during the session from both sides", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()
        assert.are.equal("staged", v:_hunk_state(1))

        confirming(1, function()
            v:revert_hunk()
        end)
        assert.are.equal(committed(root, "a.lua"), indexed(root, "a.lua"))
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8x\n", worktree(root, "a.lua"))
        assert.are.equal(1, #v.model.hunks)
        assert.are.equal("unstaged", v:_hunk_state(1))
        p:close()
    end)

    -- a new file's content is its only hunk, so reverting it deletes the file; the
    -- confirm has to say that rather than counting hunks at the user
    it("reverts a new file by deleting it, warning that it will", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "fresh\n") -- untracked
        vim.cmd.edit(root .. "/new.lua")

        local p, v = open_panel()
        assert.are.equal("deletes the file", v.staging.revert_label)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        local asked
        local orig = vim.fn.confirm
        vim.fn.confirm = function(msg)
            asked = msg
            return 1
        end
        local ok, err = pcall(function()
            v:revert_hunk()
        end)
        vim.fn.confirm = orig
        assert(ok, err)

        assert.are.equal("Revert all of new.lua? This deletes the file.", asked)
        assert.are.equal(0, vim.fn.filereadable(root .. "/new.lua"))
        p:close()
    end)

    it("reverts a staged add by dropping the file and its staged entry", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "fresh\n")
        git(root, "add", "new.lua") -- staged add: "A"
        vim.cmd.edit(root .. "/new.lua")

        local p, v = open_panel()

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(0, vim.fn.filereadable(root .. "/new.lua"))
        assert.is_nil(git(root, "ls-files", "--", "new.lua"):match("new%.lua")) -- unstaged too
        p:close()
    end)

    -- deleting the file out from under the diff would otherwise strand the window on a
    -- path that no longer exists, showing "hunk 0/0" against an empty buffer
    it("moves to another file after a whole-file revert, not an empty diff", function()
        local root = fresh_repo()
        write(root .. "/keep.lua", "kept\n")
        git(root, "add", "keep.lua")
        git(root, "commit", "-q", "-m", "keep")
        write(root .. "/keep.lua", "kept and edited\n") -- a real change to land on
        write(root .. "/gone.lua", "temporary\n") -- untracked, about to go
        vim.cmd.edit(root .. "/gone.lua")

        local p, v = open_panel()
        assert.are.equal("gone.lua", v.model.path)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(0, vim.fn.filereadable(root .. "/gone.lua"))
        -- the view followed the panel onto the surviving change
        local after = view_in_origin(p)
        assert.are.equal("keep.lua", after.model.path)
        assert.is_true(#after.model.hunks > 0)
        p:close()
    end)

    -- the cursor used to be pulled to the nearest surviving hunk, because the line a
    -- revert leaves you on is unchanged context and the re-source focus snaps to hunks
    it("keeps the cursor where the reverted hunk was, not on the next one", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n")
        git(root, "commit", "-q", "-am", "12 lines")
        -- hunks far apart, so being pulled to the second one is unmistakable
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 }) -- the 1 -> 1x hunk
        confirming(1, function()
            v:revert_hunk()
        end)

        -- the surviving hunk is the last line of the file; landing on it would mean a
        -- new-side line of 12, and the whole point is that we didn't move there
        local col = v.columns[#v.columns]
        local lnum = vim.api.nvim_win_get_cursor(col.winid)[1]
        local mapped = col.map.lines[lnum]
        assert.is_not_nil(mapped)
        assert.are.equal(1, mapped.new) -- still on line 1, now restored context
        assert.is_nil(mapped.hunk) -- and it is context, not a hunk line
        p:close()
    end)

    it("moves on when the revert takes the file's last hunk", function()
        local root = fresh_repo()
        write(root .. "/keep.lua", "kept\n")
        git(root, "add", "keep.lua")
        git(root, "commit", "-q", "-m", "keep")
        write(root .. "/keep.lua", "kept and edited\n") -- a survivor to land on
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua has one hunk
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(1, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(V1, worktree(root, "a.lua")) -- reverted
        local after = view_in_origin(p)
        assert.are.equal("keep.lua", after.model.path) -- not left on an empty a.lua
        assert.is_true(#after.model.hunks > 0)
        p:close()
    end)

    -- with nothing left to review, an open sidebar next to a diff of a file that's now
    -- clean is a dead end: every key is a no-op and the diff is frozen on a stale model
    it("ends the session when the last change in the set is reverted", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- the only change in the repo
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(1, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        _G.notifs = {}
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(V1, worktree(root, "a.lua"))
        assert.is_nil(Panel.current()) -- the session is gone, not left empty
        assert.is_false(p:is_alive())
        assert.is_false(v:is_open()) -- and it took the diff view with it
        assert.are.equal("differ: no changes left", _G.notifs[1].msg)
        assert.are.equal(1, #_G.notifs) -- said once, not once per teardown step
    end)

    it("lands back in the tab :Differ was invoked from", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local invoked_from = vim.api.nvim_get_current_tabpage()

        local p = open_panel()
        assert.is_false(invoked_from == vim.api.nvim_get_current_tabpage()) -- own tab
        local v = view_in_origin(p)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(invoked_from, vim.api.nvim_get_current_tabpage())
    end)

    -- the file list can also empty from outside differ: a commit in a tmux pane, a
    -- lazygit discard. the watcher's refresh has to end the session the same way
    it("ends the session when an outside commit empties the change set", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.is_true(v:is_open())

        git(root, "commit", "-q", "-am", "committed elsewhere")
        _G.notifs = {}
        p.on_external_change() -- what the fs watcher / FocusGained fire

        assert.is_nil(Panel.current())
        assert.is_false(p:is_alive())
        assert.is_false(v:is_open())
        assert.are.equal("differ: no changes left", _G.notifs[1].msg)
    end)

    it("keeps the session when other changes survive the revert", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/b.lua", "kept\n") -- a second change, untracked
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(p, Panel.current()) -- still live, on the surviving change
        assert.are.equal("b.lua", view_in_origin(p).model.path)
        p:close()
    end)

    -- an unstaged deletion is still in the index, and that's what its diff compares
    -- against, so it must come back from there and not from HEAD
    it("restores an unstaged deletion from the index, keeping earlier staged edits", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\ntwo\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        write(root .. "/b.lua", "one\nSTAGED\n") -- an edit staged before the delete
        git(root, "add", "b.lua")
        os.remove(root .. "/b.lua")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", false), 0 })
        p:select()
        local v = view_in_origin(p)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("restores the file", v.staging.revert_label)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        -- the staged version comes back, not HEAD's
        assert.are.equal("one\nSTAGED\n", worktree(root, "b.lua"))
        p:close()
    end)

    it("restores a staged deletion from HEAD, into the index and worktree", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\ntwo\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        git(root, "rm", "-q", "b.lua") -- deletion staged
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", true), 0 })
        p:select()
        local v = view_in_origin(p)
        assert.are.equal("b.lua", v.model.path)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal("one\ntwo\n", worktree(root, "b.lua"))
        assert.are.equal("one\ntwo\n", indexed(root, "b.lua")) -- no staged deletion left
        p:close()
    end)

    -- a deletion is the mirror of an added file: one whole-file hunk against an empty
    -- new side, staged and unstaged wholesale by s / u. X still restores the file
    it("stages and unstages a deletion from the diff view", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\ntwo\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        os.remove(root .. "/b.lua")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", false), 0 })
        p:select()
        local v = view_in_origin(p)
        assert.are.equal("b.lua", v.model.path)
        assert.is_not_nil(v.staging.apply) -- stageable now, wholesale
        assert.is_not_nil(v.staging.revert) -- and still restorable
        assert.is_true(v:_can_stage_hunk())

        -- the open landed on the file's only hunk
        vim.api.nvim_set_current_win(p.origin_win)
        local lnum = vim.api.nvim_win_get_cursor(p.origin_win)[1]
        assert.is_not_nil(v.columns[1].map.lines[lnum].hunk)

        v:stage_hunk()
        -- the removal is in the index, and the view followed the file to its staged side
        assert.are.equal("", git(root, "ls-files", "--", "b.lua"))
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(0, vim.fn.filereadable(root .. "/b.lua")) -- still gone from disk

        vim.api.nvim_set_current_win(p.origin_win)
        v:unstage_hunk() -- u puts the deletion back to worktree-only
        assert.are.equal("b.lua\n", git(root, "ls-files", "--", "b.lua"))
        p:close()
    end)

    -- a whole-file stage used to report success whatever git did, so a refused `git add`
    -- still marked the hunk and painted it staged: the marks described a state git never
    -- reached. an index lock is the cheapest way to make git refuse on demand
    it("leaves the hunk unmarked when git refuses a whole-file stage", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "z1\nz2\n") -- untracked: staged wholesale, not by hunk
        vim.cmd.edit(root .. "/z.lua")

        local p, v = open_panel()
        assert.are.equal("z.lua", v.model.path)

        _G.notifs = {}
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 1), 0 })
        write(root .. "/.git/index.lock", "")
        v:stage_hunk()
        os.remove(root .. "/.git/index.lock") -- dropped before the asserts, not after

        assert.are.equal("unstaged", v:_hunk_state(1)) -- no mark for something git didn't stage
        assert.are.equal("", git(root, "ls-files", "--", "z.lua")) -- and it really didn't
        assert.is_truthy(
            (_G.notifs[1] and _G.notifs[1].msg or ""):find("stage failed", 1, true),
            _G.notifs[1] and _G.notifs[1].msg or "no notification"
        )
        p:close()
    end)

    it("reloads an open buffer of the file it just reverted", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        vim.cmd.edit(root .. "/a.lua") -- the real file is open in a buffer
        local filebuf = vim.api.nvim_get_current_buf()

        local p, v = open_panel()
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        -- without a checktime this buffer would still hold the reverted line
        local lines = vim.api.nvim_buf_get_lines(filebuf, 0, -1, false)
        assert.are.equal("1", lines[1])
        assert.is_false(vim.bo[filebuf].modified)
        p:close()
    end)

    it("keeps staged marks on the hunks that outlive a revert", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        git(root, "commit", "-q", "-am", "9 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5x\n6\n7\n8\n9x\n") -- three hunks
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(3, #v.model.hunks)

        -- stage the first, then revert the second: the mark has to follow hunk 1
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()

        vim.api.nvim_set_current_win(p.origin_win)
        local second = nil
        for lnum, line in ipairs(v.columns[1].map.lines) do
            if line.hunk == 2 then
                second = lnum
                break
            end
        end
        vim.api.nvim_win_set_cursor(p.origin_win, { assert(second), 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(2, #v.model.hunks)
        assert.are.equal("staged", v:_hunk_state(1)) -- still the 1 -> 1x hunk
        assert.are.equal("unstaged", v:_hunk_state(2)) -- what was hunk 3, unstaged, renumbered down
        assert.are.same({ "9x" }, v.model.hunks[2].new_lines)
        p:close()
    end)

    it("lands the cursor on the first hunk, not the leading context", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n")
        git(root, "commit", "-q", "-am", "six")
        write(root .. "/a.lua", "1\n2\n3\nX\n5\n6\n") -- only line 4 changes
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        local cur = vim.api.nvim_win_get_cursor(p.origin_win)[1]
        assert.is_not_nil(v.columns[1].map.lines[cur].hunk) -- on a hunk, not context
        assert.are.equal(v:_first_review_line(), cur)
        p:close()
    end)

    it("lands on the first unstaged hunk, skipping staged ones", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- hunks at lines 1 and 8
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(1, v:_first_review_line()) -- both unstaged -> hunk 1

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk() -- stage hunk 1; the next place to review is hunk 2 (buffer line 9)
        assert.are.equal(9, v:_first_review_line())
        p:close()
    end)
end)
