local resolve = require("differ.merge.resolve")
local conflict = require("differ.git.conflict")

-- a two-conflict default-style file
local FILE = {
    "top",
    "<<<<<<< HEAD",
    "ours1",
    "=======",
    "theirs1",
    ">>>>>>> b",
    "mid",
    "<<<<<<< HEAD",
    "ours2",
    "=======",
    "theirs2",
    ">>>>>>> b",
    "bot",
}

local function has_markers(lines)
    for _, l in ipairs(lines) do
        local p = l:sub(1, 7)
        if p == "<<<<<<<" or p == "=======" or p == ">>>>>>>" or p == "|||||||" then
            return true
        end
    end
    return false
end

describe("merge.resolve.slab", function()
    local r = { ours = { "o" }, theirs = { "t" }, base = { "b" } }

    it("returns the matching slab for ours/theirs/base", function()
        assert.are.same({ "o" }, resolve.slab(r, "ours"))
        assert.are.same({ "t" }, resolve.slab(r, "theirs"))
        assert.are.same({ "b" }, resolve.slab(r, "base"))
    end)

    it("joins ours then theirs for both, and empties for none", function()
        assert.are.same({ "o", "t" }, resolve.slab(r, "both"))
        assert.are.same({}, resolve.slab(r, "none"))
    end)

    it("returns nil for base when the region has none", function()
        assert.is_nil(resolve.slab({ ours = {}, theirs = {} }, "base"))
    end)
end)

describe("merge.resolve.splice", function()
    it("replaces the marker block with the ours slab and reports the delta", function()
        local r = conflict.parse(FILE)[1]
        local new, delta = resolve.splice(FILE, r, "ours")
        assert.are.equal("ours1", new[2])
        assert.are.equal("mid", new[3]) -- the block (incl. the separator) is gone
        assert.are.equal(1 - 5, delta) -- a 1-line slab over a 5-line block
        -- the second conflict is untouched, just shifted
        assert.is_true(has_markers(new))
    end)

    it("drops the block entirely for none", function()
        local r = conflict.parse(FILE)[1]
        local new = resolve.splice(FILE, r, "none")
        assert.are.same(
            { "top", "mid", "<<<<<<< HEAD", "ours2", "=======", "theirs2", ">>>>>>> b", "bot" },
            new
        )
    end)

    it("returns nil when base is requested but absent", function()
        local r = conflict.parse(FILE)[1]
        assert.is_nil(resolve.splice(FILE, r, "base"))
    end)

    it("resolves a whole file by re-parsing between splices (no offset tracking)", function()
        -- the session's flow: splice, re-parse the result, splice the next, until clean
        local lines = FILE
        local regions = conflict.parse(lines)
        lines = resolve.splice(lines, regions[1], "ours")
        regions = conflict.parse(lines)
        assert.are.equal(1, #regions) -- one resolved, one left
        lines = resolve.splice(lines, regions[1], "theirs")
        assert.are.equal(0, #conflict.parse(lines))
        assert.is_false(has_markers(lines))
        assert.are.same({ "top", "ours1", "mid", "theirs2", "bot" }, lines)
    end)
end)
