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

---@class differ.model.Selection
---@field old table<integer, boolean>  -- union old lnums
---@field new table<integer, boolean>  -- union new lnums

---@alias differ.model.SelectRefusal
---| "between"  -- the index changes a line between hunks, so it can't be cut into blocks
---| "large"    -- a hunk too big to compare against its block
---| "hidden"   -- a selected hunk's block holds a line neither side has

-- whether the selection has a line on either side of `h`
---@param h differ.Hunk
---@param selection differ.model.Selection
---@return boolean
local function touches(h, selection)
    for l = h.old_start, h.old_start + h.old_count - 1 do
        if selection.old[l] then
            return true
        end
    end
    for l = h.new_start, h.new_start + h.new_count - 1 do
        if selection.new[l] then
            return true
        end
    end
    return false
end

-- one hunk's index block with the selected lines staged (`take`) or not. sides of the
-- same length go row by row, each kept old line then its held new line; otherwise the
-- old lines the index keeps, then the new lines it holds
---@param h differ.Hunk  -- an ended hunk
---@param held differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean
---@return string[]
local function select_block(h, held, selection, take)
    ---@param side "old"|"new"
    ---@param k integer
    ---@return boolean  -- the index has this line once the op is done
    local function in_index(side, k)
        local l = h[side .. "_start"] + k - 1
        local staged = held[side][l]
        if selection[side][l] then
            staged = take
        end
        if side == "old" then
            return not staged
        end
        return staged == true
    end
    local block = {}
    ---@param side "old"|"new"
    ---@param k integer
    local function push(side, k)
        if in_index(side, k) then
            block[#block + 1] = h[side .. "_lines"][k]
        end
    end
    if h.old_count == h.new_count then
        for k = 1, h.old_count do
            push("old", k)
            push("new", k)
        end
        return block
    end
    for k = 1, h.old_count do
        push("old", k)
    end
    for k = 1, h.new_count do
        push("new", k)
    end
    return block
end

-- the text the index takes when the selected union lines are staged (`take`) or
-- unstaged. only the hunks the selection touches are rebuilt; every other block stays
-- as the index has it. nil text with no refusal is a selection with nothing to move
---@param union differ.DiffModel   -- HEAD↔worktree
---@param cached differ.DiffModel  -- HEAD↔index
---@param selection differ.model.Selection
---@param take boolean
---@return string|nil text, differ.model.SelectRefusal|nil refusal
function M.select_index(union, cached, selection, take)
    local blocks, ended = M.index_blocks(union, cached.new_text)
    if not blocks then
        return nil, "between"
    end
    local held, hidden = marks.of_blocks(ended.hunks, blocks)
    if not held then
        return nil, "large"
    end
    local hides = {} ---@type table<integer, boolean>
    for _, i in ipairs(hidden) do
        hides[i] = true
    end
    for i, h in ipairs(ended.hunks) do
        if touches(h, selection) then
            if hides[i] then
                return nil, "hidden"
            end
            blocks[i] = select_block(h, held, selection, take)
        end
    end
    local text = apply.join(ended, blocks)
    if text == cached.new_text then
        return nil
    end
    return text
end

-- `h`'s lines read as staged, so select_block with `take` false keeps the selected old
-- lines and the new lines left unselected
---@param h differ.Hunk
---@return differ.model.Marks
local function all_held(h)
    local held = { old = {}, new = {} }
    for l = h.old_start, h.old_start + h.old_count - 1 do
        held.old[l] = true
    end
    for l = h.new_start, h.new_start + h.new_count - 1 do
        held.new[l] = true
    end
    return held
end

---@param lines string[]  -- ended lines
---@return string[]
local function unended(lines)
    local out = {}
    for i, line in ipairs(lines) do
        if line:sub(-1) == text_util.NO_EOL then
            line = line:sub(1, -2)
        end
        out[i] = line
    end
    return out
end

-- the worktree with the selected union lines reverted, as a diff from that text to the
-- worktree: one hunk per touched union hunk, its old side the lines the revert leaves
-- there and its new side the worktree's own. nil is a selection that touches no hunk
---@param union differ.DiffModel  -- HEAD↔worktree
---@param selection differ.model.Selection
---@return differ.DiffModel|nil
function M.select_worktree(union, selection)
    local ended = apply.ended(union)
    local blocks, hunks, shift = {}, {}, 0
    for i, h in ipairs(ended.hunks) do
        blocks[i] = h.new_lines
        if touches(h, selection) then
            blocks[i] = select_block(h, all_held(h), selection, false)
            -- the line the block starts on, where a side with no lines names the one before
            local old_start = h.new_start + shift
            if h.new_count == 0 then
                old_start = old_start + 1
            end
            if #blocks[i] == 0 then
                old_start = old_start - 1
            end
            hunks[#hunks + 1] = {
                old_start = old_start,
                old_count = #blocks[i],
                old_lines = unended(blocks[i]),
                new_start = h.new_start,
                new_count = h.new_count,
                new_lines = unended(h.new_lines),
            }
            shift = shift + #blocks[i] - h.new_count
        end
    end
    if #hunks == 0 then
        return nil
    end
    local out = {}
    for k, v in pairs(union) do
        out[k] = v
    end
    out.old_text, out.hunks = apply.join(ended, blocks), hunks
    return out
end

-- the index text with its lines `first`..`last` back to HEAD's, where they sit inside
-- HEAD↔index hunk `ci` and that hunk's two sides are the same length, so each index line
-- has one HEAD line at the same place in it. every other hunk stays applied
---@param cached differ.DiffModel  -- HEAD↔index
---@param ci integer
---@param first integer  -- index lines
---@param last integer
---@return string
function M.drop_lines(cached, ci, first, last)
    local hunks, applied = {}, {} ---@type differ.Hunk[], table<integer, boolean>
    local function slice(lines, from, count)
        local out = {}
        for i = from, from + count - 1 do
            out[#out + 1] = lines[i]
        end
        return out
    end
    for i, h in ipairs(cached.hunks) do
        if i ~= ci then
            hunks[#hunks + 1] = h
            applied[#hunks] = true
        else
            ---@param from integer
            ---@param to integer
            ---@param take boolean
            local function piece(from, to, take)
                if to < from then
                    return
                end
                local at, count = from - h.new_start + 1, to - from + 1
                hunks[#hunks + 1] = {
                    old_start = h.old_start + at - 1,
                    old_count = count,
                    old_lines = slice(h.old_lines, at, count),
                    new_start = from,
                    new_count = count,
                    new_lines = slice(h.new_lines, at, count),
                }
                applied[#hunks] = take
            end
            piece(h.new_start, first - 1, true)
            piece(first, last, false)
            piece(last + 1, h.new_start + h.new_count - 1, true)
        end
    end
    local split = { old_text = cached.old_text, new_text = cached.new_text, hunks = hunks }
    return apply.splice(split --[[@as differ.DiffModel]], applied)
end

return M
