-- the 3-way merge model: the full ours/base/theirs stage contents plus the ordered
-- conflicts, each a complete region parsed from the worktree file or a group of markers a
-- hand edit broke. the stages are the authoritative column content, so they're correct
-- under any merge.conflictStyle; the marker parse only locates the conflicts

local conflict = require("differ.git.conflict")
local find_run = require("differ.util.lines").find_run
local find_runs = require("differ.util.lines").find_runs
local is_binary = require("differ.util.text").is_binary
local to_lines = require("differ.util.text").to_lines

---@class differ.MergeModel
---@field path string        -- repo-relative
---@field root string
---@field ours_text string   -- full :2: stage
---@field base_text string   -- full :1: stage
---@field theirs_text string -- full :3: stage
---@field result_text string -- the worktree file as-is (markers intact)
---@field conflicts differ.merge.Conflict[]
---@field regions differ.merge.Region[]  -- the complete ones, indexed as their conflict
---@field orphans integer[]  -- marker lines no region uses, content excluded (conflict.markers)
---@field content_markers table<string, true> -- the stages' marker-shaped lines (conflict.content_markers)
---@field marker_size integer -- the path's conflict-marker-size, 7 by default
---@field head string|nil
---@field no_ancestor boolean -- add/add: no :1: stage, so no base exists to recover or take
---@field deleted "ours"|"theirs"|nil -- modify/delete: the side that deleted the file, no regions
---@field binary table<"ours"|"base"|"theirs", differ.merge.Blob>|nil -- binary stages: no regions, empty texts

---@class differ.merge.Conflict
---@field index integer         -- 1-based, conflict order in the file
---@field result_start integer  -- a broken one's first orphan, widened to its located slabs
---@field result_end integer
---@field ours string[]         -- `{}` where a broken one's slab wasn't recovered
---@field base string[]|nil
---@field theirs string[]
---@field region differ.merge.Region|nil -- the parsed region, nil when its markers are broken

---@class differ.merge.Blob
---@field oid string
---@field size integer

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
-- (ort resolves cases merge-file conflicts on, so the re-merge can carry extra ones). a claim
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

-- the stage span a run covers, anchored on its first and last located slab. the span, not
-- the sub-slabs concatenated, so a coalesced block keeps its interstitials. all-empty slabs
-- cover nothing, which take-base resolves to a deletion
---@param slabs string[][]  -- this side's slab per synthetic region, in order
---@param at table<integer, integer>  -- synthetic index -> stage start
---@param first integer
---@param last integer
---@param stage_lines string[]
---@return string[]
local function stage_span(slabs, at, first, last, stage_lines)
    local from, to
    for i = first, last do
        if at[i] then
            from = from or at[i]
            to = at[i] + #slabs[i] - 1
        end
    end
    if not from then
        return {}
    end
    local slab = {}
    for i = from, to do
        slab[#slab + 1] = stage_lines[i]
    end
    return slab
end

-- start of `slab` in `lines` between `from` and `hi`, or nil
---@param lines string[]
---@param slab string[]
---@param from integer
---@param hi integer
---@return integer|nil
local function place(lines, slab, from, hi)
    local s = find_run(lines, slab, from)
    if s and s + #slab - 1 <= hi then
        return s
    end
    return nil
end

-- the synthetic regions a broken conflict owns: those whose every non-empty side places in
-- order inside its result window `lo`..`hi`. a region that won't place is skipped (ort
-- resolved it, or the hand edit reached into it). nil when it owns none
---@param lines string[]  -- the worktree result
---@param lo integer
---@param hi integer
---@param synth differ.merge.Region[]
---@param from integer
---@param to integer
---@return { first: integer, last: integer, top: integer, bottom: integer }|nil
local function own(lines, lo, hi, synth, from, to)
    local owned
    local cursor = { ours = lo, theirs = lo }
    for i = from, to do
        local hits, ok = {}, true
        for _, side in ipairs({ "ours", "theirs" }) do
            local slab = synth[i][side]
            if #slab > 0 then
                hits[side] = place(lines, slab, cursor[side], hi)
                ok = ok and hits[side] ~= nil
            end
        end
        if ok and (hits.ours or hits.theirs) then
            owned = owned or { first = i, top = math.huge, bottom = 0 }
            owned.last = i
            for side, s in pairs(hits) do
                cursor[side] = s + #synth[i][side]
                owned.top = math.min(owned.top, s)
                owned.bottom = math.max(owned.bottom, cursor[side] - 1)
            end
        end
    end
    return owned
end

-- each side's slab per synthetic region, `{}` where a region carries none
---@param synth differ.merge.Region[]
---@param side "ours"|"base"|"theirs"
---@return string[][]
local function side_slabs(synth, side)
    local out = {}
    for i, r in ipairs(synth) do
        out[i] = r[side] or {}
    end
    return out
end

