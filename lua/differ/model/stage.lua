-- what the index should hold after a hunk of a HEAD↔worktree diff is staged or
-- unstaged. the index's lines at each hunk are their slice in the reading the view
-- draws (marks.reading), or its blocks where they cut with nothing hidden.
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

-- the index's text with union hunk `i`'s lines in the drawn reading replaced by the
-- side the op takes, or nil past the reading
---@param union differ.DiffModel
---@param index string  -- the index's text
---@param i integer
---@param take boolean
---@return string|nil
local function by_reading(union, index, i, take)
    local read = M.reading(union, index)
    if not read then
        return nil
    end
    local h = apply.ended(union).hunks[i]
    return resliced(text_util.ended_lines(index), read.slices[i], taken(h, take))
end

-- the index's text with `hunk`'s lines in the drawn reading replaced by the side the
-- op takes: its block where the index cuts into blocks with nothing hidden, else its
-- slice in marks.reading. past the reading, its block, else the pair hunks meeting it
-- on the side that pair shares. `reaches` names another union hunk such a pair hunk
-- covers too, and then there is no text
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@param hunk differ.Hunk
---@param take boolean
---@return string|nil text, integer|nil reaches
local function drawn_index(union, cached, unstaged, hunk, take)
    local blocks, ended = M.index_blocks(union, cached.new_text)
    local i = hunk_index(union, hunk)
    if blocks and i then
        local held, hidden_in = marks.of_blocks(ended.hunks, blocks)
        if not held or #hidden_in > 0 then
            local text = by_reading(union, cached.new_text, i, take)
            if text then
                return text
            end
        end
        blocks[i] = taken(ended.hunks[i], take)
        return apply.join(ended, blocks)
    end
    local from, side = unstaged, "new"
    if not take then
        from, side = cached, "old"
    end
    local reaches = marks.shared_with(union.hunks, hunk, from.hunks, side)
    if reaches then
        return nil, reaches
    end
    local text = i and by_reading(union, cached.new_text, i, take)
    if text then
        return text
    end
    return apply.splice(from, M.select_hunks(from.hunks, side, hunk, side, take))
end

-- the text the index takes when `hunk` is staged (`take`) or unstaged, as the view
-- draws it (drawn_index). no text and no `reaches` is a hunk the drawn reading already
-- has where the op puts it, or one the pair the op reads for lines up under a
-- different union hunk, leaving the index where it is
---@param union differ.DiffModel     -- HEAD↔worktree
---@param cached differ.DiffModel    -- HEAD↔index
---@param unstaged differ.DiffModel  -- index↔worktree
---@param hunk differ.Hunk
---@param take boolean
---@return string|nil text, integer|nil reaches
function M.next_index(union, cached, unstaged, hunk, take)
    local text, reaches = drawn_index(union, cached, unstaged, hunk, take)
    if reaches then
        return nil, reaches
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

-- the hunk's lines in the order a block lays out the lines it has no place for yet:
-- sides of the same length row by row, each old line then its new line; otherwise the
-- old lines, then the new
---@param h differ.Hunk
---@return differ.model.Origin[]
local function default_order(h)
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
---@return string[]
local function select_block(h, origins, selection, take)
    return lines_of(
        h,
        arrange(h, origins, function(o)
            if not selection[o.side][h[o.side .. "_start"] + o.k - 1] then
                return nil
            end
            if o.side == "old" then
                return not take
            end
            return take
        end)
    )
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
        local selected = selection[o.side][h[o.side .. "_start"] + o.k - 1] == true
        if o.side == "old" then
            return selected
        end
        return not selected
    end)
end

-- the index's block at each union hunk, line by line, where the index cuts into
-- blocks; none for a hunk whose block holds a line neither side has
---@param union differ.DiffModel   -- HEAD↔worktree
---@param cached differ.DiffModel  -- HEAD↔index
---@return table<integer, differ.model.Origin[]>|nil
function M.index_origins(union, cached)
    local blocks, ended = M.index_blocks(union, cached.new_text)
    if not blocks then
        return nil
    end
    local _, hidden, origins = marks.of_blocks(ended.hunks, blocks)
    for _, i in ipairs(hidden) do
        origins[i] = nil
    end
    return origins --[[@as table<integer, differ.model.Origin[]>]]
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
            local block = select_block(h, marks.whole_side("old", h.old_count), selection, true)
            for _, line in ipairs(block) do
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
    local held, hidden, origins = marks.of_blocks(ended.hunks, blocks)
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
            -- a hunk with nothing hidden has an origin for every block line
            blocks[i] =
                select_block(h, origins[i] --[[@as differ.model.Origin[] ]], selection, take)
        end
    end
    local text = apply.join(ended, blocks)
    if text == cached.new_text then
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

-- the worktree with the selected union lines reverted, as a diff from that text to the
-- worktree: one hunk per touched union hunk, its old side the lines the revert leaves
-- there and its new side the worktree's own. nil is a selection that touches no hunk
---@param union differ.DiffModel  -- HEAD↔worktree
---@param selection differ.model.Selection
---@param origins? table<integer, differ.model.Origin[]>  -- index_origins
---@return differ.DiffModel|nil
function M.select_worktree(union, selection, origins)
    local ended = apply.ended(union)
    local blocks, hunks, shift = {}, {}, 0
    for i, h in ipairs(ended.hunks) do
        blocks[i] = h.new_lines
        if touches(h, selection) then
            blocks[i] = lines_of(h, reverted_block(h, selection, origins and origins[i]))
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

