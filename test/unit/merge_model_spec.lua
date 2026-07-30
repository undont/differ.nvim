-- the MergeModel builder over a stubbed git layer: the parse path is real (pure
-- conflict.parse + to_lines), only the I/O reads are faked, so the assembly + the
-- no-conflict / missing-file guards are checked without a git repo or nvim runtime.
-- base recovery is stubbed at the re-merge, so the synthetic regions it maps are fed
-- in directly rather than produced by git merge-file

local model = require("differ.merge.model")

-- a default-style conflicted worktree file (no base slab in the markers)
local RESULT = table.concat({
    "keep me",
    "<<<<<<< HEAD",
    "ours",
    "=======",
    "theirs",
    ">>>>>>> branch",
}, "\n") .. "\n"

-- a diff3-style conflicted worktree file (base slab already present)
local RESULT_DIFF3 = table.concat({
    "keep me",
    "<<<<<<< HEAD",
    "ours",
    "||||||| base",
    "ancestor",
    "=======",
    "theirs",
    ">>>>>>> branch",
}, "\n") .. "\n"

-- a synthetic diff3 re-merge carrying one region, matching RESULT's single conflict
local SYNTH_ONE = table.concat({
    "keep me",
    "<<<<<<< ours",
    "ours",
    "||||||| base",
    "recovered",
    "=======",
    "theirs",
    ">>>>>>> theirs",
}, "\n") .. "\n"

-- ort coalesced two diverged spots into one block; merge-file kept them apart, so the
-- single worktree region owns both synthetic ones and its base spans the "mid" between them
local RESULT_COALESCED = table.concat({
    "head",
    "<<<<<<< HEAD",
    "A1",
    "mid",
    "B1",
    "=======",
    "A2",
    "mid",
    "B2",
    ">>>>>>> branch",
    "tail",
}, "\n") .. "\n"

local SYNTH_SPLIT = table.concat({
    "head",
    "<<<<<<< ours",
    "A1",
    "||||||| base",
    "A",
    "=======",
    "A2",
    ">>>>>>> theirs",
    "mid",
    "<<<<<<< ours",
    "B1",
    "||||||| base",
    "B",
    "=======",
    "B2",
    ">>>>>>> theirs",
    "tail",
}, "\n") .. "\n"

local COALESCED_STAGES = {
    [1] = "head\nA\nmid\nB\ntail\n",
    [2] = "head\nA1\nmid\nB1\ntail\n",
    [3] = "head\nA2\nmid\nB2\ntail\n",
}

-- the same stages and the same re-merge, but ort kept the two spots apart, so each region
-- owns one synthetic conflict and the spans stay disjoint
local RESULT_SEPARATE = table.concat({
    "head",
    "<<<<<<< HEAD",
    "A1",
    "=======",
    "A2",
    ">>>>>>> branch",
    "mid",
    "<<<<<<< HEAD",
    "B1",
    "=======",
    "B2",
    ">>>>>>> branch",
    "tail",
}, "\n") .. "\n"

-- ours deleted the line theirs modified, so the worktree region's ours slab is empty and
-- only theirs can claim the synthetic region
local RESULT_OURS_DELETED = table.concat({
    "a",
    "<<<<<<< HEAD",
    "=======",
    "Y",
    ">>>>>>> branch",
    "b",
}, "\n") .. "\n"

local SYNTH_OURS_DELETED = table.concat({
    "a",
    "<<<<<<< ours",
    "||||||| base",
    "X",
    "=======",
    "Y",
    ">>>>>>> theirs",
    "b",
}, "\n") .. "\n"

-- the sides disagree: ours holds both synthetic ours slabs, theirs holds only the first
local RESULT_DISPUTED = table.concat({
    "<<<<<<< HEAD",
    "A1",
    "B1",
    "=======",
    "A2",
    ">>>>>>> branch",
}, "\n") .. "\n"

local SYNTH_TWO = table.concat({
    "<<<<<<< ours",
    "A1",
    "||||||| base",
    "A",
    "=======",
    "A2",
    ">>>>>>> theirs",
    "<<<<<<< ours",
    "B1",
    "||||||| base",
    "B",
    "=======",
    "B2",
    ">>>>>>> theirs",
}, "\n") .. "\n"

-- a re-merge describing a conflict nothing in the worktree corresponds to
local SYNTH_FOREIGN = table.concat({
    "<<<<<<< ours",
    "zzz",
    "||||||| base",
    "base",
    "=======",
    "qqq",
    ">>>>>>> theirs",
}, "\n") .. "\n"

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
