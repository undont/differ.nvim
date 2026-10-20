-- runs under headless nvim against a throwaway git repo: dw's local view of a
-- partly staged file, and the keys inside it
local content_ops = require("differ.git.content")
local helpers = require("test.nvim.git_helpers")
local git = helpers.git
local write = helpers.write
local fresh_repo = helpers.fresh_repo
local view_in_origin = helpers.view_in_origin
local open_panel = helpers.open_panel
local confirming = helpers.confirming
local indexed = helpers.indexed
local worktree = helpers.worktree
local committed = helpers.committed
local hunk_line = helpers.hunk_line
local index_as = helpers.index_as
local staged_as = helpers.staged_as
local lines_of = helpers.lines_of
local winbar_of = helpers.winbar_of
local gutter_of = helpers.gutter_of
local partly_staged_repo = helpers.partly_staged_repo
local twelve = helpers.twelve
local staged_then = helpers.staged_then
local stage_behind = helpers.stage_behind

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

    it("dw opens a partly staged file's local view and goes back", function()
        partly_staged_repo()
        local p, v = open_panel()
        local whole = #v.model.hunks
        v:toggle_local()
        local old_rev, new_rev = v.model.old_rev, v.model.new_rev
        local hunks, state, text = #v.model.hunks, v:_hunk_state(1), winbar_of(v)
        local gutter = gutter_of(v, hunk_line(v, 1))
        v:toggle_local()
        local back_rev, back_hunks, back_text = v.model.old_rev, #v.model.hunks, winbar_of(v)
        p:close()
        assert.are.equal(3, whole)
        assert.are.same({ "INDEX", "WORKTREE" }, { old_rev, new_rev })
        assert.are.equal(1, hunks)
        assert.are.equal("unstaged", state)
        assert.is_truthy(text:find(" LOCAL ", 1, true))
        assert.is_nil(gutter:find("!", 1, true)) -- 12x touches nothing staged
        assert.are.equal("HEAD", back_rev)
        assert.are.equal(3, back_hunks)
        assert.is_nil(back_text:find("LOCAL", 1, true))
    end)

    -- the view stays frozen and the index is rebuilt from the one it opened on, so a
    -- hunk staged here stays on screen and u puts it back
    it("stages and unstages in the local view against the index it opened on", function()
        local root = partly_staged_repo()
        local before = indexed(root, "a.lua")
        local p, v = open_panel()
        v:toggle_local()
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:stage_hunk()
        local staged, state, rev_after = indexed(root, "a.lua"), v:_hunk_state(1), v.model.old_rev
        v:unstage_hunk()
        local unstaged = indexed(root, "a.lua")
        p:close()
        assert.are.equal(worktree(root, "a.lua"), staged)
        assert.are.equal("staged", state)
        assert.are.equal("INDEX", rev_after) -- still the local view
        assert.are.equal(before, unstaged)
    end)

    it("df from the local view edits the worktree file from the whole change", function()
        partly_staged_repo()
        local p, v = open_panel()
        v:toggle_local()
        v:edit_file()
        local rev_after, win = v.model.old_rev, v.edit_win
        p:close()
        assert.are.equal("HEAD", rev_after)
        assert.is_truthy(win)
    end)

    it("dw says so on a file with no local view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        _G.notifs = {}
        v:toggle_local()
        local rev_after, msg = v.model.old_rev, _G.notifs[#_G.notifs].msg
        p:close()
        assert.are.equal("HEAD", rev_after)
        assert.are.equal("differ: only a partly staged file has a local view", msg)
    end)
    -- the local view of the file :Differ opened, cursor on hunk `n`
    local function local_view_at(n)
        local p, v = open_panel()
        v:toggle_local()
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, n), 0 })
        return p, v
    end

    -- 1x staged and then put back on disk: HEAD↔worktree is empty, so the row draws the
    -- staged change it still has rather than a notice
    it("opens a staged change the worktree put back on its HEAD-to-index hunks", function()
        local root = staged_then(twelve({}))
        local p, v = open_panel()
        local revs = { v.model.old_rev, v.model.new_rev }
        local hunks, notice, badge = #v.model.hunks, v.model.notice, v.staging.badge
        local state = v:_hunk_state(1)
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        local prompt = confirming(1, function()
            v:unstage_hunk()
        end)
        local index = indexed(root, "a.lua")
        if Panel.current() then
            p:close() -- unstaging the last staged change empties the list
        end
        assert.are.same({ "HEAD", "INDEX" }, revs)
        assert.are.equal(1, hunks)
        assert.is_nil(notice)
        assert.are.equal("INDEX", badge)
        assert.are.equal("staged", state)
        assert.are.equal("Unstage hunk 1/1 in a.lua? The staged change will be lost.", prompt)
        assert.are.equal(committed(root, "a.lua"), index)
    end)

    -- 1x staged, 12x not: staging the one local hunk leaves nothing since staging to show
    it("s on the last hunk in the local view hands back to the whole change", function()
        local root = staged_then(twelve({ "1x", [12] = "12x" }))
        local p, v = local_view_at(1)
        local hunks = #v.model.hunks
        v:stage_hunk()
        vim.wait(500, function() -- the hand-back runs on a schedule
            return v.staging.badge ~= "LOCAL"
        end)
        local revs, badge = { v.model.old_rev, v.model.new_rev }, v.staging.badge
        local index = indexed(root, "a.lua")
        p:close()
        assert.are.equal(1, hunks)
        assert.are.same({ "HEAD", "WORKTREE" }, revs)
        assert.is_nil(badge)
        assert.are.equal(twelve({ "1x", [12] = "12x" }), index)
    end)

    -- the index holds the content and +x, the worktree the content and -x
    it("s in a local view with only a mode change stages the file and hands back", function()
        local root = fresh_repo()
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        vim.fn.setfperm(root .. "/a.lua", "rw-r--r--")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_local()
        local notice = v.model.notice
        v:stage_hunk()
        vim.wait(500, function() -- the hand-back runs on a schedule
            return v.staging.badge ~= "LOCAL"
        end)
        local badge = v.staging.badge
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        p:close()
        assert.is_truthy(notice:find("^Mode changed"), notice)
        assert.is_nil(badge)
        assert.are.equal("M  a.lua\n", status)
    end)

    -- the index holds new content and +x, the worktree the same content and -x
    it(
        "u in a local view with only a mode change drops the staged mode, keeping the content",
        function()
            local root = fresh_repo()
            write(root .. "/a.lua", "local x = 2\nreturn x\n")
            vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
            git(root, "add", "a.lua")
            vim.fn.setfperm(root .. "/a.lua", "rw-r--r--")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()
            v:toggle_local()
            local prompt = confirming(1, function()
                v:unstage_hunk()
            end)
            local badge = v.staging.badge
            local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
            local mode = git(root, "ls-files", "-s", "--", "a.lua"):sub(1, 6)
            p:close()
            assert.are.equal("Unstage a.lua? The staged change will be lost.", prompt)
            assert.is_nil(badge)
            assert.are.equal("M  a.lua\n", status)
            assert.are.equal("100644", mode)
        end
    )

    it("u in a staged add's local view drops the add", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "one\n")
        git(root, "add", "c.lua")
        os.remove(root .. "/c.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("c.lua", true))
        local v = view_in_origin(p)
        v:toggle_local()
        confirming(1, function()
            v:unstage_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("", status)
    end)

    it("u in a local view drops a staged binary add changed again on disk", function()
        local root = fresh_repo()
        write(root .. "/b.dat", "\0one")
        git(root, "add", "b.dat")
        write(root .. "/b.dat", "\0two")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("b.dat", true))
        local v = view_in_origin(p)
        v:toggle_local()
        confirming(1, function()
            v:unstage_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "b.dat")
        p:close()
        assert.are.equal("?? b.dat\n", status)
    end)

    it("u in a binary file's local view puts HEAD's blob back in the index", function()
        local root = fresh_repo()
        write(root .. "/b.dat", "\0one")
        git(root, "add", "b.dat")
        git(root, "commit", "-q", "-m", "b")
        write(root .. "/b.dat", "\0two")
        git(root, "add", "b.dat")
        write(root .. "/b.dat", "\0three")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("b.dat", true))
        local v = view_in_origin(p)
        v:toggle_local()
        confirming(1, function()
            v:unstage_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "b.dat")
        p:close()
        assert.are.equal(" M b.dat\n", status)
    end)

    it("X in a local view with only a mode change puts the index's mode back on disk", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        git(root, "add", "a.lua")
        vim.fn.setfperm(root .. "/a.lua", "rw-r--r--")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_local()
        local prompt = confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        local perm = vim.fn.getfperm(root .. "/a.lua")
        p:close()
        assert.are.equal("Revert all of a.lua? This resets it to the index.", prompt)
        assert.are.equal("M  a.lua\n", status)
        assert.are.equal("rwxr-xr-x", perm)
    end)

    it("X in a staged add's local view brings the file back from the index", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "one\n")
        git(root, "add", "c.lua")
        os.remove(root .. "/c.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("c.lua", true))
        local v = view_in_origin(p)
        v:toggle_local()
        confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("A  c.lua\n", status)
        assert.are.equal("one\n", worktree(root, "c.lua"))
    end)

    it("X in a binary file's local view puts the index's blob back on disk", function()
        local root = fresh_repo()
        write(root .. "/b.dat", "\0one")
        git(root, "add", "b.dat")
        git(root, "commit", "-q", "-m", "b")
        write(root .. "/b.dat", "\0two")
        git(root, "add", "b.dat")
        write(root .. "/b.dat", "\0three")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("b.dat", true))
        local v = view_in_origin(p)
        v:toggle_local()
        confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "b.dat")
        p:close()
        assert.are.equal("M  b.dat\n", status)
    end)

    it("X after s on an untracked file acts on the file as s left it", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "new\n")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/new.lua")
        local p, v = open_panel()
        v:stage_hunk()
        vim.wait(30)
        _G.notifs = {}
        local prompt = confirming(1, function()
            view_in_origin(p):revert_hunk()
        end)
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local status = git(root, "status", "--porcelain=v1", "--", "new.lua")
        p:close()
        assert.are.equal("Revert all of new.lua? This deletes the file.", prompt)
        assert.is_nil(said and said:find("skipped", 1, true), said)
        assert.are.equal("", status)
    end)

    it("X after s on a deleted file brings it back", function()
        local root = fresh_repo()
        os.remove(root .. "/a.lua")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/b.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("a.lua", true))
        view_in_origin(p):stage_hunk()
        vim.wait(30)
        confirming(1, function()
            view_in_origin(p):revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        local back = vim.fn.filereadable(root .. "/a.lua")
        p:close()
        assert.are.equal("", status)
        assert.are.equal(1, back)
    end)

    -- a.lua moved to b.lua, edited, staged, and then b.lua deleted: RD
    it("s after u on a moved file that was then deleted stages what the rows are now", function()
        local root = fresh_repo()
        write(root .. "/a.lua", twelve({}))
        git(root, "commit", "-q", "-am", "twelve lines")
        git(root, "mv", "a.lua", "b.lua")
        write(root .. "/b.lua", twelve({ [6] = "6x" }))
        git(root, "add", "b.lua")
        os.remove(root .. "/b.lua")
        write(root .. "/c.lua", "c\n")
        vim.cmd.edit(root .. "/c.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("b.lua", true))
        local row = git(root, "status", "--porcelain=v1", "--", "a.lua", "b.lua")
        confirming(1, function()
            view_in_origin(p):unstage_hunk()
        end)
        vim.wait(30)
        _G.notifs = {}
        view_in_origin(p):stage_hunk()
        vim.wait(30)
        local failed = vim.tbl_filter(function(n)
            return n.msg:find("failed", 1, true) ~= nil
        end, _G.notifs)
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua", "b.lua")
        p:close()
        assert.are.equal("RD a.lua -> b.lua\n", row)
        assert.are.same({}, failed)
        assert.are.equal("D  a.lua\n", status)
    end)

    it("says where X undoes a bare move instead of calling it a hunk", function()
        local root = fresh_repo()
        git(root, "mv", "a.lua", "b.lua")
        write(root .. "/c.lua", "c\n")
        vim.cmd.edit(root .. "/c.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("b.lua", true))
        _G.notifs = {}
        view_in_origin(p):revert_hunk()
        local said = (_G.notifs[#_G.notifs] or {}).msg
        p:close()
        assert.are.equal("differ: X on the panel row undoes the move", said)
    end)

    it("says why a staged edit deleted on disk has no local view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "edited\n")
        git(root, "add", "a.lua")
        os.remove(root .. "/a.lua")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/b.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("a.lua", true))
        _G.notifs = {}
        view_in_origin(p):toggle_local()
        local said = (_G.notifs[#_G.notifs] or {}).msg
        p:close()
        assert.are.equal(
            "differ: a.lua's only local change is its deletion, which s stages here",
            said
        )
    end)

    it("names what X drops on a staged add whose file was deleted", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "one\n")
        git(root, "add", "c.lua")
        os.remove(root .. "/c.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("c.lua", true))
        local prompt = confirming(2, function()
            view_in_origin(p):revert_hunk()
        end)
        p:close()
        assert.are.equal("Revert all of c.lua? This deletes the staged file.", prompt)
    end)

    -- 1x staged and then put back to 1 in the worktree: the local hunk undoing it is `!`
    it("u on a ! hunk in the local view drops the staged change it undoes", function()
        local root = staged_then(twelve({ [12] = "12x" }))
        local p, v = local_view_at(1)
        local marked = v.staging.hidden_in
        confirming(1, function()
            v:unstage_hunk()
        end)
        local index, hunks, rev_after = indexed(root, "a.lua"), #v.model.hunks, v.model.old_rev
        local after = v.staging.hidden_in or {}
        p:close()
        assert.are.same({ 1 }, marked)
        assert.are.equal(committed(root, "a.lua"), index)
        assert.are.equal(1, hunks) -- only 12x is left to stage
        assert.are.equal("HEAD", rev_after) -- nothing staged: the whole change takes over
        assert.are.same({}, after)
    end)

    -- 1x staged and then put back on disk, with b.lua keeping the session open
    it("hands back to the whole change once u leaves the local view nothing to show", function()
        local root = staged_then(twelve({}))
        write(root .. "/b.lua", "b\n")
        local p, v = local_view_at(1)
        confirming(1, function()
            v:unstage_hunk()
        end)
        vim.wait(30)
        local badge = view_in_origin(p).staging.badge
        p:close()
        assert.are_not.equal("LOCAL", badge)
    end)

    it(
        "hands back to the whole change once s and X leave the local view nothing to show",
        function()
            local root = staged_then(twelve({ "1x", [6] = "6x", [12] = "12x" }))
            local p, v = local_view_at(1)
            v:stage_hunk()
            vim.api.nvim_win_set_cursor(v.columns[#v.columns].winid, { hunk_line(v, 2), 0 })
            confirming(1, function()
                v:revert_hunk()
            end)
            vim.wait(30)
            local badge = view_in_origin(p).staging.badge
            local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
            p:close()
            assert.are_not.equal("LOCAL", badge)
            assert.are.equal("M  a.lua\n", status)
        end
    )

    -- 10-12 staged as ten eleven twelve, then only eleven rewritten on disk
    it("u on a ! hunk takes back only the lines it rewrote", function()
        local head = twelve({})
        local index = twelve({ [10] = "ten", [11] = "eleven", [12] = "twelve" })
        local root, p, v =
            staged_as(head, index, twelve({ [10] = "ten", [11] = "ELEVEN", [12] = "twelve" }))
        v:toggle_local()
        local win = v.columns[#v.columns].winid
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { hunk_line(v, 1), 0 })
        local prompt = confirming(1, function()
            v:unstage_hunk()
        end)
        local written = indexed(root, "a.lua")
        p:close()
        assert.are.equal("Unstage hunk 1/1 in a.lua? The staged change will be lost.", prompt)
        assert.are.equal(twelve({ [10] = "ten", [12] = "twelve" }), written)
    end)

    -- 10-12 staged as two lines, so no index line has one HEAD line of its own to go back to
    it("u on a ! hunk names the whole staged block it takes back", function()
        local head = twelve({})
        local index = lines_of({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "ten", "eleven" })
        local work = lines_of({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "ten", "ELEVEN" })
        local root, p, v = staged_as(head, index, work)
        v:toggle_local()
        local win = v.columns[#v.columns].winid
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { hunk_line(v, 1), 0 })
        local prompt = confirming(1, function()
            v:unstage_hunk()
        end)
        local written = indexed(root, "a.lua")
        p:close()
        assert.are.equal("Unstage lines 10-11 in a.lua? The staged change will be lost.", prompt)
        assert.are.equal(head, written)
    end)

    it("doesn't mark an edit to a staged add as ! in the local view", function()
        local root = fresh_repo()
        write(root .. "/c.lua", twelve({}))
        git(root, "add", "c.lua")
        write(root .. "/c.lua", twelve({ [5] = "five" }))
        vim.cmd.edit(root .. "/c.lua")
        local p, v = open_panel()
        v:toggle_local()
        local marked = v.staging.hidden_in
        local status = git(root, "status", "--porcelain=v1", "--", "c.lua")
        p:close()
        assert.are.same({}, marked or {})
        assert.are.equal("AM c.lua\n", status)
    end)

    -- 1x staged and then put back, 12x unstaged: u from 12x walks back onto the ! hunk
    it("u walks back onto a ! hunk in the local view rather than off the file", function()
        staged_then(twelve({ [12] = "12x" }))
        local p, v = local_view_at(2)
        v:unstage_hunk()
        local at, badge = v:_hunk_index_under_cursor(), v.staging.badge
        p:close()
        assert.are.equal(1, at)
        assert.are.equal("LOCAL", badge)
    end)

    -- 1x staged and then edited to 1y: u gives the index HEAD's line, where s gives 1y
    it("u on a ! hunk takes HEAD's lines, not the worktree's", function()
        local root = staged_then(twelve({ "1y", [12] = "12x" }))
        local p, v = local_view_at(1)
        confirming(1, function()
            v:unstage_hunk()
        end)
        local index = indexed(root, "a.lua")
        p:close()
        assert.are.equal(committed(root, "a.lua"), index)
    end)

    -- it drops staged content no other side holds, so a no leaves the index alone
    it("u on a ! hunk drops nothing when the confirm is declined", function()
        local root = staged_then(twelve({ [12] = "12x" }))
        local p, v = local_view_at(1)
        confirming(2, function()
            v:unstage_hunk()
        end)
        local index = indexed(root, "a.lua")
        p:close()
        assert.are.equal(twelve({ "1x" }), index)
    end)

    -- where u drops the staged 1x, X keeps it: the put-back goes and the file holds 1x again
    it("X on a ! hunk in the local view puts the staged line back into the file", function()
        local root = staged_then(twelve({ [12] = "12x" }))
        local p, v = local_view_at(1)
        local opened = v.staging
        confirming(1, function()
            v:revert_hunk()
        end)
        vim.wait(500, function() -- the local view re-reads on a schedule
            return v.staging ~= opened
        end)
        local work, index = worktree(root, "a.lua"), indexed(root, "a.lua")
        local hidden = v.staging.hidden_in
        p:close()
        assert.are.equal(twelve({ "1x", [12] = "12x" }), work)
        assert.are.equal(twelve({ "1x" }), index)
        assert.are.same({}, hidden)
    end)

    -- the rebuild starts from the index the view opened on, so a write made outside
    -- differ since then would be lost to it
    it("s in the local view refuses an index staged from outside since it opened", function()
        local root = staged_then(twelve({ "1x", [12] = "12x" }))
        local p, v = local_view_at(1)
        stage_behind(root, twelve({ "1x", "2x" }))
        _G.notifs = {}
        v:stage_hunk()
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local index = indexed(root, "a.lua")
        p:close()
        assert.are.equal("differ: the index changed outside differ: re-reading", said)
        assert.are.equal(twelve({ "1x", "2x" }), index)
    end)

    it("u on a ! hunk refuses an index staged from outside since the view opened", function()
        local root = staged_then(twelve({ [12] = "12x" }))
        local p, v = local_view_at(1)
        stage_behind(root, twelve({ "1x", "2x" }))
        _G.notifs = {}
        confirming(1, function()
            v:unstage_hunk()
        end)
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local index = indexed(root, "a.lua")
        p:close()
        assert.are.equal("differ: the index changed outside differ: re-reading", said)
        assert.are.equal(twelve({ "1x", "2x" }), index)
    end)

    -- 5x staged and put back on disk, 0 added above it: s on the 0 moves the 5x down a line
    it("u on a ! hunk finds its line below a hunk s staged in the same view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", twelve({}))
        git(root, "commit", "-q", "-am", "twelve lines")
        stage_behind(root, twelve({ [5] = "5x" }))
        write(root .. "/a.lua", "0\n" .. twelve({ [12] = "12x" }))
        vim.cmd.edit(root .. "/a.lua")
        local p, v = local_view_at(1)
        local marked = v.staging.hidden_in
        v:stage_hunk()
        vim.api.nvim_win_set_cursor(0, { hunk_line(v, 2), 0 })
        confirming(1, function()
            v:unstage_hunk()
        end)
        local index = indexed(root, "a.lua")
        p:close()
        assert.are.same({ 2 }, marked)
        assert.are.equal("0\n" .. twelve({}), index)
    end)

    -- 1x staged, 6y and 12x not: staging 6y from outside leaves the row MM
    it("re-marks a partial stage from outside that leaves the row as it was", function()
        local root, p, v =
            staged_as(twelve({}), twelve({ "1x" }), twelve({ "1x", [6] = "6y", [12] = "12x" }))
        local function states()
            local out = {}
            for i = 1, #v.model.hunks do
                out[i] = v:_hunk_state(i)
            end
            return out
        end
        local before = states()
        stage_behind(root, twelve({ "1x", [6] = "6y" }))
        p.on_external_change()
        local after = states()
        p:close()
        local S, U = "staged", "unstaged"
        assert.are.same({ S, U, U }, before)
        assert.are.same({ S, S, U }, after)
    end)

    -- git reads `:1:x.txt` as conflict stage 1 of x.txt
    it("reads the index of a file whose name starts with a stage number", function()
        local root = fresh_repo()
        write(root .. "/1:x.txt", twelve({}))
        git(root, "add", "1:x.txt")
        git(root, "commit", "-q", "-m", "twelve lines")
        index_as(root, "1:x.txt", twelve({ "1x" }))
        write(root .. "/1:x.txt", twelve({ "1x", [12] = "12x" }))
        vim.cmd.edit(vim.fn.fnameescape(root .. "/1:x.txt"))
        local p, v = open_panel()
        local states = { v:_hunk_state(1), v:_hunk_state(2) }
        p:close()
        assert.are.same({ "staged", "unstaged" }, states)
    end)

    it("refuses s when the index can't be read", function()
        local root, p, v = staged_as(twelve({}), twelve({ "1x" }), twelve({ "1x", [12] = "12x" }))
        local read = content_ops.read
        content_ops.read = function(ref, ...)
            if ref.kind == "index" then
                return nil
            end
            return read(ref, ...)
        end
        _G.notifs = {}
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 2), 0 })
        v:stage_hunk()
        content_ops.read = read
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local index = indexed(root, "a.lua")
        p:close()
        assert.are.equal("differ: couldn't read a.lua from the index", said)
        assert.are.equal(twelve({ "1x" }), index)
    end)

    it("X in the local view puts the worktree hunk back to the index's version", function()
        local root = staged_then(twelve({ "1x", [6] = "6y", [12] = "12y" }))
        local p, v = local_view_at(1)
        local opened = v.staging
        confirming(1, function()
            v:revert_hunk()
        end)
        vim.wait(500, function() -- the local view re-reads on a schedule
            return v.staging ~= opened
        end)
        local work, index, hunks = worktree(root, "a.lua"), indexed(root, "a.lua"), #v.model.hunks
        p:close()
        assert.are.equal(twelve({ "1x", [12] = "12y" }), work)
        assert.are.equal(twelve({ "1x" }), index)
        assert.are.equal(1, hunks)
    end)

    -- s put 6y in the index; throwing the hunk away takes it out of both
    it("X on a hunk staged in the local view drops it from the index too", function()
        local root = staged_then(twelve({ "1x", [6] = "6y", [12] = "12y" }))
        local p, v = local_view_at(1)
        v:stage_hunk()
        confirming(1, function()
            v:revert_hunk()
        end)
        local work, index = worktree(root, "a.lua"), indexed(root, "a.lua")
        p:close()
        assert.are.equal(twelve({ "1x", [12] = "12y" }), work)
        assert.are.equal(twelve({ "1x" }), index)
    end)
end)
