-- pure conflict-resolution splice: replace a region's marker block with a chosen
-- slab. no nvim API, so it's unit-tested; the session re-parses the live buffer after each
-- splice (markers vanish with the block) rather than tracking offsets, so resolving a
-- region by keymap and hand-editing converge on the same source of truth

local M = {}

-- the lines a choice contributes. ours/theirs come from the region; both is ours then
-- theirs (diffview's "take all" order); none drops the block. base is nil when the
-- region carries no base slab (default conflictStyle), so the caller can notify
---@param region differ.merge.Region|differ.merge.Slabs
---@param choice "ours"|"theirs"|"both"|"base"|"none"
---@return string[]|nil
function M.slab(region, choice)
    if choice == "ours" then
        return region.ours
    elseif choice == "theirs" then
        return region.theirs
    elseif choice == "base" then
        return region.base
    elseif choice == "none" then
        return {}
    elseif choice == "both" then
        local out = {}
        for _, l in ipairs(region.ours) do
            out[#out + 1] = l
        end
        for _, l in ipairs(region.theirs) do
            out[#out + 1] = l
        end
        return out
    end
end

-- replace `region`'s marker block (result_start..result_end, markers included) in `lines`
-- with the chosen slab. returns the new lines + the line-count delta, or nil when the
-- choice resolves to no slab (base requested but absent)
---@param lines string[]
---@param region differ.merge.Region
---@param choice "ours"|"theirs"|"both"|"base"|"none"
---@return string[]|nil new_lines, integer|nil delta
function M.splice(lines, region, choice)
    local slab = M.slab(region, choice)
    if not slab then
        return nil
    end
    local out = {}
    for i = 1, region.result_start - 1 do
        out[#out + 1] = lines[i]
    end
    for _, l in ipairs(slab) do
        out[#out + 1] = l
    end
    for i = region.result_end + 1, #lines do
        out[#out + 1] = lines[i]
    end
    local block_len = region.result_end - region.result_start + 1
    return out, #slab - block_len
end

return M
