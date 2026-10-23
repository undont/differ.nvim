-- pure-lua: the help cheatsheet's row formatting. `show` needs nvim, but fmt/row/
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

describe("help.key", function()
    it("renders the set's lhs, joining a multi-lhs list", function()
        assert.are.equal("gl", help.key({ toggle_local = "gl" }, "toggle_local"))
        assert.are.equal("X / dx", help.key({ discard = { "X", "dx" } }, "discard"))
    end)

    it("returns nil for a disabled action", function()
        assert.is_nil(help.key({ discard = false }, "discard"))
    end)

    it("falls back to the default when the set has no entry", function()
        local defaults = require("differ.config").defaults.keymaps
        assert.are.equal(help.fmt(defaults.stage), help.key({}, "stage"))
    end)
end)

describe("help.row", function()
    local function row(a, b)
        return help.row(a, b, "%s hunk", "next", "previous")
    end

    it("joins both sides", function()
        assert.are.same({ "]c / [c", "next / previous hunk" }, row("]c", "[c"))
    end)

    it("names only the bound side when the other is disabled", function()
        assert.are.same({ "]c", "next hunk" }, row("]c", false))
        assert.are.same({ "[c", "previous hunk" }, row(false, "[c"))
    end)

    it("leaves a nil lhs when both are disabled, so lines drops the row", function()
        assert.is_nil(row(false, false)[1])
        assert.are.same({}, help.lines({ row(false, false) }))
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
