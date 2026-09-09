local apply = require("differ.model.apply")

-- a model carrying only what partial() reads: the two texts and the hunks
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

describe("partial apply", function()
    -- index 1,2,3x,4,5 -> worktree 1,2,3x,4y,5y; stage only 4y
    local edit =
        model("1\n2\n3x\n4\n5\n", "1\n2\n3x\n4y\n5y\n", { h(4, { "4", "5" }, 4, { "4y", "5y" }) })

    it("takes one line of a replacement and leaves the rest", function()
        assert.are.equal("1\n2\n3x\n4y\n5\n", apply.partial(edit, { new = set(4) }))
    end)

    it("reads a pick on either side of a pair as that row", function()
        assert.are.equal(
            apply.partial(edit, { new = set(4) }),
            apply.partial(edit, { old = set(4) })
        )
    end)

    it("returns the old text for an empty selection", function()
        assert.are.equal(edit.old_text, apply.partial(edit, nil))
    end)

    it("returns the new text when everything is picked", function()
        assert.are.equal(edit.new_text, apply.partial(edit, { old = set(4, 5), new = set(4, 5) }))
    end)

    it("takes only the picked lines of an insertion", function()
        -- a,b -> a,x,y,b: the hunk sits after old line 1
        local m = model("a\nb\n", "a\nx\ny\nb\n", { h(1, {}, 2, { "x", "y" }) })
        assert.are.equal("a\ny\nb\n", apply.partial(m, { new = set(3) }))
    end)

    it("drops only the picked lines of a deletion", function()
        -- a,b,c,d -> a,d: the hunk removes old lines 2 and 3
        local m = model("a\nb\nc\nd\n", "a\nd\n", { h(2, { "b", "c" }, 1, {}) })
        assert.are.equal("a\nc\nd\n", apply.partial(m, { old = set(2) }))
    end)

    it("inserts at the top of the file", function()
        local m = model("a\n", "x\na\n", { h(0, {}, 1, { "x" }) })
        assert.are.equal("x\na\n", apply.partial(m, { new = set(1) }))
    end)

    -- the blocks carry no correspondence, so there is no honest way to say which of
    -- three removed lines the one added line replaces
    it("refuses a replacement whose blocks differ in length", function()
        local m = model("a\nb\nc\n", "x\n", { h(1, { "a", "b", "c" }, 1, { "x" }) })
        local text, why = apply.partial(m, { new = set(1) })
        assert.is_nil(text)
        assert.are.equal("a hunk replacing 3 lines with 1 can't be split", why)
    end)

    it("keeps an unterminated old tail the selection doesn't reach", function()
        local m = model("a\nb", "a\nB", { h(2, { "b" }, 2, { "B" }) })
        assert.are.equal("a\nb", apply.partial(m, nil))
        assert.are.equal("a\nB", apply.partial(m, { new = set(2) }))
    end)
end)
