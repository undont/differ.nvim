local text = require("differ.util.text")

describe("util.text.truncate_end", function()
    it("returns the string unchanged when it already fits", function()
        assert.are.equal("abc", text.truncate_end("abc", 3))
        assert.are.equal("abc", text.truncate_end("abc", 10))
    end)

    it("keeps the front with a trailing ellipsis when over budget", function()
        local out = text.truncate_end("EnrolTotpSheet.test.tsx", 8)
        assert.are.equal("EnrolTo…", out) -- 7 front cols + "…"
    end)

    it("keeps distinct prefixes distinguishable", function()
        assert.are.equal("EnrolPh…", text.truncate_end("EnrolPhoneSheet.test.tsx", 8))
        assert.are.equal("EnrolTo…", text.truncate_end("EnrolTotpSheet.test.tsx", 8))
    end)

    it("leaves a too-small budget alone", function()
        assert.are.equal("abcdef", text.truncate_end("abcdef", 1))
    end)
end)

describe("util.text.is_binary", function()
    it("treats plain text as non-binary", function()
        assert.is_false(text.is_binary(""))
        assert.is_false(text.is_binary("a\nb\nc\n"))
        assert.is_false(text.is_binary(("line\n"):rep(5000)))
    end)

    it("flags content with a NUL byte", function()
        assert.is_true(text.is_binary("abc\0def"))
        assert.is_true(text.is_binary("\0"))
    end)

    it("only scans the first 8kb", function()
        -- a NUL past the window is missed, mirroring git's heuristic
        assert.is_false(text.is_binary(("x"):rep(8000) .. "\0"))
        assert.is_true(text.is_binary(("x"):rep(7999) .. "\0"))
    end)
end)

local function contains(lines, want)
    for _, line in ipairs(lines) do
        if line == want then
            return true
        end
    end
    return false
end

-- pty streams captured from git runs in the float, as on_stdout delivers them
local function printed(name)
    local fd = assert(io.open("test/unit/fixtures/pty/" .. name .. ".raw", "rb"))
    local stream = fd:read("*a")
    fd:close()
    return text.printed(stream)
end

describe("util.text.printed", function()
    it("keeps git's lines whole and drops the carriage returns", function()
        local lines = printed("cherry-pick-empty-again")
        assert.are.equal("On branch main", lines[1])
        assert.is_true(
            contains(
                lines,
                "The previous cherry-pick is now empty, possibly due to conflict resolution."
            )
        )
        assert.are.equal("Otherwise, please use 'git cherry-pick --skip'", lines[#lines])
    end)

    it("keeps only what is left of a line git rewrites after a carriage return", function()
        local lines = printed("editor-round")
        assert.is_truthy(lines[1]:match("^%[main %x+%] %[hook%] topic edits$"))
        for _, line in ipairs(lines) do
            assert.is_nil(line:find("Waiting for your editor", 1, true))
        end
    end)

    it("strips colour and progress from a rebase stop", function()
        local lines = printed("rebase-multi-stop")
        assert.is_true(contains(lines, "Auto-merging auto_merged.lua"))
        assert.is_true(
            contains(lines, "hint: Resolve all conflicts manually, mark them as resolved with")
        )
        for _, line in ipairs(lines) do
            assert.is_nil(line:find("\27", 1, true))
            assert.is_nil(line:find("Rebasing (", 1, true))
        end
    end)

    it("drops what pinentry draws on the alternate screen", function()
        local lines = printed("pinentry")
        assert.are.equal(3, #lines)
        assert.is_truthy(lines[1]:match("^%[main %x+%] %[hook%] topic edits$"))
        assert.is_truthy(lines[2]:match("^ Date: "))
        assert.are.equal(" 3 files changed, 4 insertions(+), 4 deletions(-)", lines[3])
    end)
end)
