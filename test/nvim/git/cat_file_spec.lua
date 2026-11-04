-- the long-lived cat-file process: reads while a session holds the root, the index
-- names it refuses, and the spawn the caller falls back to when it can't answer
local cat_file = require("differ.git.cat_file")
local content = require("differ.git.content")
local exec = require("differ.git.exec")
local helpers = require("test.nvim.git.helpers")
local git, write, V1 = helpers.git, helpers.write, helpers.V1

---@param pred fun(): boolean
local function wait_for(pred)
    assert.is_true(vim.wait(5000, pred, 5), "timed out waiting")
end

---@param root string
---@param path string
---@return string
local function blob_sha(root, path)
    return vim.trim(git(root, "rev-parse", "HEAD:" .. path))
end

describe("cat_file", function()
    local releases = {}
    local timeout = cat_file.TIMEOUT

    ---@param root string
    local function hold(root)
        releases[#releases + 1] = cat_file.hold(root)
    end

    after_each(function()
        for _, release in ipairs(releases) do
            release()
        end
        releases = {}
        cat_file.TIMEOUT = timeout
    end)

    it("answers nothing for a root no session holds", function()
        local root = helpers.fresh_repo()
        assert.is_false((cat_file.read(root, "HEAD:a.lua")))
        assert.is_nil(cat_file.process(root))
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua")) -- spawned
    end)

    it("reads by id and by <rev>:path from one process", function()
        local root = helpers.fresh_repo()
        hold(root)
        local answered, object = cat_file.read(root, blob_sha(root, "a.lua"))
        assert.is_true(answered)
        assert.are.same({ sha = blob_sha(root, "a.lua"), kind = "blob", text = V1 }, object)
        local proc = cat_file.process(root)
        assert.is_not_nil(proc)

        answered, object = cat_file.read(root, "HEAD:a.lua")
        assert.is_true(answered)
        assert.are.equal(V1, object.text)
        assert.are.equal(proc, cat_file.process(root))
    end)

    it("answers a name git can't resolve with no object", function()
        local root = helpers.fresh_repo()
        hold(root)
        local answered, object = cat_file.read(root, "HEAD:gone.lua")
        assert.is_true(answered)
        assert.is_nil(object)
        assert.is_nil(content.read(content.HEAD, root, "gone.lua"))
        -- the queue moves past it
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
    end)

    it("resolves a rev at each read, so a commit after startup shows", function()
        local root = helpers.fresh_repo()
        hold(root)
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
        write(root .. "/a.lua", "two\n")
        git(root, "commit", "-q", "-am", "two")
        assert.are.equal("two\n", content.read(content.HEAD, root, "a.lua"))
        assert.are.equal(V1, content.read({ kind = "rev", rev = "HEAD~1" }, root, "a.lua"))
    end)

    it("never answers an index name: the process read the index at startup", function()
        local root = helpers.fresh_repo()
        hold(root)
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua")) -- started
        write(root .. "/a.lua", "staged\n")
        git(root, "add", "a.lua")
        assert.is_false((cat_file.read(root, ":0:a.lua")))
        assert.are.equal("staged\n", content.read(content.INDEX, root, "a.lua"))
        assert.are.equal("staged\n", content.blob(root, ":0:a.lua").text)
    end)

    it("reads a blob larger than one pipe chunk whole", function()
        local root = helpers.fresh_repo()
        local big = ("0123456789abcdef"):rep(1024 * 64) .. "\n" -- 1 MiB
        write(root .. "/big.txt", big)
        git(root, "add", "big.txt")
        git(root, "commit", "-q", "-m", "big")
        hold(root)
        assert.are.equal(big, content.read(content.HEAD, root, "big.txt"))
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
    end)

    it("yields inside exec.async and keeps request order with a blocking read", function()
        local root = helpers.fresh_repo()
        write(root .. "/b.lua", "b\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "b")
        hold(root)
        local got = {}
        exec.async(function()
            return content.read(content.HEAD, root, "b.lua")
        end, function(ok, text)
            got = { ok = ok, text = text }
        end)
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
        wait_for(function()
            return got.ok ~= nil
        end)
        assert.are.same({ ok = true, text = "b\n" }, got)
    end)

    it("reads a path holding a newline", function()
        local root = helpers.fresh_repo()
        write(root .. "/new\nline.txt", "nl\n")
        write(root .. "/cr.txt\r", "cr\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "odd names")
        hold(root)
        local answered, object = cat_file.read(root, "HEAD:new\nline.txt")
        assert.is_true(answered)
        assert.are.equal("nl\n", object.text)
        answered, object = cat_file.read(root, "HEAD:cr.txt\r")
        assert.is_true(answered)
        assert.are.equal("cr\n", object.text)
    end)

    it("falls back to a spawn after the process dies, then starts another", function()
        local root = helpers.fresh_repo()
        hold(root)
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
        local proc = assert(cat_file.process(root))
        proc:kill(9)
        wait_for(function()
            return cat_file.process(root) == nil
        end)
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
        local next_proc = cat_file.process(root)
        assert.is_not_nil(next_proc)
        assert.are_not.equal(proc, next_proc)
    end)

    it("gives up on a process that stops answering, and the read spawns", function()
        local root = helpers.fresh_repo()
        hold(root)
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
        local proc = assert(cat_file.process(root))
        cat_file.TIMEOUT = 100
        proc:kill("sigstop")
        local started = vim.uv.hrtime()
        assert.is_false((cat_file.read(root, "HEAD:a.lua")))
        assert.is_true((vim.uv.hrtime() - started) / 1e6 < 1000)
        assert.is_nil(cat_file.process(root))
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
    end)

    it("stops the process on the last release, once per hold", function()
        local root = helpers.fresh_repo()
        local first, second = cat_file.hold(root), cat_file.hold(root)
        assert.are.equal(V1, content.read(content.HEAD, root, "a.lua"))
        local proc = assert(cat_file.process(root))
        first()
        first() -- a second call is no release of the other hold
        assert.are.equal(proc, cat_file.process(root))
        second()
        assert.is_nil(cat_file.process(root))
        assert.is_false((cat_file.read(root, "HEAD:a.lua")))
        -- the process sees EOF and exits
        wait_for(function()
            return proc:is_closing()
        end)
    end)

    it("lives as long as the panel session on its root", function()
        local root = helpers.fresh_repo()
        write(root .. "/a.lua", "changed\n")
        vim.cmd.edit(root .. "/a.lua")
        local p = helpers.open_panel()
        local top = vim.trim(git(root, "rev-parse", "--show-toplevel"))
        assert.is_not_nil(cat_file.process(top)) -- the opening diff read HEAD through it
        p:close()
        assert.is_nil(cat_file.process(top))
        vim.cmd("silent! %bwipeout!")
    end)

    describe("without -z (git before 2.38)", function()
        local fresh, git_fn

        before_each(function()
            package.loaded["differ.git.cat_file"] = nil
            git_fn = exec.git
            exec.git = function(args, ...)
                if args[1] == "--version" then
                    return "git version 2.37.4\n"
                end
                return git_fn(args, ...)
            end
            fresh = require("differ.git.cat_file")
        end)

        after_each(function()
            exec.git = git_fn
            package.loaded["differ.git.cat_file"] = cat_file
        end)

        it("leaves a name with a newline or a trailing CR to the caller", function()
            local root = helpers.fresh_repo()
            write(root .. "/new\nline.txt", "nl\n")
            git(root, "add", "-A")
            git(root, "commit", "-q", "-m", "odd name")
            local release = fresh.hold(root)
            assert.is_false((fresh.read(root, "HEAD:new\nline.txt")))
            assert.is_false((fresh.read(root, "HEAD:a.lua\r")))
            local answered, object = fresh.read(root, "HEAD:a.lua")
            assert.is_true(answered)
            assert.are.equal(V1, object.text)
            release()
        end)
    end)
end)
