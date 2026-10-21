-- the shared line-array searches: a single located run, and an ordered disjoint
-- placement of several. pure lua, no nvim runtime

local lines = require("differ.util.lines")

local HAY = { "a", "b", "c", "a", "b", "d" }

describe("util.lines.find_run", function()
    it("returns the first start where the slab matches run-for-run", function()
        assert.are.equal(1, lines.find_run(HAY, { "a", "b" }, 1))
    end)

    it("skips matches before `from`", function()
        assert.are.equal(4, lines.find_run(HAY, { "a", "b" }, 2))
    end)

    it("returns nil when the slab is absent", function()
        assert.is_nil(lines.find_run(HAY, { "a", "c" }, 1))
    end)

    it("returns nil when the slab would run past the end", function()
        assert.is_nil(lines.find_run(HAY, { "d", "e" }, 1))
    end)

    it("matches a slab that ends exactly at the last line", function()
        assert.are.equal(5, lines.find_run(HAY, { "b", "d" }, 1))
    end)

    it("returns nil when `from` is past the last possible start", function()
        assert.is_nil(lines.find_run(HAY, { "a", "b" }, 6))
    end)
end)

describe("util.lines.find_runs", function()
    it("places every slab in order, keyed by slab index", function()
        local at = lines.find_runs(HAY, { { "a", "b" }, { "d" } }, 1)
        assert.are.same({ 1, 6 }, at)
    end)

    it("places repeated content disjointly rather than on itself", function()
        local at = lines.find_runs(HAY, { { "a", "b" }, { "a", "b" } }, 1)
        assert.are.same({ 1, 4 }, at)
    end)

    it("returns nil when a slab can't be placed at all", function()
        assert.is_nil(lines.find_runs(HAY, { { "a" }, { "zz" } }, 1))
    end)

    it("returns nil when the slabs are present but out of order", function()
        assert.is_nil(lines.find_runs(HAY, { { "d" }, { "c" } }, 1))
    end)

    it("returns nil when a repeat has no room left after the ones before it", function()
        assert.is_nil(lines.find_runs(HAY, { { "a", "b" }, { "a", "b" }, { "a", "b" } }, 1))
    end)

    it("skips an empty slab: no position for it, and the cursor doesn't move", function()
        local at = lines.find_runs(HAY, { { "a" }, {}, { "a" } }, 1)
        assert.is_nil(at[2])
        assert.are.equal(1, at[1])
        assert.are.equal(4, at[3])
    end)

    it("places nothing, successfully, when every slab is empty", function()
        assert.are.same({}, lines.find_runs(HAY, { {}, {} }, 1))
    end)

    it("searches forward from `from`", function()
        assert.are.same({ 4 }, lines.find_runs(HAY, { { "a" } }, 2))
    end)
end)
