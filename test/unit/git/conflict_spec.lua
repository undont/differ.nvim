local conflict = require("differ.git.conflict")
local rev = require("differ.git.rev")

-- a conflicted file as line arrays. labels after the markers are arbitrary (git
-- appends the ref); the parser must ignore them

describe("git.conflict.parse (default style)", function()
    local lines = {
        "context above",
        "<<<<<<< HEAD",
        "ours one",
        "ours two",
        "=======",
        "theirs one",
        ">>>>>>> feature/x",
        "context below",
    }

    it("finds one region with the marker line numbers", function()
        local r = conflict.parse(lines)
        assert.are.equal(1, #r)
        assert.are.equal(1, r[1].index)
        assert.are.equal(2, r[1].result_start)
        assert.are.equal(7, r[1].result_end)
    end)

    it("collects the ours/theirs slabs and no base", function()
        local r = conflict.parse(lines)[1]
        assert.are.same({ "ours one", "ours two" }, r.ours)
        assert.are.same({ "theirs one" }, r.theirs)
        assert.is_nil(r.base)
    end)

    it("records the separator line and leaves mark_base nil", function()
        local r = conflict.parse(lines)[1]
        assert.are.equal(5, r.mark_sep)
        assert.is_nil(r.mark_base)
    end)

    it("captures the ref labels after <<<<<<< and >>>>>>>", function()
        local r = conflict.parse(lines)[1]
        assert.are.equal("HEAD", r.label_ours)
        assert.are.equal("feature/x", r.label_theirs)
    end)

    it("keeps the marker lines out of the slabs", function()
        local r = conflict.parse(lines)[1]
        for _, slab in ipairs({ r.ours, r.theirs }) do
            for _, l in ipairs(slab) do
                assert.is_nil(l:match("^<<<<<<<"))
                assert.is_nil(l:match("^>>>>>>>"))
                assert.are_not.equal("=======", l)
            end
        end
    end)
end)

describe("git.conflict.parse (diff3 / zdiff3 style)", function()
    local lines = {
        "<<<<<<< ours",
        "ours line",
        "||||||| merged common ancestors",
        "base line",
        "=======",
        "theirs line",
        ">>>>>>> theirs",
    }

    it("collects the base slab between ||||||| and =======", function()
        local r = conflict.parse(lines)[1]
        assert.are.same({ "base line" }, r.base)
        assert.are.same({ "ours line" }, r.ours)
        assert.are.same({ "theirs line" }, r.theirs)
    end)

    it("records the ||||||| and ======= marker lines", function()
        local r = conflict.parse(lines)[1]
        assert.are.equal(1, r.result_start)
        assert.are.equal(3, r.mark_base)
        assert.are.equal(5, r.mark_sep)
        assert.are.equal(7, r.result_end)
    end)

    it("captures the labels (the ||||||| label is ignored)", function()
        local r = conflict.parse(lines)[1]
        assert.are.equal("ours", r.label_ours)
        assert.are.equal("theirs", r.label_theirs)
    end)
end)

describe("git.conflict.parse (edges)", function()
    it("orders and indexes multiple regions", function()
        local lines = {
            "<<<<<<< HEAD",
            "a",
            "=======",
            "b",
            ">>>>>>> x",
            "middle",
            "<<<<<<< HEAD",
            "c",
            "=======",
            "d",
            ">>>>>>> x",
        }
        local r = conflict.parse(lines)
        assert.are.equal(2, #r)
        assert.are.equal(1, r[1].index)
        assert.are.equal(2, r[2].index)
        assert.are.equal(7, r[2].result_start)
        assert.are.equal(11, r[2].result_end)
    end)

    it("represents a deleted side as an empty slab", function()
        local r = conflict.parse({
            "<<<<<<< HEAD",
            "=======",
            "theirs only",
            ">>>>>>> x",
        })[1]
        assert.are.same({}, r.ours)
        assert.are.same({ "theirs only" }, r.theirs)
    end)

    it("closes a region whose >>>>>>> is the final line", function()
        local r = conflict.parse({
            "<<<<<<< HEAD",
            "a",
            "=======",
            "b",
            ">>>>>>> x",
        })
        assert.are.equal(1, #r)
        assert.are.equal(5, r[1].result_end)
    end)

    it("discards an unterminated region (no >>>>>>>)", function()
        local r = conflict.parse({
            "<<<<<<< HEAD",
            "a",
            "=======",
            "b",
        })
        assert.are.equal(0, #r)
    end)

    it("ignores a bare ======= outside any conflict", function()
        local r = conflict.parse({ "Title", "=======", "body" })
        assert.are.equal(0, #r)
    end)
end)

describe("git.rev.parse_unmerged", function()
    it("splits the NUL-framed paths and drops the trailing field", function()
        assert.are.same({ "a.txt", "dir/b.lua" }, rev.parse_unmerged("a.txt\0dir/b.lua\0"))
    end)

    it("returns empty for empty output", function()
        assert.are.same({}, rev.parse_unmerged(""))
    end)
end)
