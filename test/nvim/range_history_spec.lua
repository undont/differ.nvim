-- runs under headless nvim against a throwaway git repo: exercises branch-range
-- history (dp): the range commit walk, per-commit file listing (incl. a root
-- commit), the panel expanding commits to nested files, on_file driving the view,
-- and ]f/[f walking files across commits
local git_src = require("differ.git")
local History = require("differ.history")

local function git(cwd, ...)
    local args =
        { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    local res = vim.system(args, { cwd = cwd, text = true }):wait()
    assert(
        res.code == 0,
        "git failed: " .. table.concat({ ... }, " ") .. "\n" .. (res.stderr or "")
    )
    return res.stdout
end

local function write(path, content)
    local fd = assert(io.open(path, "wb"))
    fd:write(content)
    fd:close()
end

local V1, V2, V3 = "local x = 1\nreturn x\n", "local x = 2\nreturn x\n", "local x = 3\nreturn x\n"

-- main: commit1 (root: a.lua=V1, b.lua=b1) -> commit2 (a.lua=V2). then a feature
-- branch: commit3 (a.lua=V3 + c.lua added) -> commit4 (b.lua=b2)
local function repo_with_branch()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", V1)
    write(root .. "/b.lua", "b1\n")
    git(root, "add", "a.lua", "b.lua")
    git(root, "commit", "-q", "-m", "c1: seed")
    write(root .. "/a.lua", V2)
    git(root, "commit", "-q", "-am", "c2: bump a")
    git(root, "checkout", "-q", "-b", "feature")
    write(root .. "/a.lua", V3)
    write(root .. "/c.lua", "c1\n")
    git(root, "add", "a.lua", "c.lua")
    git(root, "commit", "-q", "-m", "c3: edit a, add c")
    write(root .. "/b.lua", "b2\n")
    git(root, "commit", "-q", "-am", "c4: bump b")
    return root
end

local function view_in_origin(h)
    vim.api.nvim_set_current_win(h.origin_win)
    return require("differ.view").current()
end

-- fire a buffer's ]c / [c keymap by lhs, so the test exercises the real bound
-- callback (and its opts.fallback), not a hand-rolled call to View:goto_hunk
local function goto_hunk(bufnr, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if m.lhs == lhs and m.callback then
            return m.callback()
        end
    end
    error("no " .. lhs .. " keymap bound on buffer " .. bufnr)
end

describe("git.range_commits / commit_files", function()
    it("lists the range's commits newest first, merges excluded", function()
        local root = repo_with_branch()
        local commits = git_src.range_commits(root, "main..HEAD")
        assert.are.equal(2, #commits)
        assert.are.equal("c4: bump b", commits[1].subject)
        assert.are.equal("c3: edit a, add c", commits[2].subject)
    end)

    it("lists a commit's files with status and counts", function()
        local root = repo_with_branch()
        local commits = git_src.range_commits(root, "main..HEAD")
        local files = git_src.commit_files(root, commits[2].sha) -- c3: edit a, add c
        assert.are.equal(2, #files)
        assert.are.same({ "a.lua", "c.lua" }, { files[1].path, files[2].path })
        assert.are.equal("M", files[1].status)
        assert.are.equal("A", files[2].status)
    end)

    it("lists a root commit's files via the empty tree (pure adds)", function()
        local root = repo_with_branch()
        local first = git(root, "rev-list", "--max-parents=0", "HEAD"):gsub("%s+$", "")
        local files = git_src.commit_files(root, first)
        local by_path = {}
        for _, f in ipairs(files) do
            by_path[f.path] = f.status
        end
        assert.are.equal("A", by_path["a.lua"]) -- the root commit adds everything
        assert.are.equal("A", by_path["b.lua"])
    end)
end)

describe(":Differ log <range> (branch-range history)", function()
    it("opens an expandable commit panel showing the newest commit's first file", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        assert.is_not_nil(h)
        assert.are.equal("range", h.mode)
        assert.are.equal("main..HEAD", h.lines[1]) -- the range in the header
        -- the newest commit (c4: bump b) is expanded and its file b.lua is open
        local v = view_in_origin(h)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("b1\n", v.model.old_text) -- b.lua at the parent
        assert.are.equal("b2\n", v.model.new_text) -- b.lua at c4
        h:close()
    end)

    it("expands a commit's fold without opening, then opens a file from its row", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        -- expand c3 (commit index 2): cursor on its commit row, then <CR>
        vim.api.nvim_set_current_win(h.winid)
        vim.api.nvim_win_set_cursor(h.winid, { h:_commit_line(2), 0 })
        h:select()
        -- selecting a collapsed commit only toggles its fold; no diff opens, so the
        -- view still shows c4's b.lua (opened on launch)
        assert.is_true(h:_is_expanded(2))
        assert.are.equal("b.lua", view_in_origin(h).model.path)

        -- now open c3's second file (c.lua) from its row
        vim.api.nvim_set_current_win(h.winid)
        vim.api.nvim_win_set_cursor(h.winid, { h:_file_line(2, 2), 0 })
        h:select()
        local v = view_in_origin(h)
        assert.are.equal("c.lua", v.model.path)
        assert.are.equal("", v.model.old_text) -- newly added in c3
        assert.are.equal("c1\n", v.model.new_text)
        h:close()
    end)

    it("walks files across commit boundaries with ]f / [f", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        -- start: c4's only file b.lua
        assert.are.equal(1, h.index)
        assert.are.equal("b.lua", view_in_origin(h).model.path)

        h:step("next") -- past c4's last file -> auto-expand c3, its first file a.lua
        assert.are.equal(2, h.index)
        assert.are.equal(1, h.file_index)
        assert.are.equal("a.lua", view_in_origin(h).model.path)

        h:step("next") -- c3's second file c.lua
        assert.are.equal("c.lua", view_in_origin(h).model.path)

        h:step("prev") -- back to a.lua
        assert.are.equal("a.lua", view_in_origin(h).model.path)

        h:step("prev") -- back across the boundary to c4's b.lua
        assert.are.equal(1, h.index)
        assert.are.equal("b.lua", view_in_origin(h).model.path)
        h:close()
    end)

    it("]c / [c overflow steps across a commit's files, but stops at its edges", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        h:_open_file(2, 1, true) -- c3 (two files): its first, a.lua
        -- fired from the *diff window's own* ]c/[c (view.lua), the real-world path —
        -- not the history panel's copy, which is only reached when focus happens to be
        -- in the sidebar itself. the diff column's bufnr is stable across a file switch
        -- (rerender reuses it), so it's read once
        local diff_buf = view_in_origin(h).columns[1].bufnr
        assert.are.equal("a.lua", view_in_origin(h).model.path)

        _G.notifs = {}
        goto_hunk(diff_buf, "]c") -- past a.lua's only hunk: overflow into c3's second file
        assert.are.equal(2, h.index)
        assert.are.equal(2, h.file_index)
        assert.are.equal("c.lua", view_in_origin(h).model.path)
        assert.are.equal(0, #_G.notifs) -- a plain step within the commit, not a boundary

        _G.notifs = {}
        goto_hunk(diff_buf, "]c") -- past c.lua's only hunk too: c3 has no more files.
        -- must NOT flow into c4 (that's ]f/[f's job)
        assert.are.equal(2, h.index)
        assert.are.equal(2, h.file_index)
        assert.are.equal("differ: no more hunks in this commit", _G.notifs[1].msg)

        _G.notifs = {}
        goto_hunk(diff_buf, "[c") -- back over c3's own file boundary to a.lua, landing
        -- on its last (only) hunk
        assert.are.equal(1, h.file_index)
        assert.are.equal("a.lua", view_in_origin(h).model.path)
        assert.are.equal(0, #_G.notifs) -- a plain step within the commit, not a boundary

        _G.notifs = {}
        goto_hunk(diff_buf, "[c") -- a.lua's first file, first hunk: stop here
        assert.are.equal(2, h.index) -- still c3, not crossed back into c4
        assert.are.equal(1, h.file_index)
        assert.are.equal("differ: no previous hunks in this commit", _G.notifs[1].msg)
        h:close()
    end)

    it("toggles a commit's fold with za, hiding its files", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        local function has_file_row(path)
            for _, m in ipairs(h.meta) do
                if m and m.kind == "file" and m.entry.path == path then
                    return true
                end
            end
            return false
        end
        assert.is_true(has_file_row("b.lua")) -- c4 starts expanded
        vim.api.nvim_set_current_win(h.winid)
        vim.api.nvim_win_set_cursor(h.winid, { h:_commit_line(1), 0 })
        h:toggle_fold()
        assert.is_false(has_file_row("b.lua")) -- collapsed
        h:close()
    end)

    it("expands and collapses every commit with O / C", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        vim.api.nvim_set_current_win(h.winid)
        h:set_all_folds(false) -- O
        for i = 1, #h.commits do
            assert.is_true(h:_is_expanded(i))
        end
        h:set_all_folds(true) -- C
        for i = 1, #h.commits do
            assert.is_false(h:_is_expanded(i))
        end
        h:close()
    end)

    it("collapses the commit under the cursor with c, from a file row too", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        vim.api.nvim_set_current_win(h.winid)
        assert.is_true(h:_is_expanded(1)) -- c4 starts expanded
        -- cursor on c4's file row, c collapses its parent commit and lands on it
        vim.api.nvim_win_set_cursor(h.winid, { h:_file_line(1, 1), 0 })
        h:close_node()
        assert.is_false(h:_is_expanded(1))
        assert.are.equal(h:_commit_line(1), vim.api.nvim_win_get_cursor(h.winid)[1])
        h:close()
    end)

    it("steps between commit headers with ]] / [[ without opening", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        vim.api.nvim_set_current_win(h.winid)
        local opened = view_in_origin(h).model.path -- b.lua, from launch
        vim.api.nvim_win_set_cursor(h.winid, { h:_commit_line(1), 0 })
        h:step_commit("next")
        assert.are.equal(h:_commit_line(2), vim.api.nvim_win_get_cursor(h.winid)[1])
        assert.are.equal(opened, view_in_origin(h).model.path) -- no diff opened
        h:step_commit("prev")
        assert.are.equal(h:_commit_line(1), vim.api.nvim_win_get_cursor(h.winid)[1])

        -- [[ from a file row lands on its parent commit's header before stepping back
        h:set_all_folds(false) -- expand every commit so file rows exist
        vim.api.nvim_win_set_cursor(h.winid, { h:_file_line(2, 1), 0 })
        h:step_commit("prev")
        assert.are.equal(h:_commit_line(2), vim.api.nvim_win_get_cursor(h.winid)[1])
        h:step_commit("prev") -- now on the header, so step to the previous commit
        assert.are.equal(h:_commit_line(1), vim.api.nvim_win_get_cursor(h.winid)[1])
        h:close()
    end)

    it("jumps to the first / last commit with gg / G without opening", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        vim.api.nvim_set_current_win(h.winid)
        local opened = view_in_origin(h).model.path
        h:cursor_to_edge("last")
        assert.are.equal(h:_commit_line(#h.commits), vim.api.nvim_win_get_cursor(h.winid)[1])
        h:cursor_to_edge("first")
        assert.are.equal(h:_commit_line(1), vim.api.nvim_win_get_cursor(h.winid)[1])
        assert.are.equal(opened, view_in_origin(h).model.path) -- no diff opened
        h:close()
    end)

    it("renders ref decorations on the tip commit", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        -- the tip (c4) carries the feature/HEAD decoration; on the default bottom strip
        -- the row is one line, so the refs trail the subject on that row
        assert.is_truthy(h.commits[1].refs:find("feature", 1, true))
        assert.is_truthy(h.lines[3]:find("feature", 1, true))
        h:close()
    end)

    it("supersedes a live session on reinvoke, tearing down the previous driven view", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h1 = History.current()
        local v1 = view_in_origin(h1)
        assert.is_true(v1:is_open())

        git_src.range_history({ range = "main..HEAD" }) -- reinvoke: closes the old, opens a fresh one
        local h2 = History.current()
        assert.is_not_nil(h2)
        assert.are_not.equal(h1, h2)
        assert.is_false(v1:is_open())
        assert.is_true(view_in_origin(h2):is_open())
        h2:close()
    end)
end)
