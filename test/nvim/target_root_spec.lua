-- runs under headless nvim: which repo a command acts on, across cwd, the current buffer
-- and a differ session in this tab or another

-- the specs change cwd, and the runner's package.path is relative to the repo
local saved_cwd = vim.fn.getcwd()
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s/?.lua;"):format(saved_cwd, saved_cwd, saved_cwd)
    .. package.path

local git_src = require("differ.git")
local helpers = require("test.nvim.git.helpers")

local git, write = helpers.git, helpers.write

local function dir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return path
end

-- `a.lua` modified in the worktree, so a panel has a row to open
local function dirty_repo()
    local root = helpers.fresh_repo()
    write(root .. "/a.lua", "local x = 2\nreturn x\n")
    return root
end

-- stopped mid-merge with f.txt conflicted
local function merging_repo()
    local root = dir()
    git(root, "init", "-q")
    write(root .. "/f.txt", "a\n")
    git(root, "add", ".")
    git(root, "commit", "-q", "-m", "base")
    git(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", "feature\n")
    git(root, "commit", "-q", "-am", "feature")
    git(root, "checkout", "-q", "main")
    write(root .. "/f.txt", "main\n")
    git(root, "commit", "-q", "-am", "main")
    vim.system({ "git", "merge", "--no-edit", "feature" }, { cwd = root }):wait()
    assert(#git_src.conflicted(root) > 0, "merge didn't stop on a conflict")
    return root
end

local function same(want, got)
    assert.is_not_nil(got)
    assert.are.equal(vim.fn.resolve(want), vim.fn.resolve(got))
end

local function reset()
    for _, close in ipairs({
        function()
            return require("differ.merge").close()
        end,
        function()
            local p = require("differ.panel").current()
            return p and p:close()
        end,
        function()
            local h = require("differ.history").current()
            return h and h:close()
        end,
    }) do
        pcall(close)
    end
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
    vim.cmd("enew!")
    vim.cmd.cd(saved_cwd)
end

describe("git.target_root", function()
    after_each(reset)

    it("takes the repo cwd and the file share", function()
        local a = helpers.fresh_repo()
        vim.cmd.cd(a)
        vim.cmd.edit(a .. "/a.lua")
        same(a, git_src.target_root())
    end)

    it("takes the file's repo over cwd's", function()
        local a, b = helpers.fresh_repo(), helpers.fresh_repo()
        vim.cmd.cd(a)
        vim.cmd.edit(b .. "/a.lua")
        same(b, git_src.target_root())
    end)

    it("takes the file's repo when cwd is in none", function()
        local b = helpers.fresh_repo()
        vim.cmd.cd(dir())
        vim.cmd.edit(b .. "/a.lua")
        same(b, git_src.target_root())
    end)

    it("takes an unsaved new file's repo over cwd's", function()
        local a, b = helpers.fresh_repo(), helpers.fresh_repo()
        vim.cmd.cd(a)
        vim.cmd.edit(b .. "/new.lua")
        assert.are.equal(0, vim.fn.filereadable(b .. "/new.lua"))
        same(b, git_src.target_root())
    end)

    it("refuses a file in no repo rather than falling back to cwd's", function()
        local a, outside = helpers.fresh_repo(), dir()
        write(outside .. "/x.txt", "x\n")
        vim.cmd.cd(a)
        vim.cmd.edit(outside .. "/x.txt")
        local root, refusal = git_src.target_root()
        assert.is_nil(root)
        assert.are.equal("not inside a git repository", refusal)
    end)

    it("takes cwd's repo from a buffer that isn't a file", function()
        local a = helpers.fresh_repo()
        vim.cmd.cd(a)
        same(a, git_src.target_root())
    end)

    it("refuses a buffer that isn't a file when cwd is in no repo", function()
        vim.cmd.cd(dir())
        local root, refusal = git_src.target_root()
        assert.is_nil(root)
        assert.are.equal("not inside a git repository", refusal)
    end)

    it("follows a tab-local cwd", function()
        local a, b = helpers.fresh_repo(), helpers.fresh_repo()
        vim.cmd.cd(a)
        vim.cmd("tabnew")
        vim.cmd.tcd(b)
        same(b, git_src.target_root())
    end)

    describe("with a panel session", function()
        local a, b
        before_each(function()
            a, b = helpers.fresh_repo(), dirty_repo()
            git_src.panel({ root = b, rev = {}, open_first = true })
            assert(require("differ.panel").current())
            vim.cmd.cd(a)
        end)

        it("takes the session's repo in its tab", function()
            vim.cmd("new")
            same(b, git_src.target_root())
        end)

        it("takes a file's repo over the session's in its tab", function()
            vim.cmd.split(a .. "/a.lua")
            same(a, git_src.target_root())
        end)

        it("takes the session's repo from a terminal in its tab", function()
            vim.cmd("split | terminal")
            same(b, git_src.target_root())
        end)

        it("ignores the session from another tab", function()
            vim.cmd("tabnew")
            same(a, git_src.target_root())
        end)
    end)

    describe("with a history session", function()
        local a, b
        before_each(function()
            a, b = helpers.fresh_repo(), helpers.fresh_repo()
            vim.cmd.cd(b)
            git_src.range_history({ range = "HEAD" })
            assert(require("differ.history").current())
            vim.cmd.cd(a)
        end)

        it("takes the session's repo in its tab", function()
            vim.cmd("new")
            same(b, git_src.target_root())
        end)

        it("ignores the session from another tab", function()
            vim.cmd("tabnew")
            same(a, git_src.target_root())
        end)
    end)

    describe("with a merge session", function()
        local a, b
        before_each(function()
            a, b = helpers.fresh_repo(), merging_repo()
            vim.cmd.edit(b .. "/f.txt")
            require("differ.merge").open({})
            assert(require("differ.merge").current())
            vim.cmd.cd(a)
        end)

        it("takes the session's repo in its tab", function()
            vim.cmd("new")
            same(b, git_src.target_root())
        end)

        it("ignores the session from another tab", function()
            vim.cmd("tabnew")
            same(a, git_src.target_root())
        end)
    end)

    it("opens :Differ <rev> from a panel's tab on that panel's repo", function()
        local a, b = helpers.fresh_repo(), dirty_repo()
        git_src.panel({ root = b, rev = {}, open_first = true })
        vim.cmd.cd(a)
        vim.cmd("new")
        git_src.panel({ rev = "HEAD", open_first = true, supersede = true })
        local p = assert(require("differ.panel").current())
        same(b, p.root)
    end)
end)

describe(":Differ continue", function()
    local select
    before_each(function()
        select = vim.ui.select
    end)
    after_each(function()
        vim.ui.select = select
        reset()
    end)

    local function picked()
        local shown = false
        vim.ui.select = function()
            shown = true
        end
        _G.notifs = {}
        require("differ.command").continue()
        return shown
    end

    it("offers the picker from cwd's mid-merge repo", function()
        vim.cmd.cd(merging_repo())
        assert.is_true(picked())
    end)

    it("refuses from a file in no repo", function()
        local outside = dir()
        write(outside .. "/x.txt", "x\n")
        vim.cmd.cd(merging_repo())
        vim.cmd.edit(outside .. "/x.txt")
        assert.is_false(picked())
        assert.matches("not inside a git repository", _G.notifs[#_G.notifs].msg)
    end)
end)