-- the conflicts in result order: the complete regions plus one per incomplete group, its
-- span the group's orphan lines until attach widens it. renumbers the regions to match
---@param regions differ.merge.Region[]
---@param groups { first: integer, last: integer }[]
---@return differ.merge.Conflict[]
local function spine(regions, groups)
    local out, i, j = {}, 1, 1
    while regions[i] or groups[j] do
        local r, g = regions[i], groups[j]
        local c
        if r and (not g or r.result_start < g.first) then
            r.index = #out + 1
            c = {
                result_start = r.result_start,
                result_end = r.result_end,
                ours = r.ours,
                base = r.base,
                theirs = r.theirs,
                region = r,
            }
            i = i + 1
        else
            c = { result_start = g.first, result_end = g.last, ours = {}, theirs = {} }
            j = j + 1
        end
        c.index = #out + 1
        out[c.index] = c
    end
    return out
end

-- fill the conflicts from a diff3 re-merge of the stages, mapped onto the worktree: ort
-- coalesces conflicts that merge-file keeps apart, so a complete region owns a run of
-- synthetic ones. both sides claim independently and must agree where the run ends before
-- its base is recovered (the default `merge` conflictStyle writes none), and anything
-- ambiguous leaves base nil (a wrong slab gets spliced in by take-base). a broken conflict
-- owns the leftover synthetic regions that place inside its window between its neighbours,
-- taking its slabs from their stage spans and its result span widened to where they sit
---@param conflicts differ.merge.Conflict[]
---@param result_lines string[]
---@param texts table<"ours"|"base"|"theirs", string>
---@param size integer  -- conflict marker length
---@param no_ancestor boolean
---@return boolean remerged
local function attach(conflicts, result_lines, texts, size, no_ancestor)
    local recover, broken = false, false
    for _, c in ipairs(conflicts) do
        recover = recover or (c.region ~= nil and c.base == nil and not no_ancestor)
        broken = broken or c.region == nil
    end
    if not (recover or broken) then
        return false
    end
    local synth_text =
        require("differ.git").merge_file_diff3(texts.ours, texts.base, texts.theirs, size)
    if not synth_text then
        return false
    end
    local synth = conflict.parse(to_lines(synth_text), size)
    -- the synthetic regions came out of merging these stages, so each side's slabs must
    -- appear in its stage in order; a side where they don't isn't described by the re-merge
    local stage, slabs, at = {}, {}, {}
    for _, side in ipairs({ "ours", "base", "theirs" }) do
        stage[side] = to_lines(texts[side])
        slabs[side] = side_slabs(synth, side)
        at[side] = find_runs(stage[side], slabs[side], 1)
    end

    local claimed, from = {}, 1
    for _, c in ipairs(conflicts) do
        local run = c.region and claim(c.region, synth, from)
        if run then
            local last = math.max(run.ours, run.theirs)
            claimed[c.index] = { first = run.first, last = last }
            local agreed = agree(synth, run.ours, run.theirs)
            if c.base == nil and not no_ancestor and agreed and at.base then
                c.base = stage_span(slabs.base, at.base, run.first, last, stage.base)
                c.region.base = c.base
            end
            from = last + 1 -- consumed either way, a disputed run isn't the next region's
        end
    end

    local cursor = 1
    for k, c in ipairs(conflicts) do
        if c.region then
            cursor = claimed[k] and claimed[k].last + 1 or cursor
        else
            local stop = #synth
            for n = k + 1, #conflicts do
                if claimed[n] then
                    stop = claimed[n].first - 1
                    break
                end
            end
            local lo = k > 1 and conflicts[k - 1].result_end + 1 or 1
            local hi = conflicts[k + 1] and conflicts[k + 1].result_start - 1 or #result_lines
            local owned = own(result_lines, lo, hi, synth, cursor, stop)
            if owned then
                c.result_start = math.min(c.result_start, owned.top)
                c.result_end = math.max(c.result_end, owned.bottom)
                for _, side in ipairs({ "ours", "base", "theirs" }) do
                    if at[side] and not (side == "base" and no_ancestor) then
                        c[side] =
                            stage_span(slabs[side], at[side], owned.first, owned.last, stage[side])
                    end
                end
                cursor = owned.last + 1
            end
        end
    end
    return true
end

