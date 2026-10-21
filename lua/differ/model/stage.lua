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
local function hunk_index(union, hunk)
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
    local i = hunk_index(union, hunk)
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

-- whether a HEAD↔index hunk meets a union hunk the selection touches
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param selection differ.model.Selection
---@return boolean
local function index_meets(union, cached, selection)
    for _, h in ipairs(union.hunks) do
        if touches(h, selection) then
            for _, c in ipairs(cached.hunks) do
                if marks.meets(c, "old", h, "old") then
                    return true
                end
            end
        end
    end
    return false
end

-- the index with the selection staged at each touched hunk, where the index still holds
-- the hunk's HEAD lines: HEAD's position shifted by the HEAD↔index hunks above it. nil
-- when the index doesn't hold those lines there
---@param ended differ.DiffModel  -- the union, apply.ended
---@param cached differ.DiffModel
---@param selection differ.model.Selection
---@return string|nil
local function place_selection(ended, cached, selection)
    local index = text_util.ended_lines(cached.new_text)
    local none = { old = {}, new = {} }
    for i = #ended.hunks, 1, -1 do
        local h = ended.hunks[i]
        if touches(h, selection) then
            local first = h.old_start
            if h.old_count == 0 then
                first = first + 1
            end
            for _, c in ipairs(cached.hunks) do
                if c.old_start < h.old_start then
                    first = first + c.new_count - c.old_count
                end
            end
            for k, line in ipairs(h.old_lines) do
                if index[first + k - 1] ~= line then
                    return nil
                end
            end
            local out = {}
            for l = 1, first - 1 do
                out[#out + 1] = index[l]
            end
            for _, line in ipairs(select_block(h, none, selection, true)) do
                out[#out + 1] = line
            end
            for l = first + h.old_count, #index do
                out[#out + 1] = index[l]
            end
            index = out
        end
    end
    return text_util.ended_text(index)
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
        if index_meets(ended, cached, selection) then
            return nil, "between"
        end
        -- the index has HEAD's lines at every selected hunk, so nothing to unstage
        if not take then
            return nil
        end
        local text = place_selection(ended, cached, selection)
        if not text then
            return nil, "between"
        end
        if text == cached.new_text then
            return nil
        end
        return text
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

-- the marks the view draws for the union: the index's block at each hunk, or the two
-- pairs where the index can't be cut. `hidden` is index content no hunk shows, and
-- `hidden_in` the hunks holding some of it
---@param union differ.DiffModel     -- HEAD↔worktree
---@param cached differ.DiffModel    -- HEAD↔index
---@param unstaged differ.DiffModel  -- index↔worktree
---@return differ.model.Marks marks, boolean hidden, integer[] hidden_in
function M.marks_of(union, cached, unstaged)
    local blocks, ended = M.index_blocks(union, cached.new_text)
    if blocks then
        local held, hidden_in = marks.of_blocks(ended.hunks, blocks)
        if held then
            return held, #hidden_in > 0, hidden_in
        end
    end
    local fresh = marks.classify(union.hunks, cached.hunks, unstaged.hunks)
    if marks.complete(union.hunks, cached.hunks, unstaged.hunks) then
        return fresh, false, {}
    end
    local head = text_util.to_lines(union.old_text)
    return fresh, true, marks.hidden_in(head, union.hunks, cached.hunks, fresh)
end

---@class differ.model.LineStates
---@field old table<integer, boolean>  -- every changed union old line, staged or not
---@field new table<integer, boolean>
---@field enter integer  -- lines the op brings into the index
---@field leave integer  -- lines it takes out
---@field work_enter? integer  -- X: lines it brings back into the file
---@field work_leave? integer  -- X: lines it takes out of the file

---@param hunks differ.Hunk[]
---@param m differ.model.Marks
---@return differ.model.LineStates
local function line_states(hunks, m)
    local out = { old = {}, new = {}, enter = 0, leave = 0 }
    for _, h in ipairs(hunks) do
        for l = h.old_start, h.old_start + h.old_count - 1 do
            out.old[l] = m.old[l] == true
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            out.new[l] = m.new[l] == true
        end
    end
    return out
end

-- what s (`take`) or u on `selection` should leave: the selected lines in the op's
-- state, every other line as `m` has it
---@param union differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean
---@return differ.model.LineStates
function M.flipped(union, m, selection, take)
    local want = line_states(union.hunks, m)
    -- an old line is in the index unless staged, a new line only when staged
    for l in pairs(selection.old) do
        if want.old[l] ~= nil and want.old[l] ~= take then
            if take then
                want.leave = want.leave + 1
            else
                want.enter = want.enter + 1
            end
            want.old[l] = take
        end
    end
    for l in pairs(selection.new) do
        if want.new[l] ~= nil and want.new[l] ~= take then
            if take then
                want.enter = want.enter + 1
            else
                want.leave = want.leave + 1
            end
            want.new[l] = take
        end
    end
    return want
end

-- every line of `hunk`, as a selection
---@param hunk differ.Hunk
---@return differ.model.Selection
function M.hunk_selection(hunk)
    local selection = { old = {}, new = {} }
    for l = hunk.old_start, hunk.old_start + hunk.old_count - 1 do
        selection.old[l] = true
    end
    for l = hunk.new_start, hunk.new_start + hunk.new_count - 1 do
        selection.new[l] = true
    end
    return selection
end

-- what X on `selection` should leave: the selected lines gone and every other line as
-- `m` has it, its new side placed where select_worktree's text puts it
---@param union differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@return differ.model.LineStates
function M.reverted(union, m, selection)
    local want = { old = {}, new = {}, enter = 0, leave = 0, work_enter = 0, work_leave = 0 }
    local shift = 0
    for _, h in ipairs(union.hunks) do
        -- the index takes back a selected old line it had staged away, and drops a
        -- selected new line it had staged
        for l = h.old_start, h.old_start + h.old_count - 1 do
            if not selection.old[l] then
                want.old[l] = m.old[l] == true
            else
                want.work_enter = want.work_enter + 1
                if m.old[l] == true then
                    want.enter = want.enter + 1
                end
            end
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            if selection.new[l] then
                want.work_leave = want.work_leave + 1
                if m.new[l] == true then
                    want.leave = want.leave + 1
                end
            end
        end
        if not touches(h, selection) then
            for l = h.new_start, h.new_start + h.new_count - 1 do
                want.new[l + shift] = m.new[l] == true
            end
        else
            -- select_block's order with every line held: a selected old line comes
            -- back, an unselected new line stays
            local at = h.new_start + shift
            if h.new_count == 0 then
                at = at + 1
            end
            local kept = 0
            local function old_line(k)
                if selection.old[h.old_start + k - 1] then
                    kept = kept + 1
                end
            end
            local function new_line(k)
                local l = h.new_start + k - 1
                if not selection.new[l] then
                    want.new[at + kept] = m.new[l] == true
                    kept = kept + 1
                end
            end
            if h.old_count == h.new_count then
                for k = 1, h.old_count do
                    old_line(k)
                    new_line(k)
                end
            else
                for k = 1, h.old_count do
                    old_line(k)
                end
                for k = 1, h.new_count do
                    new_line(k)
                end
            end
            shift = shift + kept - h.new_count
        end
    end
    return want
end

-- whether two sides mark the same lines, counted per run of identical adjacent lines: a
-- diff may mark any one of them
---@param a table<integer, boolean>
---@param b table<integer, boolean>
---@param lines string[]  -- that side's ended lines
---@return boolean
local function same_side(a, b, lines)
    -- run start -> marked lines and staged lines, a's less b's
    local runs = {} ---@type table<integer, { marked: integer, staged: integer }>
    local function count(side, sign)
        for l, staged in pairs(side) do
            local first = l
            while first > 1 and lines[first - 1] == lines[l] do
                first = first - 1
            end
            local run = runs[first] or { marked = 0, staged = 0 }
            run.marked = run.marked + sign
            if staged then
                run.staged = run.staged + sign
            end
            runs[first] = run
        end
    end
    count(a, 1)
    count(b, -1)
    for _, run in pairs(runs) do
        if run.marked ~= 0 or run.staged ~= 0 then
            return false
        end
    end
    return true
end

-- the HEAD↔index hunks clear of every union hunk the selection touches, by place and
-- text
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param selection differ.model.Selection
---@return table<string, boolean>
local function index_elsewhere(union, cached, selection)
    local out = {}
    for _, c in ipairs(cached.hunks) do
        local clear = true
        for _, h in ipairs(union.hunks) do
            if touches(h, selection) and marks.meets(c, "old", h, "old") then
                clear = false
            end
        end
        if clear then
            local key = ("%d,%d:%s"):format(
                c.old_start,
                c.old_count,
                table.concat(c.new_lines, "\n")
            )
            out[key] = true
        end
    end
    return out
end

-- whether a minimal diff from `from` to `to` drops at most `leave` lines and adds at most
-- `enter`, changing the length by as much. the union's own pairing may take more lines
-- than a minimal one, never fewer
---@param edits fun(a: string, b: string): integer, integer
---@param from string
---@param to string
---@param leave integer
---@param enter integer
---@return boolean
local function moves_only(edits, from, to, leave, enter)
    local dropped, added = edits(from, to)
    return dropped <= leave and added <= enter and added - dropped == enter - leave
end

---@class differ.model.Before
---@field union differ.DiffModel
---@field cached differ.DiffModel
---@field hidden boolean
---@field edits fun(a: string, b: string): integer, integer  -- lines a minimal diff drops, adds

-- whether the pairs an op's texts make read back as `want`. a minimal diff from each old
-- text to its new one stays within the lines the op moves (moves_only), so nothing else
-- changes place. index content no hunk shows stays exactly as it was, so where there is
-- some, the HEAD↔index hunks away from the selection come through unchanged
---@param want differ.model.LineStates
---@param before differ.model.Before
---@param selection differ.model.Selection
---@param union differ.DiffModel     -- read from the op's texts
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@return boolean
function M.reads_as(want, before, selection, union, cached, unstaged)
    local m, hidden = M.marks_of(union, cached, unstaged)
    if hidden ~= before.hidden then
        return false
    end
    local got = line_states(union.hunks, m)
    local old_lines = text_util.ended_lines(union.old_text)
    local new_lines = text_util.ended_lines(union.new_text)
    if
        not same_side(got.old, want.old, old_lines) or not same_side(got.new, want.new, new_lines)
    then
        return false
    end
    if
        not moves_only(
            before.edits,
            before.cached.new_text,
            cached.new_text,
            want.leave,
            want.enter
        )
    then
        return false
    end
    local work_from, work_to = before.union.new_text, union.new_text
    if
        want.work_enter
        and not moves_only(before.edits, work_from, work_to, want.work_leave, want.work_enter)
    then
        return false
    end
    if not hidden then
        return true
    end
    local kept = index_elsewhere(before.union, before.cached, selection)
    local now = index_elsewhere(before.union, cached, selection)
    for key in pairs(kept) do
        if not now[key] then
            return false
        end
    end
    for key in pairs(now) do
        if not kept[key] then
            return false
        end
    end
    return true
end

-- whether X's file text for a view that only moves the file reads back as `want`: the
-- unselected lines where reverted() puts them, and a minimal diff from the old file
-- that stays within the selected lines
---@param want differ.model.LineStates  -- reverted() with no line staged
---@param work string                   -- the file before
---@param after differ.DiffModel        -- the view's old side against the file after
---@param edits fun(a: string, b: string): integer, integer
---@return boolean
function M.file_reads_as(want, work, after, edits)
    local got = line_states(after.hunks, { old = {}, new = {} })
    local old_lines = text_util.ended_lines(after.old_text)
    local new_lines = text_util.ended_lines(after.new_text)
    if
        not same_side(got.old, want.old, old_lines) or not same_side(got.new, want.new, new_lines)
    then
        return false
    end
    return moves_only(edits, work, after.new_text, want.work_leave, want.work_enter)
end

return M
