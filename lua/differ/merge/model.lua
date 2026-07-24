-- the 3-way merge model: the full ours/base/theirs stage contents plus the
-- ordered conflict regions parsed from the worktree file (the result spine slices 2-3
-- render and edit). the stages are the authoritative column content, so they're correct
-- under any merge.conflictStyle; the marker parse only locates the regions

local conflict = require("differ.git.conflict")
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

-- the default `merge` conflictStyle writes no base slab, so the parsed regions carry
-- `base = nil` and the BASE column has nothing to locate or take. recover the slabs by
-- re-merging the stages in diff3 style and copying each synthetic region's base across by
-- position. only the slab is copied, never mark_base: the worktree result genuinely has no
-- base marker, so its per-side painting stays correct. trusted only when the synthetic
-- merge yields the same region count (else the regions may not correspond, and no base
-- beats a mislabelled one); a no-op under diff3/zdiff3, where the markers already carried it
---@param regions differ.merge.Region[]
---@param ours_text string
---@param base_text string
---@param theirs_text string
local function recover_base(regions, ours_text, base_text, theirs_text)
    if #regions == 0 or regions[1].base then
        return
    end
    local synth = require("differ.git").merge_file_diff3(ours_text, base_text, theirs_text)
    if not synth then
        return
    end
    local synth_regions = conflict.parse(to_lines(synth))
    if #synth_regions ~= #regions then
        return
    end
    for i, r in ipairs(regions) do
        r.base = synth_regions[i].base
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
