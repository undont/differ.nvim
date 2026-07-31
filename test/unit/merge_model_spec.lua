-- the MergeModel builder over a stubbed git layer: the parse path is real (pure
-- conflict.parse + to_lines), only the I/O reads are faked, so the assembly + the
-- no-conflict / missing-file guards are checked without a git repo or nvim runtime.
-- base recovery is stubbed at the re-merge, so the synthetic regions it maps are fed
-- in directly rather than produced by git merge-file

local model = require("differ.merge.model")

local function extend(t, items)
    for _, v in ipairs(items) do
        t[#t + 1] = v
    end
end

-- a conflict block in git's default `merge` conflictStyle, as the worktree file carries it
local function merge_block(ours, theirs)
    local out = { "<<<<<<< HEAD" }
    extend(out, ours)
    out[#out + 1] = "======="
    extend(out, theirs)
    out[#out + 1] = ">>>>>>> branch"
    return out
end

-- the same block in `diff3` conflictStyle, base slab and all, as the re-merge emits
local function diff3_block(ours, base, theirs)
    local out = { "<<<<<<< ours" }
    extend(out, ours)
    out[#out + 1] = "||||||| base"
    extend(out, base)
    out[#out + 1] = "======="
    extend(out, theirs)
    out[#out + 1] = ">>>>>>> theirs"
    return out
end

-- join blocks and plain context lines into file text
local function file(...)
    local out = {}
    for _, part in ipairs({ ... }) do
        if type(part) == "string" then
            out[#out + 1] = part
        else
            extend(out, part)
        end
    end
    return table.concat(out, "\n") .. "\n"
end

-- a conflicted worktree file with no base slab in the markers
local RESULT = file("keep me", merge_block({ "ours" }, { "theirs" }))

-- the same file with the base slab already there, as diff3/zdiff3 writes it
local RESULT_DIFF3 = file("keep me", diff3_block({ "ours" }, { "ancestor" }, { "theirs" }))

-- a re-merge carrying one region, matching RESULT's single conflict
local SYNTH_ONE = file("keep me", diff3_block({ "ours" }, { "recovered" }, { "theirs" }))

-- ort coalesced two diverged spots into one block; merge-file kept them apart, so the
-- single worktree region owns both synthetic ones and its base spans the "mid" between them
local RESULT_COALESCED =
    file("head", merge_block({ "A1", "mid", "B1" }, { "A2", "mid", "B2" }), "tail")

local SYNTH_SPLIT = file(
    "head",
    diff3_block({ "A1" }, { "A" }, { "A2" }),
    "mid",
    diff3_block({ "B1" }, { "B" }, { "B2" }),
    "tail"
)

local COALESCED_STAGES = {
    [1] = "head\nA\nmid\nB\ntail\n",
    [2] = "head\nA1\nmid\nB1\ntail\n",
    [3] = "head\nA2\nmid\nB2\ntail\n",
}

-- the same stages and the same re-merge, but ort kept the two spots apart, so each region
-- owns one synthetic conflict and the spans stay disjoint
local RESULT_SEPARATE =
    file("head", merge_block({ "A1" }, { "A2" }), "mid", merge_block({ "B1" }, { "B2" }), "tail")

-- ours deleted the line theirs modified, so the worktree region's ours slab is empty and
-- only theirs can claim the synthetic region
local RESULT_OURS_DELETED = file("a", merge_block({}, { "Y" }), "b")
local SYNTH_OURS_DELETED = file("a", diff3_block({}, { "X" }, { "Y" }), "b")

-- the sides disagree: ours holds both synthetic ours slabs, theirs holds only the first
local RESULT_DISPUTED = file(merge_block({ "A1", "B1" }, { "A2" }))
local SYNTH_TWO =
    file(diff3_block({ "A1" }, { "A" }, { "A2" }), diff3_block({ "B1" }, { "B" }, { "B2" }))

-- a re-merge describing a conflict nothing in the worktree corresponds to
local SYNTH_FOREIGN = file(diff3_block({ "zzz" }, { "base" }, { "qqq" }))

local function fake_git(opts)
    opts = opts or {}
    return {
        read = function()
            if opts.worktree == nil then
                return RESULT
            end
            return opts.worktree -- false/nil-able via an explicit field
        end,
        read_stage = function(_, _, stage)
            return (opts.stages or { [1] = "base\n", [2] = "ours\n", [3] = "theirs\n" })[stage]
                or ""
        end,
        -- the diff3 re-merge used to recover base slabs; nil by default so recovery bails
        merge_file_diff3 = function()
            return opts.diff3
        end,
    }
end

describe("merge.model.build", function()
    after_each(function()
        package.loaded["differ.git"] = nil
    end)

    it("assembles the model from the worktree result and the three stages", function()
        package.loaded["differ.git"] = fake_git()
        local m, err = model.build("/repo", "a.txt", "main")
        assert.is_nil(err)
        assert.are.equal("a.txt", m.path)
        assert.are.equal("/repo", m.root)
        assert.are.equal("main", m.head)
        assert.are.equal(RESULT, m.result_text)
        assert.are.equal("ours\n", m.ours_text)
        assert.are.equal("base\n", m.base_text)
        assert.are.equal("theirs\n", m.theirs_text)
        assert.are.equal(1, #m.regions)
        assert.are.equal(2, m.regions[1].result_start)
    end)

    it("returns nil + reason when the file has no conflict markers", function()
        package.loaded["differ.git"] = fake_git({ worktree = "clean file\n" })
        local m, err = model.build("/repo", "a.txt", nil)
        assert.is_nil(m)
        assert.is_string(err)
    end)

    it("returns nil + reason when the file is not in the working tree", function()
        package.loaded["differ.git"] = fake_git({ worktree = false })
        local m, err = model.build("/repo", "gone.txt", nil)
        assert.is_nil(m)
        assert.is_string(err)
    end)

    it("reads an absent stage as empty (modify/delete conflict)", function()
        package.loaded["differ.git"] = fake_git({ stages = { [2] = "ours\n" } })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.equal("ours\n", m.ours_text)
        assert.are.equal("", m.base_text)
        assert.are.equal("", m.theirs_text)
    end)
end)

describe("merge.model base recovery", function()
    after_each(function()
        package.loaded["differ.git"] = nil
    end)

    it("recovers the slab for an isolated conflict", function()
        package.loaded["differ.git"] = fake_git({
            diff3 = SYNTH_ONE,
            stages = { [1] = "recovered\n", [2] = "ours\n", [3] = "theirs\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "recovered" }, m.regions[1].base)
    end)

    it("spans the interstitial base lines of a coalesced block", function()
        package.loaded["differ.git"] = fake_git({
            worktree = RESULT_COALESCED,
            diff3 = SYNTH_SPLIT,
            stages = COALESCED_STAGES,
        })
        local m = model.build("/repo", "a.txt", nil)
        -- the run covers base lines A..B, so "mid" comes back with them
        assert.are.same({ "A", "mid", "B" }, m.regions[1].base)
    end)

    it("gives each region its own span when the same conflicts stay apart", function()
        package.loaded["differ.git"] = fake_git({
            worktree = RESULT_SEPARATE,
            diff3 = SYNTH_SPLIT,
            stages = COALESCED_STAGES,
        })
        local m = model.build("/repo", "a.txt", nil)
        -- one synthetic region each, so neither span reaches across "mid" into the other's
        assert.are.same({ "A" }, m.regions[1].base)
        assert.are.same({ "B" }, m.regions[2].base)
    end)

    it("recovers via theirs when ours deleted what theirs modified", function()
        package.loaded["differ.git"] = fake_git({
            worktree = RESULT_OURS_DELETED,
            diff3 = SYNTH_OURS_DELETED,
            stages = { [1] = "a\nX\nb\n", [2] = "a\nb\n", [3] = "a\nY\nb\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "X" }, m.regions[1].base)
    end)

    it("anchors spans at BOF and EOF without leaning on context", function()
        package.loaded["differ.git"] = fake_git({
            worktree = file(
                merge_block({ "A1" }, { "A2" }),
                "mid",
                merge_block({ "B1" }, { "B2" })
            ),
            diff3 = file(
                diff3_block({ "A1" }, { "A" }, { "A2" }),
                "mid",
                diff3_block({ "B1" }, { "B" }, { "B2" })
            ),
            stages = { [1] = "A\nmid\nB\n", [2] = "A1\nmid\nB1\n", [3] = "A2\nmid\nB2\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "A" }, m.regions[1].base) -- first line of the base stage
        assert.are.same({ "B" }, m.regions[2].base) -- last line
    end)

    it("disambiguates duplicate conflict content by order", function()
        package.loaded["differ.git"] = fake_git({
            worktree = file(
                merge_block({ "X1" }, { "X2" }),
                "mid",
                merge_block({ "X1" }, { "X2" })
            ),
            diff3 = file(
                diff3_block({ "X1" }, { "P" }, { "X2" }),
                "mid",
                diff3_block({ "X1" }, { "Q" }, { "X2" })
            ),
            stages = { [1] = "P\nmid\nQ\n", [2] = "X1\nmid\nX1\n", [3] = "X2\nmid\nX2\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "P" }, m.regions[1].base)
        assert.are.same({ "Q" }, m.regions[2].base)
    end)

    it("carries a sub-conflict with an empty ours slab along inside a run", function()
        package.loaded["differ.git"] = fake_git({
            worktree = file(merge_block({ "A1", "x", "D1" }, { "A2", "x", "C2", "D2" })),
            diff3 = file(
                diff3_block({ "A1" }, { "A" }, { "A2" }),
                "x",
                diff3_block({}, { "C" }, { "C2" }),
                diff3_block({ "D1" }, { "D" }, { "D2" })
            ),
            stages = { [1] = "A\nx\nC\nD\n", [2] = "A1\nx\nD1\n", [3] = "A2\nx\nC2\nD2\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        -- the run reached D, so it passed over the ours-deleted C on the way
        assert.are.same({ "A", "x", "C", "D" }, m.regions[1].base)
    end)

    it("recovers a coalesced block whose last sub-conflict is an ours deletion", function()
        package.loaded["differ.git"] = fake_git({
            worktree = file(merge_block({ "A1" }, { "A2", "x", "C2" })),
            diff3 = file(
                diff3_block({ "A1" }, { "A" }, { "A2" }),
                "x",
                diff3_block({}, { "C" }, { "C2" })
            ),
            stages = { [1] = "A\nx\nC\n", [2] = "A1\n", [3] = "A2\nx\nC2\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "A", "x", "C" }, m.regions[1].base)
    end)

    it("anchors the span on the first non-empty base slab in the run", function()
        package.loaded["differ.git"] = fake_git({
            worktree = file(merge_block({ "A1", "B1" }, { "A2", "B2" })),
            diff3 = file(
                diff3_block({ "A1" }, {}, { "A2" }),
                diff3_block({ "B1" }, { "B" }, { "B2" })
            ),
            stages = { [1] = "B\n", [2] = "A1\nB1\n", [3] = "A2\nB2\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "B" }, m.regions[1].base)
    end)

    it("skips a synthetic conflict no worktree region owns", function()
        package.loaded["differ.git"] = fake_git({
            worktree = file(
                merge_block({ "A1" }, { "A2" }),
                "mid",
                merge_block({ "C1" }, { "C2" })
            ),
            diff3 = file(
                diff3_block({ "A1" }, { "A" }, { "A2" }),
                diff3_block({ "B1" }, { "B" }, { "B2" }),
                "mid",
                diff3_block({ "C1" }, { "C" }, { "C2" })
            ),
            stages = { [1] = "A\nB\nmid\nC\n", [2] = "A1\nmid\nC1\n", [3] = "A2\nmid\nC2\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "A" }, m.regions[1].base)
        assert.are.same({ "C" }, m.regions[2].base)
    end)

    it("won't skip to a claim only one side corroborates", function()
        -- the second region could reach the third synthetic conflict on theirs alone, but
        -- getting there means skipping an orphan, so one side's word isn't enough
        package.loaded["differ.git"] = fake_git({
            worktree = file(merge_block({ "A1" }, { "A2" }), "mid", merge_block({}, { "C2" })),
            diff3 = file(
                diff3_block({ "A1" }, { "A" }, { "A2" }),
                diff3_block({ "B1" }, { "B" }, { "B2" }),
                "mid",
                diff3_block({}, { "C" }, { "C2" })
            ),
            stages = { [1] = "A\nB\nmid\nC\n", [2] = "A1\nmid\n", [3] = "A2\nmid\nC2\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "A" }, m.regions[1].base)
        assert.is_nil(m.regions[2].base)
    end)

    it("leaves base absent when the two sides disagree on the run", function()
        package.loaded["differ.git"] = fake_git({
            worktree = RESULT_DISPUTED,
            diff3 = SYNTH_TWO,
            stages = { [1] = "A\nB\n", [2] = "A1\nB1\n", [3] = "A2\n" },
        })
        local m = model.build("/repo", "a.txt", nil)
        assert.is_nil(m.regions[1].base)
    end)

    it("leaves base absent when the region owns no synthetic conflict", function()
        package.loaded["differ.git"] = fake_git({ diff3 = SYNTH_FOREIGN })
        local m = model.build("/repo", "a.txt", nil)
        assert.is_nil(m.regions[1].base)
    end)

    it("bails when a synthetic base slab isn't in the base stage", function()
        -- SYNTH_ONE's base slab is "recovered"; the default base stage is "base"
        package.loaded["differ.git"] = fake_git({ diff3 = SYNTH_ONE })
        local m = model.build("/repo", "a.txt", nil)
        assert.is_nil(m.regions[1].base)
    end)

    it("leaves base absent when the re-merge is unavailable", function()
        package.loaded["differ.git"] = fake_git({ diff3 = nil })
        local m = model.build("/repo", "a.txt", nil)
        assert.is_nil(m.regions[1].base)
    end)

    it("keeps the marker-derived base under diff3 style (no re-merge)", function()
        -- the worktree already carries a base slab, so recovery is skipped and the
        -- re-merge stub (which would return a different slab) is never consulted
        package.loaded["differ.git"] = fake_git({ worktree = RESULT_DIFF3, diff3 = SYNTH_ONE })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "ancestor" }, m.regions[1].base)
    end)
end)
