-- what the index should hold after a hunk of a HEAD↔worktree diff is staged or
-- unstaged. the index's lines at each hunk come from marks.blocks where the index holds
-- every unchanged line between them; otherwise the op moves whole pair hunks.
-- pure lua, no vim API

local apply = require("differ.model.apply")
local marks = require("differ.model.marks")
local text_util = require("differ.util.text")

local M = {}

-- the index's lines at each union hunk, and the union with a last line and its ending
-- read as one (apply.ended). the blocks are nil unless the index holds every unchanged
-- line between the hunks and rejoins to exactly its own text
---@param union differ.DiffModel  -- HEAD↔worktree
---@param index string            -- the index's text
---@return string[][]|nil blocks, differ.DiffModel ended
function M.index_blocks(union, index)
    local ended = apply.ended(union)
    local head_lines, index_lines =
        text_util.ended_lines(union.old_text), text_util.ended_lines(index)
    local blocks = marks.blocks(ended.hunks, head_lines, index_lines)
    if not blocks or apply.join(ended, blocks) ~= index then
        return nil, ended
    end
    return blocks, ended
end

-- the hunks that meet `anchor` on the sides given, or the rest of them
---@param hunks differ.Hunk[]
---@param side "old"|"new"  -- the side of `hunks` compared
---@param anchor differ.Hunk
---@param anchor_side "old"|"new"
---@param want boolean  -- true picks the hunks that meet it, false the rest
---@return table<integer, boolean>
function M.select_hunks(hunks, side, anchor, anchor_side, want)
    local applied = {}
    for i, h in ipairs(hunks) do
        applied[i] = marks.meets(h, side, anchor, anchor_side) == want
    end
    return applied
end

-- where `hunk` sits in a fresh read of the union, by its line ranges
---@param union differ.DiffModel
---@param hunk differ.Hunk
---@return integer|nil
function M.hunk_index(union, hunk)
    for i, u in ipairs(union.hunks) do
        if
            u.old_start == hunk.old_start
            and u.old_count == hunk.old_count
            and u.new_start == hunk.new_start
            and u.new_count == hunk.new_count
        then
            return i
        end
    end
    return nil
end

-- the index's lines at each union hunk with `hunk`'s own replaced by the side the op
-- takes, or nil where the index can't be cut into blocks
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param hunk differ.Hunk
---@param take boolean
---@return string|nil
local function by_blocks(union, cached, hunk, take)
    local blocks, ended = M.index_blocks(union, cached.new_text)
    local i = M.hunk_index(union, hunk)
    if not (blocks and i) then
        return nil
    end
    blocks[i] = ended.hunks[i].old_lines
    if take then
        blocks[i] = ended.hunks[i].new_lines
    end
    return apply.join(ended, blocks)
end

-- the text the index takes when `hunk` is staged (`take`) or unstaged. the index's lines
-- at the hunk become the hunk's new or old lines; an index that changes a line between
-- hunks moves by the pair hunks meeting it on the side that pair shares. `reaches` names
-- another union hunk such a pair hunk covers too, and then there is no text: staging by
-- hunk can't take one without the other. no text and no `reaches` is a hunk the pair the
-- op reads for lines up under a different union hunk, leaving the index where it is
---@param union differ.DiffModel     -- HEAD↔worktree
---@param cached differ.DiffModel    -- HEAD↔index
---@param unstaged differ.DiffModel  -- index↔worktree
---@param hunk differ.Hunk
---@param take boolean
---@return string|nil text, integer|nil reaches
function M.next_index(union, cached, unstaged, hunk, take)
    local text = by_blocks(union, cached, hunk, take)
    if not text then
        local from, side = unstaged, "new"
        if not take then
            from, side = cached, "old"
        end
        local reaches = marks.shared_with(union.hunks, hunk, from.hunks, side)
        if reaches then
            return nil, reaches
        end
        text = apply.splice(from, M.select_hunks(from.hunks, side, hunk, side, take))
    end
    if text == cached.new_text then
        return nil -- the op has nothing of this hunk to move on its own
    end
    return text
end

return M
