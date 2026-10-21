local viewed = require("differ.pr.viewed")

-- entries with a `viewed` boolean, like map_files yields. v(true)/u(false) read clearly
local function entry(path, is_viewed)
    return { path = path, viewed = is_viewed }
end

describe("pr.viewed.index_of", function()
    it("finds an entry by identity", function()
        local a, b, c = entry("a", false), entry("b", true), entry("c", false)
        assert.are.equal(2, viewed.index_of({ a, b, c }, b))
    end)

    it("returns nil for an entry not in the list, or a nil entry", function()
        local a, b = entry("a", false), entry("b", true)
        assert.is_nil(viewed.index_of({ a }, b))
        assert.is_nil(viewed.index_of({ a }, nil))
    end)
end)

describe("pr.viewed.next_unviewed", function()
    -- a: unviewed, b: viewed, c: unviewed, d: viewed
    local entries = {
        entry("a", false),
        entry("b", true),
        entry("c", false),
        entry("d", true),
    }

    it("steps forward to the nearest unviewed, skipping viewed", function()
        assert.are.equal(3, viewed.next_unviewed(entries, 1, "next"))
    end)

    it("steps backward to the nearest unviewed", function()
        assert.are.equal(1, viewed.next_unviewed(entries, 3, "prev"))
    end)

    it("scans from the start with from = 0", function()
        assert.are.equal(1, viewed.next_unviewed(entries, 0, "next"))
    end)

    it("does not wrap: nil when no unviewed remains ahead", function()
        assert.is_nil(viewed.next_unviewed(entries, 3, "next"))
    end)

    it("does not wrap: nil when no unviewed remains behind", function()
        assert.is_nil(viewed.next_unviewed(entries, 1, "prev"))
    end)

    it("returns nil when every file is viewed", function()
        local all = { entry("a", true), entry("b", true) }
        assert.is_nil(viewed.next_unviewed(all, 0, "next"))
    end)
end)
