-- what the index should hold after a hunk of a HEAD↔worktree diff is staged or
-- unstaged. the index's lines at each hunk are their slice in the reading the view
-- draws (marks.reading), or its blocks where they cut with nothing hidden.
-- pure lua, no vim API

local apply = require("differ.model.apply")
local marks = require("differ.model.marks")
local text_util = require("differ.util.text")

local M = {}

-- the index's lines at each HEAD↔worktree hunk, and HEAD↔worktree with a last line and
-- its ending read as one (apply.ended). the blocks are nil unless the index holds every
-- unchanged line between the hunks and rejoins to exactly its own text
---@param head_work differ.DiffModel  -- HEAD↔worktree
---@param index string                -- the index's text
---@return string[][]|nil blocks, differ.DiffModel ended
function M.index_blocks(head_work, index)
    local ended = apply.ended(head_work)
    local head_lines, index_lines =
        text_util.ended_lines(head_work.old_text), text_util.ended_lines(index)
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

-- where `hunk` sits in a fresh read of HEAD↔worktree, by its line ranges
---@param head_work differ.DiffModel
---@param hunk differ.Hunk
---@return integer|nil
local function hunk_index(head_work, hunk)
    for i, u in ipairs(head_work.hunks) do
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

-- the side of `h` s (`take`) or u gives the index
---@param h differ.Hunk
---@param take boolean
---@return string[]
local function taken(h, take)
    if take then
        return h.new_lines
    end
    return h.old_lines
end

