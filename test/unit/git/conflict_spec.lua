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

describe("git.conflict.parse (marker shape)", function()
    it("takes a marker only as exactly 7 chars then whitespace or end of line", function()
        local r = conflict.parse({
            "<<<<<<<<",
            "<<<<<<<x",
            "<<<<<<<\tHEAD",
            "a",
            "==========",
            "=======",
            "b",
            ">>>>>>>",
        })
        assert.are.equal(1, #r)
        assert.are.equal(3, r[1].result_start)
        assert.are.same({ "a", "==========" }, r[1].ours)
        assert.are.equal(6, r[1].mark_sep)
        assert.are.equal("", r[1].label_theirs)
    end)
end)

describe("git.conflict.orphans", function()
    local function region(label)
        return { "<<<<<<< HEAD", "a", "=======", "b", ">>>>>>> " .. label }
    end

    local function join(...)
        local out = {}
        for _, part in ipairs({ ... }) do
            for _, line in ipairs(part) do
                out[#out + 1] = line
            end
        end
        return out
    end

    it("finds none in clean regions or a file without markers", function()
        assert.are.same({}, conflict.orphans(join(region("x"), { "middle" }, region("y"))))
        assert.are.same({}, conflict.orphans({ "plain", "text" }))
    end)

    it("ignores runs that are not git's marker shape", function()
        assert.are.same(
            {},
            conflict.orphans({
                "Title",
                "==========",
                "<<<<<<<<",
                ">>>>>>>>x",
                " =======",
                "/* ======= */",
            })
        )
    end)

    it("reports the markers left when ======= is removed", function()
        assert.are.same({ 1, 4 }, conflict.orphans({ "<<<<<<< HEAD", "a", "b", ">>>>>>> x" }))
    end)

    it("reports the markers left when <<<<<<< is removed", function()
        assert.are.same({ 2, 4 }, conflict.orphans({ "a", "=======", "b", ">>>>>>> x" }))
    end)

    it("reports the markers left when >>>>>>> is removed", function()
        assert.are.same({ 1, 3 }, conflict.orphans({ "<<<<<<< HEAD", "a", "=======", "b" }))
    end)

    it("reports the markers left when ||||||| is removed under diff3", function()
        local lines = { "<<<<<<< HEAD", "a", "base", "=======", "b", ">>>>>>> x" }
        assert.are.same({}, conflict.orphans(lines))
        lines = { "<<<<<<< HEAD", "a", "||||||| base", "base", "b", ">>>>>>> x" }
        assert.are.same({ 1, 3, 6 }, conflict.orphans(lines))
    end)

    it("reports a stray marker between two clean regions", function()
        assert.are.same({ 6 }, conflict.orphans(join(region("x"), { "=======" }, region("y"))))
    end)

    it("restarts at a <<<<<<< inside an open region", function()
        local lines = { "<<<<<<< HEAD", "a", "<<<<<<< HEAD", "=======", "b", ">>>>>>> x" }
        local r = conflict.parse(lines)
        assert.are.equal(1, #r)
        assert.are.equal(3, r[1].result_start)
        assert.are.same({}, r[1].ours)
        assert.are.same({ 1 }, conflict.orphans(lines))
    end)

    it("breaks a region at a >>>>>>> before its =======", function()
        local lines = join(region("x"), { "<<<<<<< HEAD", "c", ">>>>>>> y" }, region("z"))
        local r = conflict.parse(lines)
        assert.are.equal(2, #r)
        assert.are.equal(1, r[1].result_start)
        assert.are.equal(9, r[2].result_start)
        assert.are.same({ "a" }, r[2].ours)
        assert.are.same({ 6, 8 }, conflict.orphans(lines))
    end)

    it("breaks a diff3 region at a >>>>>>> in its base slab", function()
        local lines = { "<<<<<<< HEAD", "a", "||||||| base", "o", ">>>>>>> x" }
        assert.are.same({}, conflict.parse(lines))
        assert.are.same({ 1, 3, 5 }, conflict.orphans(lines))
    end)

    it("keeps a stray ======= or ||||||| in the theirs slab as content", function()
        local lines = { "<<<<<<< HEAD", "a", "=======", "b", "=======", "||||||| c", ">>>>>>> x" }
        local r = conflict.parse(lines)
        assert.are.equal(1, #r)
        assert.are.same({ "b", "=======", "||||||| c" }, r[1].theirs)
        assert.are.same({ 5, 6 }, conflict.orphans(lines))
    end)

    it("uses the given marker size", function()
        local lines = { "<<<<<<<<< HEAD", "a", "=======", "b", "=========", "c", ">>>>>>>>> x" }
        local r = conflict.parse(lines, 9)
        assert.are.equal(1, #r)
        assert.are.equal("HEAD", r[1].label_ours)
        assert.are.same({ "a", "=======", "b" }, r[1].ours)
        assert.are.same({}, conflict.orphans(lines, 9))
        assert.are.same({}, conflict.parse(lines))
        assert.are.same({ 3 }, conflict.orphans(lines))
        assert.are.same(
            { 1, 4 },
            conflict.orphans({ "<<<<<<<<< HEAD", "a", "b", ">>>>>>>>> x" }, 9)
        )
    end)

    it("reports an unterminated region at EOF after a clean one", function()
        local lines = join(region("x"), { "<<<<<<< HEAD", "c", "=======", "d" })
        assert.are.same({ 6, 8 }, conflict.orphans(lines))
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
