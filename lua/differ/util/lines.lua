-- shared line-array searching, pure lua, no nvim API

local M = {}

-- first 1-based start at or after `from` where `slab` matches `lines` run-for-run, or nil.
-- an empty slab matches trivially at `from`, so callers must not pass one
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

-- place every slab inside `lines`, in order and disjoint, searching from `from`. all or
-- nothing: nil as soon as one won't place. empty slabs are skipped and take no position, so
-- the result is keyed by slab index and may be sparse, don't take its length
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
