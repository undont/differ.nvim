-- runs under headless nvim against a throwaway git repo: exercises single-file
-- history end-to-end: the log walk, the history panel driving one View per
-- commit (commit vs its parent), commit stepping, the root-commit add edge, and
-- session teardown
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

local V1 = "local x = 1\nreturn x\n"
local V2 = "local x = 2\nreturn x\n"
local V3 = "local x = 3\nreturn x\n"

-- a repo with three commits to a.lua (V1 -> V2 -> V3), each its own commit
local function repo_with_history()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", V1)
    git(root, "add", "a.lua")
    git(root, "commit", "-q", "-m", "v1: seed")
    write(root .. "/a.lua", V2)
    git(root, "commit", "-q", "-am", "v2: bump to 2")
    write(root .. "/a.lua", V3)
    git(root, "commit", "-q", "-am", "v3: bump to 3")
    return root
end

-- a repo whose newest commit changes two well-separated lines (2 and 9), so the
-- origin-line landing is distinguishable from the first hunk
local function repo_two_hunks()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
    git(root, "add", "a.lua")
    git(root, "commit", "-q", "-m", "seed")
    write(root .. "/a.lua", "1\n2x\n3\n4\n5\n6\n7\n8\n9x\n10\n")
    git(root, "commit", "-q", "-am", "two edits")
    return root
end

-- the History panel returns focus to the diff by default, so the View lives in the
-- origin window (View.current keys off the focused buffer)
local function view_in_origin(h)
    vim.api.nvim_set_current_win(h.origin_win)
    return require("differ.view").current()
end

