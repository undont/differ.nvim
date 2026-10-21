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
