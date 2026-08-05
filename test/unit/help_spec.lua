-- pure-lua: the help cheatsheet's row formatting. `show` needs nvim, but fmt/pair/
-- lines don't, so the disabled-action handling is unit-testable
local help = require("differ.ui.help")

describe("help.fmt", function()
    it("renders a single lhs and joins a multi-lhs list", function()
        assert.are.equal("g?", help.fmt("g?"))
        assert.are.equal("<CR> / o", help.fmt({ "<CR>", "o" }))
    end)

    it("returns nil for a disabled action", function()
        assert.is_nil(help.fmt(false))
        assert.is_nil(help.fmt(nil))
    end)
end)

describe("help.pair", function()
    it("joins both sides", function()
        assert.are.equal("]c / [c", help.pair("]c", "[c"))
    end)

    it("keeps whichever side survives when the other is disabled", function()
        assert.are.equal("]c", help.pair("]c", false))
        assert.are.equal("[c", help.pair(false, "[c"))
        assert.is_nil(help.pair(false, false))
    end)
end)

describe("help.lines", function()
    it("aligns descriptions to the widest lhs", function()
        assert.are.same({
            " g?      this help",
            " ]c/[c   next hunk",
        }, help.lines({ { "g?", "this help" }, { "]c/[c", "next hunk" } }))
    end)

    it("skips disabled rows and doesn't let them pad the column", function()
        -- the dropped row's lhs is the longest, so a naive width pass would over-pad
        assert.are.same(
            { " g?   this help" },
            help.lines({ { nil, "a very long disabled lhs" }, { "g?", "this help" } })
        )
    end)
end)
