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

    it("takes the picked hunk and leaves the other", function()
        assert.are.equal("1\n2\n3\n4y\n5y\n", apply.splice(two, set(2)))
    end)

    it("returns the old text when nothing is picked", function()
        assert.are.equal(two.old_text, apply.splice(two, {}))
    end)

    it("returns the new text when everything is picked", function()
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

        it("takes the new side's ending when a picked hunk reaches eof", function()
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