-- the index with its lines from slice[1] up to slice[2] replaced by `lines`
---@param index string[]  -- ended lines
---@param slice integer[]
---@param lines string[]
---@return string
local function resliced(index, slice, lines)
    local out = {}
    for l = 1, slice[1] - 1 do
        out[#out + 1] = index[l]
    end
    for _, line in ipairs(lines) do
        out[#out + 1] = line
    end
    for l = slice[2], #index do
        out[#out + 1] = index[l]
    end
    return text_util.ended_text(out)
end

-- the index's text with HEAD↔worktree hunk `i`'s lines in the drawn reading replaced by
-- the side the op takes, or nil past the reading
---@param head_work differ.DiffModel
---@param index string  -- the index's text
---@param i integer
---@param take boolean
---@return string|nil
local function by_reading(head_work, index, i, take)
    local read = M.reading(head_work, index)
    if not read then
        return nil
    end
    local h = apply.ended(head_work).hunks[i]
    return resliced(text_util.ended_lines(index), read.slices[i], taken(h, take))
end

-- the index's text with `hunk`'s lines in the drawn reading replaced by the side the
-- op takes: its block where the index cuts into blocks with nothing hidden, else its
-- slice in marks.reading. past the reading, its block, else the pair hunks meeting it
-- on the side that pair shares. `reaches` names another HEAD↔worktree hunk such a pair
-- hunk covers too, and then there is no text
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@param hunk differ.Hunk
---@param take boolean
---@return string|nil text, integer|nil reaches
local function drawn_index(head_work, head_index, index_work, hunk, take)
    local blocks, ended = M.index_blocks(head_work, head_index.new_text)
    local i = hunk_index(head_work, hunk)
    if blocks and i then
        local held, hidden_in = marks.of_blocks(ended.hunks, blocks)
        if not held or #hidden_in > 0 then
            local text = by_reading(head_work, head_index.new_text, i, take)
            if text then
                return text
            end
        end
        blocks[i] = taken(ended.hunks[i], take)
        return apply.join(ended, blocks)
    end
    local from, side = index_work, "new"
    if not take then
        from, side = head_index, "old"
    end
    local reaches = marks.shared_with(head_work.hunks, hunk, from.hunks, side)
    if reaches then
        return nil, reaches
    end
    local text = i and by_reading(head_work, head_index.new_text, i, take)
    if text then
        return text
    end
    return apply.splice(from, M.select_hunks(from.hunks, side, hunk, side, take))
end

-- the text the index takes when `hunk` is staged (`take`) or unstaged, as the view
-- draws it (drawn_index). no text and no `reaches` is a hunk the drawn reading already
-- has where the op puts it, or one the pair the op reads for lines up under a
-- different HEAD↔worktree hunk, leaving the index where it is
---@param head_work differ.DiffModel   -- HEAD↔worktree
---@param head_index differ.DiffModel  -- HEAD↔index
---@param index_work differ.DiffModel  -- index↔worktree
---@param hunk differ.Hunk
---@param take boolean
---@return string|nil text, integer|nil reaches
function M.next_index(head_work, head_index, index_work, hunk, take)
    local text, reaches = drawn_index(head_work, head_index, index_work, hunk, take)
    if reaches then
        return nil, reaches
    end
    if text == head_index.new_text then
        return nil -- the op has nothing of this hunk to move on its own
    end
    return text
end

---@class differ.model.Selection
---@field old table<integer, boolean>  -- HEAD↔worktree old lnums
---@field new table<integer, boolean>  -- HEAD↔worktree new lnums

---@alias differ.model.SelectRefusal
---| "between"  -- a file too big to read, or a selection the drawn marks need moved that the cut has in place
---| "large"    -- a hunk too big to compare against its block
---| "hidden"   -- a selected hunk's block holds a line neither side has
---| "ending"   -- the op would leave a line with no newline above others, its newline change unselected
---| "ending_after"  -- the op would leave a line with no newline above others it didn't select
---| "split_ending"  -- the op would move one line of a line and its newline change without the other
---| "unshown"  -- a line the index holds again where no row shows it: HEAD's moved, or staged with HEAD's deleted

-- whether the selection has `o`, a line of `h`
---@param h differ.Hunk
---@param selection differ.model.Selection
---@param o differ.model.Origin
---@return boolean
local function picked(h, selection, o)
    return selection[o.side][h[o.side .. "_start"] + o.k - 1] == true
end

---@class differ.model.EndingPair
---@field line differ.model.Origin    -- the other side's line with the same text
---@field ending differ.model.Origin  -- the line carrying NO_EOL

-- each line of `h` carrying NO_EOL with the last line of the other side with its
-- text: one line and its newline change
---@param h differ.Hunk  -- an ended hunk
---@return differ.model.EndingPair[]
local function ending_pairs(h)
    local pairs_of = {}
    for _, side in ipairs({ "old", "new" }) do
        local other = "new"
        if side == "new" then
            other = "old"
        end
        local lines = h[side .. "_lines"]
        local last = lines[#lines]
        if last and last:sub(-1) == text_util.NO_EOL then
            local others = h[other .. "_lines"]
            for k = #others, 1, -1 do
                if others[k] == last:sub(1, -2) then
                    pairs_of[#pairs_of + 1] =
                        { line = { side = other, k = k }, ending = { side = side, k = #lines } }
                    break
                end
            end
        end
    end
    return pairs_of
end

---@param a differ.model.Origin
---@param b differ.model.Origin
---@return boolean
local function same(a, b)
    return a.side == b.side and a.k == b.k
end

---@param block differ.model.Origin[]
---@param o differ.model.Origin
---@return boolean
local function holds(block, o)
    for _, b in ipairs(block) do
        if same(b, o) then
            return true
        end
    end
    return false
end

-- whether going from `base` to `block` moves one line of a line and its newline change
-- in or out without the other
---@param h differ.Hunk  -- an ended hunk
---@param base differ.model.Origin[]
---@param block differ.model.Origin[]
---@return boolean
local function splits_ending(h, base, block)
    for _, pair in ipairs(ending_pairs(h)) do
        local line = holds(base, pair.line) ~= holds(block, pair.line)
        local ending = holds(base, pair.ending) ~= holds(block, pair.ending)
        if line ~= ending then
            return true
        end
    end
    return false
end

-- the refusal for `block` holding a line after the NO_EOL line of a line and its
-- newline change: "ending_after" where going from `base` moves that pair
---@param h differ.Hunk  -- an ended hunk
---@param base differ.model.Origin[]
---@param block differ.model.Origin[]
---@return "ending"|"ending_after"|nil
local function ending_inside(h, base, block)
    for _, pair in ipairs(ending_pairs(h)) do
        if holds(block, pair.ending) and not same(block[#block], pair.ending) then
            if holds(base, pair.ending) then
                return "ending"
            end
            return "ending_after"
        end
    end
    return nil
end

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

-- the hunk's lines side by side: sides of the same length row by row, each old line
-- then its new line; otherwise the old lines, then the new
---@param h differ.Hunk
---@return differ.model.Origin[]
local function side_order(h)
    if h.old_count ~= h.new_count then
        local order = marks.whole_side("old", h.old_count)
        for _, o in ipairs(marks.whole_side("new", h.new_count)) do
            order[#order + 1] = o
        end
        return order
    end
    local order = {}
    for k = 1, h.old_count do
        order[#order + 1] = { side = "old", k = k }
        order[#order + 1] = { side = "new", k = k }
    end
    return order
end

---@param order differ.model.Origin[]
---@param o differ.model.Origin
---@return integer
local function place_of(order, o)
    for i, p in ipairs(order) do
        if same(p, o) then
            return i
        end
    end
    error("origin not in order")
end

-- the hunk's lines in the order a block lays out the lines it has no place for yet:
-- side_order's, with a line carrying NO_EOL moved to follow its pair's line and its
-- own side's line before it, whichever comes later
---@param h differ.Hunk  -- an ended hunk
---@return differ.model.Origin[]
local function default_order(h)
    local order = side_order(h)
    for _, pair in ipairs(ending_pairs(h)) do
        local ending = pair.ending
        table.remove(order, place_of(order, ending))
        local after = place_of(order, pair.line)
        if ending.k > 1 then
            after = math.max(after, place_of(order, { side = ending.side, k = ending.k - 1 }))
        end
        table.insert(order, after + 1, ending)
    end
    return order
end

-- where `o` goes in `block`: after the last line of it that comes before `o` in
-- `order`, but ahead of any later line of `o`'s own side
---@param block differ.model.Origin[]
---@param o differ.model.Origin
---@param rank table<string, integer>  -- "side:k" -> place in the default order
---@return integer
local function slot(block, o, rank)
    local after, before = 0, #block + 1
    local own = rank[o.side .. ":" .. o.k]
    for i, b in ipairs(block) do
        if rank[b.side .. ":" .. b.k] < own then
            after = i
        elseif b.side == o.side and before > #block then
            before = i
        end
    end
    return math.min(after, before - 1) + 1
end

-- one hunk's block laid out from `base`: the lines of it `state` doesn't drop stay in
-- its order, and each line `state` brings in goes by slot, in default_order
---@param h differ.Hunk
---@param base differ.model.Origin[]
---@param state fun(o: differ.model.Origin): boolean|nil  -- in or out, nil for as `base` has it
---@return differ.model.Origin[]
local function arrange(h, base, state)
    local out, has = {}, {}
    for _, o in ipairs(base) do
        has[o.side .. ":" .. o.k] = true
        if state(o) ~= false then
            out[#out + 1] = o
        end
    end
    local order, rank = default_order(h), {}
    for i, o in ipairs(order) do
        rank[o.side .. ":" .. o.k] = i
    end
    for _, o in ipairs(order) do
        if not has[o.side .. ":" .. o.k] and state(o) then
            table.insert(out, slot(out, o, rank), o)
        end
    end
    return out
end

---@param h differ.Hunk
---@param origins differ.model.Origin[]
---@return string[]
local function lines_of(h, origins)
    local lines = {}
    for i, o in ipairs(origins) do
        lines[i] = h[o.side .. "_lines"][o.k]
    end
    return lines
end

-- one hunk's index block with the selected lines staged (`take`) or not, laid out
-- from the block the index has
---@param h differ.Hunk  -- an ended hunk
---@param origins differ.model.Origin[]  -- the block the index has, line by line
---@param selection differ.model.Selection
---@param take boolean
---@return differ.model.Origin[]
local function select_block(h, origins, selection, take)
    return arrange(h, origins, function(o)
        if not picked(h, selection, o) then
            return nil
        end
        if o.side == "old" then
            return not take
        end
        return take
    end)
end

-- one hunk's worktree block once X on the selection reverts it: the selected old lines
-- and the unselected new ones, laid out from the index's block where it has one, else
-- from the worktree's
---@param h differ.Hunk
---@param selection differ.model.Selection
---@param index? differ.model.Origin[]  -- the index's block at `h`
---@return differ.model.Origin[]
local function reverted_block(h, selection, index)
    return arrange(h, index or marks.whole_side("new", h.new_count), function(o)
        local selected = picked(h, selection, o)
        if o.side == "old" then
            return selected
        end
        return not selected
    end)
end

-- whether the selection touches any of `hunks`
---@param hunks differ.Hunk[]
---@param selection differ.model.Selection
---@return boolean
local function touches_any(hunks, selection)
    for _, h in ipairs(hunks) do
        if touches(h, selection) then
            return true
        end
    end
    return false
end

---@class differ.model.IndexCut
---@field ended differ.DiffModel  -- HEAD↔worktree, apply.ended
---@field blocks string[][]  -- the index's lines at each HEAD↔worktree hunk
---@field slices? integer[][]  -- each block's {index line, length}, nil for a whole-file cut

-- the index's block at every HEAD↔worktree hunk where the index cuts into blocks, else
-- its slice in the drawn reading (marks.reading). nil for a file too big to read
---@param head_work differ.DiffModel   -- HEAD↔worktree
---@param head_index differ.DiffModel  -- HEAD↔index
---@return differ.model.IndexCut|nil
local function index_cut(head_work, head_index)
    local blocks, ended = M.index_blocks(head_work, head_index.new_text)
    if blocks then
        return { ended = ended, blocks = blocks }
    end
    local read = M.reading(head_work, head_index.new_text)
    if not read then
        return nil
    end
    local index = text_util.ended_lines(head_index.new_text)
    local slices = {}
    blocks = {}
    for i, slice in ipairs(read.slices) do
        local block = {}
        for l = slice[1], slice[2] - 1 do
            block[#block + 1] = index[l]
        end
        blocks[i], slices[i] = block, { slice[1], slice[2] - slice[1] }
    end
    return { ended = ended, blocks = blocks, slices = slices }
end

-- the index's text with the cut's blocks in place
---@param cut differ.model.IndexCut
---@param index string  -- the index's text
---@return string
local function cut_text(cut, index)
    if not cut.slices then
        return apply.join(cut.ended, cut.blocks)
    end
    local lines, out, l = text_util.ended_lines(index), {}, 1
    for i, block in ipairs(cut.blocks) do
        local at, n = cut.slices[i][1], cut.slices[i][2]
        for k = l, at - 1 do
            out[#out + 1] = lines[k]
        end
        for _, line in ipairs(block) do
            out[#out + 1] = line
        end
        l = at + n
    end
    for k = l, #lines do
        out[#out + 1] = lines[k]
    end
    return text_util.ended_text(out)
end

-- the index's block at each HEAD↔worktree hunk index_cut places, line by line; none for a
-- hunk whose block holds a line neither side has
---@param head_work differ.DiffModel   -- HEAD↔worktree
---@param head_index differ.DiffModel  -- HEAD↔index
---@return table<integer, differ.model.Origin[]>|nil
function M.index_origins(head_work, head_index)
    local cut = index_cut(head_work, head_index)
    if not cut then
        return nil
    end
    local _, hidden, origins = marks.of_blocks(cut.ended.hunks, cut.blocks)
    for _, i in ipairs(hidden) do
        origins[i] = nil
    end
    return origins --[[@as table<integer, differ.model.Origin[]>]]
end

-- the text the index takes when the selected HEAD↔worktree lines are staged (`take`) or
-- unstaged. only the hunks the selection touches are rebuilt; every other line stays
-- as the index has it. nil text with no refusal is a selection with nothing to move
---@param head_work differ.DiffModel   -- HEAD↔worktree
---@param head_index differ.DiffModel  -- HEAD↔index
---@param selection differ.model.Selection
---@param take boolean
---@return string|nil text, differ.model.SelectRefusal|nil refusal
function M.select_index(head_work, head_index, selection, take)
    local cut = index_cut(head_work, head_index)
    if not cut then
        if touches_any(head_work.hunks, selection) then
            return nil, "between"
        end
        return nil
    end
    local held, hidden, origins = marks.of_blocks(cut.ended.hunks, cut.blocks)
    if not held then
        return nil, "large"
    end
    local hides = {} ---@type table<integer, boolean>
    for _, i in ipairs(hidden) do
        hides[i] = true
    end
    local split = false
    local inside ---@type "ending"|"ending_after"|nil
    for i, h in ipairs(cut.ended.hunks) do
        if touches(h, selection) then
            if hides[i] then
                return nil, "hidden"
            end
            -- a hunk with nothing hidden has an origin for every block line
            local base = origins[i] --[[@as differ.model.Origin[] ]]
            local block = select_block(h, base, selection, take)
            split = split or splits_ending(h, base, block)
            inside = inside or ending_inside(h, base, block)
            cut.blocks[i] = lines_of(h, block)
        end
    end
    if split then
        return nil, "split_ending"
    end
    if inside then
        return nil, inside
    end
    local text = cut_text(cut, head_index.new_text)
    if text == head_index.new_text then
        return nil
    end
    return text
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

-- the worktree with the selected HEAD↔worktree lines reverted, as a diff from that text
-- to the worktree: one hunk per touched HEAD↔worktree hunk, its old side the lines the
-- revert leaves there and its new side the worktree's own. nil and why where it refuses;
-- nil alone is a selection that touches no hunk
---@param head_work differ.DiffModel  -- HEAD↔worktree
---@param selection differ.model.Selection
---@param origins? table<integer, differ.model.Origin[]>  -- index_origins
---@return differ.DiffModel|nil reverted, "ending"|"ending_after"|"split_ending"|nil refusal
function M.select_worktree(head_work, selection, origins)
    local ended = apply.ended(head_work)
    local blocks, hunks, shift = {}, {}, 0
    for i, h in ipairs(ended.hunks) do
        blocks[i] = h.new_lines
        if touches(h, selection) then
            local block = reverted_block(h, selection, origins and origins[i])
            local base = marks.whole_side("new", h.new_count)
            if splits_ending(h, base, block) then
                return nil, "split_ending"
            end
            local inside = ending_inside(h, base, block)
            if inside then
                return nil, inside
            end
            blocks[i] = lines_of(h, block)
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
    for k, v in pairs(head_work) do
        out[k] = v
    end
    out.old_text, out.hunks = apply.join(ended, blocks), hunks
    return out
end

-- the index text with its lines `first`..`last` back to HEAD's, where they sit inside
-- HEAD↔index hunk `ci` and that hunk's two sides are the same length, so each index line
-- has one HEAD line at the same place in it. every other hunk stays applied
---@param head_index differ.DiffModel  -- HEAD↔index
---@param ci integer
---@param first integer                -- index lines
---@param last integer
---@return string
function M.drop_lines(head_index, ci, first, last)
    local hunks, applied = {}, {} ---@type differ.Hunk[], table<integer, boolean>
    local function slice(lines, from, count)
        local out = {}
        for i = from, from + count - 1 do
            out[#out + 1] = lines[i]
        end
        return out
    end
    for i, h in ipairs(head_index.hunks) do
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
    local split = { old_text = head_index.old_text, new_text = head_index.new_text, hunks = hunks }
    return apply.splice(split --[[@as differ.DiffModel]], applied)
end

-- the index read against HEAD↔worktree's rows at the least cost (marks.reading), or nil
-- for a file too big to read that way
---@param head_work differ.DiffModel
---@param index string  -- the index's text
---@param doubt? boolean  -- also find doubt_in
---@return differ.model.Reading|nil
function M.reading(head_work, index, doubt)
    local ended = apply.ended(head_work)
    local head_lines, index_lines =
        text_util.ended_lines(head_work.old_text), text_util.ended_lines(index)
    return marks.reading(ended.hunks, head_lines, index_lines, doubt)
end

---@param a integer[]
---@param b integer[]
---@return integer[]  -- the hunks in either, ascending
local function merged(a, b)
    local seen, out = {}, {}
    for _, list in ipairs({ a, b }) do
        for _, i in ipairs(list) do
            if not seen[i] then
                seen[i] = true
                out[#out + 1] = i
            end
        end
    end
    table.sort(out)
    return out
end

-- the marks the view draws for HEAD↔worktree: the least-cost reading of the index
-- (marks.reading), or its blocks where they cut with nothing hidden, which read the
-- same. `hidden` is index content no hunk shows, and `hidden_in` the hunks holding some
-- of it, or that a reading of the same cost puts it in or stages other lines in, or
-- nearest each side of what it hides outside every hunk. `unread` is a file too big to
-- read, drawn from its blocks or the two pairs
---@param head_work differ.DiffModel   -- HEAD↔worktree
---@param head_index differ.DiffModel  -- HEAD↔index
---@param index_work differ.DiffModel  -- index↔worktree
---@return differ.model.Marks marks, boolean hidden, integer[] hidden_in, boolean unread
function M.marks_of(head_work, head_index, index_work)
    local blocks, ended = M.index_blocks(head_work, head_index.new_text)
    local held, hidden_in = nil, {}
    if blocks then
        held, hidden_in = marks.of_blocks(ended.hunks, blocks)
        if held and #hidden_in == 0 then
            return held, false, hidden_in, false
        end
    end
    local read = M.reading(head_work, head_index.new_text, true)
    if read then
        local shown = merged(read.hidden_in, merged(read.doubt_in or {}, read.unowned_in or {}))
        return read.marks, read.cost > 0, shown, false
    end
    if held then
        return held, true, hidden_in, true
    end
    held = marks.classify(head_work.hunks, head_index.hunks, index_work.hunks)
    if marks.complete(head_work.hunks, head_index.hunks, index_work.hunks) then
        return held, false, {}, true
    end
    local head = text_util.to_lines(head_work.old_text)
    return held, true, marks.hidden_in(head, head_work.hunks, head_index.hunks, held), true
end

---@class differ.model.LineStates
---@field old table<integer, boolean>  -- every changed HEAD↔worktree old line, staged or not
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
---@param head_work differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean
---@return differ.model.LineStates
function M.flipped(head_work, m, selection, take)
    local want = line_states(head_work.hunks, m)
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
---@param head_work differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param origins? table<integer, differ.model.Origin[]>  -- as select_worktree takes them
---@return differ.model.LineStates
function M.reverted(head_work, m, selection, origins)
    local want = { old = {}, new = {}, enter = 0, leave = 0, work_enter = 0, work_leave = 0 }
    local shift = 0
    for i, h in ipairs(apply.ended(head_work).hunks) do
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
            local at = h.new_start + shift
            if h.new_count == 0 then
                at = at + 1
            end
            local block = reverted_block(h, selection, origins and origins[i])
            for p, o in ipairs(block) do
                if o.side == "new" then
                    want.new[at + p - 1] = m.new[h.new_start + o.k - 1] == true
                end
            end
            shift = shift + #block - h.new_count
        end
    end
    return want
end

-- whether two sides mark the same lines, counted per run of identical adjacent lines (a
-- diff may mark any one of them), or per text anywhere on the side (`by_text`)
---@param a table<integer, boolean>
---@param b table<integer, boolean>
---@param lines string[]  -- that side's ended lines
---@param by_text boolean
---@return boolean
local function same_side(a, b, lines, by_text)
    -- run start or text -> marked lines and staged lines, a's less b's
    local runs = {} ---@type table<integer|string, { marked: integer, staged: integer }>
    local function count(side, sign)
        for l, staged in pairs(side) do
            local first = l
            while first > 1 and lines[first - 1] == lines[l] do
                first = first - 1
            end
            local key = first ---@type integer|string
            if by_text then
                key = lines[l]
            end
            local run = runs[key] or { marked = 0, staged = 0 }
            run.marked = run.marked + sign
            if staged then
                run.staged = run.staged + sign
            end
            runs[key] = run
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

-- the span of the drawn slices of the hunks the selection touches, {first, after} index
-- lines, and how many lines in them no row of their hunk holds. first > after where
-- the selection touches no hunk
---@param read differ.model.Reading
---@param head_work differ.DiffModel
---@param selection differ.model.Selection
---@return integer first, integer after, integer hidden
local function touched_slices(read, head_work, selection)
    local first, after, hidden = math.huge, -math.huge, 0
    for i, h in ipairs(head_work.hunks) do
        if touches(h, selection) then
            local slice = read.slices[i]
            first, after = math.min(first, slice[1]), math.max(after, slice[2])
            hidden = hidden + slice[2] - slice[1]
            for l = h.old_start, h.old_start + h.old_count - 1 do
                if read.marks.old[l] == false then
                    hidden = hidden - 1
                end
            end
            for l = h.new_start, h.new_start + h.new_count - 1 do
                if read.marks.new[l] == true then
                    hidden = hidden - 1
                end
            end
        end
    end
    return first, after, hidden
end

-- whether `to` holds the lines of `from` before index line `first` and from `after` on,
-- unchanged
---@param from string[]
---@param to string[]
---@param first integer
---@param after integer
---@return boolean
local function outside_kept(from, to, first, after)
    if first > after then
        first, after = #from + 1, #from + 1
    end
    local tail = #from - after + 1
    if #to < first - 1 + tail then
        return false
    end
    for l = 1, first - 1 do
        if from[l] ~= to[l] then
            return false
        end
    end
    for d = 0, tail - 1 do
        if from[#from - d] ~= to[#to - d] then
            return false
        end
    end
    return true
end

-- the hidden lines in the drawn slices the selection touches, which the op drops, where
-- it leaves the index outside those slices as it was and the reading after it hides
-- exactly the rest. nil otherwise, or past either reading
---@param before differ.model.Before
---@param selection differ.model.Selection
---@param head_work differ.DiffModel   -- read from the op's texts
---@param head_index differ.DiffModel
---@return integer|nil
local function hidden_dropped(before, selection, head_work, head_index)
    local read = M.reading(before.head_work, before.head_index.new_text)
    local now = M.reading(head_work, head_index.new_text)
    if not (read and now) then
        return nil
    end
    local first, after, hidden = touched_slices(read, before.head_work, selection)
    if now.cost ~= read.cost - hidden then
        return nil
    end
    local from = text_util.ended_lines(before.head_index.new_text)
    if not outside_kept(from, text_util.ended_lines(head_index.new_text), first, after) then
        return nil
    end
    return hidden
end

---@param h differ.Hunk
---@return integer first, integer last  -- the old lines either side of `h`'s
local function old_beside(h)
    if h.old_count == 0 then
        return h.old_start, h.old_start + 1
    end
    return h.old_start - 1, h.old_start + h.old_count
end

-- the marked lines of `h` on one side, in order
---@param side table<integer, boolean>
---@param start integer
---@param count integer
---@return integer[]
local function marked(side, start, count)
    local out = {}
    for l = start, start + count - 1 do
        if side[l] ~= nil then
            out[#out + 1] = l
        end
    end
    return out
end

-- pairs what's left in `out` of `a` with a line of `b` on the other side of the
-- unchanged lines between them, where those lines all have its text
---@param out differ.model.LineStates
---@param a differ.Hunk
---@param b differ.Hunk
---@param old_lines string[]
---@param new_lines string[]
local function pair_across(out, a, b, old_lines, new_lines)
    local _, from = old_beside(a)
    local to = old_beside(b)
    ---@param x_side table<integer, boolean>
    ---@param xs integer[]
    ---@param x_lines string[]
    ---@param y_side table<integer, boolean>
    ---@param ys integer[]
    ---@param y_lines string[]
    local function pair(x_side, xs, x_lines, y_side, ys, y_lines)
        for _, x in ipairs(xs) do
            local through = x_side[x] ~= nil
            for l = from, to do
                through = through and old_lines[l] == x_lines[x]
            end
            for _, y in ipairs(ys) do
                if through and y_side[y] == x_side[x] and y_lines[y] == x_lines[x] then
                    x_side[x], y_side[y] = nil, nil
                    break
                end
            end
        end
    end
    pair(
        out.old,
        marked(out.old, a.old_start, a.old_count),
        old_lines,
        out.new,
        marked(out.new, b.new_start, b.new_count),
        new_lines
    )
    pair(
        out.new,
        marked(out.new, a.new_start, a.new_count),
        new_lines,
        out.old,
        marked(out.old, b.old_start, b.old_count),
        old_lines
    )
end

-- `states` less each old line and a new line of the same hunk with the same text and
-- state, or of neighbouring hunks with only lines of that text between them: together
-- they put that line in the index once, as an unchanged line does
---@param states differ.model.LineStates
---@param hunks differ.Hunk[]
---@param old_lines string[]
---@param new_lines string[]
---@return differ.model.LineStates
local function paired_out(states, hunks, old_lines, new_lines)
    local out = { old = {}, new = {} }
    for l, v in pairs(states.old) do
        out.old[l] = v
    end
    for l, v in pairs(states.new) do
        out.new[l] = v
    end
    for _, h in ipairs(hunks) do
        for o = h.old_start, h.old_start + h.old_count - 1 do
            for n = h.new_start, h.new_start + h.new_count - 1 do
                if
                    out.old[o] ~= nil
                    and out.new[n] == out.old[o]
                    and old_lines[o] == new_lines[n]
                then
                    out.old[o], out.new[n] = nil, nil
                    break
                end
            end
        end
    end
    for i = 2, #hunks do
        pair_across(out, hunks[i - 1], hunks[i], old_lines, new_lines)
    end
    return out
end

-- whether a minimal diff from `from` to `to` drops at most `leave` lines and adds at most
-- `enter`, changing the length by as much. HEAD↔worktree's own pairing may take more
-- lines than a minimal one, never fewer
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

-- whether the index cuts into blocks with nothing hidden, so its marks come from the
-- blocks rather than a reading (marks_of)
---@param head_work differ.DiffModel
---@param index string
---@return boolean
local function cuts_clean(head_work, index)
    local blocks, ended = M.index_blocks(head_work, index)
    if not blocks then
        return false
    end
    local held, hidden_in = marks.of_blocks(ended.hunks, blocks)
    return held ~= nil and #hidden_in == 0
end

-- whether `to` lies on a shortest edit path from `from` to `towards`, by minimal diffs.
-- the HEAD↔worktree diff pairs by histogram, so a write the drawn rows place exactly
-- can still fall off this path
---@param edits fun(a: string, b: string): integer, integer
---@param towards string
---@param from string
---@param to string
---@return boolean
local function straight(edits, towards, from, to)
    local function distance(a, b)
        local dropped, added = edits(a, b)
        return dropped + added
    end
    return distance(towards, to) + distance(to, from) == distance(towards, from)
end

---@param text string
---@return table<string, integer>
local function counts(text)
    local n = {}
    for _, line in ipairs(text_util.to_lines(text)) do
        n[line] = (n[line] or 0) + 1
    end
    return n
end

-- HEAD↔worktree's old and new lines outside `selection`, counted per line
---@param head_work differ.DiffModel
---@param selection differ.model.Selection
---@return table<string, integer> old, table<string, integer> new
local function unselected(head_work, selection)
    local old_lines, new_lines =
        text_util.to_lines(head_work.old_text), text_util.to_lines(head_work.new_text)
    local old, new = {}, {}
    for _, h in ipairs(head_work.hunks) do
        for l = h.old_start, h.old_start + h.old_count - 1 do
            if not selection.old[l] then
                old[old_lines[l]] = (old[old_lines[l]] or 0) + 1
            end
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            if not selection.new[l] then
                new[new_lines[l]] = (new[new_lines[l]] or 0) + 1
            end
        end
    end
    return old, new
end

-- whether every line's count in `to` stays where `from` has it or within `towards`'s
-- count less its `below` rows and plus its `above` rows. a line and its ending count as
-- one
---@param towards string
---@param from string
---@param to string
---@param below table<string, integer>
---@param above table<string, integer>
---@return boolean
local function counts_within(towards, from, to, below, above)
    local target, old, new = counts(towards), counts(from), counts(to)
    for _, side in ipairs({ target, old, new }) do
        for line in pairs(side) do
            local t, o, n = target[line] or 0, old[line] or 0, new[line] or 0
            local low = math.min(o, t - (below[line] or 0))
            local high = math.max(o, t + (above[line] or 0))
            if n < low or n > high then
                return false
            end
        end
    end
    return true
end

-- whether `seg` is `a` and `b` merged, each kept in its own order
---@param a string[]
---@param b string[]
---@param seg string[]
---@return boolean
local function interleaves(a, b, seg)
    if #a + #b ~= #seg then
        return false
    end
    -- ok[i][j]: a's first i lines and b's first j make seg's first i + j
    local ok = {} ---@type table<integer, table<integer, boolean>>
    for i = 0, #a do
        ok[i] = {}
        for j = 0, #b do
            local k = i + j
            if k == 0 then
                ok[i][j] = true
            else
                local from_a = i > 0 and ok[i - 1][j] and a[i] == seg[k]
                local from_b = j > 0 and ok[i][j - 1] and b[j] == seg[k]
                ok[i][j] = from_a or from_b
            end
        end
    end
    return ok[#a][#b]
end

-- whether HEAD, the index and the worktree hold exactly what `want` marks, whichever
-- lines a diff of them would mark: HEAD less its marked lines is the worktree less its
-- marked lines, and between each pair of those unchanged lines the index holds that
-- gap's unstaged old lines and staged new lines
---@param want differ.model.LineStates
---@param head_work differ.DiffModel  -- HEAD against the worktree
---@param index string
---@return boolean
local function holds_as(want, head_work, index)
    local head = text_util.ended_lines(head_work.old_text)
    local work = text_util.ended_lines(head_work.new_text)
    local held = text_util.ended_lines(index)
    local h, w, i = 1, 1, 1
    while true do
        local kept, added = {}, {}
        while want.old[h] ~= nil do
            if not want.old[h] then
                kept[#kept + 1] = head[h]
            end
            h = h + 1
        end
        while want.new[w] ~= nil do
            if want.new[w] then
                added[#added + 1] = work[w]
            end
            w = w + 1
        end
        local n = #kept + #added
        if not interleaves(kept, added, { unpack(held, i, i + n - 1) }) then
            return false
        end
        i = i + n
        if h > #head or w > #work then
            return h > #head and w > #work and i > #held
        end
        if head[h] ~= work[w] or held[i] ~= head[h] then
            return false
        end
        h, w, i = h + 1, w + 1, i + 1
    end
end

---@class differ.model.Before
---@field head_work differ.DiffModel
---@field head_index differ.DiffModel
---@field hidden boolean
---@field edits fun(a: string, b: string): integer, integer  -- lines a minimal diff drops, adds
---@field take boolean  -- s, which moves the index towards the worktree; u and X move it towards HEAD

-- whether the pairs an op's texts make read back as `want`, the marks counted per text
-- for s and u on an index with nothing hidden, else per run (same_side). a minimal diff
-- from each old text to its new one stays within the lines the op moves (moves_only), so
-- nothing else changes place. each line's count ends off the side the op takes by no
-- more than the unselected rows of that line, or stays put (counts_within). where a reading places
-- the index, it also moves straight towards the side the op takes (straight). where the
-- index holds content no hunk shows, the op also drops the hidden lines in the drawn
-- slices it touches, and nothing else of it (hidden_dropped). for X from an index with
-- nothing hidden, a read-back that marks other lines or hides content still passes where
-- the texts hold exactly what `want` marks (holds_as)
---@param want differ.model.LineStates
---@param before differ.model.Before
---@param selection differ.model.Selection
---@param head_work differ.DiffModel     -- read from the op's texts
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@return boolean, "unshown"|nil
function M.reads_as(want, before, selection, head_work, head_index, index_work)
    local m, hidden = M.marks_of(head_work, head_index, index_work)
    local dropped = 0 ---@type integer|nil
    if before.hidden then
        dropped = hidden_dropped(before, selection, head_work, head_index)
        if not dropped then
            return false
        end
    end
    local old_lines = text_util.ended_lines(head_work.old_text)
    local new_lines = text_util.ended_lines(head_work.new_text)
    local got = paired_out(line_states(head_work.hunks, m), head_work.hunks, old_lines, new_lines)
    local expect = paired_out(want, head_work.hunks, old_lines, new_lines)
    local by_text = not (want.work_enter or before.hidden)
    local hides_more = hidden and not before.hidden
    local drawn_as = not hides_more
        and same_side(got.old, expect.old, old_lines, by_text)
        and same_side(got.new, expect.new, new_lines, by_text)
    local holds_applies = want.work_enter ~= nil and not before.hidden
    if not drawn_as and not (holds_applies and holds_as(want, head_work, head_index.new_text)) then
        return false
    end
    local index_from, index_to = before.head_index.new_text, head_index.new_text
    if not moves_only(before.edits, index_from, index_to, want.leave + dropped, want.enter) then
        return false
    end
    local old_out, new_out = unselected(before.head_work, selection)
    local towards, below, above = before.head_work.old_text, old_out, new_out
    if before.take then
        towards, below, above = before.head_work.new_text, new_out, old_out
    end
    if not counts_within(towards, index_from, index_to, below, above) then
        return false, "unshown"
    end
    if not cuts_clean(before.head_work, index_from) then
        if not straight(before.edits, towards, index_from, index_to) then
            return false
        end
    end
    local work_from, work_to = before.head_work.new_text, head_work.new_text
    if
        want.work_enter
        and not moves_only(before.edits, work_from, work_to, want.work_leave, want.work_enter)
    then
        return false
    end
    if
        want.work_enter
        and not counts_within(before.head_work.old_text, work_from, work_to, old_out, new_out)
    then
        return false, "unshown"
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
        not same_side(got.old, want.old, old_lines, false)
        or not same_side(got.new, want.new, new_lines, false)
    then
        return false
    end
    return moves_only(edits, work, after.new_text, want.work_leave, want.work_enter)
end

return M
