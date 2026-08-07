-- runs under headless nvim: buffer lookup by exact name. the cases that matter are
-- the ones vim.fn.bufnr() gets wrong, since it treats its argument as a file-pattern
local buf_util = require("differ.util.buf")

-- name a scratch buffer and hand it to fn, wiping it after
local function with_named(names, fn)
    local made = {}
    for _, name in ipairs(names) do
        local b = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(b, name)
        made[name] = b
    end
    local ok, err = pcall(fn, made)
    for _, b in pairs(made) do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    assert(ok, err)
end

describe("util.buf.find", function()
    it("finds a buffer by its exact name", function()
        with_named({ "/tmp/differ-test/plain.lua" }, function(made)
            assert.are.equal(
                made["/tmp/differ-test/plain.lua"],
                buf_util.find("/tmp/differ-test/plain.lua")
            )
        end)
    end)

    it("returns nil when no buffer holds the path", function()
        assert.is_nil(buf_util.find("/tmp/differ-test/definitely-absent.lua"))
    end)

    it("does not resolve a regex metacharacter path to the wrong buffer", function()
        -- `[1]` is a pattern character class: vim.fn.bufnr("…/a[1].lua") matches the
        -- buffer named `a1.lua`, which is the bug this helper exists to avoid
        with_named({ "/tmp/differ-test/a1.lua" }, function()
            assert.is_nil(buf_util.find("/tmp/differ-test/a[1].lua"))
            -- the pattern form really does mis-resolve, so the guard is load-bearing
            assert.are_not.equal(-1, vim.fn.bufnr("/tmp/differ-test/a[1].lua"))
        end)
    end)

    it("matches a buffer nvim named through a resolved symlink", function()
        -- nvim resolves symlinks when it names a buffer, so a caller path that goes
        -- through one (every tempname() on macOS, /var -> /private/var) has to be
        -- compared against its real path too, or jump-to-file :edits a dirty buffer
        -- and raises E37
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = dir .. "/symlinked.txt"
        vim.fn.writefile({ "x" }, path)
        vim.cmd.edit(vim.fn.fnameescape(path))
        local b = vim.api.nvim_get_current_buf()
        assert.are_not.equal(path, vim.api.nvim_buf_get_name(b)) -- nvim resolved it
        assert.are.equal(b, buf_util.find(path))
        pcall(vim.api.nvim_buf_delete, b, { force = true })
    end)

    it("picks the exact name when another buffer's name contains it", function()
        with_named({
            "/tmp/differ-test/nested/src/app.lua",
            "/tmp/differ-test/src/app.lua",
        }, function(made)
            assert.are.equal(
                made["/tmp/differ-test/src/app.lua"],
                buf_util.find("/tmp/differ-test/src/app.lua")
            )
        end)
    end)
end)