-- whether a broken conflict is a conflict rather than marker-shaped content: it is content
-- when the re-merge ran and gave it no slabs, and every orphan in its span is text a stage
-- carries
---@param c differ.merge.Conflict
---@param lines string[]
---@param orphans integer[]
---@param content table<string, true>
---@param remerged boolean
---@return boolean
local function is_conflict(c, lines, orphans, content, remerged)
    if c.region or not remerged or #c.ours > 0 or #c.theirs > 0 then
        return true
    end
    local inside = {}
    for _, lnum in ipairs(orphans) do
        if lnum >= c.result_start and lnum <= c.result_end then
            inside[#inside + 1] = lnum
        end
    end
    return #conflict.markers(lines, inside, {}, content) > 0
end

-- the side that deleted a modify/delete file: the ancestor and exactly one side's stage
-- are in the index. git leaves the other side's file on disk with no markers
---@param root string
---@param relpath string
---@return "ours"|"theirs"|nil
local function deleted_side(root, relpath)
    local git = require("differ.git")
    if not git.has_stage(root, relpath, 1) then
        return nil
    end
    local has_ours = git.has_stage(root, relpath, 2)
    if has_ours == git.has_stage(root, relpath, 3) then
        return nil
    end
    if has_ours then
        return "theirs"
    end
    return "ours"
end

local STAGE_SIDES = { [1] = "base", [2] = "ours", [3] = "theirs" }

-- each present stage's object id and size, by side
---@param stages table<integer, { mode: string, oid: string }>
---@param texts table<"ours"|"base"|"theirs", string>
---@return table<"ours"|"base"|"theirs", differ.merge.Blob>
local function stage_blobs(stages, texts)
    local blobs = {}
    for stage, side in pairs(STAGE_SIDES) do
        if stages[stage] then
            blobs[side] = { oid = stages[stage].oid, size = #texts[side] }
        end
    end
    return blobs
end

-- whether a stage or the worktree holds `relpath` as a symlink
---@param root string
---@param relpath string
---@param stages table<integer, { mode: string, oid: string }>
---@return boolean
local function is_symlink(root, relpath, stages)
    for stage in pairs(STAGE_SIDES) do
        if stages[stage] and stages[stage].mode == "120000" then
            return true
        end
    end
    return require("differ.git").is_symlink(root, relpath)
end

-- build a MergeModel for a conflicted `relpath`. returns nil + a reason when the file
-- is a symlink, isn't on disk, or carries no conflict marker lines and is neither binary
-- nor a modify/delete conflict
---@param root string
---@param relpath string
---@param head string|nil
---@return differ.MergeModel|nil, string|nil err
function M.build(root, relpath, head)
    local git = require("differ.git")
    local stages = git.stages(root, relpath)
    if is_symlink(root, relpath, stages) then
        return nil, relpath .. " is a symlink"
    end
    local result_text = git.read({ kind = "worktree", label = "WORKTREE" }, root, relpath)
    if not result_text then
        return nil, relpath .. " is not in the working tree"
    end
    local ours_text = git.read_stage(root, relpath, 2)
    local base_text = git.read_stage(root, relpath, 1)
    local theirs_text = git.read_stage(root, relpath, 3)
    -- only ambiguous when the stage read back empty, so the extra call sits inside that
    local no_ancestor = base_text == "" and not git.has_stage(root, relpath, 1)
    if is_binary(ours_text) or is_binary(base_text) or is_binary(theirs_text) then
        local texts = { ours = ours_text, base = base_text, theirs = theirs_text }
        return {
            path = relpath,
            root = root,
            ours_text = "",
            base_text = "",
            theirs_text = "",
            result_text = "",
            conflicts = {},
            regions = {},
            orphans = {},
            content_markers = {},
            marker_size = 7, -- no markers in a binary result
            head = head,
            no_ancestor = no_ancestor,
            deleted = deleted_side(root, relpath),
            binary = stage_blobs(stages, texts),
        }
    end
    local marker_size = git.marker_size(root, relpath)
    local result_lines = to_lines(result_text)
    local regions = conflict.parse(result_lines, marker_size)
    local orphans = conflict.orphans(result_lines, marker_size)
    local content = conflict.content_markers(
        { to_lines(ours_text), to_lines(base_text), to_lines(theirs_text) },
        marker_size
    )
    local spun = spine(regions, conflict.incomplete(result_lines, marker_size))
    -- with no ancestor the re-merge still yields empty base slabs, which attach would copy
    -- across as `{}`; that's truthy, so take-base would splice it and silently drop the block
    local texts = { ours = ours_text, base = base_text, theirs = theirs_text }
    local remerged = attach(spun, result_lines, texts, marker_size, no_ancestor)
    local conflicts = {}
    for _, c in ipairs(spun) do
        if is_conflict(c, result_lines, orphans, content, remerged) then
            c.index = #conflicts + 1
            if c.region then
                c.region.index = c.index
            end
            conflicts[c.index] = c
        end
    end
    local deleted = nil
    if #conflicts == 0 then
        deleted = deleted_side(root, relpath)
        if not deleted then
            return nil, relpath .. " has no conflicts to resolve"
        end
    end
    return {
        path = relpath,
        root = root,
        ours_text = ours_text,
        base_text = base_text,
        theirs_text = theirs_text,
        result_text = result_text,
        conflicts = conflicts,
        regions = regions,
        orphans = conflict.markers(result_lines, orphans, conflicts, content),
        content_markers = content,
        marker_size = marker_size,
        head = head,
        no_ancestor = no_ancestor,
        deleted = deleted,
    }
end

return M
