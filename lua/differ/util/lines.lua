-- shared line-array searching, pure lua, no nvim API. locating a run of lines inside a
-- larger array, in file order, is how both the merge renderer places a region's slab in
-- its stage file and how base recovery maps re-merged regions onto the worktree's

local M = {}

-- first 1-based start at or after `from` where `slab` matches `lines` run-for-run, or nil.
-- callers must not pass an empty slab: a zero-length run trivially matches at `from`, which
-- is a cursor position rather than a located anchor
---@param lines string[]
---@param slab string[]
---@param from integer
---@return integer|nil
function M.find_run(lines, slab, from)
    for start = from, #lines - #slab + 1 do
        local hit = true
        for k = 1, #slab do
            if lines[start + k - 1] ~= slab[k] then
                hit = false
                break
            end
        end
        if hit then
            return start
        end
    end
    return nil
end

-- place every slab in `slabs` inside `lines`, in order and without overlap, searching
-- forward from `from`. all-or-nothing: nil as soon as one can't be placed after the ones
-- before it, so a caller gets a whole consistent placement or no answer at all. empty slabs
-- are skipped rather than searched for (see find_run) and so take no position: the result
-- is keyed by index into `slabs` and may be sparse, don't take its length
---@param lines string[]
---@param slabs string[][]
---@param from integer
---@return table<integer, integer>|nil
function M.find_runs(lines, slabs, from)
    local out, cursor = {}, from
    for i, slab in ipairs(slabs) do
        if #slab > 0 then
            local s = M.find_run(lines, slab, cursor)
            if not s then
                return nil
            end
            out[i] = s
            cursor = s + #slab
        end
    end
    return out
end

return M