describe("git.log_commits", function()
    it("lists a file's commits newest first with parsed fields", function()
        local root = repo_with_history()
        local commits = git_src.log_commits(root, { path = "a.lua" })
        assert.are.equal(3, #commits)
        assert.are.equal("v3: bump to 3", commits[1].subject)
        assert.are.equal("v2: bump to 2", commits[2].subject)
        assert.are.equal("v1: seed", commits[3].subject)
        assert.are.equal(40, #commits[1].sha)
        assert.is_number(commits[1].epoch)
        assert.is_true(commits[1].epoch > 0)
        assert.are.equal("t", commits[1].author) -- the test git identity
        assert.are.equal(1, commits[1].additions) -- v3 changes one line
        assert.are.equal(1, commits[1].deletions)
        assert.are.equal(2, commits[3].additions) -- the root commit adds the whole file
        assert.are.equal(0, commits[3].deletions)
    end)

    it("returns an empty list for a path with no history", function()
        local root = repo_with_history()
        assert.are.same({}, git_src.log_commits(root, { path = "nope.lua" }))
    end)
end)

describe(":Differ log (single-file history)", function()
    it("opens the history panel and the newest commit's diff", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")

        git_src.history({})
        local h = History.current()
        assert.is_not_nil(h)
        assert.is_true(h:is_open())
        -- one row per commit, header lines first
        assert.are.equal(3, #h.commits)
        -- newest commit selected: V2 (its parent) vs V3
        local v = view_in_origin(h)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(V2, v.model.old_text)
        assert.are.equal(V3, v.model.new_text)
        h:close()
    end)

    it("renders each row with sha, date, diffstat, author and subject", function()
        -- the default bottom strip is wide, so the whole row fits on one line
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        local row = h.lines[3] -- first commit row (after the 2-line header)
        assert.is_truthy(row:find(h.commits[1].short, 1, true)) -- short sha
        assert.is_truthy(row:find("%d%d%d%d%-%d%d%-%d%d")) -- absolute date by default
        assert.is_truthy(row:find("+1 -1", 1, true)) -- this commit's diffstat
        assert.is_truthy(row:find("t", 1, true)) -- author
        assert.is_truthy(row:find("v3: bump to 3", 1, true)) -- subject
        h:close()
    end)

    it("splits each commit across two lines on a narrow left/right panel", function()
        -- a vertical panel is too narrow for the full row: the metadata grid sits on
        -- line 1, the subject on the continuation line (untruncated, clipped by the win)
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({ position = "right" })
        local h = History.current()
        local meta = h.lines[3] -- metadata line (after the 2-line header)
        assert.is_truthy(meta:find(h.commits[1].short, 1, true)) -- short sha
        assert.is_truthy(meta:find("+1 -1", 1, true)) -- this commit's diffstat
        assert.is_falsy(meta:find("v3: bump to 3", 1, true)) -- subject is NOT on line 1
        assert.is_truthy(h.lines[4]:find("v3: bump to 3", 1, true)) -- subject on line 2
        h:close()
    end)

    it("floats the full commit message (subject + body) on demand", function()
        local root = repo_with_history()
        -- give the newest commit a body so the float has more than the subject
        write(root .. "/a.lua", "local x = 4\nreturn x\n")
        git(root, "commit", "-q", "-am", "v4: subject line\n\na body paragraph explaining why")
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        h:_move_cursor(h:_commit_line(1)) -- cursor on the newest commit
        h:show_details()
        -- the details float is the current window; its buffer holds subject + body
        local buf = vim.api.nvim_win_get_buf(0)
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("v4: subject line", 1, true))
        assert.is_truthy(text:find("a body paragraph explaining why", 1, true))
        vim.api.nvim_win_close(0, true)
        h:close()
    end)

    it("keeps ]c / [c within the commit (no crossing into the adjacent commit)", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        local v = view_in_origin(h)
        -- the newest commit's diff is a single hunk; stepping past it must NOT flow into
        -- the next/previous commit (that's ]f/[f) — the selected commit stays put
        v:goto_hunk("next")
        assert.are.equal(1, h.index)
        v:goto_hunk("prev")
        assert.are.equal(1, h.index)
        h:close()
    end)

    it("renders relative dates when configured, and toggles live", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        require("differ").setup({ relative_dates = true })
        git_src.history({})
        local h = History.current()
        assert.is_truthy(h.lines[3]:find("ago", 1, true)) -- relative by config
        assert.is_falsy(h.lines[3]:find("%d%d%d%d%-%d%d%-%d%d")) -- not absolute

        h:toggle_relative_dates()
        assert.is_truthy(h.lines[3]:find("%d%d%d%d%-%d%d%-%d%d")) -- back to absolute
        h:close()
        require("differ").setup({}) -- restore defaults for the rest of the suite
    end)

    it("opens the newest commit's diff at the origin line, not the first hunk", function()
        local root = repo_two_hunks()
        vim.cmd.edit(root .. "/a.lua")
        vim.api.nvim_win_set_cursor(0, { 9, 0 }) -- park on the lower change

        git_src.history({})
        local h = History.current()
        local v = view_in_origin(h)
        local col = v.columns[1]
        local cur = vim.api.nvim_win_get_cursor(h.origin_win)[1]
        assert.are.equal(col.map.from_new[9], cur) -- held line 9's row, not the line-2 hunk
        assert.is_not_nil(col.map.lines[cur].hunk) -- and it's a real changed line
        h:close()
    end)

    it(
        "holds the origin line only on the first commit; later steps land on the first hunk",
        function()
            local root = repo_two_hunks()
            vim.cmd.edit(root .. "/a.lua")
            vim.api.nvim_win_set_cursor(0, { 9, 0 })

            git_src.history({})
            local h = History.current()
            h:step("next") -- step to an older commit
            local v = view_in_origin(h)
            local col = v.columns[1]
            local cur = vim.api.nvim_win_get_cursor(h.origin_win)[1]
            assert.are.equal(v:_first_review_line(col), cur) -- first hunk, origin not re-applied
            h:close()
        end
    )

    it("ignores the origin line for `:Differ log <other-file>`", function()
        local root = repo_two_hunks()
        write(root .. "/b.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        write(root .. "/b.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9x\n10\n")
        git(root, "commit", "-q", "-am", "edit b line 9")
        vim.cmd.edit(root .. "/a.lua") -- sitting in a.lua, cursor at line 1
        vim.api.nvim_win_set_cursor(0, { 9, 0 })

        git_src.history({ path = root .. "/b.lua" }) -- history for a different file
        local h = History.current()
        local v = view_in_origin(h)
        local col = v.columns[1]
        local cur = vim.api.nvim_win_get_cursor(h.origin_win)[1]
        assert.are.equal(v:_first_review_line(col), cur) -- first hunk, origin ignored
        h:close()
    end)

    it("steps to an older commit and re-sources the same view in place", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        local diff_buf = vim.api.nvim_win_get_buf(h.origin_win)

        h:step("next") -- next = older: v2 (parent v1) vs v2
        local v = view_in_origin(h)
        assert.are.equal(V1, v.model.old_text)
        assert.are.equal(V2, v.model.new_text)
        -- same window + buffer: re-sourced, not a new view
        assert.are.equal(diff_buf, vim.api.nvim_win_get_buf(h.origin_win))
        h:close()
    end)

    it("renders the root commit as a pure add (no parent)", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        h:step("next") -- v2
        h:step("next") -- v1, the root commit
        local v = view_in_origin(h)
        assert.are.equal("", v.model.old_text) -- parent doesn't resolve -> empty old side
        assert.are.equal(V1, v.model.new_text)
        h:close()
    end)

    it("clamps stepping at the ends of the history", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        assert.are.equal(1, h.index)
        h:step("prev") -- already newest; clamped
        assert.are.equal(1, h.index)
        h:step("next")
        h:step("next")
        h:step("next") -- only three commits; clamped at the oldest
        assert.are.equal(3, h.index)
        h:close()
    end)

    it("steps commits via ]f / [f from inside the diff window", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        local v = view_in_origin(h)
        assert.are.equal(V3, v.model.new_text) -- newest

        v:step_file("next") -- no file panel open -> drives the history walk
        assert.are.equal(h.origin_win, vim.api.nvim_get_current_win()) -- focus kept in the diff
        assert.are.equal(2, h.index)
        assert.are.equal(V2, require("differ.view").current().model.new_text)
        h:close()
    end)

    it("targets an explicit path argument", function()
        local root = repo_with_history()
        write(root .. "/b.lua", "first\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        vim.cmd.edit(root .. "/a.lua") -- editing a.lua, but ask for b.lua's history

        git_src.history({ path = root .. "/b.lua" })
        local h = History.current()
        assert.are.equal(1, #h.commits)
        assert.are.equal("add b", h.commits[1].subject)
        h:close()
    end)

    it("supersedes a live session when reinvoked, tearing down the previous driven view", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h1 = History.current()
        local v1 = view_in_origin(h1)
        assert.is_true(v1:is_open())

        git_src.history({}) -- reinvoke: closes the old session and opens a fresh one
        local h2 = History.current()
        assert.is_not_nil(h2)
        assert.are_not.equal(h1, h2)
        assert.is_false(v1:is_open())
        assert.is_true(view_in_origin(h2):is_open())
        h2:close()
    end)
end)

-- the history panel window's position relative to the origin window it split from
local function geom(h)
    local prow, pcol = unpack(vim.api.nvim_win_get_position(h.winid))
    local orow, ocol = unpack(vim.api.nvim_win_get_position(h.origin_win))
    return { prow = prow, pcol = pcol, orow = orow, ocol = ocol }
end

-- per position: which fixed-size flag the split carries, and which edge the panel
-- sits on (left/right compare columns, top/bottom compare rows against the origin)
local PLACEMENT = {
    left = {
        axis = "winfixwidth",
        cmp = function(g)
            return g.pcol < g.ocol
        end,
    },
    right = {
        axis = "winfixwidth",
        cmp = function(g)
            return g.pcol > g.ocol
        end,
    },
    top = {
        axis = "winfixheight",
        cmp = function(g)
            return g.prow < g.orow
        end,
    },
    bottom = {
        axis = "winfixheight",
        cmp = function(g)
            return g.prow > g.orow
        end,
    },
}

describe("history runtime position", function()
    for _, pos in ipairs({ "left", "right", "top", "bottom" }) do
        it("opens on the " .. pos .. " edge via cfg.history.position", function()
            local root = repo_with_history()
            require("differ").setup({ history = { position = pos } })
            vim.cmd.edit(root .. "/a.lua")

            git_src.history({})
            local h = History.current()
            assert.are.equal(pos, h.position)
            local spec = PLACEMENT[pos]
            assert.is_true(vim.wo[h.winid][spec.axis])
            assert.is_true(spec.cmp(geom(h)), "wrong edge for " .. pos)
            h:close()
            require("differ").setup({}) -- restore defaults for the rest of the suite
        end)
    end

    it("re-positions live through every edge, keeping one panel + buffer", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        local buf, win = h.bufnr, h.winid
        for _, pos in ipairs({ "left", "top", "right", "bottom" }) do
            h:set_position(pos)
            local spec = PLACEMENT[pos]
            assert.is_true(h:is_open(), pos)
            assert.are.equal(buf, h.bufnr) -- same buffer, just re-windowed
            assert.is_false(win == h.winid) -- new window each move
            assert.is_true(vim.wo[h.winid][spec.axis])
            assert.is_true(spec.cmp(geom(h)), "wrong edge for " .. pos)
            win = h.winid
        end
        h:close()
    end)

    it("set_position is a safe no-op when the panel isn't open", function()
        local h = History.new({ commits = {}, path = "x", on_select = function() end })
        assert.is_false(h:is_open())
        h:set_position("left")
        assert.are.equal("left", h.position) -- still recorded
        assert.is_false(h:is_open()) -- no window opened, no throw
    end)
end)
