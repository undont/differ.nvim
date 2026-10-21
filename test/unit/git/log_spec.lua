local log = require("differ.git.log")

local US = "\31"

describe("git.log.log_args", function()
    it("builds a single-file --numstat log with the path after --", function()
        local a = log.log_args({ path = "lua/foo.lua" })
        assert.are.equal("log", a[1])
        assert.are.equal("--numstat", a[2])
        assert.are.equal("--", a[#a - 1])
        assert.are.equal("lua/foo.lua", a[#a])
    end)

    it("omits the -- path pair when no path is given", function()
        local a = log.log_args({})
        for _, v in ipairs(a) do
            assert.are_not.equal("--", v)
        end
    end)

    it("splices extra args before the path (the dp range seam)", function()
        local a = log.log_args({ path = "x", extra = { "--no-merges", "main...HEAD" } })
        -- order: ... extra ... -- path
        assert.are.equal("main...HEAD", a[#a - 2])
        assert.are.equal("--no-merges", a[#a - 3])
        assert.are.equal("--", a[#a - 1])
        assert.are.equal("x", a[#a])
    end)

    it("does not depend on vim (pure, busted-runnable)", function()
        -- log_args is called above with no vim global available; reaching here is the
        -- assertion. a marker keeps luacheck from flagging an empty body
        assert.is_table(log.log_args({}))
    end)
end)

describe("git.log.parse_log", function()
    -- a commit header (the pretty-format line) followed by its --numstat rows. refs
    -- (%D) sit between the epoch and the subject; default empty
    local function header(sha, short, author, epoch, subject, refs)
        return table.concat({ sha, short, author, epoch, refs or "", subject }, US)
    end

    it("parses one commit per header, newest first, with numstat counts", function()
        local out = table.concat({
            header("aaaa1111", "aaaa111", "Ada", "1781349032", "add the thing"),
            "",
            "12\t8\tlua/foo.lua",
            header("bbbb2222", "bbbb222", "Bo", "1781318934", "seed the file"),
            "",
            "40\t0\tlua/foo.lua",
        }, "\n")
        local c = log.parse_log(out)
        assert.are.equal(2, #c)
        assert.are.same({
            sha = "aaaa1111",
            short = "aaaa111",
            author = "Ada",
            epoch = 1781349032,
            refs = "",
            subject = "add the thing",
            additions = 12,
            deletions = 8,
        }, c[1])
        assert.are.equal("seed the file", c[2].subject)
        assert.are.equal(40, c[2].additions)
        assert.are.equal(0, c[2].deletions)
    end)

    it("returns an empty list for empty output", function()
        assert.are.same({}, log.parse_log(""))
    end)

    it("parses ref decorations (%D)", function()
        local out = table.concat({
            header("a", "a", "Ada", "1781349032", "tip", "HEAD -> main, tag: v1"),
            "",
            "1\t0\ta.lua",
            header("b", "b", "Ada", "1781318934", "older", ""),
            "",
            "1\t0\ta.lua",
        }, "\n")
        local c = log.parse_log(out)
        assert.are.equal("HEAD -> main, tag: v1", c[1].refs)
        assert.are.equal("", c[2].refs)
    end)

    it("sums numstat across multiple files in one commit", function()
        local out = table.concat({
            header("a", "a", "Ada", "1781349032", "two files"),
            "",
            "3\t1\ta.lua",
            "5\t2\tb.lua",
        }, "\n")
        local c = log.parse_log(out)
        assert.are.equal(8, c[1].additions)
        assert.are.equal(3, c[1].deletions)
    end)

    it("reads binary `-` numstat counts as zero", function()
        local out = table.concat({
            header("a", "a", "Ada", "1781349032", "add a png"),
            "",
            "-\t-\timg.png",
        }, "\n")
        local c = log.parse_log(out)
        assert.are.equal(0, c[1].additions)
        assert.are.equal(0, c[1].deletions)
    end)

    it("skips headers short of their five fields", function()
        local out = table.concat({
            header("a", "a", "Ada", "1781349032", "ok"),
            "",
            "1\t0\ta.lua",
            "garbage-without-separators",
        }, "\n")
        local c = log.parse_log(out)
        assert.are.equal(1, #c)
        assert.are.equal("ok", c[1].subject)
    end)

    it("preserves a subject that itself contains the field separator", function()
        local out = header("a", "a", "Ada", "1781349032", "weird" .. US .. "subject")
        local c = log.parse_log(out)
        assert.are.equal("weird" .. US .. "subject", c[1].subject)
    end)
end)
