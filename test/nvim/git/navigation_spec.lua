-- runs under headless nvim against a throwaway git repo: df, the review walk of
-- s / u / S / U across files, ]c / [c / ]f / [f, and where the walk stops
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
local hunk_line = helpers.hunk_line
local twelve = helpers.twelve
local paths = helpers.paths

describe(":Differ diff hunk staging", function()
    local Panel = require("differ.panel")

    -- the first buffer row of the diff showing `text`
    local function row_at(v, text)
        for row, l in ipairs(vim.api.nvim_buf_get_lines(v.columns[1].bufnr, 0, -1, false)) do
            if l == text then
                return row
            end
        end
    end
    local function fold_closed_at(v, text)
        return vim.api.nvim_win_call(v.columns[1].winid, function()
            return vim.fn.foldclosed(row_at(v, text))
        end)
    end
    local function open_fold_at(v, text)
        vim.api.nvim_win_call(v.columns[1].winid, function()
            vim.cmd(("normal! %dGzo"):format(row_at(v, text)))
        end)
    end
    local function keymaps(bufnr)
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
            lhs[m.lhs] = true
        end
        return lhs
    end

    it("df on a fully staged file edits the worktree and leaves the index alone", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n")
        git(root, "commit", "-q", "-am", "base")
        write(root .. "/a.lua", "1x\n2\n3\n") -- modify
        git(root, "add", "a.lua") -- and stage it (fully staged: worktree == index)
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("WORKTREE", v.model.new_rev)

        v:edit_file()
        assert.is_truthy(v.edit_win)
        local staged = git(root, "diff", "--cached", "--name-only") or ""
        assert.is_truthy(staged:find("a.lua", 1, true)) -- still staged
        p:close()
    end)

    -- a file deleted in the worktree has nothing on disk to open
    it("df on a worktree deletion refuses rather than opening a missing file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        os.remove(root .. "/a.lua") -- MD: an edit staged, the file then deleted
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/b.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("a.lua"))
        p:select(true)
        local v = view_in_origin(p)

        _G.notifs = {}
        v:edit_file()
        assert.is_nil(v.edit_win)
        assert.is_truthy(_G.notifs[#_G.notifs].msg:find("a.lua is not on disk", 1, true))
        p:close()
    end)

    it("df on a staged diff keeps the folds the user opened", function()
        local root = fresh_repo()
        local lines = {}
        for i = 1, 20 do
            lines[i] = tostring(i)
        end
        write(root .. "/a.lua", table.concat(lines, "\n") .. "\n")
        git(root, "commit", "-q", "-am", "20 lines")
        lines[2], lines[18] = "2x", "18x"
        write(root .. "/a.lua", table.concat(lines, "\n") .. "\n")
        git(root, "add", "a.lua")
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        v:set_context(1)
        assert.are_not.equal(-1, fold_closed_at(v, "10"))
        open_fold_at(v, "10")

        v:edit_file()
        assert.are.equal("WORKTREE", v.model.new_rev)
        assert.are.equal(-1, fold_closed_at(v, "10"))
        p:close()
    end)

    -- the file half of "search by state": from the bottom of the list the walk carries
    -- on past the end rather than reporting there's nothing left
    it("wraps the review walk past the end of the file list", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        write(root .. "/z.lua", "z1x\nz2\n")
        vim.cmd.edit(root .. "/z.lua") -- open on the last file in the list

        local p, v = open_panel()
        assert.are.equal("z.lua", v.model.path)

        _G.notifs = {}
        assert.is_true(p:step_review("next", false, true))
        assert.are.equal("a.lua", v.model.path) -- wrapped round to the file above
        -- its own wording: goto_file's would claim the first file, not the first with
        -- anything left to do
        assert.are.equal(
            "differ: wrapped to the first file left to stage",
            _G.notifs[1] and _G.notifs[1].msg
        )
        p:close()
    end)

    -- a file's own staged row sits above its unstaged one, so the forward walk meets
    -- staged rows constantly; they hold nothing to stage and must not be landed on
    it("skips staged rows when walking for something to stage", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b1\nb2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "b.lua", "z.lua")
        git(root, "commit", "-q", "-am", "three files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- a.lua: staged only, nothing left to stage
        write(root .. "/b.lua", "b1x\nb2\n") -- b.lua: unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: unstaged
        vim.cmd.edit(root .. "/z.lua")

        local p, v = open_panel()
        assert.are.equal("z.lua", v.model.path)
        -- the staged a.lua row renders first, so the wrap meets it before b.lua
        assert.is_true(file_line(p, "a.lua", true) < file_line(p, "b.lua", false))

        assert.is_true(p:step_review("next", false, true))
        assert.are.equal("b.lua", v.model.path) -- stepped over the staged a.lua
        p:close()
    end)

    -- the walk stops short of the file it started on: what's left inside it is the
    -- caller's business, and re-opening would re-source the frozen diff
    it("returns false when the open file is the only one left to stage", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- staged only
        write(root .. "/z.lua", "z1x\nz2\n") -- the only unstaged file
        vim.cmd.edit(root .. "/z.lua")

        local p, v = open_panel()
        assert.are.equal("z.lua", v.model.path)
        local hunks_before = #v.model.hunks

        assert.is_false(p:step_review("next", false, true))
        assert.are.equal("z.lua", v.model.path) -- stayed put
        assert.are.equal(hunks_before, #v.model.hunks) -- and wasn't re-sourced
        p:close()
    end)

    -- the mirror: u hunts backward for a file with something staged
    it("walks backward for a file with staged hunks", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- the staged file, rendered first
        write(root .. "/z.lua", "z1x\nz2\n") -- unstaged
        vim.cmd.edit(root .. "/z.lua")

        local p, v = open_panel()
        assert.are.equal("z.lua", v.model.path)

        assert.is_true(p:step_review("prev", true, true))
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("staged", v:_hunk_state(1))
        p:close()
    end)

    -- the reported bug: starting partway down a file leaves hunk 1 behind the cursor,
    -- where a walk that only ever moves forward can't reach it. the file it started in
    -- comes first, so the leftovers are picked up before the review moves on
    it("picks up the hunks left behind when review starts mid-file", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua: one hunk, above z.lua
        write(root .. "/z.lua", "1x\n2\n3\n4\n5x\n6\n7\n8\n9x\n") -- z.lua: three hunks
        vim.cmd.edit(root .. "/z.lua")

        local p, v = open_panel()
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(3, #v.model.hunks)

        -- stage from hunk 2 down, deliberately leaving hunk 1 alone
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 })
        v:stage_hunk() -- stage hunk 2
        v:stage_hunk() -- advance to hunk 3
        assert.are.equal(hunk_line(v, 3), vim.api.nvim_win_get_cursor(p.origin_win)[1])
        v:stage_hunk() -- stage hunk 3
        assert.are.equal("staged", v:_hunk_state(2))
        assert.are.equal("staged", v:_hunk_state(3))
        assert.are.equal("unstaged", v:_hunk_state(1))

        -- at the bottom of the file: back round to the hunk left behind, not off to
        -- another file, and without re-sourcing the frozen diff
        _G.notifs = {}
        v:stage_hunk()
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(3, #v.model.hunks)
        assert.are.equal(hunk_line(v, 1), vim.api.nvim_win_get_cursor(p.origin_win)[1])
        assert.are.equal(
            "differ: wrapped to the first hunk left to stage",
            _G.notifs[1] and _G.notifs[1].msg
        )

        v:stage_hunk() -- stage it: z.lua is done, and follows to its staged side
        assert.are.equal(worktree(root, "z.lua"), indexed(root, "z.lua"))
        assert.are.equal("staged", v:_hunk_state(1))

        -- only now does the review leave, for the file it never opened
        vim.api.nvim_set_current_win(p.origin_win)
        v:stage_hunk()
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("unstaged", v:_hunk_state(1))
        p:close()
    end)

    -- the minimal case: one file, so the wrap is the only place left to look
    it("wraps back to an earlier hunk in the same file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        git(root, "commit", "-q", "-am", "nine lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5x\n6\n7\n8\n9x\n") -- the only file, three hunks
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(3, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 })
        v:stage_hunk() -- stage hunk 2
        v:stage_hunk() -- advance to hunk 3
        v:stage_hunk() -- stage hunk 3

        _G.notifs = {}
        v:stage_hunk() -- past the last hunk: back round to hunk 1
        assert.are.equal("a.lua", v.model.path) -- same file, not re-sourced
        assert.are.equal(3, #v.model.hunks)
        assert.are.equal(hunk_line(v, 1), vim.api.nvim_win_get_cursor(p.origin_win)[1])
        assert.are.equal(
            "differ: wrapped to the first hunk left to stage",
            _G.notifs[1] and _G.notifs[1].msg
        )

        -- and it stages there, finishing the file
        v:stage_hunk()
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    -- the mirror of the forward wrap: u looks backward, so it rounds to the *last* hunk
    -- still staged rather than the first left to stage
    it("wraps round to a later staged hunk in the same file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        git(root, "commit", "-q", "-am", "nine lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5x\n6\n7\n8\n9x\n") -- the only file, three hunks
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal(3, #v.model.hunks)

        -- stage 1 and 2, leaving 3 alone: the unstaged side survives, so the view stays
        -- frozen on it rather than following the file to its staged pair
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 1), 0 })
        v:stage_hunk() -- stage hunk 1
        v:stage_hunk() -- advance to hunk 2
        v:stage_hunk() -- stage hunk 2
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("staged", v:_hunk_state(2))
        assert.are.equal("unstaged", v:_hunk_state(3))

        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 1), 0 })
        v:unstage_hunk() -- unstage hunk 1, in place
        assert.are.equal("unstaged", v:_hunk_state(1))

        _G.notifs = {}
        v:unstage_hunk() -- nothing staged behind it: round to hunk 2
        assert.are.equal("a.lua", v.model.path) -- same file, not re-sourced
        assert.are.equal(hunk_line(v, 2), vim.api.nvim_win_get_cursor(p.origin_win)[1])
        assert.are.equal(
            "differ: wrapped to the last hunk left to unstage",
            _G.notifs[1] and _G.notifs[1].msg
        )
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

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)
        -- opened from new-file line 1 (the "1" -> "1x" change), so it lands on that
        -- line's new-side row (row 2, under the deleted old "1"), not the hunk's top
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.origin_win)[1]) -- on hunk 1

        v:stage_hunk() -- stage hunk 1; cursor stays put, marked
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.origin_win)[1])

        v:stage_hunk() -- second s: advance to hunk 2 (buffer line 9)
        assert.are.equal(9, vim.api.nvim_win_get_cursor(p.origin_win)[1])

        v:stage_hunk() -- stage hunk 2
        assert.are.equal("staged", v:_hunk_state(2))

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

        local p, v = open_panel()
        v:step_file("next") -- move forward to z.lua (the last file)
        assert.are.equal("z.lua", v.model.path)

        v:unstage_hunk() -- unstage z.lua's hunk; cursor stays, now unstaged
        assert.are.equal("unstaged", v:_hunk_state(1))

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

        local p, v = open_panel()
        assert.are.equal(2, #v.model.hunks)

        v:stage_all() -- both hunks into the index in one go
        assert.are.equal("a\nINS1\nINS2\nb\nc\nD\n", indexed(root, "a.lua"))
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.equal("staged", v:_hunk_state(2))

        v:unstage_all() -- back out of the index entirely
        assert.are.equal("a\nb\nc\nd\n", indexed(root, "a.lua")) -- == HEAD
        assert.are.equal("unstaged", v:_hunk_state(1))
        assert.are.equal("unstaged", v:_hunk_state(2))
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

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)

        v:stage_all() -- a.lua now fully staged; we stay put
        assert.are.equal("a.lua", v.model.path)
        v:stage_all() -- nothing left to stage: step to z.lua
        assert.are.equal("z.lua", v.model.path)
        p:close()
    end)

    -- S carried the same positional walk s did: from the bottom of the list it claimed
    -- there were no files left, and it would land on staged rows where it does nothing
    it("S wraps past the end of the list, skipping rows with nothing to stage", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b1\nb2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "b.lua", "z.lua")
        git(root, "commit", "-q", "-am", "three files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- a.lua: staged only, nothing left to stage
        write(root .. "/b.lua", "b1x\nb2\n") -- b.lua: unstaged, above z.lua
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: unstaged, last in the list
        vim.cmd.edit(root .. "/z.lua")

        local p, v = open_panel()
        assert.are.equal("z.lua", v.model.path)

        v:stage_all() -- z.lua fully staged; the view follows to its staged side
        assert.are.equal("z1x\nz2\n", indexed(root, "z.lua"))

        v:stage_all() -- nothing left here: round the end and past the staged a.lua
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("unstaged", v:_hunk_state(1))
        p:close()
    end)

    -- U steps back to a file it can actually unstage something in, not merely to the
    -- previous one: a file with nothing staged is somewhere U would do nothing
    it("U steps back to a file with something staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n")
        git(root, "add", "a.lua") -- a.lua: one hunk, staged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, unstaged
        vim.cmd.edit(root .. "/z.lua")

        local p, v = open_panel()
        assert.are.equal("z.lua", v.model.path)

        v:unstage_all() -- nothing staged here: back to a.lua, on its last staged hunk
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("staged", v:_hunk_state(1))
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        p:close()
    end)

    it("bounded step_file stops at the list ends, but ]f / [f still wrap", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk, left unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, left unstaged
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_panel()
        assert.are.equal("a.lua", v.model.path)

        -- u / U at the first file with nothing staged: stay put, no wrap to the last
        v:unstage_hunk()
        assert.are.equal("a.lua", v.model.path)
        v:unstage_all()
        assert.are.equal("a.lua", v.model.path)

        _G.notifs = {}
        v:step_file("next") -- ]f to z.lua (the last file)
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(0, #_G.notifs) -- a plain step, not a wrap

        _G.notifs = {}
        v:step_file("next", false) -- the bounded step ]c / [c use: no wrap off the last file
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(0, #_G.notifs) -- wrap disabled, so no wrap notify either

        _G.notifs = {}
        v:step_file("next") -- ]f / [f: wraps to the first
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("differ: wrapped to the first file", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)
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

        local p, v = open_panel()
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

    it(
        "a superseding :Differ <rev> closes a live log session, not just leaves it dangling",
        function()
            local History = require("differ.history")
            local root = fresh_repo()
            write(root .. "/z.lua", "z1\nz2\n")
            git(root, "add", "z.lua")
            git(root, "commit", "-q", "-am", "two files")
            write(root .. "/a.lua", "1x\nreturn x\n") -- a.lua: one hunk, unstaged
            write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, unstaged
            vim.cmd.edit(root .. "/a.lua")

            git_src.history({ path = root .. "/a.lua" }) -- :Differ log a.lua
            assert.is_not_nil(History.current())
            assert.is_true(History.current():is_open())

            -- :Differ HEAD (a rev arg, so opts.supersede applies) must close the live log
            -- session rather than leave its History.current() dangling alongside a fresh one
            git_src.panel({ rev = { "HEAD" }, open_first = true, supersede = true })
            assert.is_nil(History.current())
            local p = Panel.current()
            local v = view_in_origin(p)
            assert.are.equal("a.lua", v.model.path)

            -- a leftover History.current() used to make goto_hunk treat this unrelated rev
            -- diff as still inside a single-commit history session, so ]c at the boundary
            -- just notified "no next hunk" instead of flowing into the next file
            vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
            _G.notifs = {}
            v:goto_hunk("next")
            assert.are.equal("z.lua", v.model.path)
            assert.are.equal(0, #_G.notifs)
            p:close()
        end
    )

    it("a superseding bare :Differ also closes a live log session", function()
        local History = require("differ.history")
        local root = fresh_repo()
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\nreturn x\n") -- a.lua: one hunk, unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.history({ path = root .. "/a.lua" }) -- :Differ log a.lua
        assert.is_not_nil(History.current())

        -- a bare `:Differ` (no rev) still passes opts.supersede = true from dispatch;
        -- it must close the live log session the same as a `:Differ <rev>` does
        git_src.panel({ rev = {}, open_first = true, supersede = true })
        assert.is_nil(History.current())
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        _G.notifs = {}
        v:goto_hunk("next")
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(0, #_G.notifs)
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

        local p, v = open_panel()
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
        local p = open_panel()
        local lhs = keymaps(view_in_origin(p).columns[1].bufnr)
        for _, k in ipairs({ "s", "u", "S", "U", "X" }) do
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
        assert.is_nil(lhs2["X"]) -- nor revertable: there's no worktree side to write
        p2:close()
    end)

    it("binds df only on a worktree-vs-base source, not a `<rev>↔worktree` open", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        -- default `:Differ` is HEAD↔worktree (uncommitted): df is bound
        local p = open_panel()
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

    -- HEAD's "x x" pair loses one line in the worktree, which the union shows under the
    -- first hunk. the index's x x reads as hunk 1's x held and hunk 2's dropped, so s on
    -- either takes the worktree's lines there and keeps the other as drawn
    for idx, want in ipairs({ "1\n2x\nx\nx\n5x\n", "1\nx\n5x\n" }) do
        it(("stages hunk %d next to a pair the union lines up differently"):format(idx), function()
            local root = fresh_repo()
            write(root .. "/a.lua", "1\n2\nx\nx\n5\n")
            git(root, "commit", "-q", "-am", "five")
            write(root .. "/a.lua", "1\nx\nx\n5x\n")
            git(root, "add", "a.lua")
            write(root .. "/a.lua", "1\n2x\nx\n5x\n")
            vim.cmd.edit(root .. "/a.lua")
            local p, v = open_panel()
            local changed = v:_apply_hunk(idx, true)
            local index = indexed(root, "a.lua")
            p:close()
            assert.is_true(changed)
            assert.are.equal(want, index)
        end)
    end

    -- staged, then the worktree puts the committed content back, so only dw reaches it
    local function put_back(root, paths)
        for _, path in ipairs(paths) do
            vim.fn.mkdir(vim.fs.dirname(root .. "/" .. path), "p")
            write(root .. "/" .. path, "one\n")
            git(root, "add", path)
        end
        git(root, "commit", "-q", "-m", "leftovers")
        for _, path in ipairs(paths) do
            write(root .. "/" .. path, "two\n")
            git(root, "add", path)
            write(root .. "/" .. path, "one\n")
        end
    end

    -- press s until a notice matches `want`, letting scheduled hand-backs run between
    local function press_s(p, want)
        for _ = 1, 30 do
            view_in_origin(p):stage_hunk()
            vim.wait(20)
            local said = (_G.notifs[#_G.notifs] or {}).msg
            if said and said:find(want) then
                return said
            end
        end
    end

    -- a.lua's one hunk to walk past, then s until the walk stops on a local view
    local function walk(root)
        write(root .. "/a.lua", "changed\n")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        _G.notifs = {}
        return p, press_s(p, "has local changes: dw shows them$")
    end

    -- the same walk, leaving each file it stops on with ]f, to its last word
    local function walk_leaving(root)
        local p = walk(root)
        local said
        for _ = 1, 10 do
            view_in_origin(p):step_file("next")
            _G.notifs = {}
            said = press_s(p, "^differ: nothing left")
                or press_s(p, "has local changes: dw shows them$")
            if said:find("^differ: nothing left") then
                break
            end
        end
        p:close()
        return said
    end

    it("stops s on a file whose local view has something left", function()
        local root = fresh_repo()
        put_back(root, { "b.lua" })
        local p, said = walk(root)
        view_in_origin(p):stage_hunk()
        local again, path = _G.notifs[#_G.notifs].msg, view_in_origin(p).model.path
        p:close()
        assert.are.equal("differ: b.lua has local changes: dw shows them", said)
        assert.are.equal(said, again)
        assert.are.equal("b.lua", path)
    end)

    it("walks on once dw has finished the file it stopped on", function()
        local root = fresh_repo()
        put_back(root, { "b.lua", "c.lua" })
        local p = walk(root)
        view_in_origin(p):toggle_local()
        _G.notifs = {}
        local stop = press_s(p, "has local changes: dw shows them$")
        view_in_origin(p):toggle_local()
        _G.notifs = {}
        local last = press_s(p, "^differ: nothing left")
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("differ: c.lua has local changes: dw shows them", stop)
        assert.are.equal("differ: nothing left to stage", last)
        assert.are.equal("M  a.lua\n", status)
    end)

    it("names a file ]f left the walk stopped on in its last word", function()
        local root = fresh_repo()
        put_back(root, { "b.lua" })
        assert.are.equal(
            "differ: nothing left to stage (b.lua has local changes: dw shows them)",
            walk_leaving(root)
        )
    end)

    -- c.lua moved to d.lua with an edit, all staged: U leaves the move staged
    it("ends the u walk without naming rows only a move keeps staged", function()
        local root = fresh_repo()
        write(root .. "/c.lua", twelve({}))
        git(root, "add", "c.lua")
        git(root, "commit", "-q", "-m", "c")
        git(root, "mv", "c.lua", "d.lua")
        write(root .. "/d.lua", twelve({ [3] = "3x" }))
        git(root, "add", "d.lua")
        vim.cmd.edit(root .. "/d.lua")
        local p = open_panel()
        _G.notifs = {}
        local said
        for _ = 1, 10 do
            view_in_origin(p):unstage_all()
            vim.wait(20)
            said = (_G.notifs[#_G.notifs] or {}).msg
            if said and said:find("^differ: nothing left") then
                break
            end
        end
        p:close()
        assert.are.equal("differ: nothing left to unstage", said)
    end)

    it("stays on the file when U refuses a drawing the file has since changed", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "one\n")
        git(root, "add", "a.lua")
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        write(root .. "/a.lua", "one\ntwo\n") -- before the watcher has re-read it
        _G.notifs = {}
        v:unstage_all()
        vim.wait(20)
        local path = view_in_origin(p).model.path
        local said = vim.tbl_map(function(n)
            return n.msg
        end, _G.notifs)
        p:close()
        assert.are.equal("a.lua", path)
        assert.is_nil(table.concat(said, "\n"):find("local changes", 1, true))
    end)

    -- b, c and d staged and then put back on disk: u on b empties its row
    it("]f after the open row leaves the list opens the row that took its place", function()
        local root = fresh_repo()
        for _, f in ipairs({ "b.lua", "c.lua", "d.lua" }) do
            write(root .. "/" .. f, "one\n")
        end
        git(root, "add", "b.lua", "c.lua", "d.lua")
        git(root, "commit", "-q", "-m", "bcd")
        for _, f in ipairs({ "b.lua", "c.lua", "d.lua" }) do
            write(root .. "/" .. f, "two\n")
            git(root, "add", f)
            write(root .. "/" .. f, "one\n")
        end
        vim.cmd.edit(root .. "/b.lua")
        local p, v = open_panel()
        confirming(1, function()
            v:unstage_hunk()
        end)
        vim.wait(20)
        view_in_origin(p):step_file("next")
        local path = view_in_origin(p).model.path
        p:close()
        assert.are.equal("c.lua", path)
    end)

    it("ends the walk once ]f has left the only file it stops on", function()
        local root = fresh_repo()
        put_back(root, { "b.lua" })
        vim.cmd.edit(root .. "/b.lua")
        local p = open_panel()
        _G.notifs = {}
        local stop = press_s(p, "has local changes: dw shows them$")
        view_in_origin(p):step_file("next")
        _G.notifs = {}
        local last = press_s(p, "^differ: nothing left")
        p:close()
        assert.are.equal("differ: b.lua has local changes: dw shows them", stop)
        assert.are.equal(
            "differ: nothing left to stage (b.lua has local changes: dw shows them)",
            last
        )
    end)

    it("doesn't stop s in the commit preview, which has no local view", function()
        local root = fresh_repo()
        put_back(root, { "b.lua" })
        vim.cmd.edit(root .. "/b.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        _G.notifs = {}
        for _ = 1, 3 do
            view_in_origin(p):stage_hunk()
            vim.wait(20)
        end
        local stops = vim.tbl_filter(function(n)
            return n.msg:find("has local changes: dw shows them$") ~= nil
        end, _G.notifs)
        p:close()
        assert.are.same({}, stops)
    end)

    it("names rows left with a local view while they fit and counts the rest", function()
        local root = fresh_repo()
        local paths = { "b.lua", "c.lua" }
        for i = 1, 3 do
            paths[#paths + 1] = ("z_leftover_with_a_rather_long_name_%d.lua"):format(i)
        end
        put_back(root, paths)
        local said = walk_leaving(root)
        assert.is_truthy(
            said:find(
                "^differ: nothing left to stage %(b.lua, c.lua.* %+%d+ have local changes: dw shows them%)$"
            ),
            said
        )
    end)

    it("names a row left with a local view whole even when it alone is past the width", function()
        local root = fresh_repo()
        local long = ("x"):rep(80) .. ".lua"
        put_back(root, { long })
        local want = ("differ: nothing left to stage (%s has local changes: dw shows them)"):format(
            long
        )
        assert.are.equal(want, walk_leaving(root))
    end)

    it("names rows left with a local view by their repo paths", function()
        local root = fresh_repo()
        put_back(root, { "x/b.lua", "y/b.lua" })
        local want =
            "differ: nothing left to stage (x/b.lua, y/b.lua have local changes: dw shows them)"
        assert.are.equal(want, walk_leaving(root))
    end)

    -- b.lua's content is staged and its index entry carries a mode the worktree doesn't:
    -- the walk can't take that, and dw opens on the mode change
    it("stops s on a row left with only a mode change", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        write(root .. "/b.lua", "two\n")
        git(root, "add", "b.lua")
        local sha = git(root, "rev-parse", ":0:b.lua"):gsub("%s+$", "")
        git(root, "update-index", "--cacheinfo", "100755," .. sha .. ",b.lua")
        local p, said = walk(root)
        local v = view_in_origin(p)
        v:toggle_local()
        local notice = v.model.notice
        p:close()
        assert.are.equal("differ: b.lua has local changes: dw shows them", said)
        assert.is_truthy(notice:find("^Mode changed"), notice)
    end)

    -- an AD: the whole change is HEAD↔index, which can't show the file being deleted
    it("stages a staged add's deletion from its local view", function()
        local root = fresh_repo()
        write(root .. "/c.lua", "one\n")
        git(root, "add", "c.lua")
        os.remove(root .. "/c.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("c.lua", true))
        local v = view_in_origin(p)
        v:toggle_local()
        local badge, hunks = v.staging.badge, #v.model.hunks
        local prompt = confirming(1, function()
            v:stage_hunk()
        end)
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal("Stage the deletion of c.lua? The staged file will be lost.", prompt)
        assert.are.equal("LOCAL", badge)
        assert.are.equal(1, hunks) -- the index's lines, all going
        assert.are.equal("", status)
    end)

    it("asks before s stages an edit's deletion from its view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        os.remove(root .. "/a.lua") -- MD: the index alone holds the edit
        write(root .. "/z.lua", "z\n")
        vim.cmd.edit(root .. "/z.lua")
        local p = open_panel()
        assert.is_true(p:goto_path("a.lua", true))
        local v = view_in_origin(p)
        local staged = git(root, "rev-parse", ":a.lua")
        local prompt = confirming(2, function()
            v:stage_hunk()
        end)
        local kept = git(root, "rev-parse", ":a.lua")
        p:close()
        assert.are.equal("Stage the deletion of a.lua? The staged file will be lost.", prompt)
        assert.are.equal(staged, kept)
    end)
end)
