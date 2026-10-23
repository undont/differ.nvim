-- runs under headless nvim against a throwaway git repo: the diff's staging notices
-- name the keys `keymaps` binds, and drop a hint whose discard key is disabled
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local fresh_repo = helpers.fresh_repo
local view_in_origin = helpers.view_in_origin
local open_panel = helpers.open_panel
local confirming = helpers.confirming
local hunk_line = helpers.hunk_line

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
