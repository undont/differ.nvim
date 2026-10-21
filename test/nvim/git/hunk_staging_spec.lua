-- runs under headless nvim against a throwaway git repo: s / u / S / U on the
-- diff's hunks, in place, and how the open diff re-sources around them
local git_src = require("differ.git")
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local V1 = helpers.V1
local fresh_repo = helpers.fresh_repo
local view_in_origin = helpers.view_in_origin
local open_panel = helpers.open_panel
local confirming = helpers.confirming
local indexed = helpers.indexed
local worktree = helpers.worktree
local committed = helpers.committed
local hunk_line = helpers.hunk_line
local staged_as = helpers.staged_as
local lines_of = helpers.lines_of
local winbar_of = helpers.winbar_of
local gutter_of = helpers.gutter_of

describe(":Differ diff hunk staging", function()
    local Panel = require("differ.panel")

    -- an "RM": a.lua renamed to b.lua and edited in the index, then edited again in the
    -- worktree
    ---@return string path  -- the new name
    local function rename_and_edit(root, staged_text, work_text)
        git(root, "mv", "a.lua", "b.lua")
        write(root .. "/b.lua", staged_text)
        git(root, "add", "b.lua")
        write(root .. "/b.lua", work_text)
        return "b.lua"
    end

    it("stages one hunk in place: index updated, worktree kept, diff stays frozen", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two far-apart edits
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("unstaged", v:_hunk_state(1)) -- index↔worktree opens unstaged
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
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("unstaged", v:_hunk_state(2))
        p:close()
    end)

    -- the in-place staged marks are the whole point of the frozen diff, and the watcher
    -- protects them by re-sourcing only when git moved for a reason differ didn't cause.
    -- a staging key pressed in the sidebar writes the index too, so it has to re-baseline
    -- that signature or the next watcher fire reads it as an outside change
    it("keeps in-place staged marks across a staging op driven from the panel", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two hunks to mark
        write(root .. "/z.lua", "z1x\nz2\n") -- a second file to stage from the panel
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk() -- mark hunk 1 in place, leaving hunk 2 unstaged
        assert.are.equal("staged", v:_hunk_state(1))

        -- stage a *different* file whole, from the sidebar
        vim.api.nvim_set_current_win(p.winid)
        assert.is_true(p:focus_file("z.lua"))
        p:stage_op("stage")
        assert.are.equal("z1x\nz2\n", indexed(root, "z.lua")) -- z.lua really is staged

        -- the index write that caused: the watcher fires, and must read it as differ's
        -- own doing rather than re-sourcing a.lua's diff out from under the marks
        p.on_external_change()

        assert.are.equal(2, #v.model.hunks) -- still frozen on the same two hunks
        assert.are.equal("staged", v:_hunk_state(1)) -- and hunk 1 is still marked staged
        assert.are.equal("unstaged", v:_hunk_state(2))
        p:close()
    end)

    it("unstages a staged hunk in place, then re-stages it", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- whole change staged
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("staged", v:_hunk_state(1)) -- a staged (HEAD↔index) diff
        assert.are.equal("staged", v:_hunk_state(1)) -- opens marked staged
        assert.are.equal("local x = 2\nreturn x\n", indexed(root, "a.lua"))

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:unstage_hunk()
        assert.are.equal(V1, indexed(root, "a.lua")) -- index reverted to HEAD
        assert.are.equal("unstaged", v:_hunk_state(1)) -- now marked unstaged, still visible

        v:stage_hunk() -- u then s on the same hunk: the mark toggles back
        assert.are.equal("local x = 2\nreturn x\n", indexed(root, "a.lua"))
        assert.are.equal("staged", v:_hunk_state(1))
        p:close()
    end)

    it("notifies rather than re-applying when a hunk is already in the target state", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two far-apart edits
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()
        assert.are.equal("staged", v:_hunk_state(1))

        -- s/u on a hunk already in the target state re-enter the review flow instead
        -- (stage_hunk/unstage_hunk step past it), so _toggle_hunk itself is called
        -- directly here to exercise its own already-staged/already-unstaged guard
        _G.notifs = {}
        v:_toggle_hunk(true)
        assert.are.equal("differ: hunk already staged", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)
        assert.are.equal("staged", v:_hunk_state(1)) -- state untouched

        v:_toggle_hunk(false) -- actually unstage it, so the mirror check below is real
        assert.are.equal("unstaged", v:_hunk_state(1))
        _G.notifs = {}
        v:_toggle_hunk(false)
        assert.are.equal("differ: hunk already unstaged", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)
        assert.are.equal("unstaged", v:_hunk_state(1)) -- state untouched
        p:close()
    end)

    it("stages an untracked file as one whole-file hunk instead of warning", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "alpha\nbeta\n") -- untracked, the only change
        vim.cmd.edit(root .. "/new.lua")

        local p, v = open_panel()
        assert.is_not_nil(v.staging) -- a new file now offers (whole-file) staging
        assert.are.equal("unstaged", v:_hunk_state(1))
        assert.are.equal(1, #v.model.hunks) -- empty<->content is a single hunk

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()
        assert.are.equal("alpha\nbeta\n", indexed(root, "new.lua")) -- whole file staged
        assert.are.equal("staged", v:_hunk_state(1))

        v:unstage_hunk() -- u back: leaves the index, untracked again
        assert.are.equal("unstaged", v:_hunk_state(1))
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

        local p, v = open_panel()
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

    -- a change made outside differ can turn the shown file into a different kind of
    -- change, and the keys then act on that one instead, so the swap can't be silent
    it("says when an external change re-sources the diff onto another status", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        assert.are.equal("M", p:current_entry().status)

        _G.notifs = {}
        os.remove(root .. "/a.lua") -- a modification becomes a deletion
        write(root .. "/other.lua", "unrelated\n")
        git(root, "add", "other.lua")
        p:reload()

        local msg
        for _, n in ipairs(_G.notifs) do
            if tostring(n.msg):find("changed outside differ", 1, true) then
                msg = tostring(n.msg)
            end
        end
        assert.is_truthy(msg)
        assert.is_truthy(msg:find("a.lua", 1, true))
        p:close()
    end)

    it("stays quiet when the re-source lands on the same pair", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()

        _G.notifs = {}
        write(root .. "/a.lua", "local x = 99\nreturn x\n") -- same file, same pair
        write(root .. "/b.lua", "new\n")
        git(root, "add", "b.lua")
        p:reload()

        for _, n in ipairs(_G.notifs) do
            assert.is_nil(tostring(n.msg):find("changed outside differ", 1, true))
        end
        p:close()
    end)

    -- the panel's own staging keys move the index under the open diff, so the window
    -- re-sources to pick up the marks
    it("re-sources the open diff when the panel's own keys stage the file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        assert.are.equal("unstaged", view_in_origin(p):_hunk_state(1))

        _G.notifs = {}
        p:stage_op("stage_all") -- S on the panel row, not in the diff

        local v = view_in_origin(p)
        assert.are.equal("WORKTREE", v.model.new_rev) -- still HEAD↔worktree
        assert.are.equal("staged", v:_hunk_state(1))
        -- differ's own doing, so it isn't reported the way an outside change is
        for _, n in ipairs(_G.notifs) do
            assert.is_nil(tostring(n.msg):find("changed outside differ", 1, true))
        end
        p:close()
    end)

    it("follows a delete-plus-add pair to the rename the panel then lists", function()
        local root = fresh_repo()
        write(root .. "/old.lua", string.rep("a line\n", 20))
        git(root, "add", "old.lua")
        git(root, "commit", "-q", "-m", "add old.lua")
        git(root, "mv", "old.lua", "new.lua")
        git(root, "reset", "-q", "HEAD") -- unstaged: a deletion plus an untracked file
        vim.cmd.edit(root .. "/new.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("old.lua"))
        p:select(true)
        assert.are.equal("old.lua", view_in_origin(p).model.path)

        p:stage_op("stage_all") -- both halves reach the index, and git pairs them

        -- old.lua has no entry left at all, so the window moves to the rename rather
        -- than sitting on a deletion the change set no longer holds
        assert.are.equal("new.lua", view_in_origin(p).model.path)
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

        local p, v = open_panel()

        -- opened a.lua (the current file) though m.lua sorts first in the list
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n", v.model.new_text)
        -- and snapped to the second hunk (nearest the cursor), not the first
        local col = v.columns[#v.columns]
        local row = vim.api.nvim_win_get_cursor(col.winid)[1]
        assert.are.equal(2, col.map.lines[row].hunk)
        p:close()
    end)

    -- an "MM" file takes one row diffing HEAD↔worktree. the origin line is a worktree
    -- line, and the union pair's new side is the worktree, so it lands exactly rather
    -- than being read in index coordinates and snapping to a stray hunk
    it("opens an MM file on its union pair, holding the exact origin line", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n") -- staged: a hunk at line 1
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n") -- unstaged: a hunk at line 10

        vim.cmd.edit(root .. "/a.lua")
        vim.api.nvim_win_set_cursor(0, { 10, 2 }) -- on the unstaged change

        local p, v = open_panel()

        -- HEAD↔worktree, carrying both the staged hunk at line 1 and the unstaged one
        assert.are.equal(committed(root, "a.lua"), v.model.old_text)
        assert.are.equal(worktree(root, "a.lua"), v.model.new_text)
        assert.are.equal(2, #v.model.hunks)

        -- line 10 is a changed line there, so it's held exactly (column included)
        -- rather than falling back to the nearest hunk
        local col = v.columns[#v.columns]
        local row, ccol = unpack(vim.api.nvim_win_get_cursor(col.winid))
        assert.are.equal(10, col.map.lines[row].new)
        assert.is_not_nil(col.map.lines[row].hunk)
        assert.are.equal(2, ccol)
        p:close()
    end)

    -- a file staged outright has a worktree equal to its index, so its HEAD↔worktree
    -- diff is the staged change, every hunk marked
    it("opens a fully staged origin file with its hunks marked staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- staged, with nothing left in the worktree
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(V1, v.model.old_text)
        assert.are.equal(indexed(root, "a.lua"), v.model.new_text)
        p:close()
    end)

    -- staging a file's last unstaged hunk moves its row from Partial to Staged, so the
    -- rows shift. restoring the panel cursor by line number then lands it on a
    -- different file, and ]f / [f step from there
    it("keeps the panel cursor on its file when the row leaves the section", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n") -- staged: a hunk at line 1
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- unstaged: a hunk at line 8
        write(root .. "/z.lua", "z1x\nz2\n") -- a neighbour to slide into the vacated row

        vim.cmd.edit(root .. "/a.lua")
        vim.api.nvim_win_set_cursor(0, { 8, 0 })

        local p, v = open_panel()
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("unstaged", v:_hunk_state(2))
        local before = p:current_entry()
        assert.are.equal("a.lua", before.path)
        assert.are.equal("M", before.y)

        -- the open landed on the line-8 hunk already; stage it, emptying the unstaged side
        vim.api.nvim_set_current_win(p.origin_win)
        local col = v.columns[#v.columns]
        assert.is_not_nil(col.map.lines[vim.api.nvim_win_get_cursor(col.winid)[1]].hunk)
        v:stage_hunk()
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua"))

        -- a.lua moved to the Staged section; the cursor follows the file there rather
        -- than staying on the line z.lua just slid into
        local after = p:current_entry()
        assert.are.equal("a.lua", after.path)
        assert.are.equal(" ", after.y)
        -- and the selection ]f / [f step from tracks it too
        assert.are.equal("a.lua", p.meta[p.selected_row].entry.path)
        p:close()
    end)

    -- staging a file's last unstaged hunk moves only the marks: HEAD↔worktree doesn't
    -- change under staging, so the diff and the reviewer's line stay put
    it("stays on the same diff when the last unstaged hunk is staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        local path = rename_and_edit(
            root,
            "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", -- staged: a hunk at line 1
            "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n" -- unstaged: a hunk at line 10
        )

        vim.cmd.edit(root .. "/" .. path)
        vim.api.nvim_win_set_cursor(0, { 10, 2 })

        local p, v = open_panel()
        assert.are.equal(2, #v.model.hunks) -- the staged line-1 change and the line-10 one
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("unstaged", v:_hunk_state(2))
        local model = v.model

        vim.api.nvim_set_current_win(p.origin_win)
        local real_notify, said = vim.notify, {}
        vim.notify = function(msg)
            said[#said + 1] = msg
        end
        local ok, err = pcall(v.stage_hunk, v)
        vim.notify = real_notify
        assert.is_true(ok, tostring(err))

        assert.are.same({}, said)

        -- the same diff, now with every hunk marked staged
        assert.are.equal(model, v.model)
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("staged", v:_hunk_state(2))

        -- and the cursor held line 10 rather than snapping to the first hunk
        local col = v.columns[#v.columns]
        local row, ccol = unpack(vim.api.nvim_win_get_cursor(col.winid))
        assert.are.equal(10, col.map.lines[row].new)
        assert.are.equal(2, ccol)
        p:close()
    end)

    -- an "MM" file diffs HEAD↔worktree, so staging moves the marks and leaves the diff
    -- alone: no pair to empty, nothing to follow, and s/u round-trip on the same buffer
    it("stages and unstages an MM file's hunks without swapping the diff", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n")

        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()

        local buffer = vim.api.nvim_buf_get_lines(v.columns[#v.columns].bufnr, 0, -1, false)
        assert.are.equal(2, #v.model.hunks) -- both edits, in one diff
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("unstaged", v:_hunk_state(2))

        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 2), 0 })
        v:stage_hunk()

        assert.are.equal("staged", v:_hunk_state(2))
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua")) -- all of it staged
        -- the buffer never moved: only the marks did
        assert.are.same(buffer, vim.api.nvim_buf_get_lines(col.bufnr, 0, -1, false))

        v:unstage_hunk()
        assert.are.equal("unstaged", v:_hunk_state(2))
        assert.are.equal("staged", v:_hunk_state(1)) -- the other hunk is untouched
        assert.are.same(buffer, vim.api.nvim_buf_get_lines(col.bufnr, 0, -1, false))
        p:close()
    end)

    local ACME_HEAD = [==[
package main

import (
    "context"
    "fmt"
    "net/http"
    "net/http/httptrace"
    "time"
)

func main() {
    now := time.Now()
    fmt.Printf("starting up: %v\n", now.Format(time.UnixDate))

    ctx := context.TODO()

    for i := range 5 {
        startTime := time.Now()
        c := http.Client{}
        trace := httptrace.ClientTrace{
            DNSStart: func(di httptrace.DNSStartInfo) {
                fmt.Printf("dns lookup started at %v with host: %s\n", time.Now().Format(time.UnixDate), di.Host)
            },
            TLSHandshakeStart: func() {
                fmt.Printf("tls handshake started at %v\n", time.Since(startTime))
            },
            ConnectDone: func(network, addr string, err error) {
                if err != nil {
                    fmt.Printf("failed to connect: %s\n", err.Error())
                    return
                }
                fmt.Printf("connected to network at address: %s\n", addr)
            },
        }
        traceCtx := httptrace.WithClientTrace(ctx, &trace)
        req, err := http.NewRequestWithContext(traceCtx, http.MethodGet, "https://acme.example/download?bytes=42", nil)
        if err != nil {
            panic(err)
        }

        _, err = c.Do(req)
        if err != nil {
            panic(err)
        }
        fmt.Printf("request %d took %v\n", i, time.Since(startTime))
    }

    fmt.Printf("total time lapsed: %s\n", time.Since(now).String())
}
]==]

    local ACME_WORK = [==[
package main

import (
    "context"
    "fmt"
    "io"
    "net/http"
    "net/http/httptrace"
    "slices"
    "time"
)

func main() {
    now := time.Now()
    times := []time.Duration{}
    ctx := context.TODO()
    url := "https://acme.example/download?bytes=1337"

    fmt.Printf("starting up: %v\n", now.Format(time.UnixDate))

    for i := range 5 {
        reqTime := ping(ctx, url, i)
        fmt.Printf("request %d took %v\n", i, reqTime)
        times = append(times, reqTime)
    }

    slices.Sort(times)

    fmt.Printf("total time lapsed: %s\nmedian request: %v\n", time.Since(now).String(), median(times))
}

func ping(ctx context.Context, url string, iteration int) time.Duration {
    now := time.Now()
    c := http.Client{}
    trace := httptrace.ClientTrace{
        DNSStart: func(di httptrace.DNSStartInfo) {
            fmt.Printf("dns lookup started at %v with host: %s\n", time.Now().Format(time.UnixDate), di.Host)
        },
        TLSHandshakeStart: func() {
            fmt.Printf("tls handshake started at %v\n", time.Now().Format(time.UnixDate))
        },
        ConnectDone: func(network, addr string, err error) {
            if err != nil {
                fmt.Printf("failed to connect: %s\n", err.Error())
                return
            }
            fmt.Printf("connected to network at address: %s\n", addr)
        },
        GotFirstResponseByte: func() {
            fmt.Printf("response %d took %s to get first response byte\n", iteration, time.Since(now).String())
        },
    }
    traceCtx := httptrace.WithClientTrace(ctx, &trace)
    req, err := http.NewRequestWithContext(traceCtx, http.MethodGet, url, nil)
    if err != nil {
        panic(err)
    }

    resp, err := c.Do(req)
    if err != nil {
        panic(err)
    }

    io.Copy(io.Discard, resp.Body)

    defer resp.Body.Close()

    return time.Since(now)
}

func median(input []time.Duration) time.Duration {
    middle := len(input) / 2
    if len(input)%2 == 1 {
        return input[middle]
    }

    return (input[middle-1] + input[middle]) / 2
}

func getDownloadSpeed() {
    // throughput = bytes / (t_end − t_first_byte)
}
]==]

    -- with hunks 1-4 staged, HEAD↔index keeps `ctx` in place and moves the Printf, where
    -- HEAD↔worktree keeps the Printf and moves `ctx`: the index still holds whole hunks
    it("stages and unstages hunk by hunk where HEAD↔index pairs lines differently", function()
        local root = fresh_repo()
        write(root .. "/a.go", ACME_HEAD)
        git(root, "add", "a.go")
        git(root, "commit", "-q", "-m", "ping")
        write(root .. "/a.go", ACME_WORK)

        vim.cmd.edit(root .. "/a.go")
        local p, v = open_panel()
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        local function press(n, op)
            vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, n), 0 })
            v[op](v)
        end
        local function states()
            local out = {}
            for i = 1, #v.model.hunks do
                out[i] = v:_hunk_state(i)
            end
            return out
        end

        local count = #v.model.hunks
        for n = 1, 4 do
            press(n, "stage_hunk")
        end
        local staged, hidden, index = states(), v.staging.hidden_in, indexed(root, "a.go")
        press(4, "unstage_hunk")
        local after4 = states()
        press(3, "unstage_hunk")
        local after3, index3 = states(), indexed(root, "a.go")
        press(2, "unstage_hunk")
        press(1, "unstage_hunk")
        local final = indexed(root, "a.go")
        p:close()

        local h, w = vim.split(ACME_HEAD, "\n"), vim.split(ACME_WORK, "\n")
        local function joined(top, rest)
            return table.concat(vim.list_extend(top, rest), "\n")
        end
        local S, U = "staged", "unstaged"
        assert.are.equal(6, count)
        assert.are.same({ S, S, S, S, U, U }, staged)
        assert.is_nil(hidden)
        assert.are.equal(joined(vim.list_slice(w, 1, 20), vim.list_slice(h, 17)), index)
        assert.are.same({ S, S, S, U, U, U }, after4)
        assert.are.same({ S, S, U, U, U, U }, after3)
        assert.are.equal(joined(vim.list_slice(w, 1, 14), vim.list_slice(h, 13)), index3)
        assert.are.equal(ACME_HEAD, final)
    end)

    -- HEAD a b c unterminated, worktree A b c with its final newline: the ending is
    -- hunk 2, on line c
    it("stages and unstages a final newline as the last line's hunk", function()
        local head = "a\nb\nc"
        local root, p, v = staged_as(head, head, "A\nb\nc\n")
        local function states()
            local out = {}
            for i = 1, #v.model.hunks do
                out[i] = v:_hunk_state(i)
            end
            return out
        end
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        local function press(n, op)
            vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, n), 0 })
            v[op](v)
            return states(), indexed(root, "a.lua")
        end
        local before = states()
        local s1, i1 = press(1, "stage_hunk")
        local s2, i2 = press(2, "stage_hunk")
        local u2, i3 = press(2, "unstage_hunk")
        local u1, i4 = press(1, "unstage_hunk")
        local reverted = v.staging.revert(v.model, 2)
        local fd = assert(io.open(root .. "/a.lua", "rb")) -- worktree() always adds a newline
        local work, index = fd:read("*a"), indexed(root, "a.lua")
        fd:close()
        p:close()

        local S, U = "staged", "unstaged"
        assert.are.same({ U, U }, before)
        assert.are.same({ S, U }, s1)
        assert.are.equal("A\nb\nc", i1)
        assert.are.same({ S, S }, s2)
        assert.are.equal("A\nb\nc\n", i2)
        assert.are.same({ S, U }, u2)
        assert.are.equal("A\nb\nc", i3)
        assert.are.same({ U, U }, u1)
        assert.are.equal(head, i4)
        assert.is_true(reverted)
        assert.are.equal("A\nb\nc", work)
        assert.are.equal(head, index)
    end)

    -- HEAD a b _ _ c d, worktree a b B _ d: the blank beside hunk 1 also fits hunk 2
    it("stages and reverts by hunk where a blank line fits either hunk", function()
        local head = lines_of({ "a", "b", "", "", "c", "d" })
        local root, p, v = staged_as(head, head, lines_of({ "a", "b", "B", "", "d" }))
        local function states()
            local out = {}
            for i = 1, #v.model.hunks do
                out[i] = v:_hunk_state(i)
            end
            return out
        end
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        local before, hidden = states(), v.staging.hidden
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:stage_hunk()
        local staged, index = states(), indexed(root, "a.lua")
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        local unstaged = indexed(root, "a.lua")
        local reverted = v.staging.revert(v.model, 1)
        local after, work =
            indexed(root, "a.lua"), table.concat(vim.fn.readfile(root .. "/a.lua"), "\n")
        p:close()

        local S, U = "staged", "unstaged"
        assert.are.same({ U, U }, before)
        assert.is_nil(hidden)
        assert.are.same({ S, U }, staged)
        assert.are.equal(lines_of({ "a", "b", "B", "", "", "c", "d" }), index)
        assert.are.equal(head, unstaged)
        assert.is_true(reverted)
        assert.are.equal(head, after)
        assert.are.equal("a\nb\n\nd", work)
    end)

    -- hunk 3 staged without its `url` line and hunk 4 staged whole: u on 3 leaves 4 alone
    it("unstages a partly staged hunk without reaching the whole one beside it", function()
        local h, w = vim.split(ACME_HEAD, "\n"), vim.split(ACME_WORK, "\n")
        local function joined(...)
            local out = {}
            for _, part in ipairs({ ... }) do
                vim.list_extend(out, part)
            end
            return table.concat(out, "\n")
        end
        local index =
            joined(vim.list_slice(w, 1, 16), vim.list_slice(w, 18, 20), vim.list_slice(h, 17))
        local root, p, v = staged_as(ACME_HEAD, index, ACME_WORK)
        local function states()
            local out = {}
            for i = 1, #v.model.hunks do
                out[i] = v:_hunk_state(i)
            end
            return out
        end
        local before, hidden = states(), v.staging.hidden_in
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 3), 0 })
        v:unstage_hunk()
        local after, written = states(), indexed(root, "a.lua")
        p:close()

        local S, U, P = "staged", "unstaged", "partial"
        assert.are.same({ S, S, P, S, U, U }, before)
        assert.is_nil(hidden)
        assert.are.same({ S, S, U, S, U, U }, after)
        local want =
            joined(vim.list_slice(w, 1, 14), vim.list_slice(h, 13, 14), vim.list_slice(h, 17))
        assert.are.equal(want, written)
    end)

    -- HEAD 1..7, index 1 A B C D E 7, worktree 1 A2 3 4 D2 E2 7: the index's B C sit
    -- between the two hunks, where neither u nor s on one hunk can reach them
    local JOINED = {
        head = lines_of({ "1", "2", "3", "4", "5", "6", "7" }),
        index = lines_of({ "1", "A", "B", "C", "D", "E", "7" }),
        work = lines_of({ "1", "A2", "3", "4", "D2", "E2", "7" }),
    }

    it("U gives the index HEAD's text where hunk by hunk can't", function()
        local root, p, v = staged_as(JOINED.head, JOINED.index, JOINED.work)
        local prompt = confirming(1, function()
            v:unstage_all()
        end)
        local written, hidden = indexed(root, "a.lua"), v.staging.hidden
        p:close()
        assert.are.equal("Unstage all of a.lua? Some staged changes will be lost.", prompt)
        assert.are.equal(JOINED.head, written)
        assert.is_nil(hidden)
    end)

    -- 2x staged and then edited again to 2y: the index's 2x is on neither side
    it(
        "u on a ! hunk in the whole change asks before dropping what only the index holds",
        function()
            local head, index = lines_of({ "1", "2", "3" }), lines_of({ "1", "2x", "3" })
            local root, p, v = staged_as(head, index, lines_of({ "1", "2y", "3" }))
            local win = v.columns[#v.columns].winid
            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_cursor(win, { hunk_line(v, 1), 0 })
            local prompt = confirming(2, function()
                v:unstage_hunk()
            end)
            local kept = indexed(root, "a.lua")
            confirming(1, function()
                v:unstage_hunk()
            end)
            local dropped = indexed(root, "a.lua")
            p:close()
            assert.are.equal("Unstage hunk 1/1 in a.lua? The staged change will be lost.", prompt)
            assert.are.equal(index, kept)
            assert.are.equal(head, dropped)
        end
    )

    -- 2x staged with +x, then -x and 2y on disk: the mode change doesn't hide 2x from u
    it("u on a ! hunk asks too when the index also holds a mode change", function()
        local root = fresh_repo()
        write(root .. "/a.lua", lines_of({ "1", "2", "3" }))
        git(root, "commit", "-q", "-am", "head")
        local index = lines_of({ "1", "2x", "3" })
        write(root .. "/a.lua", index)
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        git(root, "add", "a.lua")
        vim.fn.setfperm(root .. "/a.lua", "rw-r--r--")
        write(root .. "/a.lua", lines_of({ "1", "2y", "3" }))
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local win = v.columns[#v.columns].winid
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { hunk_line(v, 1), 0 })
        local prompt = confirming(2, function()
            v:unstage_hunk()
        end)
        local kept = indexed(root, "a.lua")
        local mode = git(root, "ls-files", "-s", "--", "a.lua"):match("^(%d+)")
        p:close()
        assert.are.equal("Unstage hunk 1/1 in a.lua? The staged change will be lost.", prompt)
        assert.are.equal(index, kept)
        assert.are.equal("100755", mode)
    end)

    it("u on a staged edit whose file was deleted asks before dropping it", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "edited\n")
        git(root, "add", "a.lua")
        os.remove(root .. "/a.lua")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/b.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("a.lua", true))
        local prompt = confirming(1, function()
            view_in_origin(p):unstage_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1", "--", "a.lua")
        p:close()
        assert.are.equal("Unstage a.lua? The staged change will be lost.", prompt)
        assert.are.equal(" D a.lua\n", status)
    end)

    it(
        "u on a binary file staged and changed again asks before dropping the staged blob",
        function()
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
            local prompt = confirming(2, function()
                view_in_origin(p):unstage_hunk()
            end)
            local status = git(root, "status", "--porcelain=v1", "--", "b.dat")
            p:close()
            assert.are.equal("Unstage b.dat? The staged change will be lost.", prompt)
            assert.are.equal("MM b.dat\n", status)
        end
    )

    it("S gives the index the worktree's text where hunk by hunk can't", function()
        local root, p, v = staged_as(JOINED.head, JOINED.index, JOINED.work)
        v:stage_all()
        local written, hidden = indexed(root, "a.lua"), v.staging.hidden
        p:close()
        assert.are.equal(JOINED.work, written)
        assert.is_nil(hidden)
    end)

    -- +x staged over HEAD's 644: no hunk shows the mode, and S and U still land the
    -- index on the mode of the side they take
    local function with_staged_mode(work_exec)
        local root, p, v = staged_as(JOINED.head, JOINED.index, JOINED.work)
        local sha = git(root, "rev-parse", ":0:a.lua"):gsub("%s+$", "")
        git(root, "update-index", "--cacheinfo", "100755," .. sha .. ",a.lua")
        if work_exec then
            vim.fn.system({ "chmod", "+x", root .. "/a.lua" })
        end
        return root, p, v
    end
    local function index_mode(root)
        return git(root, "ls-files", "-s", "--", "a.lua"):match("^(%d+)")
    end

    it("S takes the worktree's mode", function()
        local root, p, v = with_staged_mode(false)
        v:stage_all()
        local mode = index_mode(root)
        p:close()
        assert.are.equal("100644", mode)
    end)

    it("S keeps a mode the worktree has too", function()
        local root, p, v = with_staged_mode(true)
        v:stage_all()
        local mode = index_mode(root)
        p:close()
        assert.are.equal("100755", mode)
    end)

    it("U takes HEAD's mode", function()
        local root, p, v = with_staged_mode(true)
        confirming(1, function()
            v:unstage_all()
        end)
        local mode = index_mode(root)
        p:close()
        assert.are.equal("100644", mode)
    end)

    -- 5x staged and then put back to 5 on disk: no hunk shows it, U still takes it out
    it("U drops staged content no hunk shows", function()
        local ten = {}
        for i = 1, 10 do
            ten[i] = tostring(i)
        end
        local head = lines_of(ten)
        ten[5] = "5x"
        local index = lines_of(ten)
        ten[5], ten[1] = "5", "1x"
        local root, p, v = staged_as(head, index, lines_of(ten))
        local hidden_before = v.staging.hidden
        confirming(1, function()
            v:unstage_all()
        end)
        local written, hidden = indexed(root, "a.lua"), v.staging.hidden
        p:close()
        assert.is_not_nil(hidden_before)
        assert.are.equal(head, written)
        assert.is_nil(hidden)
    end)

    -- the file moves on disk after the diff is drawn and before the watcher re-reads it
    for _, case in ipairs({
        {
            what = "an edit inside a hunk",
            edit = function(t)
                t[10] = "10z"
            end,
        },
        {
            what = "a line above every hunk",
            edit = function(t)
                table.insert(t, 1, "0")
            end,
        },
    }) do
        it(("refuses s on a diff drawn before %s, then re-reads"):format(case.what), function()
            local t = {}
            for i = 1, 12 do
                t[i] = tostring(i)
            end
            local head = lines_of(t)
            t[3], t[10] = "3x", "10x"
            local root, p, v = staged_as(head, head, lines_of(t))
            local drawn = v.model
            case.edit(t)
            write(root .. "/a.lua", lines_of(t))
            local col = v.columns[#v.columns]
            vim.api.nvim_set_current_win(col.winid)
            vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 2), 0 })
            _G.notifs = {}
            v:stage_hunk()
            local written = indexed(root, "a.lua")
            local said = (_G.notifs[#_G.notifs] or {}).msg or ""
            vim.wait(1000, function()
                return v.model ~= drawn
            end, 20)
            local reread = v.model.new_text
            p:close()
            assert.are.equal(head, written)
            assert.is_truthy(said:find("changed since the diff was drawn", 1, true))
            assert.are.equal(lines_of(t), reread)
        end)
    end

    -- a change staged and then edited again within a few lines merges into one
    -- HEAD↔worktree hunk holding both. it reads as partial, and per line the marks still
    -- say which of it the index has
    it("marks a merged hunk partial and stages the rest with s", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\n2\n3x\n4y\n5y\n6\n7\n8\n9\n10\n")

        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()

        assert.are.equal(1, #v.model.hunks)
        assert.are.equal("partial", v:_hunk_state(1))
        -- the staged half is line 3 on each side; the later edits are not
        local col = v.columns[#v.columns]
        local dimmed = {}
        for _, line in ipairs(col.map.lines) do
            if v:_line_staged(line) then
                dimmed[#dimmed + 1] = line.kind == "old" and line.old or line.new
            end
        end
        assert.are.same({ 3, 3 }, dimmed)

        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:stage_hunk()
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    it("unstages a partial hunk with u", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\n2\n3x\n4y\n5y\n6\n7\n8\n9\n10\n")

        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.are.equal("partial", v:_hunk_state(1))

        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        assert.are.equal("unstaged", v:_hunk_state(1))
        assert.are.equal(committed(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    -- a staged insertion sits after line 2, and the edit below it starts at line 3: the
    -- one hunk they merge into holds both, so u and X reach the insertion too
    ---@param root string
    ---@return differ.Panel, differ.View
    local function insert_then_edit_below(root)
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\nN\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\n2\nN\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        return p, v
    end

    it("unstages an insertion staged just above the hunk's edit", function()
        local root = fresh_repo()
        local p, v = insert_then_edit_below(root)
        assert.are.equal("partial", v:_hunk_state(1))
        v:unstage_hunk()
        local state, index = v:_hunk_state(1), indexed(root, "a.lua")
        p:close()
        assert.are.equal("unstaged", state)
        assert.are.equal(committed(root, "a.lua"), index)
    end)

    it("reverts an insertion staged just above the hunk's edit from both sides", function()
        local root = fresh_repo()
        local p, v = insert_then_edit_below(root)
        confirming(1, function()
            v:revert_hunk()
        end)
        local work, index = worktree(root, "a.lua"), indexed(root, "a.lua")
        p:close()
        assert.are.equal(committed(root, "a.lua"), work)
        assert.are.equal(committed(root, "a.lua"), index)
    end)

    -- the worktree deletes line 3, just above the staged 4x: index↔worktree holds the
    -- deletion as an insertion point that sits before the union hunk's first line
    it("stages a deletion just above a staged edit", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3\n4x\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\n2\n4x\n5\n6\n7\n8\n9\n10\n")

        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.are.equal("partial", v:_hunk_state(1))
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:stage_hunk()
        local state, index = v:_hunk_state(1), indexed(root, "a.lua")
        p:close()
        assert.are.equal("staged", state)
        assert.are.equal(worktree(root, "a.lua"), index)
    end)

    -- the index rewrote 2..6 as A..E and the worktree put 3 and 4 back: both pairs hold
    -- one hunk across what shows as two, and B C sit only in the index
    ---@param root string
    ---@return differ.Panel, differ.View
    local function shared_change(root)
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n")
        git(root, "commit", "-q", "-am", "seven lines")
        write(root .. "/a.lua", "1\nA\nB\nC\nD\nE\n7\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\nA2\n3\n4\nD2\nE2\n7\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        _G.notifs = {}
        return p, v
    end

    for _, case in ipairs({
        {
            key = "s",
            op = "stage_hunk",
            what = "this hunk can't be staged without hunk 2; stage it from dw",
        },
        {
            key = "u",
            op = "unstage_hunk",
            what = "this hunk can't be unstaged without hunk 2; unstage it from ds",
        },
        {
            key = "X",
            op = "revert_hunk",
            what = "this hunk can't be reverted without hunk 2",
        },
    }) do
        it(("refuses %s on a hunk sharing a change with the next"):format(case.key), function()
            local root = fresh_repo()
            local p, v = shared_change(root)
            local before = { worktree(root, "a.lua"), indexed(root, "a.lua") }
            local hunks = #v.model.hunks
            local prompt = confirming(1, function()
                v[case.op](v)
            end)
            local after = { worktree(root, "a.lua"), indexed(root, "a.lua") }
            -- the first thing said, since s and u go on to step the walk and may
            -- announce a wrap after the refusal
            local said = (_G.notifs[1] or {}).msg or ""
            p:close()
            assert.are.equal(2, hunks)
            assert.are.same(before, after)
            assert.is_truthy(said:find(case.what, 1, true), said)
            assert.is_nil(prompt) -- refused before anything is asked
        end)
    end

    -- the same refusal as above: s can't take hunk 1 without hunk 2, so it says where
    -- both can be taken and carries the walk on rather than parking on hunk 1
    it("steps s off a hunk sharing a change with the next", function()
        local root = fresh_repo()
        local p, v = shared_change(root)
        assert.are.equal(1, v:_hunk_index_under_cursor())
        v:stage_hunk()
        assert.are_not.equal(1, v:_hunk_index_under_cursor())
        assert.is_true(v.stuck.staged[1])
        p:close()
    end)

    -- the file is edited under the open view: X refuses before either side moves, so the
    -- index keeps its half too rather than dropping it alone
    it("X leaves the index alone when the file won't take the revert", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        local edited = "1z\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n"
        write(root .. "/a.lua", edited)
        _G.notifs = {}
        confirming(1, function()
            v:revert_hunk()
        end)
        local said = (_G.notifs[#_G.notifs] or {}).msg
        local index, work = indexed(root, "a.lua"), worktree(root, "a.lua")
        p:close()
        assert.are.equal("differ: the file changed since the diff was drawn: re-reading", said)
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", index)
        assert.are.equal(edited, work)
    end)

    -- the glob a[1].txt matches the executable a1.txt, which sorts first
    it("stages a hunk of a glob-named file keeping its own mode", function()
        local root = fresh_repo()
        local ten = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
        write(root .. "/a1.txt", "one\n")
        write(root .. "/a[1].txt", ten)
        git(root, "add", "a1.txt", "a[1].txt")
        git(root, "update-index", "--chmod=+x", "a1.txt")
        git(root, "commit", "-q", "-m", "two")
        write(root .. "/a[1].txt", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "--", ":(literal)a[1].txt")
        write(root .. "/a[1].txt", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n")

        vim.cmd.edit(vim.fn.fnameescape(root .. "/a[1].txt"))
        local p, v = open_panel()
        if v.model.path ~= "a[1].txt" then
            p:close()
            error("opened " .. v.model.path .. ", not the bracketed file")
        end
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 2), 0 })
        v:stage_hunk()
        p:close()
        local listed = git(root, "--literal-pathspecs", "ls-files", "-s", "--", "a[1].txt")
        assert.are.equal("100644", listed:match("^(%d+)"))
    end)

    -- a partial hunk still holds something to unstage, so the backward walk stops on it
    it("walks u back onto a partial hunk", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1\n2\n3x\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1\n2\n3x\n4y\n5y\n6\n7\n8\n9\n10x\n")

        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        assert.are.equal("partial", v:_hunk_state(1))
        assert.are.equal("unstaged", v:_hunk_state(2))

        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 2), 0 })
        v:unstage_hunk() -- nothing staged here, so it steps back
        assert.are.equal(hunk_line(v, 1), vim.api.nvim_win_get_cursor(col.winid)[1])
        p:close()
    end)

    -- a Partial row holds work in both directions, so the file step backwards (U with
    -- nothing staged here) lands on it rather than passing it by
    it("steps the unstage walk onto a Partial row", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        write(root .. "/b.lua", "one\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-am", "ten lines and b")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n")
        write(root .. "/b.lua", "two\n") -- unstaged only

        vim.cmd.edit(root .. "/b.lua")
        local p = open_panel()
        assert.are.equal("b.lua", view_in_origin(p).model.path)

        assert.is_true(p:step_review("prev", true, true))
        assert.are.equal("a.lua", view_in_origin(p).model.path)
        p:close()
    end)

    -- git's `\ No newline at end of file`, as a gutter glyph beside the line it belongs to
    it("marks a line its side ends on without a newline in the gutter", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "one\ntwo\n")
        git(root, "commit", "-q", "-am", "two lines")
        write(root .. "/a.lua", "one\ntwo")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        local marked, plain = {}, gutter_of(v, 1)
        for lnum, line in ipairs(v.columns[#v.columns].map.lines) do
            if gutter_of(v, lnum):find("¬", 1, true) then
                marked[#marked + 1] = line.kind
            end
        end
        p:close()
        assert.are.same({ "new" }, marked) -- only the side that lost the newline
        assert.is_nil(plain:find("¬", 1, true))
    end)

    -- the staged line edited again: the index's version reaches neither side of the diff
    it("says in the winbar when staged content isn't on screen", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "local x = 3\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        local text, gutter = winbar_of(v), gutter_of(v, hunk_line(v, 1))
        v:toggle_local()
        local local_gutter = gutter_of(v, hunk_line(v, 1))
        p:close()
        assert.is_truthy(text:find("1 hidden (dw)", 1, true))
        assert.is_truthy(gutter:find("!", 1, true)) -- the hunk it's hidden in
        assert.is_truthy(local_gutter:find("!", 1, true)) -- the local hunk that rewrote it
    end)

    it("says in the winbar when a staged mode change isn't on screen", function()
        local root = fresh_repo()
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        git(root, "add", "a.lua") -- the index holds +x
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.fn.setfperm(root .. "/a.lua", "rw-r--r--") -- the worktree is back to -x
        vim.cmd.edit(root .. "/a.lua")

        local p = open_panel()
        local text = winbar_of(view_in_origin(p))
        p:close()
        assert.is_truthy(text:find("hidden (dw)", 1, true))
    end)

    it("names a kept deletion's copy on disk in the winbar", function()
        local root = fresh_repo()
        git(root, "rm", "-q", "--cached", "a.lua")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/b.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("a.lua"))
        p:select(true)
        local v = view_in_origin(p)
        local new_rev, text = v.model.new_rev, winbar_of(v)
        p:close()
        assert.are.equal("INDEX", new_rev) -- the removal, not the copy on disk
        assert.is_truthy(text:find("untracked copy on disk", 1, true))
    end)

    -- git reset on an added file drops it from the index, and u taking the last staged
    -- line of one does the same rather than staging an empty file
    it("drops an added file from the index once nothing of it is staged", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo\n")
        git(root, "add", "new.lua")
        write(root .. "/new.lua", "one\ntwo\nthree\n") -- AM
        vim.cmd.edit(root .. "/new.lua")

        local p, v = open_panel()
        local state = v:_hunk_state(1)
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        p:close()
        assert.are.equal("partial", state)
        assert.are.equal("?? new.lua\n", git(root, "status", "--porcelain=v1", "--", "new.lua"))
    end)

    -- a rename only the worktree has made (`git add -N`) keeps the old path in the
    -- index, so staging content from it has to stage the move too
    it("stages a worktree-only rename along with the content staged from it", function()
        local root = fresh_repo()
        local lines = {}
        for n = 1, 10 do
            lines[n] = "line " .. n
        end
        write(root .. "/a.lua", table.concat(lines, "\n") .. "\n")
        git(root, "commit", "-q", "-am", "ten lines")
        os.rename(root .. "/a.lua", root .. "/b.lua")
        lines[1], lines[10] = "line 1 edited", "line 10 edited"
        write(root .. "/b.lua", table.concat(lines, "\n") .. "\n")
        git(root, "add", "-N", "b.lua") -- " R a.lua -> b.lua"
        vim.cmd.edit(root .. "/b.lua")

        local p, v = open_panel()
        local hunks = #v.model.hunks
        local col = v.columns[#v.columns]
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { hunk_line(v, 1), 0 })
        v:stage_hunk()
        p:close()
        assert.are.equal(2, hunks) -- read against HEAD's a.lua, not a whole-file add
        local status = git(root, "status", "--porcelain=v1")
        assert.are.equal("RM a.lua -> b.lua\n", status)
    end)

    -- unstaging a fully staged file's last hunk leaves the diff where it is, which is
    -- what lets s put the hunk straight back
    it("unstages and re-stages a fully staged file in place", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- staged outright: the diff opens on HEAD↔index
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(1, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 1), 0 })
        v:unstage_hunk()
        assert.are.equal(V1, indexed(root, "a.lua")) -- back to HEAD
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("unstaged", v:_hunk_state(1))

        v:stage_hunk() -- and s puts it back in place
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    it("re-sources on a worktree-only edit (no status change) via the signature", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua modified
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()

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

    it("re-marks a file staged wholesale outside differ", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua modified, unstaged
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("unstaged", v:_hunk_state(1))

        git(root, "add", "a.lua") -- stage the whole file in "lazygit"
        vim.api.nvim_exec_autocmds("FocusGained", { group = p.augroup })
        vim.wait(200, function()
            return v:_hunk_state(1) == "staged"
        end)

        -- the same diff, re-read with the hunk now marked staged
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text)
        p:close()
    end)

    it("offsets later hunks by earlier staged ones (line-count shift)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\nc\nd\n")
        git(root, "commit", "-q", "-am", "abcd")
        -- hunk 1 inserts two lines (changes the line count); hunk 2 edits d
        write(root .. "/a.lua", "a\nINS1\nINS2\nb\nc\nD\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
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

    -- git relocates a zero-context hunk by content, but a pure insertion gives its `-`
    -- side no content to match, so it falls back to the header's `+` number. leave that
    -- side in worktree coordinates and the lines land wherever the worktree put them
    it("stages a pure insertion behind an unstaged hunk at the right line", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        -- hunk 1 inserts two lines and is left alone; hunk 2 inserts one, eleven
        -- worktree lines below where it sits in the index
        write(root .. "/a.lua", "1\nA1\nA2\n2\n3\n4\n5\n6\nB1\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 })
        v:stage_hunk()
        assert.are.equal("staged", v:_hunk_state(2))
        assert.are.equal("unstaged", v:_hunk_state(1))

        -- B1 after line 6, where the hunk actually is; not after line 8, where the
        -- worktree's own numbering would put it
        assert.are.equal("1\n2\n3\n4\n5\n6\nB1\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- the mirror: unstaging a pure deletion leaves the `+` side empty, so git reads the
    -- `-` side. it applied cleanly with a stale number there, silently restoring the
    -- lines in the wrong place rather than failing
    it("unstages a pure deletion behind a staged hunk at the right line", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        -- hunk 1 inserts two lines, hunk 2 deletes two, hunk 3 keeps the unstaged side
        -- alive so the view stays frozen on it
        write(root .. "/a.lua", "1\nINS1\nINS2\n2\n3\n4\n7\n8\n9\nZ\n")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(3, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        for _, n in ipairs({ 1, 2 }) do
            vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, n), 0 })
            v:stage_hunk()
            assert.are.equal("staged", v:_hunk_state(n))
        end
        assert.are.equal("1\nINS1\nINS2\n2\n3\n4\n7\n8\n9\n10\n", indexed(root, "a.lua"))

        -- put the deletion back: lines 5 and 6 belong after 4, not earlier
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 })
        v:unstage_hunk()
        assert.are.equal("unstaged", v:_hunk_state(2))
        assert.are.equal("1\nINS1\nINS2\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)
end)

-- split pairs a pure deletion with filler rows in the new column and a pure insertion
-- with filler in the old one; staging and hunk nav find those hunks from either column
describe(":Differ diff split hunks across filler rows", function()
    local TWENTY = {}
    for i = 1, 20 do
        TWENTY[i] = tostring(i)
    end
    local BASE = table.concat(TWENTY, "\n") .. "\n"

    -- a.lua with line 3 deleted (hunk 1) and a line added after 15 (hunk 2), opened
    -- in split. `seed` adds to the repo before the panel lists it
    ---@param seed? fun(root: string)
    local function split_repo(seed)
        local root = fresh_repo()
        write(root .. "/a.lua", BASE)
        git(root, "commit", "-q", "-am", "twenty lines")
        local lines = vim.list_slice(TWENTY, 1, 2)
        vim.list_extend(lines, vim.list_slice(TWENTY, 4, 15))
        lines[#lines + 1] = "15a"
        vim.list_extend(lines, vim.list_slice(TWENTY, 16, 20))
        write(root .. "/a.lua", table.concat(lines, "\n") .. "\n")
        if seed then
            seed(root)
        end
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_layout()
        assert.are.equal(2, #v.columns)
        return root, p, v
    end
    local function indexed(root)
        return git(root, "show", ":a.lua")
    end
    -- the rows of the deletion and the insertion, the same in both columns
    local function rows(v)
        return v.columns[1].map.from_old[3], v.columns[2].map.from_new[15]
    end
    local function at(col, row)
        vim.api.nvim_set_current_win(col.winid)
        vim.api.nvim_win_set_cursor(col.winid, { row, 0 })
    end
    local function cursor(col)
        return vim.api.nvim_win_get_cursor(col.winid)[1]
    end

    it("s from the old column steps past a staged deletion to a pure insertion", function()
        local _, p, v = split_repo()
        local old = v.columns[1]
        local del, ins = rows(v)
        at(old, del)
        v:stage_hunk()
        assert.are.equal("staged", v:_hunk_state(1))

        v:stage_hunk()
        assert.are.equal(old.winid, vim.api.nvim_get_current_win())
        assert.are.equal(ins, cursor(old))
        p:close()
    end)

    it("s on a pure insertion's filler row in the old column stages it", function()
        local root, p, v = split_repo()
        local _, ins = rows(v)
        at(v.columns[1], ins)
        assert.are.equal(2, v:_hunk_index_under_cursor())

        v:stage_hunk()
        assert.are.equal("unstaged", v:_hunk_state(1))
        assert.are.equal("staged", v:_hunk_state(2))
        assert.is_truthy(indexed(root):find("15\n15a\n16\n", 1, true))
        p:close()
    end)

    it("]c from the old column visits a pure insertion", function()
        local _, p, v = split_repo()
        local old = v.columns[1]
        local del, ins = rows(v)
        at(old, 1)
        v:goto_hunk("next")
        assert.are.equal(del, cursor(old))
        v:goto_hunk("next")
        assert.are.equal(ins, cursor(old))
        v:goto_hunk("prev")
        assert.are.equal(del, cursor(old))
        p:close()
    end)

    it("]c and s from the new column reach a pure deletion", function()
        local root, p, v = split_repo()
        local new = v.columns[2]
        local del, ins = rows(v)
        at(new, 1)
        v:goto_hunk("next")
        assert.are.equal(del, cursor(new))
        assert.are.equal(1, v:_hunk_index_under_cursor())

        v:stage_hunk()
        assert.are.equal("staged", v:_hunk_state(1))
        assert.is_nil(indexed(root):find("\n3\n", 1, true))

        v:stage_hunk()
        assert.are.equal(ins, cursor(new))
        p:close()
    end)

    it("a file opening on a pure insertion lands on it in split", function()
        local _, p, v = split_repo(function(root)
            write(root .. "/b.lua", "one\n")
            git(root, "add", "b.lua")
            git(root, "commit", "-q", "-m", "b")
            write(root .. "/b.lua", "one\n" .. BASE)
        end)
        assert.are.equal("a.lua", v.model.path)
        v:step_file("next")
        v = view_in_origin(p)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal(2, #v.columns)

        local old = v.columns[1]
        assert.are.equal(v.columns[2].map.from_new[2], cursor(old))
        assert.are.equal(1, v:_hunk_index_under_cursor())
        p:close()
    end)
end)
