-- runs under headless nvim against a throwaway git repo: ds's commit preview of
-- the staged changes, and X / u / s inside it
local git_src = require("differ.git")
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
local hunk_line = helpers.hunk_line
local winbar_of = helpers.winbar_of
local partly_staged_repo = helpers.partly_staged_repo
local twelve = helpers.twelve
local staged_then = helpers.staged_then
local stage_behind = helpers.stage_behind
local paths = helpers.paths

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

    it("says so when the commit preview empties and hands back every change", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "staged\n")
        git(root, "add", "a.lua")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        _G.notifs = {}
        view_in_origin(p):unstage_all()
        vim.wait(30)
        local said = vim.tbl_map(function(n)
            return n.msg
        end, _G.notifs)
        p:close()
        assert.is_true(vim.tbl_contains(said, "differ: nothing staged: back to every change"))
    end)

    it("says nothing is staged when X in the commit preview follows u on it", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "one\n")
        git(root, "add", "c.lua")
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        vim.cmd.edit(root .. "/c.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        v = view_in_origin(p)
        v:unstage_hunk()
        _G.notifs = {}
        confirming(1, function()
            view_in_origin(p):revert_hunk()
        end)
        local said = (_G.notifs[#_G.notifs] or {}).msg
        p:close()
        assert.are.equal("differ: c.lua has nothing staged now: s stages it back", said)
        assert.are.equal(1, vim.fn.filereadable(root .. "/c.lua"))
    end)

    it("X on a file whose only change is its mode puts HEAD's mode back", function()
        local root = fresh_repo()
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local prompt = confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        local perm = vim.fn.getfperm(root .. "/a.lua")
        p:close()
        assert.are.equal("Revert all of a.lua? This resets it to HEAD.", prompt)
        assert.are.equal("", status)
        assert.are.equal("rw-r--r--", perm)
    end)

    it("X on a binary file puts it back as HEAD has it", function()
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
        confirming(1, function()
            view_in_origin(p):revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("", status)
    end)

    -- the index holds +x, the worktree +x and an edit on top that the preview doesn't show
    it("X in the commit preview refuses a whole-file row with unstaged changes on top", function()
        local root = fresh_repo()
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "edited\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        v = view_in_origin(p)
        _G.notifs = {}
        v:revert_hunk()
        local said = _G.notifs[#_G.notifs].msg
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("differ: X would also discard the unstaged changes to a.lua", said)
        assert.are.equal("MM a.lua\n", status)
        assert.are.equal("edited\n", worktree(root, "a.lua"))
    end)

    -- the index adds three lines under a and turns p into q; the file also turns h into q
    it("X in the commit preview reverts the right lines after u moves the index", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\nc\nd\ne\np\nf\ng\nh\ni\n")
        git(root, "commit", "-q", "-am", "base")
        write(root .. "/a.lua", "a\nx1\nx2\nx3\nb\nc\nd\ne\nq\nf\ng\nh\ni\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "a\nx1\nx2\nx3\nb\nc\nd\ne\nq\nf\ng\nq\ni\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        v = view_in_origin(p)
        local win = v.columns[#v.columns].winid
        vim.api.nvim_win_set_cursor(win, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        vim.api.nvim_win_set_cursor(win, { hunk_line(v, 2), 0 })
        confirming(1, function()
            v:revert_hunk()
        end)
        local index, work = indexed(root, "a.lua"), worktree(root, "a.lua")
        p:close()
        assert.are.equal("a\nb\nc\nd\ne\np\nf\ng\nh\ni\n", index)
        assert.are.equal("a\nx1\nx2\nx3\nb\nc\nd\ne\np\nf\ng\nq\ni\n", work)
    end)

    -- the index drops c and d; the file still has them, so the row opens on HEAD↔index
    it("X on a deletion the file already put back moves only the index", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\nc\nd\ne\nf\n")
        git(root, "commit", "-q", "-am", "base")
        write(root .. "/a.lua", "a\nb\ne\nf\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "a\nb\nc\nd\ne\nf\n")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local badge = v.staging.badge
        confirming(1, function()
            v:revert_hunk()
        end)
        local work = worktree(root, "a.lua")
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        p:close()
        assert.are.equal("INDEX", badge)
        assert.are.equal("a\nb\nc\nd\ne\nf\n", work)
        assert.are.equal("", status)
    end)

    it("X on a staged edit the file already put back moves only the index", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\nc\nd\n")
        git(root, "commit", "-q", "-am", "base")
        write(root .. "/a.lua", "a\nB\nc\nd\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "a\nb\nc\nd\n")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        _G.notifs = {}
        confirming(1, function()
            v:revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        local said = (_G.notifs[#_G.notifs] or {}).msg
        p:close()
        assert.are.equal("", status)
        assert.is_nil(said and said:find("nothing reverted", 1, true), said)
    end)

    it("X in the commit preview reads the file again before discarding it", function()
        local root = fresh_repo()
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        git(root, "add", "a.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        write(root .. "/a.lua", "edited\n") -- before the watcher has re-read it
        _G.notifs = {}
        confirming(1, function()
            view_in_origin(p):revert_hunk()
        end)
        local said = _G.notifs[#_G.notifs].msg
        p:close()
        assert.is_truthy(
            said:find("X would also discard the unstaged changes to a.lua", 1, true),
            said
        )
        assert.are.equal("edited\n", worktree(root, "a.lua"))
    end)

    it("X in the commit preview still discards a whole-file row with nothing on top", function()
        local root = fresh_repo()
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        git(root, "add", "a.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        confirming(1, function()
            view_in_origin(p):revert_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("", status)
    end)

    -- ds, from the panel
    local function toggle_preview(p)
        p.extra_keymaps[1].fn()
    end
    local function titles(p)
        local out = {}
        for _, sec in ipairs(p.sections) do
            out[#out + 1] = sec.title
        end
        return out
    end
    -- the partly staged a.lua plus a staged add c.lua (edited again) and an unstaged b.lua
    local function preview_repo()
        local root = partly_staged_repo()
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b", "--", "b.lua") -- a.lua's staged edits stay staged
        write(root .. "/b.lua", "b2\n")
        write(root .. "/c.lua", "one\n")
        git(root, "add", "c.lua")
        write(root .. "/c.lua", "one\ntwo\n")
        return root
    end

    -- dw, from the panel: extra_keymaps[2], where [1] is ds
    local function toggle_local_key(p)
        p.extra_keymaps[2].fn()
    end

    it("dw in the panel opens the row's local view, and takes it back", function()
        local root = partly_staged_repo()
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        toggle_local_key(p)
        local v = view_in_origin(p)
        local revs, badge = { v.model.old_rev, v.model.new_rev }, v.staging.badge
        toggle_local_key(p)
        v = view_in_origin(p)
        local back = { v.model.old_rev, v.model.new_rev }
        p:close()
        assert.are.same({ "INDEX", "WORKTREE" }, revs)
        assert.are.equal("LOCAL", badge)
        assert.are.same({ "HEAD", "WORKTREE" }, back)
    end)

    it("dw in the panel refuses in the commit preview", function()
        preview_repo()
        local p = open_panel()
        toggle_preview(p)
        _G.notifs = {}
        toggle_local_key(p)
        local said, rev_after = (_G.notifs[#_G.notifs] or {}).msg, view_in_origin(p).model.new_rev
        p:close()
        assert.are.equal("differ: the commit preview has no local view: ds goes back", said)
        assert.are.equal("INDEX", rev_after)
    end)

    -- the first s turns a.lua Partial and the last makes it Staged, with no re-source
    -- between: dw follows the row rather than the state the diff opened on
    it("offers dw once the first s leaves a row partly staged, and not after the last", function()
        local root = fresh_repo()
        local ten = {}
        for i = 1, 10 do
            ten[i] = tostring(i)
        end
        write(root .. "/a.lua", table.concat(ten, "\n") .. "\n")
        git(root, "commit", "-q", "-am", "ten")
        ten[2], ten[9] = "2x", "9x"
        write(root .. "/a.lua", table.concat(ten, "\n") .. "\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local col = v.columns[1]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:stage_hunk()
        v:toggle_local()
        local partial_badge = view_in_origin(p).staging.badge
        view_in_origin(p):toggle_local() -- back to the whole change
        v = view_in_origin(p)
        col = v.columns[1]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 2), 0 })
        v:stage_hunk()
        _G.notifs = {}
        v:toggle_local()
        local said = (_G.notifs[#_G.notifs] or {}).msg
        p:close()
        assert.are.equal("LOCAL", partial_badge)
        assert.are.equal("differ: only a partly staged file has a local view", said)
    end)

    it("dw in the panel refuses a row with nothing staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "one\ntwo\n")
        git(root, "add", "a.lua")
        git(root, "commit", "-q", "-m", "one")
        write(root .. "/a.lua", "one\ntwo2\n")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        _G.notifs = {}
        toggle_local_key(p)
        local said, rev_after = (_G.notifs[#_G.notifs] or {}).msg, view_in_origin(p).model.old_rev
        p:close()
        assert.are.equal("differ: only a partly staged file has a local view", said)
        assert.are.equal("HEAD", rev_after)
    end)

    it("ds in the diff flips the listing the same way the panel's does", function()
        preview_repo()
        local p, v = open_panel()
        local before = titles(p)
        local bound = false
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(v.columns[#v.columns].bufnr, "n")) do
            bound = bound or map.lhs == "ds"
        end
        v:toggle_commit_preview()
        local in_titles, in_badge = titles(p), view_in_origin(p).staging.badge
        view_in_origin(p):toggle_commit_preview()
        local out_titles, out_badge = titles(p), view_in_origin(p).staging.badge
        p:close()
        assert.is_true(bound)
        assert.are.same({ "Staged changes" }, in_titles)
        assert.are.equal("STAGED", in_badge)
        assert.are.same(before, out_titles)
        assert.is_nil(out_badge)
    end)

    it("ds lists only the staged changes, each diffing HEAD-to-index, and back", function()
        preview_repo()
        local p = open_panel()
        local before = titles(p)
        toggle_preview(p)
        local v = view_in_origin(p)
        local in_titles, in_paths = titles(p), paths(p)
        local path, revs = v.model.path, { v.model.old_rev, v.model.new_rev }
        local state, text = v:_hunk_state(1), winbar_of(v)
        toggle_preview(p)
        local out_titles, out_rev = titles(p), v.model.new_rev
        p:close()
        assert.are.same({ "Staged changes" }, in_titles)
        assert.are.same({ "a.lua", "c.lua" }, in_paths)
        assert.are.equal("a.lua", path) -- the file on screen stays
        assert.are.same({ "HEAD", "INDEX" }, revs)
        assert.are.equal("staged", state)
        assert.is_truthy(text:find(" STAGED ", 1, true))
        assert.is_truthy(text:find(" hunk 1/2 ", 1, true))
        assert.is_nil(text:find("staged ·", 1, true)) -- every hunk staged: no tally
        assert.are.same(before, out_titles)
        assert.are.equal("WORKTREE", out_rev)
    end)

    -- frozen like the local view: the index is rebuilt from HEAD plus the hunks still
    -- marked staged, so hunks come out in any order and go straight back
    it("unstages in the commit preview in any order, and stages back in place", function()
        local root = preview_repo()
        local p = open_panel()
        toggle_preview(p)
        local v = view_in_origin(p)
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 2), 0 })
        v:unstage_hunk()
        local second_out = indexed(root, "a.lua")
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        local both_out = indexed(root, "a.lua")
        v:stage_hunk()
        local first_back = indexed(root, "a.lua")
        local hunks, rev_after = #v.model.hunks, v.model.new_rev
        p:close()
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n", second_out)
        assert.are.equal(committed(root, "a.lua"), both_out)
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n", first_back)
        assert.are.equal(2, hunks)
        assert.are.equal("INDEX", rev_after)
    end)

    -- an add is one unit whose index entry goes and comes back: s restores what was
    -- staged, not the worktree's copy
    it("unstages an add in the commit preview and stages back what was staged", function()
        local root = preview_repo()
        local p = open_panel()
        toggle_preview(p)
        assert.is_true(p:goto_path("c.lua", true))
        local v = view_in_origin(p)
        confirming(1, function()
            v:unstage_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "c.lua")
        v:stage_hunk()
        local back = indexed(root, "c.lua")
        p:close()
        assert.are.equal("?? c.lua\n", status)
        assert.are.equal("one\n", back)
    end)

    it("s in the commit preview refuses an add staged from outside since u", function()
        local root = preview_repo()
        local p = open_panel()
        toggle_preview(p)
        assert.is_true(p:goto_path("c.lua", true))
        local v = view_in_origin(p)
        confirming(1, function()
            v:unstage_hunk()
        end)
        write(root .. "/c.lua", "three\n")
        git(root, "add", "c.lua")
        _G.notifs = {}
        v:stage_hunk()
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local index = indexed(root, "c.lua")
        p:close()
        assert.are.equal("differ: the index changed outside differ: re-reading", said)
        assert.are.equal("three\n", index)
    end)

    it("u in the commit preview refuses an add staged again from outside", function()
        local root = preview_repo()
        local p = open_panel()
        toggle_preview(p)
        assert.is_true(p:goto_path("c.lua", true))
        local v = view_in_origin(p)
        git(root, "add", "c.lua")
        _G.notifs = {}
        v:unstage_hunk()
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local index = indexed(root, "c.lua")
        p:close()
        assert.are.equal("differ: the index changed outside differ: re-reading", said)
        assert.are.equal("one\ntwo\n", index)
    end)

    it("refuses s in the commit preview panel", function()
        local root = preview_repo()
        local p = open_panel()
        toggle_preview(p)
        local before = indexed(root, "a.lua")
        _G.notifs = {}
        p:stage_op("stage_all")
        local msg, after = _G.notifs[#_G.notifs].msg, indexed(root, "a.lua")
        p:close()
        assert.are.equal("differ: the commit preview only unstages: ds goes back", msg)
        assert.are.equal(before, after)
    end)

    -- an MD row is lettered D in the whole list but M in the preview
    it("discards an edit staged and then deleted from the commit preview panel", function()
        local root = preview_repo()
        os.remove(root .. "/a.lua")
        vim.cmd.edit(root .. "/c.lua") -- a buffer on a file still on disk resolves the repo
        local p = open_panel()
        toggle_preview(p)
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        _G.notifs = {}
        confirming(1, function()
            p:discard()
        end)
        local skipped = false
        for _, n in ipairs(_G.notifs) do
            skipped = skipped or n.msg:find("discard skipped", 1, true) ~= nil
        end
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        local on_disk = vim.fn.filereadable(root .. "/a.lua") == 1
        local work = on_disk and worktree(root, "a.lua") or nil
        p:close()
        assert.is_false(skipped)
        assert.are.equal("", status)
        assert.are.equal(committed(root, "a.lua"), work)
    end)

    -- an RD: a.lua renamed to b.lua in the index, then b.lua deleted from disk. the row
    -- is lettered D in the whole list and R in the preview
    local function renamed_then_deleted()
        local root = fresh_repo()
        write(root .. "/z.lua", "z\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-m", "z")
        git(root, "mv", "a.lua", "b.lua")
        os.remove(root .. "/b.lua")
        vim.cmd.edit(root .. "/z.lua")
        return root
    end
    ---@param root string
    ---@param preview boolean
    ---@return { complaints: string[], status: string, a: string|nil, b_on_disk: boolean }
    local function discard_renamed_then_deleted(root, preview)
        local p = open_panel()
        if preview then
            toggle_preview(p)
        end
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua"), 0 })
        _G.notifs = {}
        confirming(1, function()
            p:discard()
        end)
        local out = { complaints = {} }
        for _, n in ipairs(_G.notifs) do
            if n.msg:find("discard", 1, true) then
                out.complaints[#out.complaints + 1] = n.msg
            end
        end
        out.status = git(root, "status", "--porcelain=v1")
        if vim.fn.filereadable(root .. "/a.lua") == 1 then
            out.a = worktree(root, "a.lua")
        end
        out.b_on_disk = vim.fn.filereadable(root .. "/b.lua") == 1
        p:close()
        return out
    end

    it("brings back a staged rename whose new path was deleted, from the whole list", function()
        local root = renamed_then_deleted()
        local got = discard_renamed_then_deleted(root, false)
        assert.are.equal("R  a.lua -> b.lua\n", got.status)
        assert.is_nil(got.a)
        assert.is_true(got.b_on_disk)
        assert.are.same({}, got.complaints)
    end)

    it("unstages both ends of a staged rename whose new path was deleted", function()
        local root = renamed_then_deleted()
        local p = open_panel()
        assert.is_true(p:goto_path("b.lua", true))
        view_in_origin(p):unstage_hunk()
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal(" D a.lua\n", status)
    end)

    -- an AD: HEAD and the worktree both lack c.lua, so only the index shows the add
    it("draws a staged add whose file was deleted as HEAD-to-index", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "one\n")
        git(root, "add", "c.lua")
        os.remove(root .. "/c.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("c.lua", true))
        local v = view_in_origin(p)
        local revs, hunks, badge =
            { v.model.old_rev, v.model.new_rev }, #v.model.hunks, v.staging.badge
        local prompt = confirming(1, function()
            v:unstage_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.same({ "HEAD", "INDEX" }, revs)
        assert.are.equal(1, hunks)
        assert.are.equal("INDEX", badge)
        assert.are.equal("Unstage c.lua? The staged change will be lost.", prompt)
        assert.are.equal("", status)
    end)

    -- c.lua was added and then deleted: its whole change is the staged add, and only its
    -- local view shows the deletion, so the s walk stops on it rather than passing it
    it("stops s on a staged add whose file was deleted", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "one\n")
        git(root, "add", "c.lua")
        os.remove(root .. "/c.lua")
        write(root .. "/a.lua", "changed\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local landed = {}
        for _ = 1, 5 do
            view_in_origin(p):stage_hunk()
            landed[#landed + 1] = view_in_origin(p).model.path
        end
        local said = _G.notifs[#_G.notifs].msg
        p:close()
        assert.is_not_nil(v)
        assert.are.same({ "a.lua", "c.lua", "c.lua", "c.lua", "c.lua" }, landed)
        assert.are.equal("differ: c.lua has local changes: dw shows them", said)
    end)

    -- b.lua staged then put back on disk: passed once, and back in the walk once it changes
    it("puts a passed row back in the walk when its file changes", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        write(root .. "/b.lua", "two\n")
        git(root, "add", "b.lua")
        write(root .. "/b.lua", "one\n")
        write(root .. "/a.lua", "changed\n")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        view_in_origin(p):stage_hunk() -- a.lua staged
        view_in_origin(p):stage_hunk() -- onto b.lua
        view_in_origin(p):stage_hunk() -- b.lua passed: nothing left
        write(root .. "/b.lua", "three\n")
        p:refresh()
        assert.is_true(p:goto_path("a.lua", true))
        view_in_origin(p):stage_hunk() -- a.lua is done: the walk looks again
        local landed = view_in_origin(p).model.path
        p:close()
        assert.are.equal("b.lua", landed)
    end)

    -- a.lua and c.lua half staged, d.lua not at all: finishing c.lua moves it up into
    -- Staged, and the walk goes on to d.lua below it rather than back up to a.lua
    it("walks on from where a finished file sat, not from where it moved", function()
        local root = fresh_repo()
        for _, name in ipairs({ "c.lua", "d.lua" }) do
            write(root .. "/" .. name, "one\n")
        end
        git(root, "add", "c.lua", "d.lua")
        git(root, "commit", "-q", "-m", "c d")
        write(root .. "/a.lua", "staged\n")
        write(root .. "/c.lua", "staged\n")
        git(root, "add", "a.lua", "c.lua")
        write(root .. "/a.lua", "staged\nand more\n")
        write(root .. "/c.lua", "staged\nand more\n")
        write(root .. "/d.lua", "two\n")
        vim.cmd.edit(root .. "/c.lua")
        local p = open_panel()
        assert.are.equal("c.lua", view_in_origin(p).model.path)
        view_in_origin(p):stage_hunk() -- c.lua's rest: the file moves to Staged
        view_in_origin(p):stage_hunk() -- on to the next file
        local landed = view_in_origin(p).model.path
        p:close()
        assert.are.equal("d.lua", landed)
    end)

    it("discards a staged rename whose new path was deleted, from the commit preview", function()
        local root = renamed_then_deleted()
        local got = discard_renamed_then_deleted(root, true)
        assert.are.equal("", got.status)
        assert.are.equal(committed(root, "a.lua"), got.a)
        assert.is_false(got.b_on_disk)
        assert.are.same({}, got.complaints)
    end)

    it("returns to the whole list once the commit preview is unstaged", function()
        preview_repo()
        local p = open_panel()
        toggle_preview(p)
        p:stage_op("unstage_all")
        local alive, got = p:is_alive(), titles(p)
        local rev_after = view_in_origin(p).model.new_rev
        p:close()
        assert.is_true(alive)
        assert.are.same({ "Unstaged", "Untracked" }, got)
        assert.are.equal("WORKTREE", rev_after)
    end)

    it("df from the commit preview edits the file from the whole list", function()
        preview_repo()
        local p = open_panel()
        toggle_preview(p)
        local v = view_in_origin(p)
        v:edit_file()
        local got, rev_after, win = titles(p), v.model.new_rev, v.edit_win
        p:close()
        assert.are.same({ "Partial", "Unstaged" }, got)
        assert.are.equal("WORKTREE", rev_after)
        assert.is_truthy(win)
    end)

    -- confirm X's prompt, then wait out the re-read the preview schedules
    local function revert_confirmed(v)
        local opened = v.staging
        confirming(1, function()
            v:revert_hunk()
        end)
        vim.wait(500, function()
            return v.staging ~= opened
        end)
    end

    it("X in the commit preview drops a staged hunk from the index and the file", function()
        local root = preview_repo()
        local p = open_panel()
        toggle_preview(p)
        local v = view_in_origin(p)
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 2), 0 })
        revert_confirmed(v)
        local index, work = indexed(root, "a.lua"), worktree(root, "a.lua")
        local hunks, rev_after = #v.model.hunks, v.model.new_rev
        p:close()
        assert.are.equal(twelve({ "1x" }), index)
        assert.are.equal(twelve({ "1x", [12] = "12x" }), work)
        assert.are.equal(1, hunks)
        assert.are.equal("INDEX", rev_after) -- still the preview
    end)

    -- 1x staged and then edited to 1y: taking 1x out of the file would lose 1y
    it("X in the commit preview refuses a hunk the file has changed since staging", function()
        local root = staged_then(twelve({ "1y", [12] = "12x" }))
        local p = open_panel()
        toggle_preview(p)
        local v = view_in_origin(p)
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        _G.notifs = {}
        confirming(1, function()
            v:revert_hunk()
        end)
        local msg = _G.notifs[#_G.notifs].msg
        local index, work = indexed(root, "a.lua"), worktree(root, "a.lua")
        p:close()
        assert.are.equal("differ: the file has changed these lines: nothing reverted", msg)
        assert.are.equal(twelve({ "1x" }), index)
        assert.are.equal(twelve({ "1y", [12] = "12x" }), work)
    end)

    -- the index drops l6 l7 and the worktree does too, with three lines added on top:
    -- the deletion's index line number is three short of where it sits in the file
    it("X in the commit preview puts a staged deletion back where the file has it", function()
        local root = fresh_repo()
        local head = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"
        write(root .. "/a.lua", head)
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "l1\nl2\nl3\nl4\nl5\nl8\nl9\nl10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "n1\nn2\nn3\nl1\nl2\nl3\nl4\nl5\nl8\nl9\nl10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        toggle_preview(p)
        local v = view_in_origin(p)
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        revert_confirmed(v)
        local index, work = indexed(root, "a.lua"), worktree(root, "a.lua")
        p:close()
        assert.are.equal(head, index)
        assert.are.equal("n1\nn2\nn3\n" .. head, work)
    end)

    it("u in the commit preview refuses an index staged from outside since it opened", function()
        local root = staged_then(twelve({ "1x", [12] = "12x" }))
        local p = open_panel()
        toggle_preview(p)
        local v = view_in_origin(p)
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        stage_behind(root, twelve({ "1x", "2x" }))
        _G.notifs = {}
        v:unstage_hunk()
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local index = indexed(root, "a.lua")
        p:close()
        assert.are.equal("differ: the index changed outside differ: re-reading", said)
        assert.are.equal(twelve({ "1x", "2x" }), index)
    end)

    it("X in the commit preview deletes a staged add", function()
        local root = preview_repo()
        git(root, "add", "c.lua") -- nothing unstaged on top, which X would refuse
        local p = open_panel()
        toggle_preview(p)
        assert.is_true(p:goto_path("c.lua", true))
        local v = view_in_origin(p)
        confirming(1, function()
            v:revert_hunk()
        end)
        local on_disk = vim.fn.filereadable(root .. "/c.lua")
        local status = git(root, "status", "--porcelain=v1", "--", "c.lua")
        p:close()
        assert.are.equal(0, on_disk)
        assert.are.equal("", status)
    end)

    it("dw and ds say why they do nothing", function()
        preview_repo()
        local p = open_panel()
        toggle_preview(p)
        local v = view_in_origin(p)
        _G.notifs = {}
        v:toggle_local()
        local dw_msg = _G.notifs[#_G.notifs].msg
        p:close()

        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = {}, open_first = true })
        p = Panel.current()
        _G.notifs = {}
        toggle_preview(p)
        local ds_msg, got = _G.notifs[#_G.notifs].msg, titles(p)
        p:close()
        assert.are.equal("differ: the commit preview has no local view: ds goes back", dw_msg)
        assert.are.equal("differ: nothing staged to preview", ds_msg)
        assert.are.same({ "Unstaged" }, got)
    end)

    -- the winbar counts the hunks the index holds whole and in part; zero counts drop out
    it("tallies staged and partial hunks in the diff winbar", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\n2\n3x\n4y\n5y\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        local mixed = winbar_of(v)
        v:stage_hunk()
        local whole = winbar_of(v)
        v:unstage_hunk()
        local none = winbar_of(v)
        p:close()
        assert.is_truthy(mixed:find(" 1 partial · hunk 1/1 ", 1, true))
        assert.is_truthy(whole:find(" hunk 1/1 ", 1, true))
        assert.is_nil(whole:find("staged ·", 1, true)) -- every hunk staged: no tally
        assert.is_truthy(none:find(" hunk 1/1 ", 1, true))
        assert.is_nil(none:find("staged", 1, true))
        assert.is_nil(none:find("partial", 1, true))
    end)

    -- the winbar as drawn on the screen grid rather than re-evaluated, so a stale one shows
    local function drawn_winbar(v)
        local win = v.columns[#v.columns].winid
        vim.cmd("redraw")
        local row, col = unpack(vim.api.nvim_win_get_position(win))
        local chars = {}
        for c = col + 1, col + vim.api.nvim_win_get_width(win) do
            chars[#chars + 1] = vim.fn.screenstring(row + 1, c)
        end
        return table.concat(chars)
    end

    it("redraws the winbar tally as soon as a hunk is unstaged", function()
        partly_staged_repo()
        local p, v = open_panel()
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        local before = drawn_winbar(v)
        v:unstage_hunk()
        local after = drawn_winbar(v)
        p:close()
        assert.is_truthy(before:find("2 staged", 1, true))
        assert.is_truthy(after:find("1 staged", 1, true))
    end)

    it("tallies staged hunks beside unstaged ones", function()
        partly_staged_repo()
        local p = open_panel()
        local text = winbar_of(view_in_origin(p))
        p:close()
        assert.is_truthy(text:find(" 2 staged · hunk %d/3 "))
        assert.is_nil(text:find("partial", 1, true))
    end)
end)
