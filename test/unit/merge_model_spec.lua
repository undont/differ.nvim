-- the MergeModel builder over a stubbed git layer: the parse path is real (pure
-- conflict.parse + to_lines), only the I/O reads are faked, so the assembly + the
-- no-conflict / missing-file guards are checked without a git repo or nvim runtime

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

-- a synthetic diff3 re-merge carrying one region with a base slab, matching RESULT's count
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

    it("recovers base slabs from a diff3 re-merge when the markers omit them", function()
        package.loaded["differ.git"] = fake_git({ diff3 = SYNTH_ONE })
        local m = model.build("/repo", "a.txt", nil)
        assert.are.same({ "recovered" }, m.regions[1].base)
    end)

    it("leaves base absent when the re-merge count disagrees with the worktree", function()
        -- two synthetic regions against RESULT's one: the regions may not correspond,
        -- so nothing is copied across
        local synth = SYNTH_ONE:gsub("\n$", "\n") .. SYNTH_ONE
        package.loaded["differ.git"] = fake_git({ diff3 = synth })
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