-- the index read against the union's rows at the least cost (marks.reading), or nil for
-- a file too big to read that way
---@param union differ.DiffModel
---@param index string  -- the index's text
---@return differ.model.Reading|nil
function M.reading(union, index)
    local ended = apply.ended(union)
    local head_lines, index_lines =
        text_util.ended_lines(union.old_text), text_util.ended_lines(index)
    return marks.reading(ended.hunks, head_lines, index_lines)
end

-- the marks the view draws for the union: the least-cost reading of the index
-- (marks.reading), or its blocks where they cut with nothing hidden, which read the
-- same. `hidden` is index content no hunk shows, and `hidden_in` the hunks holding some
-- of it. `unread` is a file too big to read, drawn from its blocks or the two pairs
---@param union differ.DiffModel     -- HEAD↔worktree
---@param cached differ.DiffModel    -- HEAD↔index
---@param unstaged differ.DiffModel  -- index↔worktree
---@return differ.model.Marks marks, boolean hidden, integer[] hidden_in, boolean unread
function M.marks_of(union, cached, unstaged)
    local blocks, ended = M.index_blocks(union, cached.new_text)
    local held, hidden_in = nil, {}
    if blocks then
        held, hidden_in = marks.of_blocks(ended.hunks, blocks)
        if held and #hidden_in == 0 then
            return held, false, hidden_in, false
        end
    end
    local read = M.reading(union, cached.new_text)
    if read then
        return read.marks, read.cost > 0, read.hidden_in, false
    end
    if held then
        return held, true, hidden_in, true
    end
    held = marks.classify(union.hunks, cached.hunks, unstaged.hunks)
    if marks.complete(union.hunks, cached.hunks, unstaged.hunks) then
        return held, false, {}, true
    end
    local head = text_util.to_lines(union.old_text)
    return held, true, marks.hidden_in(head, union.hunks, cached.hunks, held), true
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
---@param origins? table<integer, differ.model.Origin[]>  -- as select_worktree takes them
---@return differ.model.LineStates
function M.reverted(union, m, selection, origins)
    local want = { old = {}, new = {}, enter = 0, leave = 0, work_enter = 0, work_leave = 0 }
    local shift = 0
    for i, h in ipairs(union.hunks) do
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

-- the span of the drawn slices of the hunks the selection touches, {first, after} index
-- lines, and how many lines in them no row of their hunk holds. first > after where
-- the selection touches no hunk
---@param read differ.model.Reading
---@param union differ.DiffModel
---@param selection differ.model.Selection
---@return integer first, integer after, integer hidden
local function touched_slices(read, union, selection)
    local first, after, hidden = math.huge, -math.huge, 0
    for i, h in ipairs(union.hunks) do
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
---@param union differ.DiffModel   -- read from the op's texts
---@param cached differ.DiffModel
---@return integer|nil
local function hidden_dropped(before, selection, union, cached)
    local read = M.reading(before.union, before.cached.new_text)
    local now = M.reading(union, cached.new_text)
    if not (read and now) then
        return nil
    end
    local first, after, hidden = touched_slices(read, before.union, selection)
    if now.cost ~= read.cost - hidden then
        return nil
    end
    local from = text_util.ended_lines(before.cached.new_text)
    if not outside_kept(from, text_util.ended_lines(cached.new_text), first, after) then
        return nil
    end
    return hidden
end

-- `states` less each old line and a new line of the same hunk with the same text and
-- state: together they put that line in the index once, as an unchanged line does
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
-- changes place. where the index holds content no hunk shows, the op also drops the
-- hidden lines in the drawn slices it touches, and nothing else of it (hidden_dropped)
---@param want differ.model.LineStates
---@param before differ.model.Before
---@param selection differ.model.Selection
---@param union differ.DiffModel     -- read from the op's texts
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@return boolean
function M.reads_as(want, before, selection, union, cached, unstaged)
    local m, hidden = M.marks_of(union, cached, unstaged)
    local dropped = 0 ---@type integer|nil
    if before.hidden then
        dropped = hidden_dropped(before, selection, union, cached)
        if not dropped then
            return false
        end
    elseif hidden then
        return false
    end
    local old_lines = text_util.ended_lines(union.old_text)
    local new_lines = text_util.ended_lines(union.new_text)
    local got = paired_out(line_states(union.hunks, m), union.hunks, old_lines, new_lines)
    local expect = paired_out(want, union.hunks, old_lines, new_lines)
    if
        not same_side(got.old, expect.old, old_lines)
        or not same_side(got.new, expect.new, new_lines)
    then
        return false
    end
    local index_from, index_to = before.cached.new_text, cached.new_text
    if not moves_only(before.edits, index_from, index_to, want.leave + dropped, want.enter) then
        return false
    end
    local work_from, work_to = before.union.new_text, union.new_text
    if
        want.work_enter
        and not moves_only(before.edits, work_from, work_to, want.work_leave, want.work_enter)
    then
        return false
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
