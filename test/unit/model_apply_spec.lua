local apply = require("differ.model.apply")

-- a model carrying only what splice() reads: the two texts and the hunks
local function model(old_text, new_text, hunks)
    return {
        path = "f",
        old_rev = "A",
        new_rev = "B",
        old_text = old_text,
        new_text = new_text,
        hunks = hunks,
    }
end

local function h(old_start, old_lines, new_start, new_lines)
    return {
        old_start = old_start,
        old_count = #old_lines,
        old_lines = old_lines,
        new_start = new_start,
        new_count = #new_lines,
        new_lines = new_lines,
    }
end

local function set(...)
    local out = {}
    for _, n in ipairs({ ... }) do
        out[n] = true
    end
    return out
end

describe("splice", function()
    -- 1,2,3,4,5 -> 1,2x,3,4y,5y
    local two = model(
        "1\n2\n3\n4\n5\n",
        "1\n2x\n3\n4y\n5y\n",
        { h(2, { "2" }, 2, { "2x" }), h(4, { "4", "5" }, 4, { "4y", "5y" }) }
    )

    it("takes the applied hunk and leaves the other", function()
        assert.are.equal("1\n2\n3\n4y\n5y\n", apply.splice(two, set(2)))
    end)

    it("returns the old text when nothing is applied", function()
        assert.are.equal(two.old_text, apply.splice(two, {}))
    end)

    it("returns the new text when everything is applied", function()
        assert.are.equal(two.new_text, apply.splice(two, set(1, 2)))
    end)

    it("reads the unchanged lines from the new side", function()
        assert.are.equal("1\n2\n3\n4y\n5y\n", apply.splice(two, set(2), "new"))
    end)

    it("places an insertion after the line it follows", function()
        local m = model("a\nb\n", "a\nx\ny\nb\n", { h(1, {}, 2, { "x", "y" }) })
        assert.are.equal(m.new_text, apply.splice(m, set(1)))
    end)

    it("inserts at the top of the file", function()
        local m = model("a\n", "x\na\n", { h(0, {}, 1, { "x" }) })
        assert.are.equal("x\na\n", apply.splice(m, set(1)))
    end)

    it("puts back a deletion from the new side", function()
        local m = model("a\nb\nc\n", "a\nc\n", { h(2, { "b" }, 1, {}) })
        assert.are.equal(m.old_text, apply.splice(m, {}, "new"))
    end)

    describe("the final newline", function()
        it("keeps an unterminated old tail no hunk reaches", function()
            local m = model("a\nb\nc", "A\nb\nc\n", { h(1, { "a" }, 1, { "A" }) })
            assert.are.equal("A\nb\nc", apply.splice(m, set(1)))
        end)

        it("takes the new side's ending when an applied hunk reaches eof", function()
            local m = model("a\nb", "a\nB", { h(2, { "b" }, 2, { "B" }) })
            assert.are.equal("a\nB", apply.splice(m, set(1)))
        end)

        it("ends terminated after deleting an unterminated last line", function()
            local m = model("a\nb", "a\n", { h(2, { "b" }, 1, {}) })
            assert.are.equal("a\n", apply.splice(m, set(1)))
        end)

        it("ends unterminated after deleting a last line when the new side does", function()
            local m = model("a\nb\n", "a", { h(2, { "b" }, 1, {}) })
            assert.are.equal("a", apply.splice(m, set(1)))
        end)

        it("empties the file when every line goes", function()
            local m = model("a\nb\n", "", { h(1, { "a", "b" }, 0, {}) })
            assert.are.equal("", apply.splice(m, set(1)))
        end)
    end)
end)

describe("join", function()
    -- 1,2,3,4,5 -> 1,2x,3,4y,5y
    local two = model(
        "1\n2\n3\n4\n5\n",
        "1\n2x\n3\n4y\n5y\n",
        { h(2, { "2" }, 2, { "2x" }), h(4, { "4", "5" }, 4, { "4y", "5y" }) }
    )

    it("rejoins each side's own blocks to that side's text", function()
        assert.are.equal(two.old_text, apply.join(two, { { "2" }, { "4", "5" } }, two.old_text))
        assert.are.equal(two.new_text, apply.join(two, { { "2x" }, { "4y", "5y" } }, two.new_text))
    end)

    it("places any lines at a hunk between the unchanged ones", function()
        local text = apply.join(two, { { "2", "z" }, {} }, two.old_text)
        assert.are.equal("1\n2\nz\n3\n", text)
    end)

    describe("the final newline", function()
        it("ends as the text given when no hunk reaches eof", function()
            local m = model("a\nb\nc", "A\nb\nc\n", { h(1, { "a" }, 1, { "A" }) })
            assert.are.equal("A\nb\nc\n", apply.join(m, { { "A" } }, "A\nb\nc\n"))
        end)

        it("ends as the side named for the hunk that reaches eof", function()
            local m = model("a\nb", "a\nB\n", { h(2, { "b" }, 2, { "B" }) })
            assert.are.equal("a\nB\n", apply.join(m, { { "B" } }, "a\nb", { "new" }))
            assert.are.equal("a\nb", apply.join(m, { { "b" } }, "a\nB\n", { "old" }))
        end)

        -- b and b⏎: both sides hold the same line, so only the side named says which
        it("ends as the side named where both sides hold the same lines", function()
            local m = model("a\nb", "a\nb\n", { h(2, { "b" }, 2, { "b" }) })
            assert.are.equal("a\nb\n", apply.join(m, { { "b" } }, "a\nb", { "new" }))
            assert.are.equal("a\nb", apply.join(m, { { "b" } }, "a\nb\n", { "old" }))
            assert.are.equal("a\nb", apply.join(m, { { "b" } }, "a\nb"))
        end)
    end)
end)
