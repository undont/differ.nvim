-- runs under headless nvim against a throwaway git repo: staging renames
local git_src = require("differ.git")
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local view_in_origin = helpers.view_in_origin
local confirming = helpers.confirming

-- a rename is the one whole-file status that can show several hunks, and the one that
-- owns two paths. git pairs renames only in the index, so every R entry is staged
describe(":Differ diff rename staging", function()
    local Panel = require("differ.panel")

    -- a 60-line file committed at old/big.lua, then staged-renamed to new/big.lua with
    -- `edits` (a list of line numbers) changed on the way, so the rename carries that
    -- many hunks. 60 lines keeps a few edits well above git's 50% similarity threshold,
    -- below which git reports an add and a delete instead of a rename
    local function renamed_repo(edits)
        local root = vim.fn.tempname()
        vim.fn.mkdir(root .. "/old", "p")
        git(root, "init", "-q")
        local lines = {}
        for n = 1, 60 do
            lines[n] = "line " .. n
        end
        write(root .. "/old/big.lua", table.concat(lines, "\n") .. "\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "init")
        vim.fn.mkdir(root .. "/new", "p")
        git(root, "mv", "old/big.lua", "new/big.lua")
        for _, n in ipairs(edits or {}) do
            lines[n] = lines[n] .. " edited"
        end
        write(root .. "/new/big.lua", table.concat(lines, "\n") .. "\n")
        git(root, "add", "new/big.lua")
        return root
    end

    -- put the cursor on hunk `n` in the view's primary column
    local function goto_hunk(v, n)
        local col = v.columns[1]
        for i, line in ipairs(col.map.lines) do
            if line.hunk == n then
                vim.api.nvim_win_set_cursor(col.winid, { i, 0 })
                return
            end
        end
        error("no hunk " .. n)
    end

    local function open_staged(p, path)
        assert.is_true(p:focus_file(path))
        p:select(true)
        return view_in_origin(p)
    end

    -- the paths git holds a staged change for (a non-blank X column)
    local function staged_paths(root)
        local out = {}
        for line in git(root, "status", "--porcelain=v1"):gmatch("[^\n]+") do
            if line:sub(1, 1) ~= " " and line:sub(1, 1) ~= "?" then
                out[#out + 1] = line
            end
        end
        return out
    end

    -- the hunks the staged-mark overlay paints, read back from the extmarks: a mark
    -- left behind on a hunk git no longer has staged is what the reviewer sees
    local function painted_hunks(v)
        local ns = vim.api.nvim_get_namespaces()["differ.staging"]
        local col = v.columns[1]
        local seen, out = {}, {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(col.bufnr, ns, 0, -1, {})) do
            local line = col.map.lines[mark[2] + 1]
            if line and line.hunk then
                seen[line.hunk] = true
            end
        end
        for i = 1, #v.model.hunks do
            out[i] = seen[i] or false
        end
        return out
    end

    it("moves both of a rename's paths together on u, and back on s", function()
        local root = renamed_repo()
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        local v = open_staged(p, "new/big.lua")
        assert.is_true(v.staging.whole_file)
        assert.are.same({ "R  old/big.lua -> new/big.lua" }, staged_paths(root))

        v:unstage_hunk()

        -- resetting only the new path would leave "D  old/big.lua" staged behind
        assert.are.same({}, staged_paths(root))

        view_in_origin(p):stage_hunk()

        assert.are.same({ "R  old/big.lua -> new/big.lua" }, staged_paths(root))
        p:close()
    end)

    it("opens a staged rename with all of its hunks marked staged", function()
        local root = renamed_repo({ 5, 30, 55 })
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        local v = open_staged(p, "new/big.lua")

        assert.are.equal(3, #v.model.hunks)
        assert.are.equal("staged", v:_hunk_state(1))
        assert.are.same({ true, true, true }, painted_hunks(v))
        p:close()
    end)

    -- git records no rename: a staged one is the old path absent from the index and the
    -- new path present, and `R` is a similarity reading over that. so a hunk patches the
    -- same blob it would on a modification, and the move rides along untouched
    it("unstages one hunk of a rename, leaving the move and the other hunks staged", function()
        local root = renamed_repo({ 5, 30, 55 })
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        local v = open_staged(p, "new/big.lua")
        assert.are.equal(3, #v.model.hunks)
        assert.is_falsy(v.staging.whole_file) -- hunk-level, like a modification

        goto_hunk(v, 2)
        v:unstage_hunk()

        assert.are.same({ true, false, true }, painted_hunks(view_in_origin(p)))
        -- the move survives: still one rename entry, now with content left unstaged
        assert.are.same({ "RM old/big.lua -> new/big.lua" }, staged_paths(root))
        p:close()
    end)

    it("leaves the file once every hunk of the rename is unstaged", function()
        local root = renamed_repo({ 5, 30, 55 })
        write(root .. "/other.lua", "one\ntwo\n")
        git(root, "add", "other.lua")
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        local v = open_staged(p, "new/big.lua")
        v:unstage_all() -- U: every hunk at once, the move left alone

        assert.are.same({ false, false, false }, painted_hunks(view_in_origin(p)))
        view_in_origin(p):unstage_hunk() -- nothing left here: step to the other file

        assert.are.equal("other.lua", view_in_origin(p).model.path)
        p:close()
    end)

    -- an RM: the old path is in neither the index nor the worktree, so git add refuses it
    it("stages the rest of a staged rename from the panel row without an error", function()
        local root = renamed_repo({ 5 })
        local text = table.concat(vim.fn.readfile(root .. "/new/big.lua"), "\n") .. "\n"
        write(root .. "/new/big.lua", (text:gsub("line 30\n", "line 30 unstaged\n")))
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("new/big.lua"))
        _G.notifs = {}
        p:stage_op("stage")
        local failed = false
        for _, n in ipairs(_G.notifs) do
            failed = failed or n.msg:find("failed", 1, true) ~= nil
        end
        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.is_false(failed)
        assert.are.equal("R  old/big.lua -> new/big.lua\n", status)
    end)

    it("leaves a file back at a staged rename's old path untracked on s", function()
        local root = renamed_repo({ 5 })
        write(root .. "/old/big.lua", "new file\n")
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("new/big.lua"))
        p:stage_op("stage")

        local status = git(root, "status", "--porcelain=v1", "-uall")
        p:close()
        assert.are.equal("R  old/big.lua -> new/big.lua\n?? old/big.lua\n", status)
        assert.are.same({ "new file" }, vim.fn.readfile(root .. "/old/big.lua"))
    end)

    it("unstages both of a rename's paths from the panel row, as the diff keys do", function()
        local root = renamed_repo({ 5 })
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("new/big.lua"))

        p:stage_op("unstage") -- u on the file row, not in the diff window

        -- resetting the new path alone leaves "D  old/big.lua" staged: the rename undone
        -- on one side only, and the panel disagreeing with what u in the diff does
        assert.are.same({}, staged_paths(root))
        p:close()
    end)

    it("undoes a rename with X, restoring the old path and dropping the new", function()
        local root = renamed_repo({ 5, 30 })
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("new/big.lua"))

        confirming(1, function()
            p:discard()
        end)

        -- `checkout HEAD -- new/big.lua` would have failed here: HEAD has no such path
        assert.are.same({}, staged_paths(root))
        assert.are.equal(1, vim.fn.filereadable(root .. "/old/big.lua"))
        assert.are.equal(0, vim.fn.filereadable(root .. "/new/big.lua"))
        p:close()
    end)

    it("undoes a rename with X in the index only when a file is back at the old path", function()
        local root = renamed_repo({ 5 })
        write(root .. "/old/big.lua", "new file\n")
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("new/big.lua"))

        confirming(1, function()
            p:discard()
        end)

        local status = git(root, "status", "--porcelain=v1")
        p:close()
        assert.are.equal(" M old/big.lua\n", status)
        assert.are.same({ "new file" }, vim.fn.readfile(root .. "/old/big.lua"))
        assert.are.equal(0, vim.fn.filereadable(root .. "/new/big.lua"))
    end)

    it("names the path X will restore in its confirm", function()
        local root = renamed_repo()
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("new/big.lua"))

        local prompt = confirming(2, function() -- answer No: nothing is discarded
            p:discard()
        end)

        assert.is_truthy(prompt:find("new/big.lua (restoring old/big.lua)", 1, true))
        assert.are.same({ "R  old/big.lua -> new/big.lua" }, staged_paths(root))
        p:close()
    end)

    it("refuses a rename whose status moved under the prompt", function()
        local root = renamed_repo()
        vim.cmd.edit(root .. "/new/big.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        assert.is_true(p:focus_file("new/big.lua"))

        _G.notifs = {}
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            -- unstaged from outside while the prompt blocks, leaving an untracked new
            -- path and an unstaged deletion: no longer a rename to undo
            git(root, "reset", "-q", "HEAD", "--", "new/big.lua", "old/big.lua")
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.are.equal(1, vim.fn.filereadable(root .. "/new/big.lua"))
        assert.are.equal(0, vim.fn.filereadable(root .. "/old/big.lua"))
        assert.is_truthy(_G.notifs[#_G.notifs].msg:find("discard skipped: new/big.lua", 1, true))
        p:close()
    end)

    -- a pure rename shows no lines, so the landing heuristics (gg/G, the initial open)
    -- skip it. the review walk can't: it stages and unstages as a file, and skipping it
    -- would announce the review done with that rename still staged
    it("stops the u review on a rename with no lines to show", function()
        local root = renamed_repo() -- no edits: a rename with an empty diff
        write(root .. "/other.lua", "one\ntwo\n")
        git(root, "add", "other.lua")
        vim.cmd.edit(root .. "/other.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        open_staged(p, "other.lua")

        for _ = 1, 4 do
            view_in_origin(p):unstage_hunk()
        end

        assert.are.equal("new/big.lua", view_in_origin(p).model.path) -- the walk reached it
        assert.are.same({}, staged_paths(root))
        p:close()
    end)

    it("walks the u review past a staged rename to the files beyond it", function()
        local root = renamed_repo({ 5, 30, 55 })
        write(root .. "/aaa.lua", "a1\na2\n")
        write(root .. "/zzz.lua", "z1\nz2\n")
        git(root, "add", "aaa.lua", "zzz.lua")
        vim.cmd.edit(root .. "/zzz.lua")

        git_src.panel({ rev = {} })
        local p = Panel.current()
        open_staged(p, "zzz.lua")

        -- two presses per file (unstage, then step on); the rename used to swallow the
        -- walk, leaving everything past it staged for good
        for _ = 1, 20 do
            view_in_origin(p):unstage_hunk()
        end

        -- every hunk is unstaged, the rename's included. the move itself is not a hunk
        -- and stays: unstaging that is the panel row's job, as it is for any whole file
        assert.are.same({ "RM old/big.lua -> new/big.lua" }, staged_paths(root))
        p:close()
    end)
end)
