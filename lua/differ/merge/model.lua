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
    return {
        path = relpath,
        root = root,
        ours_text = git.read_stage(root, relpath, 2),
        base_text = git.read_stage(root, relpath, 1),
        theirs_text = git.read_stage(root, relpath, 3),
        result_text = result_text,
        regions = regions,
        head = head,
    }
end

return M
