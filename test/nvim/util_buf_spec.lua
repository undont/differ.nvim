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

    it("finds a buffer named by its real path when asked through a symlink", function()
        -- nvim names a buffer through the file's real path, so jump-to-file asking with
        -- an unresolved path would miss and fall back to :edit, raising E37 on a dirty
        -- buffer. the buffer is named explicitly here rather than opened via :edit: how
        -- much nvim itself resolves is platform-dependent (macos hands every tempname()
        -- a /var -> /private/var link, linux does not), and it is this helper's own
        -- resolution that needs pinning
        local real_dir = vim.fn.tempname()
        vim.fn.mkdir(real_dir, "p")
        vim.fn.writefile({ "x" }, real_dir .. "/via-link.txt")
        local link = vim.fn.tempname()
        assert.is_true((vim.uv or vim.loop).fs_symlink(real_dir, link) == true)

        local b = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(b, real_dir .. "/via-link.txt")
        assert.are.equal(b, buf_util.find(link .. "/via-link.txt"))
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
