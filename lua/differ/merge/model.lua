-- the 3-way merge model: the full ours/base/theirs stage contents plus the
-- ordered conflict regions parsed from the worktree file (the result spine slices 2-3
-- render and edit). the stages are the authoritative column content, so they're correct
-- under any merge.conflictStyle; the marker parse only locates the regions

local conflict = require("differ.git.conflict")
local find_run = require("differ.util.lines").find_run
local find_runs = require("differ.util.lines").find_runs
local to_lines = require("differ.util.text").to_lines

---@class differ.MergeModel
---@field path string        -- repo-relative
---@field root string
---@field ours_text string   -- full :2: stage
---@field base_text string   -- full :1: stage
---@field theirs_text string -- full :3: stage
---@field result_text string -- the worktree file as-is (markers intact)
---@field regions differ.merge.Region[]
---@field head string|nil

local M = {}

-- the maximal run of synthetic regions this side owns, extending while each candidate's
-- slab places in order and disjoint inside `lines`. empty slabs are skipped, so they ride
-- along mid-run and are left behind at its end. `from - 1` when the side located nothing
---@param lines string[]  -- the worktree region's slab for this side
---@param synth differ.merge.Region[]
---@param key "ours"|"theirs"
---@param from integer
---@return integer
local function claim_run(lines, synth, key, from)
    local last, cursor = from - 1, 1
    for i = from, #synth do
        local slab = synth[i][key]
        if #slab > 0 then
            local s = find_run(lines, slab, cursor)
            if not s then
                break
            end
            cursor, last = s + #slab, i
        end
    end
    return last
end

-- claims that differ are blindness rather than contradiction when every synth region the
-- shorter side stopped short of is empty on that side: it had nothing to look for there
---@param synth differ.merge.Region[]
---@param ours_last integer
---@param theirs_last integer
---@return boolean
local function agree(synth, ours_last, theirs_last)
    local key = ours_last < theirs_last and "ours" or "theirs"
    for i = math.min(ours_last, theirs_last) + 1, math.max(ours_last, theirs_last) do
        if #synth[i][key] > 0 then
            return false
        end
    end
    return true
end

-- the run a worktree region owns, scanning past synthetic regions nothing corresponds to
-- (ort resolves cases merge-file conflicts on, so the re-merge can carry orphans). a claim
-- that needed skipping must be corroborated by both sides, else a region owning nothing
-- would hunt the rest of the file for a coincidental match. nil when it owns nothing at all
---@param region differ.merge.Region
---@param synth differ.merge.Region[]
---@param from integer
---@return { first: integer, ours: integer, theirs: integer }|nil
local function claim(region, synth, from)
    for start = from, #synth do
        local ours = claim_run(region.ours, synth, "ours", start)
        local theirs = claim_run(region.theirs, synth, "theirs", start)
        local corroborated = ours >= start and theirs >= start
        if math.max(ours, theirs) >= start and (start == from or corroborated) then
            return { first = start, ours = ours, theirs = theirs }
        end
    end
end

-- the base-stage span a run covers, anchored on its first and last located slab. the span,
-- not the sub-slabs concatenated, so a coalesced block keeps its interstitials. all-empty
-- base slabs cover nothing, which take-base resolves to a deletion
---@param base_slabs string[][]  -- per synthetic region, in order
---@param at table<integer, integer>  -- synthetic index -> base-stage start
---@param first integer
---@param last integer
---@param base_lines string[]
---@return string[]
local function base_span(base_slabs, at, first, last, base_lines)
    local from, to
    for i = first, last do
        if at[i] then
            from = from or at[i]
            to = at[i] + #base_slabs[i] - 1
        end
    end
    if not from then
        return {}
    end
    local slab = {}
    for i = from, to do
        slab[#slab + 1] = base_lines[i]
    end
    return slab
end

-- the default `merge` conflictStyle writes no base slab, so the parsed regions carry
-- `base = nil` and the BASE column has nothing to take. recover them by re-merging the
-- stages in diff3 style and mapping the synthetic regions onto the worktree ones: ort
-- coalesces conflicts that merge-file keeps apart, so a worktree region owns a run of them.
-- both sides claim independently and must agree where the run ends, a side with nothing
-- locatable abstains, anything ambiguous leaves base nil (a wrong slab gets spliced in by
-- take-base). only the slab is copied, never mark_base. a no-op under diff3/zdiff3
---@param regions differ.merge.Region[]
---@param ours_text string
---@param base_text string
---@param theirs_text string
local function recover_base(regions, ours_text, base_text, theirs_text)
    if #regions == 0 or regions[1].base then
        return
    end
    local synth_text = require("differ.git").merge_file_diff3(ours_text, base_text, theirs_text)
    if not synth_text then
        return
    end
    local synth = conflict.parse(to_lines(synth_text))
    local base_slabs = {}
    for i, s in ipairs(synth) do
        base_slabs[i] = s.base or {}
    end
    -- the synthetic regions came out of merging this base, so their slabs must appear in it
    -- in order; if they don't, the re-merge doesn't describe our stages
    local base_lines = to_lines(base_text)
    local at = find_runs(base_lines, base_slabs, 1)
    if not at then
        return
    end
    local from = 1
    for _, r in ipairs(regions) do
        local run = claim(r, synth, from)
        if run then
            local last = math.max(run.ours, run.theirs)
            if agree(synth, run.ours, run.theirs) then
                r.base = base_span(base_slabs, at, run.first, last, base_lines)
            end
            from = last + 1 -- consumed either way, a disputed run isn't the next region's
        end
    end
end

-- build a MergeModel for a conflicted `relpath`. returns nil + a reason when the file
-- isn't on disk or carries no conflict markers (already resolved / never conflicted)
---@param root string
---@param relpath string
---@param head string|nil
---@return differ.MergeModel|nil, string|nil err
function M.build(root, relpath, head)
    local git = require("differ.git")
    local result_text = git.read({ kind = "worktree", label = "WORKTREE" }, root, relpath)
    if not result_text then
        return nil, "file is not in the working tree"
    end
    local regions = conflict.parse(to_lines(result_text))
    if #regions == 0 then
        return nil, "no conflicts to resolve"
    end
    local ours_text = git.read_stage(root, relpath, 2)
    local base_text = git.read_stage(root, relpath, 1)
    local theirs_text = git.read_stage(root, relpath, 3)
    recover_base(regions, ours_text, base_text, theirs_text)
    return {
        path = relpath,
        root = root,
        ours_text = ours_text,
        base_text = base_text,
        theirs_text = theirs_text,
        result_text = result_text,
        regions = regions,
        head = head,
    }
end

return M
