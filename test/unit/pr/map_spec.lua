local pr = require("differ.pr")

describe("pr.map_files", function()
    it("translates github status words to single-letter codes", function()
        local out = pr.map_files({
            { path = "a.go", status = "modified", additions = 3, deletions = 1 },
            { path = "b.go", status = "added" },
            { path = "c.go", status = "removed" },
        })
        assert.are.equal("M", out[1].status)
        assert.are.equal("A", out[2].status)
        assert.are.equal("D", out[3].status)
    end)

    it("maps a modified file, passing counts through", function()
        local out = pr.map_files({
            {
                path = "a.go",
                status = "modified",
                additions = 3,
                deletions = 1,
                viewed_state = "UNVIEWED",
            },
        })
        assert.are.same({
            {
                path = "a.go",
                status = "M",
                additions = 3,
                deletions = 1,
                previous_path = nil,
                viewed = false,
            },
        }, out)
    end)

    it("carries previous_path on a rename, translating the status", function()
        local out = pr.map_files({
            {
                path = "new.go",
                status = "renamed",
                additions = 0,
                deletions = 0,
                previous_path = "old.go",
                viewed_state = "UNVIEWED",
            },
        })
        assert.are.equal("old.go", out[1].previous_path)
        assert.are.equal("R", out[1].status)
    end)

    it("treats VIEWED and DISMISSED as viewed, UNVIEWED as not", function()
        local out = pr.map_files({
            { path = "v.go", status = "modified", viewed_state = "VIEWED" },
            { path = "d.go", status = "modified", viewed_state = "DISMISSED" },
            { path = "u.go", status = "modified", viewed_state = "UNVIEWED" },
        })
        assert.is_true(out[1].viewed)
        assert.is_true(out[2].viewed)
        assert.is_false(out[3].viewed)
    end)

    it("defaults missing counts to zero", function()
        local out = pr.map_files({ { path = "x.go", status = "added" } })
        assert.are.equal(0, out[1].additions)
        assert.are.equal(0, out[1].deletions)
    end)

    it("returns an empty list for no files", function()
        assert.are.same({}, pr.map_files(nil))
        assert.are.same({}, pr.map_files({}))
    end)
end)
