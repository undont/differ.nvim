local tracked = vim.fs.abspath("test/gitconfig")

---@param args string[]
---@return string[]
local function git_lines(args)
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    local res = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = outside }):wait()
    assert.are.equal(0, res.code, res.stderr)
    return vim.split(vim.trim(res.stdout), "\n", { trimempty = true })
end

describe("test git config", function()
    it("is the global config", function()
        local origin =
            git_lines({ "config", "--global", "--show-origin", "--get", "user.email" })[1]
        assert.are.equal("file:" .. tracked .. "\tt@t", origin)
    end)

    it("is the only config git reads outside a repo", function()
        for _, line in ipairs(git_lines({ "config", "--list", "--show-scope", "--show-origin" })) do
            local scope, origin = line:match("^(%S+)\t([^\t]*)\t")
            assert.are.equal("global", scope, line)
            assert.are.equal("file:" .. tracked, origin, line)
        end
    end)
end)
