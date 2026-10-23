-- runs under headless nvim against a throwaway git repo: the diff's and the panel's
-- staging notices name the keys `keymaps` binds on that surface, and drop a hint whose
-- discard key is disabled
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local fresh_repo = helpers.fresh_repo
local view_in_origin = helpers.view_in_origin
local open_panel = helpers.open_panel
local confirming = helpers.confirming
local hunk_line = helpers.hunk_line
local file_line = helpers.file_line

describe(":Differ diff notices with remapped keys", function()
    local Panel = require("differ.panel")

    local function last_said()
        return (_G.notifs[#_G.notifs] or {}).msg or ""
    end

    before_each(function()
        require("differ").setup({
            keymaps = {
                stage = "zs",
                toggle_local = "zw",
                commit_preview = "zp",
                diff = { discard = "zx" },
            },
        })
    end)

    after_each(function()
        require("differ").setup({})
    end)

    -- the index rewrote 2..6 and the worktree put 3 and 4 back, so hunk 1 can't move
    -- without hunk 2
    for _, case in ipairs({
        { op = "stage_hunk", what = "stage it from zw" },
        { op = "unstage_hunk", what = "unstage it from zp" },
    }) do
        it(("names the remapped key in %s's cross-hunk refusal"):format(case.op), function()
            local root = fresh_repo()
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
            v[case.op](v)
            local said = (_G.notifs[1] or {}).msg or ""
            p:close()
            assert.is_truthy(said:find(case.what, 1, true), said)
        end)
    end

    it("names the diff's own discard key when X can't take lines", function()
        local root = fresh_repo()
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        _G.notifs = {}
        v:revert_lines()
        local said = last_said()
        p:close()
        assert.are.equal("differ: a mode change has no lines to revert; zx resets it whole", said)
    end)

    it("names the remapped commit preview key in the preview's dw refusal", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "staged\n")
        git(root, "add", "a.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        v:toggle_commit_preview()
        _G.notifs = {}
        view_in_origin(p):toggle_local()
        local said = last_said()
        p:close()
        assert.are.equal("differ: the commit preview has no local view: zp goes back", said)
    end)

    it("names the remapped stage key once u leaves nothing staged", function()
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
        local said = last_said()
        p:close()
        assert.are.equal("differ: c.lua has nothing staged now: zs stages it back", said)
    end)

    it("drops the discard hint when the diff's discard is disabled", function()
        require("differ").setup({ keymaps = { diff = { discard = false } } })
        local root = fresh_repo()
        vim.fn.setfperm(root .. "/a.lua", "rwxr-xr-x")
        vim.cmd.edit(root .. "/a.lua")
        local p, v = open_panel()
        _G.notifs = {}
        v:revert_lines()
        local said = last_said()
        p:close()
        assert.are.equal("differ: a mode change has no lines to revert", said)
    end)

    it("says the panel's discard is disabled when X on a move can't point there", function()
        require("differ").setup({ keymaps = { panel = { discard = false } } })
        local root = fresh_repo()
        git(root, "mv", "a.lua", "b.lua")
        write(root .. "/keep.lua", "keep\n")
        vim.cmd.edit(root .. "/keep.lua")
        local p = open_panel()
        assert.is_true(Panel.current():goto_path("b.lua", true))
        local v = view_in_origin(p)
        _G.notifs = {}
        local prompt = confirming(1, function()
            v:revert_hunk()
        end)
        local said = last_said()
        p:close()
        assert.is_nil(prompt)
        assert.are.equal(
            "differ: the move reverts from the panel row, where discard is disabled",
            said
        )
    end)
end)

describe(":Differ panel notices with remapped keys", function()
    local function last_said()
        return (_G.notifs[#_G.notifs] or {}).msg or ""
    end

    -- ds and dw on the panel: extra_keymaps[1] and [2]
    local function toggle_preview(p)
        p.extra_keymaps[1].fn()
    end
    local function panel_dw(p)
        p.extra_keymaps[2].fn()
    end

    -- a staged edit then deleted on disk, beside a file still there to open
    local function deleted_after_staging()
        local root = fresh_repo()
        write(root .. "/a.lua", "edited\n")
        git(root, "add", "a.lua")
        os.remove(root .. "/a.lua")
        write(root .. "/b.lua", "b\n")
        vim.cmd.edit(root .. "/b.lua")
        return root
    end

    before_each(function()
        require("differ").setup({
            keymaps = {
                commit_preview = "zp",
                panel = { stage = "zs", discard = "zx" },
                diff = { stage = "ys", discard = "yx" },
            },
        })
    end)

    after_each(function()
        require("differ").setup({})
    end)

    for _, op in ipairs({ "stage", "stage_all" }) do
        it(("names the remapped preview key when %s refuses in the preview"):format(op), function()
            local root = fresh_repo()
            write(root .. "/a.lua", "staged\n")
            git(root, "add", "a.lua")
            vim.cmd.edit(root .. "/a.lua")
            local p = open_panel()
            toggle_preview(p)
            vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
            _G.notifs = {}
            p:stage_op(op)
            local said = last_said()
            p:close()
            assert.are.equal("differ: the commit preview only unstages: zp goes back", said)
        end)
    end

    it("names the remapped preview key in the panel's dw refusal", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "staged\n")
        git(root, "add", "a.lua")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        toggle_preview(p)
        _G.notifs = {}
        panel_dw(p)
        local said = last_said()
        p:close()
        assert.are.equal("differ: the commit preview has no local view: zp goes back", said)
    end)

    it("names each surface's stage key in the deletion's dw note", function()
        deleted_after_staging()
        local p = open_panel()
        assert.is_true(p:goto_path("a.lua", true))
        _G.notifs = {}
        panel_dw(p)
        local from_panel = last_said()
        view_in_origin(p):toggle_local()
        local from_diff = last_said()
        p:close()
        local note = "differ: a.lua's only local change is its deletion, which %s stages here"
        assert.are.equal(note:format("zs"), from_panel)
        assert.are.equal(note:format("ys"), from_diff)
    end)

    it("names the panel's discard key, not the diff's, when X refuses a kept deletion", function()
        local root = fresh_repo()
        git(root, "rm", "-q", "--cached", "a.lua")
        write(root .. "/a.lua", "mine\n")
        vim.cmd.edit(root .. "/a.lua")
        local p = open_panel()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", true), 0 })
        _G.notifs = {}
        local prompt = confirming(1, function()
            p:discard()
        end)
        local said = last_said()
        p:close()
        assert.is_nil(prompt)
        assert.is_truthy(said:find("zx would overwrite a.lua on disk; u unstages", 1, true), said)
    end)
end)
