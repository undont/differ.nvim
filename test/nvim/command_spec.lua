-- runs under headless nvim: the :Differ subcommand router. completion is pure
-- string logic; the `panel <pos>` routing drives a live Panel (no git source needed,
-- since Panel.current() tracks any open panel)
local command = require("differ.command")
local Panel = require("differ.panel")

local function fe(path)
    return { path = path, status = "M", additions = 0, deletions = 0 }
end

local function open_panel()
    vim.cmd("silent! only")
    local p = Panel.new({
        sections = { { entries = { fe("a.lua") } } },
        on_select = function() end,
    })
    p:open()
    return p
end

local function git(cwd, ...)
    local args =
        { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    local res = vim.system(args, { cwd = cwd, text = true }):wait()
    assert(
        res.code == 0,
        "git failed: " .. table.concat({ ... }, " ") .. "\n" .. (res.stderr or "")
    )
end

-- a one-commit repo, opened so git.history has something to list
local function repo_with_history()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    local fd = assert(io.open(root .. "/a.lua", "wb"))
    fd:write("local x = 1\n")
    fd:close()
    git(root, "add", "a.lua")
    git(root, "commit", "-q", "-m", "seed")
    return root
end

describe("command completion", function()
    it("offers subcommands at position 1", function()
        local out = command.complete("", "Differ ")
        assert.is_true(vim.tbl_contains(out, "panel"))
        assert.is_true(vim.tbl_contains(out, "layout"))
    end)

    it("offers positions under panel", function()
        assert.are.same({ "left", "right", "top", "bottom" }, command.complete("", "Differ panel "))
        assert.are.same({ "left" }, command.complete("l", "Differ panel l"))
    end)

    it("offers the base shortcut at position 1 and under log", function()
        assert.is_true(vim.tbl_contains(command.complete("", "Differ "), "base"))
        assert.are.same({ "base" }, command.complete("", "Differ log "))
    end)
end)

describe("command base shortcut", function()
    it("log base opens range history of <base>...HEAD", function()
        local git = require("differ.git")
        local saved_base, saved_range = git.resolve_base, git.range_history
        local got
        git.resolve_base = function()
            return "origin/main"
        end
        git.range_history = function(opts)
            got = opts
        end
        command.log("base")
        git.resolve_base, git.range_history = saved_base, saved_range
        assert.are.same({ range = "origin/main...HEAD" }, got)
    end)

    it("bare base opens the panel over <base>... (branch vs trunk)", function()
        local git = require("differ.git")
        local saved_base, saved_panel = git.resolve_base, git.panel
        local got
        git.resolve_base = function()
            return "origin/main"
        end
        git.panel = function(opts)
            got = opts
        end
        command.dispatch({ "base" })
        git.resolve_base, git.panel = saved_base, saved_panel
        -- supersede: re-running over a live session reopens (idempotent), like :Differ <rev>
        assert.are.same({ rev = "origin/main...", open_first = true, supersede = true }, got)
    end)

    it("does nothing when no base resolves", function()
        local git = require("differ.git")
        local saved_base, saved_range = git.resolve_base, git.range_history
        local called = false
        git.resolve_base = function()
            return nil
        end
        git.range_history = function()
            called = true
        end
        command.log("base")
        git.resolve_base, git.range_history = saved_base, saved_range
        assert.is_false(called)
    end)
end)

describe("command bare dispatch reroute", function()
    -- the hint fires once per conflict episode, and that flag outlives a test
    before_each(function()
        require("differ.git").notify_conflicts("/repo", {})
    end)

    -- stub root + conflicted so the routing is checked without a repo; record which
    -- surface dispatch reaches
    local function run(args, conflicted)
        local git = require("differ.git")
        local merge = require("differ.merge")
        local sr, sc, sp, so = git.root, git.conflicted, git.panel, merge.open
        local sb = git.resolve_base
        local routed = {}
        git.root = function()
            return "/repo"
        end
        git.conflicted = function()
            return conflicted
        end
        git.resolve_base = function() -- `base` needs a trunk to expand against
            return "origin/HEAD"
        end
        git.panel = function()
            routed.panel = true
        end
        merge.open = function()
            routed.merge = true
        end
        command.dispatch(args)
        git.root, git.conflicted, git.panel, merge.open = sr, sc, sp, so
        git.resolve_base = sb
        return routed
    end

    it("routes bare :Differ to the merge tool when the tree has conflicts", function()
        local routed = run({}, { "f.txt" })
        assert.is_true(routed.merge)
        assert.is_nil(routed.panel)
    end)

    it("opens the diff panel when there are no conflicts", function()
        local routed = run({}, {})
        assert.is_true(routed.panel)
        assert.is_nil(routed.merge)
    end)

    -- the reroute follows the question, not the arg count: `:Differ HEAD` asks the same
    -- thing the bare form does, so it gets the same answer
    it("routes :Differ HEAD to the merge tool", function()
        local routed = run({ "HEAD" }, { "f.txt" })
        assert.is_true(routed.merge)
        assert.is_nil(routed.panel)
    end)

    -- a named rev or range asked something else; it opens, with a hint. `base` included:
    -- it stands for `<base>...`, and the two spellings must not diverge
    for _, args in ipairs({ { "HEAD~1" }, { "main..." }, { "base" }, { "a..b" }, { "a", "b" } }) do
        it("keeps :Differ " .. table.concat(args, " ") .. " on the diff", function()
            local routed = run(args, { "f.txt" })
            assert.is_true(routed.panel)
            assert.is_nil(routed.merge)
        end)
    end

    it("keeps :Differ HEAD on the diff when nothing is conflicted", function()
        local routed = run({ "HEAD" }, {})
        assert.is_true(routed.panel)
        assert.is_nil(routed.merge)
    end)

    it("says why it rerouted", function()
        _G.notifs = {}
        run({ "HEAD" }, { "f.txt", "g.txt" })
        assert.are.equal("differ: 2 files conflicted, opening the merge tool", _G.notifs[1].msg)
    end)

    it("points a committed range at the merge tool without blocking it", function()
        _G.notifs = {}
        local routed = run({ "a..b" }, { "f.txt" })
        assert.is_true(routed.panel)
        assert.are.equal(
            "differ: 1 file conflicted; :Differ mergetool to resolve",
            _G.notifs[1].msg
        )
    end)

    it("tracks the hint per repo, so alternating trees don't re-nag", function()
        local git = require("differ.git")
        _G.notifs = {}
        git.notify_conflicts("/a", { "f.txt" })
        git.notify_conflicts("/b", { "f.txt" })
        git.notify_conflicts("/a", { "f.txt" }) -- back to a: already spoken for
        assert.are.equal(2, #_G.notifs)
        git.notify_conflicts("/b", {}) -- b resolved; a's hint is untouched
        git.notify_conflicts("/a", { "f.txt" })
        assert.are.equal(2, #_G.notifs)
        git.notify_conflicts("/b", { "f.txt" }) -- a fresh merge in b speaks again
        assert.are.equal(3, #_G.notifs)
        git.notify_conflicts("/a", {})
        git.notify_conflicts("/b", {})
    end)

    it("hints once per conflict episode, not once per command", function()
        _G.notifs = {}
        run({ "a..b" }, { "f.txt" })
        run({ "a..b" }, { "f.txt" })
        assert.are.equal(1, #_G.notifs)
        run({ "a..b" }, {}) -- resolved: the next merge speaks again
        run({ "a..b" }, { "f.txt" })
        assert.are.equal(2, #_G.notifs)
    end)
end)

describe("command panel", function()
    it("always opens with a file shown (open_first), so there's a diff window", function()
        local git = require("differ.git")
        local saved = git.panel
        local got
        git.panel = function(opts)
            got = opts
        end
        command.panel("")
        git.panel = saved
        assert.is_true(got.open_first)
    end)
end)

describe("command panel position", function()
    it("repositions the live panel", function()
        local p = open_panel()
        command.panel("right")
        assert.are.equal("right", p.position)
        assert.is_true(p:is_open())
        p:close()
    end)

    it("opens at the position when no panel is live", function()
        vim.cmd("silent! only")
        local git = require("differ.git")
        local saved = git.panel
        local got
        git.panel = function(opts)
            got = opts
        end
        command.panel("top")
        git.panel = saved
        -- open_first so a fresh panel always shows a diff (the session anchor)
        assert.are.same({ position = "top", open_first = true }, got)
    end)

    it("treats a non-position arg as a rev spec, not a position", function()
        local p = open_panel()
        local git_mod = require("differ.git")
        local saved = git_mod.panel
        local got
        git_mod.panel = function(opts)
            got = opts
        end
        command.panel("lfet") -- a typo'd position is just a rev spec; panel stays put
        git_mod.panel = saved
        assert.are.equal("bottom", p.position) -- unchanged
        assert.are.equal("lfet", got.rev)
        p:close()
    end)

    it("repositions a live history session, not a second panel", function()
        vim.cmd("silent! only")
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        local git_mod = require("differ.git")
        git_mod.history({})
        local h = require("differ.history").current()
        assert.is_not_nil(h)

        local saved = git_mod.panel
        local git_called = false
        git_mod.panel = function()
            git_called = true
        end
        command.panel("right")
        git_mod.panel = saved

        assert.are.equal("right", h.position) -- the live history sidebar moved in place
        assert.is_false(git_called) -- no second, overlapping session spawned
        h:close()
    end)

    it("bare panel over a live history is a no-op, not a second session", function()
        vim.cmd("silent! only")
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        local git_mod = require("differ.git")
        git_mod.history({})
        local h = require("differ.history").current()

        local saved = git_mod.panel
        local git_called = false
        git_mod.panel = function()
            git_called = true
        end
        command.panel("") -- bare, no position word: nothing to toggle
        git_mod.panel = saved

        assert.is_false(git_called) -- no worktree-diff session opened over the history
        assert.is_not_nil(require("differ.history").current()) -- same live session
        h:close()
    end)
end)
