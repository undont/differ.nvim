-- which lines of a HEAD<->worktree diff the index already holds.
-- each real pair shares one side with HEAD<->worktree (HEAD<->index shares HEAD,
-- index<->worktree shares the worktree), so a displayed line is classified by whichever
-- pair shares its side and the two never have to be composed. pure lua, no nvim API

local M = {}

---@alias differ.model.HunkState "staged"|"unstaged"|"partial"

---@class differ.model.Marks
---@field old table<integer, boolean>  -- old lnum -> the index already dropped this line
---@field new table<integer, boolean>  -- new lnum -> the index already holds this line
---@field whole differ.model.HunkState|nil  -- a whole-file source: the file's state as one unit

-- the lines a hunk list covers on one side, as a set
---@param hunks differ.Hunk[]
---@param side "old"|"new"
---@return table<integer, boolean>
local function covered(hunks, side)
    local out = {}
    local start_key, count_key = side .. "_start", side .. "_count"
    for _, h in ipairs(hunks) do
        for l = h[start_key], h[start_key] + h[count_key] - 1 do
            out[l] = true
        end
    end
    return out
end

-- classify every line of a HEAD<->worktree diff as staged or not. a HEAD line HEAD<->worktree
-- deletes is staged when HEAD<->index deletes it too (the index has already dropped it);
-- a worktree line HEAD<->worktree adds is staged unless index<->worktree adds it (anything
-- that pair leaves as context is in the index already)
---@param head_work differ.Hunk[]   -- HEAD<->worktree
---@param head_index differ.Hunk[]  -- HEAD<->index
---@param index_work differ.Hunk[]  -- index<->worktree
---@return differ.model.Marks
function M.classify(head_work, head_index, index_work)
    local dropped = covered(head_index, "old")
    local fresh = covered(index_work, "new")
    local marks = { old = {}, new = {} }
    for _, h in ipairs(head_work) do
        for l = h.old_start, h.old_start + h.old_count - 1 do
            marks.old[l] = dropped[l] or false
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            marks.new[l] = not fresh[l]
        end
    end
    return marks
end

-- a hunk's state, rolled up from its lines: staged when the index holds all of it,
-- unstaged when it holds none, partial in between
---@param marks differ.model.Marks
---@param h differ.Hunk
---@return differ.model.HunkState
function M.state(marks, h)
    local staged, live = 0, 0
    for l = h.old_start, h.old_start + h.old_count - 1 do
        if marks.old[l] then
            staged = staged + 1
        else
            live = live + 1
        end
    end
    for l = h.new_start, h.new_start + h.new_count - 1 do
        if marks.new[l] then
            staged = staged + 1
        else
            live = live + 1
        end
    end
    if live == 0 then
        return "staged"
    end
    if staged == 0 then
        return "unstaged"
    end
    return "partial"
end

-- the HEAD line a HEAD<->worktree hunk's lines start at, and the first HEAD line after them
---@param h differ.Hunk
---@return integer first, integer after
local function old_bounds(h)
    local first = h.old_count > 0 and h.old_start or h.old_start + 1
    return first, first + h.old_count
end

-- whether the index holds `lines` from line `at`
---@param index string[]
---@param at integer
---@param lines string[]
---@return boolean
local function holds(index, at, lines)
    for k, line in ipairs(lines) do
        if index[at + k - 1] ~= line then
            return false
        end
    end
    return true
end

-- the block lengths worth trying for hunk `h` at index line `at`. `next_line` is the
-- HEAD line the block has to be followed by (nil at the end of HEAD), and `where` maps
-- each index line to the lines it sits at, ascending
---@alias differ.model.BlockLengths
---| fun(h: differ.Hunk, index: string[], at: integer, next_line?: string, where: table<string, integer[]>): integer[]

-- lengths for a block that is exactly one of the hunk's sides
---@type differ.model.BlockLengths
local function whole_lengths(h, index, at)
    local out = {}
    if holds(index, at, h.new_lines) then
        out[#out + 1] = h.new_count
    end
    if holds(index, at, h.old_lines) and h.old_count ~= out[1] then
        out[#out + 1] = h.old_count
    end
    return out
end

-- every length that ends where `next_line` sits, shortest first, or the rest of the
-- index when nothing follows
---@type differ.model.BlockLengths
local function any_lengths(_, index, at, next_line, where)
    if next_line == nil then
        return { #index - at + 1 }
    end
    local lines = where[next_line] or {}
    local lo, hi = 1, #lines + 1 -- the first entry at or after `at`
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if lines[mid] < at then
            lo = mid + 1
        else
            hi = mid
        end
    end
    local out = {}
    for k = lo, #lines do
        out[#out + 1] = lines[k] - at
    end
    return out
end

-- lengths tried and lines compared past which a cut is reported as ambiguous. a file of
-- mostly repeated lines leaves any_lengths a length to try at nearly every line
local MAX_STEPS = 1e6

-- the ways to cut the index into a block per HEAD<->worktree hunk, with HEAD's unchanged
-- lines between them: the cut when there is only one, and how many there are (0, 1, or 2
-- for two or more, or for a search past MAX_STEPS)
---@param head_work differ.Hunk[]
---@param head string[]
---@param index string[]
---@param lengths differ.model.BlockLengths
---@return string[][] cut, integer ways
local function cut(head_work, head, index, lengths)
    local ways = {} ---@type table<string, integer>  -- "hunk:index line" -> ways through
    local picks = {} ---@type table<string, integer[]>  -- "hunk:index line" -> first block's {at, n}
    local where = {} ---@type table<string, integer[]>
    for l, line in ipairs(index) do
        where[line] = where[line] or {}
        table.insert(where[line], l)
    end
    local steps = 0
    ---@param i integer     -- the next HEAD<->worktree hunk
    ---@param from integer  -- the next HEAD line
    ---@param at integer    -- the next index line
    ---@return integer
    local function count(i, from, at)
        local key = i .. ":" .. at
        if ways[key] then
            return ways[key]
        end
        local h = head_work[i]
        local first, after = #head + 1, #head + 1
        if h then
            first, after = old_bounds(h)
        end
        for l = from, first - 1 do
            steps = steps + 1
            if index[at] ~= head[l] then
                ways[key] = 0
                return 0
            end
            at = at + 1
        end
        if not h then
            ways[key] = 0
            if at == #index + 1 then
                ways[key] = 1
            end
            return ways[key]
        end
        local total = 0
        local tried = lengths(h, index, at, head[after], where)
        steps = steps + #tried
        if steps > MAX_STEPS then
            return 2
        end
        for _, n in ipairs(tried) do
            -- the unchanged line after the block, when there is one, has to come next
            local fits = after > #head or index[at + n] == head[after]
            local through = 0
            if fits then
                through = count(i + 1, after, at + n)
            end
            if through > 0 and total == 0 then
                picks[key] = { at, n }
            end
            total = total + through
            if total >= 2 then
                break
            end
        end
        ways[key] = math.min(total, 2)
        return ways[key]
    end
    local total = count(1, 1, 1)
    local out, at = {}, 1
    if total ~= 1 then
        return out, total -- a cut that isn't the only one is never read
    end
    for i in ipairs(head_work) do
        local pick = picks[i .. ":" .. at]
        local block = {}
        for l = pick[1], pick[1] + pick[2] - 1 do
            block[#block + 1] = index[l]
        end
        out[i] = block
        at = pick[1] + pick[2]
    end
    return out, total
end

-- the index's lines at each HEAD<->worktree hunk, when the index holds every unchanged line
-- between them. a cut where every block is one of its hunk's sides wins; nil when the
-- index can't be cut, or can be cut more than one way
---@param head_work differ.Hunk[]  -- HEAD<->worktree
---@param head string[]            -- HEAD's lines
---@param index string[]           -- the index's lines
---@return string[][]|nil
function M.blocks(head_work, head, index)
    for _, lengths in ipairs({ whole_lengths, any_lengths }) do
        local found, ways = cut(head_work, head, index, lengths)
        if ways == 1 then
            return found
        end
        if ways > 1 then
            return nil
        end
    end
    return nil
end

-- LCS grid size past which a hunk's block isn't compared line by line
local MAX_CELLS = 1e6

-- which lines of `a` and `b` a longest common subsequence pairs up; nil past MAX_CELLS
---@param a string[]
---@param b string[]
---@return table<integer, boolean>|nil in_a, table<integer, boolean>|nil in_b
local function common(a, b)
    local n, m = #a, #b
    if n * m > MAX_CELLS then
        return nil, nil
    end
    local dp = {} -- dp[i][j] = LCS length of a[i..] and b[j..]
    for i = 1, n + 1 do
        dp[i] = { [m + 1] = 0 }
    end
    for j = 1, m + 1 do
        dp[n + 1][j] = 0
    end
    for i = n, 1, -1 do
        for j = m, 1, -1 do
            if a[i] == b[j] then
                dp[i][j] = dp[i + 1][j + 1] + 1
            else
                dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
            end
        end
    end
    local in_a, in_b = {}, {}
    local i, j = 1, 1
    while i <= n and j <= m do
        if a[i] == b[j] then
            in_a[i], in_b[j] = true, true
            i, j = i + 1, j + 1
        elseif dp[i + 1][j] >= dp[i][j + 1] then
            i = i + 1
        else
            j = j + 1
        end
    end
    return in_a, in_b
end

---@class differ.model.Origin
---@field side "old"|"new"
---@field k integer  -- the line's place in that side of the hunk

---@param side "old"|"new"
---@param count integer
---@return differ.model.Origin[]
function M.whole_side(side, count)
    local out = {}
    for k = 1, count do
        out[k] = { side = side, k = k }
    end
    return out
end

-- in `origins`, the lines of `lines` that `in_lines` pairs with the `in_block` lines of
-- `block`, where `at` maps each of those to its place in the whole block
---@param origins (differ.model.Origin|false)[]
---@param side "old"|"new"
---@param in_lines table<integer, boolean>
---@param lines string[]
---@param in_block table<integer, boolean>
---@param at integer[]
local function pair_up(origins, side, in_lines, lines, in_block, at)
    local k = 0
    for j = 1, #at do
        if in_block[j] then
            repeat
                k = k + 1
            until in_lines[k] or k > #lines
            origins[at[j]] = { side = side, k = k }
        end
    end
end

-- where each line of a hunk's index block comes from: HEAD's line where it pairs with
-- an old line, else the worktree's where it pairs with a new one, false for neither.
-- nil for a hunk too big to compare
---@param h differ.Hunk
---@param block string[]
---@return (differ.model.Origin|false)[]|nil
function M.origins(h, block)
    -- a block that is one whole side is that side, even where the two sides share a line
    if #block == h.new_count and holds(block, 1, h.new_lines) then
        return M.whole_side("new", h.new_count)
    end
    if #block == h.old_count and holds(block, 1, h.old_lines) then
        return M.whole_side("old", h.old_count)
    end
    local kept, used = common(h.old_lines, block)
    if not (kept and used) then
        return nil
    end
    local origins, rest, all, rest_at = {}, {}, {}, {}
    for k, line in ipairs(block) do
        origins[k] = false
        all[k] = k
        if not used[k] then
            rest[#rest + 1] = line
            rest_at[#rest_at + 1] = k
        end
    end
    local held, placed = common(h.new_lines, rest)
    if not (held and placed) then
        return nil
    end
    pair_up(origins, "old", kept, h.old_lines, used, all)
    pair_up(origins, "new", held, h.new_lines, placed, rest_at)
    return origins
end

-- mark one hunk's lines from where its index block's lines come from
---@param h differ.Hunk
---@param origins (differ.model.Origin|false)[]
---@param marks differ.model.Marks
---@return boolean hidden  -- a block line neither side has
local function mark_origins(h, origins, marks)
    for l = h.old_start, h.old_start + h.old_count - 1 do
        marks.old[l] = true
    end
    for l = h.new_start, h.new_start + h.new_count - 1 do
        marks.new[l] = false
    end
    local hidden = false
    for _, o in ipairs(origins) do
        if not o then
            hidden = true
        else
            marks[o.side][h[o.side .. "_start"] + o.k - 1] = o.side == "new"
        end
    end
    return hidden
end

-- mark one hunk's lines from its index block
---@param h differ.Hunk
---@param block string[]
---@param marks differ.model.Marks
---@return boolean compared  -- false for a hunk too big to compare
---@return boolean hidden    -- a block line neither side has
local function mark_block(h, block, marks)
    local origins = M.origins(h, block)
    if not origins then
        return false, false
    end
    return true, mark_origins(h, origins, marks)
end

-- marks for the HEAD<->worktree hunks from the index's block at each, the hunks whose block
-- holds a line neither side has, and where each block's lines come from. nil when a
-- hunk is too big to compare
---@param head_work differ.Hunk[]
---@param blocks string[][]
---@return differ.model.Marks|nil marks, integer[] hidden, (differ.model.Origin|false)[][] origins
function M.of_blocks(head_work, blocks)
    local marks = { old = {}, new = {} }
    local hidden, all = {}, {}
    for i, h in ipairs(head_work) do
        local origins = M.origins(h, blocks[i])
        if not origins then
            return nil, {}, {}
        end
        all[i] = origins
        if mark_origins(h, origins, marks) then
            hidden[#hidden + 1] = i
        end
    end
    return marks, hidden, all
end

---@class differ.model.Segment
---@field line? string     -- a HEAD line HEAD<->worktree leaves unchanged
---@field hunk? integer    -- else a HEAD<->worktree hunk
---@field olds? string[]
---@field news? string[]

-- HEAD<->worktree as rows in file order: each unchanged line, and each hunk as one segment
---@param hunks differ.Hunk[]
---@param head string[]
---@return differ.model.Segment[]
local function segments(hunks, head)
    local segs, from = {}, 1
    for i, h in ipairs(hunks) do
        local first, after = old_bounds(h)
        for l = from, first - 1 do
            segs[#segs + 1] = { line = head[l] }
        end
        segs[#segs + 1] = { hunk = i, olds = h.old_lines, news = h.new_lines }
        from = after
    end
    for l = from, #head do
        segs[#segs + 1] = { line = head[l] }
    end
    return segs
end

---@class differ.model.Reading
---@field marks differ.model.Marks
---@field cost integer          -- index lines no row holds, plus unchanged lines the index lacks
---@field slices integer[][]    -- hunk -> its index lines, {first, after}
---@field hidden_in integer[]   -- the hunks whose slice holds an index line no row holds
---@field doubt_in? integer[]   -- the hunks another reading of the same cost stages other lines in, or hides otherwise
---@field unowned_in? integer[] -- the nearest hunk each side of what is hidden outside every hunk

-- a hunk segment's state for a old and b new lines passed, as a key into its costs
---@param seg differ.model.Segment
---@param a integer
---@param b integer
---@return integer
local function state(seg, a, b)
    return a * (#seg.news + 1) + b
end

-- the costs a hunk state moves on to: past the next old line, past the next new line,
-- each nil where that side is used up
---@param seg differ.model.Segment
---@param g table<integer, number[]>
---@param a integer
---@param b integer
---@return number[]|nil drop, number[]|nil pass
local function onward(seg, g, a, b)
    local drop, pass = nil, nil
    if a < #seg.olds then
        drop = g[state(seg, a + 1, b)]
    end
    if b < #seg.news then
        pass = g[state(seg, a, b + 1)]
    end
    return drop, pass
end

-- the least cost from each index line on, at an unchanged line with `after` beyond it
---@param line string
---@param index string[]
---@param after number[]
---@param big integer
---@return number[]
local function line_costs(line, index, after, big)
    local n = #index
    local here = { [n + 1] = big + after[n + 1] }
    for i = n, 1, -1 do
        local best = math.min(big + after[i], big + here[i + 1])
        if index[i] == line then
            best = math.min(best, after[i + 1])
        end
        here[i] = best
    end
    return here
end

-- the least cost from each hunk state and index line on, with `after` beyond the hunk,
-- and from the hunk's start, where it can also be read as one whole side
---@param seg differ.model.Segment
---@param index string[]
---@param after number[]
---@param big integer
---@return table<integer, number[]> states, number[] enter
local function hunk_costs(seg, index, after, big)
    local n, g = #index, {}
    for a = #seg.olds, 0, -1 do
        for b = #seg.news, 0, -1 do
            local drop, pass = onward(seg, g, a, b)
            local here = {}
            for i = n + 1, 1, -1 do
                local best = math.huge
                if not (drop or pass) then
                    best = after[i] + 1
                end
                best = math.min(best, drop and drop[i] or math.huge, pass and pass[i] or math.huge)
                if i <= n then
                    best = math.min(best, big + here[i + 1])
                    if drop and index[i] == seg.olds[a + 1] then
                        best = math.min(best, drop[i + 1])
                    end
                    if pass and index[i] == seg.news[b + 1] then
                        best = math.min(best, pass[i + 1])
                    end
                end
                here[i] = best
            end
            g[state(seg, a, b)] = here
        end
    end
    local enter = {}
    for i = 1, n + 1 do
        enter[i] = g[0][i]
        for _, side in ipairs({ seg.news, seg.olds }) do
            if holds(index, i, side) then
                enter[i] = math.min(enter[i], after[i + #side])
            end
        end
    end
    return g, enter
end

-- the least cost from each segment and index line on, and each hunk segment's states.
-- a hidden or missing line costs `big`, more than all the hunks together, and a hunk
-- read line by line rather than as one whole side costs 1
---@param segs differ.model.Segment[]
---@param index string[]
---@param big integer
---@return table<integer, number[]> cost, table<integer, table<integer, number[]>> states
local function costs(segs, index, big)
    local cost, states = { [#segs + 1] = {} }, {}
    for i = 1, #index + 1 do
        cost[#segs + 1][i] = (#index + 1 - i) * big
    end
    for s = #segs, 1, -1 do
        local seg = segs[s]
        if seg.line then
            cost[s] = line_costs(seg.line, index, cost[s + 1], big)
        else
            states[s], cost[s] = hunk_costs(seg, index, cost[s + 1], big)
        end
    end
    return cost, states
end

---@class differ.model.Walk
---@field marks differ.model.Marks
---@field seg_of integer[]                -- index line -> its segment
---@field matched table<integer, boolean>  -- index line -> a row holds it
---@field total integer                   -- the walk's hidden and missing lines
---@field tied boolean                    -- some step had more than one cheapest move
---@field missed integer[]                -- unchanged line segments the index lacks

-- the move taken among `count` moves, `fits` telling which stay cheapest: the first, or
-- the last in reverse. 0 for none. `tied` is whether a second one fits, looked for only
-- with `ties`
---@param fits fun(k: integer): boolean
---@param count integer
---@param reverse boolean
---@param ties boolean
---@return integer move, boolean tied
local function choose(fits, count, reverse, ties)
    if reverse then
        for k = count, 1, -1 do
            if fits(k) then
                return k, false
            end
        end
        return 0, false
    end
    for k = 1, count do
        if fits(k) then
            if not ties then
                return k, false
            end
            for later = k + 1, count do
                if fits(later) then
                    return k, true
                end
            end
            return k, false
        end
    end
    return 0, false
end

-- a cheapest walk down the cost tables from the top. at an unchanged line it tries
-- match, hide, miss; at a hunk whole new, whole old, keep old, hold new, drop old, pass
-- new, leave, hide; in reverse, the last of those that stays cheapest
---@param hunks differ.Hunk[]
---@param segs differ.model.Segment[]
---@param index string[]
---@param cost table<integer, number[]>
---@param states table<integer, table<integer, number[]>>
---@param reverse boolean
---@param ties boolean  -- note whether some step has more than one cheapest move
---@return differ.model.Walk
local function walk(hunks, segs, index, cost, states, reverse, ties)
    local big = #hunks + 1
    local n, marks = #index, { old = {}, new = {} }
    local seg_of, matched, missed = {}, {}, {} ---@type integer[], table<integer, boolean>, integer[]
    local left, s, i, a, b, inside, tied = cost[1][1], 1, 1, 0, 0, false, false
    local seg, here, drop, pass ---@type differ.model.Segment, string, number[]|nil, number[]|nil
    -- whether move k at an unchanged line stays cheapest
    local function line_fits(k)
        if k == 1 then
            return here == seg.line and cost[s + 1][i + 1] == left
        elseif k == 2 then
            return i <= n and big + cost[s][i + 1] == left
        end
        return big + cost[s + 1][i] == left
    end
    -- whether move k at a hunk stays cheapest
    local function hunk_fits(k)
        if k == 1 then
            return not inside and holds(index, i, seg.news) and cost[s + 1][i + #seg.news] == left
        elseif k == 2 then
            return not inside and holds(index, i, seg.olds) and cost[s + 1][i + #seg.olds] == left
        elseif k == 3 then
            return drop ~= nil and here == seg.olds[a + 1] and drop[i + 1] == left
        elseif k == 4 then
            return pass ~= nil and here == seg.news[b + 1] and pass[i + 1] == left
        elseif k == 5 then
            return drop ~= nil and drop[i] == left
        elseif k == 6 then
            return pass ~= nil and pass[i] == left
        elseif k == 7 then
            return not (drop or pass) and cost[s + 1][i] + 1 == left
        end
        return i <= n and big + states[s][state(seg, a, b)][i + 1] == left
    end
    -- move to segment `to`, past index line i when `line`, held by a row when `match`
    local function step(to, line, match)
        if line then
            seg_of[i], matched[i] = s, match
            i = i + 1
        end
        s = to
    end
    local function hide()
        left = left - big
        step(s, true, false)
    end
    -- the hunk at `s` as one whole side
    local function whole(h, side, staged)
        for l = h.old_start, h.old_start + h.old_count - 1 do
            marks.old[l] = staged
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            marks.new[l] = staged
        end
        for _ = 1, #side do
            step(s, true, true)
        end
        s = s + 1
    end
    while s <= #segs or i <= n do
        seg, here = segs[s], index[i]
        local move, tie = 0, false
        if seg and seg.line then
            move, tie = choose(line_fits, 3, reverse, ties)
            if move == 1 then
                step(s + 1, true, true)
            elseif move == 3 then
                left = left - big
                missed[#missed + 1] = s
                step(s + 1, false, false)
            end
        elseif seg then
            local h = hunks[seg.hunk]
            drop, pass = onward(seg, states[s], a, b)
            move, tie = choose(hunk_fits, 8, reverse, ties)
            inside = move >= 3 and move ~= 7
            if move == 1 then
                whole(h, seg.news, true)
            elseif move == 2 then
                whole(h, seg.olds, false)
            elseif move == 3 then
                marks.old[h.old_start + a], a = false, a + 1
                step(s, true, true)
            elseif move == 4 then
                marks.new[h.new_start + b], b = true, b + 1
                step(s, true, true)
            elseif move == 5 then
                marks.old[h.old_start + a], a = true, a + 1
            elseif move == 6 then
                marks.new[h.new_start + b], b = false, b + 1
            elseif move == 7 then
                left = left - 1
                a, b = 0, 0
                step(s + 1, false, false)
            end
            inside = inside or move == 0
        end
        tied = tied or tie
        if not seg or move == 0 or (seg.line and move == 2) or (seg.hunk and move == 8) then
            hide()
        end
    end
    return {
        marks = marks,
        seg_of = seg_of,
        matched = matched,
        total = math.floor(cost[1][1] / big),
        tied = tied,
        missed = missed,
    }
end

-- each index line's owning segment: its own for a held line, and for a hidden one the
-- hunk of the held line before it, else the first hunk up to the held line after it,
-- else the segment before it. owners never decrease down the index
---@param segs differ.model.Segment[]
---@param seg_of integer[]
---@param matched table<integer, boolean>
---@return integer[] owner, table<integer, boolean> hides  -- hunk segments owning a hidden line
local function owners(segs, seg_of, matched)
    local next_hunk = { [#segs + 1] = math.huge }
    for k = #segs, 1, -1 do
        next_hunk[k] = segs[k].hunk and k or next_hunk[k + 1]
    end
    local next_held, upto = {}, #segs
    for l = #seg_of, 1, -1 do
        next_held[l] = upto
        if matched[l] then
            upto = seg_of[l]
        end
    end
    local owner, hides, prev = {}, {}, 0
    for l = 1, #seg_of do
        if matched[l] then
            prev = seg_of[l]
            owner[l] = prev
        elseif segs[prev] and segs[prev].hunk then
            owner[l], hides[prev] = prev, true
        elseif next_hunk[prev + 1] <= next_held[l] then
            owner[l] = next_hunk[prev + 1]
            hides[owner[l]] = true
        else
            owner[l] = prev
        end
    end
    return owner, hides
end

-- `segs` and `index` with `lead` and `tail` entries cut from their ends
---@generic T
---@param list T[]
---@param lead integer
---@param tail integer
---@return T[]
local function middle(list, lead, tail)
    local out = {}
    for k = lead + 1, #list - tail do
        out[#out + 1] = list[k]
    end
    return out
end

-- how many times each line occurs in `lines`
---@param lines string[]
---@return table<string, integer>
local function counts(lines)
    local out = {}
    for _, line in ipairs(lines) do
        out[line] = (out[line] or 0) + 1
    end
    return out
end

---@class differ.model.Run
---@field s integer  -- first segment
---@field i integer  -- first index line
---@field n integer  -- unchanged lines matched line for line

-- the unchanged lines HEAD and the index each hold once and no hunk adds, between the
-- ends' runs, as their segment and index line, in segment order
---@param hunks differ.Hunk[]
---@param head string[]
---@param segs differ.model.Segment[]
---@param index string[]
---@param from differ.model.Run  -- the run at the top
---@param to differ.model.Run    -- the run at the bottom
---@return differ.model.Run[]
local function unique_lines(hunks, head, segs, index, from, to)
    local in_head, in_index, added = counts(head), counts(index), {}
    for _, h in ipairs(hunks) do
        for _, line in ipairs(h.new_lines) do
            added[line] = true
        end
    end
    local at = {} ---@type table<string, integer>
    for i = from.i + from.n, to.i - 1 do
        at[index[i]] = i
    end
    local out = {}
    for s = from.s + from.n, to.s - 1 do
        local line = segs[s].line
        if line and in_head[line] == 1 and in_index[line] == 1 and not added[line] and at[line] then
            out[#out + 1] = { s = s, i = at[line], n = 1 }
        end
    end
    return out
end

-- the longest set of `lines` whose index lines rise in segment order, taking the
-- earliest where several are longest
---@param lines differ.model.Run[]
---@return differ.model.Run[]
local function rising(lines)
    -- tails[n] is the highest index line a rise of n starts at
    local longest, tails = {}, {} ---@type integer[], integer[]
    for k = #lines, 1, -1 do
        local i = lines[k].i
        local lo, hi = 1, #tails + 1 -- the first length whose tail isn't above i
        while lo < hi do
            local mid = math.floor((lo + hi) / 2)
            if tails[mid] > i then
                lo = mid + 1
            else
                hi = mid
            end
        end
        longest[k] = lo
        tails[lo] = math.max(tails[lo] or 0, i)
    end
    local out, need, after = {}, #tails, 0
    for k, line in ipairs(lines) do
        if longest[k] == need and line.i > after then
            out[#out + 1] = line
            need, after = need - 1, line.i
        end
    end
    return out
end

-- whether segment s is an unchanged line the index holds at line i
---@param segs differ.model.Segment[]
---@param index string[]
---@param s integer
---@param i integer
---@return boolean
local function same(segs, index, s, i)
    return segs[s] ~= nil and segs[s].line ~= nil and segs[s].line == index[i]
end

-- the unchanged lines matched line for line before the walk, as runs from the top: from
-- the top and from the bottom up to a mismatch or a hunk, then from each of the rising
-- unique lines down to a mismatch, a hunk or the bottom's run
---@param hunks differ.Hunk[]
---@param head string[]
---@param segs differ.model.Segment[]
---@param index string[]
---@return differ.model.Run[]
local function matched_runs(hunks, head, segs, index)
    local lead, tail = 0, 0
    while same(segs, index, lead + 1, lead + 1) do
        lead = lead + 1
    end
    while
        tail < #segs - lead
        and tail < #index - lead
        and same(segs, index, #segs - tail, #index - tail)
    do
        tail = tail + 1
    end
    local top = { s = 1, i = 1, n = lead }
    local bottom = { s = #segs - tail + 1, i = #index - tail + 1, n = tail }
    local runs, last = { top }, top
    for _, run in ipairs(rising(unique_lines(hunks, head, segs, index, top, bottom))) do
        if run.s >= last.s + last.n then
            while
                run.s + run.n < bottom.s
                and run.i + run.n < bottom.i
                and same(segs, index, run.s + run.n, run.i + run.n)
            do
                run.n = run.n + 1
            end
            runs[#runs + 1], last = run, run
        end
    end
    runs[#runs + 1] = bottom
    return runs
end

---@class differ.model.Window
---@field s integer  -- first segment
---@field i integer  -- first index line
---@field segs differ.model.Segment[]
---@field index string[]

-- the segments and index lines between `runs`, and the cells their walks fill
---@param segs differ.model.Segment[]
---@param index string[]
---@param runs differ.model.Run[]
---@return differ.model.Window[] windows, integer cells
local function windows_of(segs, index, runs)
    local windows, cells = {}, 0
    for k = 2, #runs do
        local s, i = runs[k - 1].s + runs[k - 1].n, runs[k - 1].i + runs[k - 1].n
        local win = { s = s, i = i, segs = middle(segs, s - 1, #segs - runs[k].s + 1) }
        win.index = middle(index, i - 1, #index - runs[k].i + 1)
        for _, seg in ipairs(win.segs) do
            cells = cells + (seg.line and 1 or (#seg.olds + 1) * (#seg.news + 1)) * (#win.index + 1)
        end
        windows[#windows + 1] = win
    end
    return windows, cells
end

-- the walk over each window of segments and index lines between `runs`, the runs'
-- lines matched, and with `reverse` the walk in reverse order too, which is the same
-- walk in a window with no tie. nil past MAX_CELLS over all windows
---@param hunks differ.Hunk[]
---@param segs differ.model.Segment[]
---@param index string[]
---@param runs differ.model.Run[]
---@param reverse boolean
---@return differ.model.Walk|nil walk, differ.model.Walk|nil reversed
local function walk_windows(hunks, segs, index, runs, reverse)
    local windows, cells = windows_of(segs, index, runs)
    if cells > MAX_CELLS then
        return nil, nil
    end
    local walks = {} ---@type differ.model.Walk[]
    for k = 1, reverse and 2 or 1 do
        walks[k] = {
            marks = { old = {}, new = {} },
            seg_of = {},
            matched = {},
            total = 0,
            tied = false,
            missed = {},
        }
        for _, run in ipairs(runs) do
            for d = 0, run.n - 1 do
                walks[k].seg_of[run.i + d], walks[k].matched[run.i + d] = run.s + d, true
            end
        end
    end
    for _, win in ipairs(windows) do
        local cost, states = costs(win.segs, win.index, #hunks + 1)
        local part = walk(hunks, win.segs, win.index, cost, states, false, reverse)
        for k, w in ipairs(walks) do
            if k == 2 and part.tied then
                part = walk(hunks, win.segs, win.index, cost, states, true, false)
            end
            for _, side in ipairs({ "old", "new" }) do
                for l, v in pairs(part.marks[side]) do
                    w.marks[side][l] = v
                end
            end
            for l = 1, #win.index do
                w.seg_of[win.i + l - 1] = part.seg_of[l] + win.s - 1
                w.matched[win.i + l - 1] = part.matched[l]
            end
            for _, m in ipairs(part.missed) do
                w.missed[#w.missed + 1] = m + win.s - 1
            end
            w.total = w.total + part.total
            w.tied = w.tied or part.tied
        end
    end
    return walks[1], walks[2]
end

-- a hunk's marks from its slice as of_blocks reads a block, where that reads every
-- line of it; else the walk's marks stay
---@param h differ.Hunk
---@param slice string[]
---@param marks differ.model.Marks
local function remark(h, slice, marks)
    local own = { old = {}, new = {} }
    local compared, hidden = mark_block(h, slice, own)
    if not compared or hidden then
        return
    end
    for l, v in pairs(own.old) do
        marks.old[l] = v
    end
    for l, v in pairs(own.new) do
        marks.new[l] = v
    end
end

-- a walk read into slices, hiding hunks and marks, each hunk with nothing hidden
-- reading its slice as of_blocks does where that holds every line
---@param hunks differ.Hunk[]
---@param segs differ.model.Segment[]
---@param index string[]
---@param w differ.model.Walk
---@return differ.model.Reading
local function read_walk(hunks, segs, index, w)
    local owner, hides = owners(segs, w.seg_of, w.matched)
    local slices, hidden_in, l = {}, {}, 1
    for k, seg in ipairs(segs) do
        if seg.hunk then
            while owner[l] and owner[l] < k do
                l = l + 1
            end
            local first = l
            while owner[l] == k do
                l = l + 1
            end
            slices[seg.hunk] = { first, l }
            if hides[k] then
                hidden_in[#hidden_in + 1] = seg.hunk
            else
                remark(hunks[seg.hunk], middle(index, first - 1, #index - l + 1), w.marks)
            end
        end
    end
    return { marks = w.marks, cost = w.total, slices = slices, hidden_in = hidden_in }
end

-- whether `a` and `b` stage different lines on a side of `h`, counting each line's text
-- rather than which copy of it
---@param h differ.Hunk
---@param a differ.model.Marks
---@param b differ.model.Marks
---@return boolean
local function stages_other(h, a, b)
    for _, side in ipairs({ "old", "new" }) do
        local count = {} ---@type table<string, integer>
        for k, line in ipairs(h[side .. "_lines"]) do
            local l = h[side .. "_start"] + k - 1
            count[line] = (count[line] or 0) + (a[side][l] and 1 or 0) - (b[side][l] and 1 or 0)
        end
        for _, c in pairs(count) do
            if c ~= 0 then
                return true
            end
        end
    end
    return false
end

-- flags in `doubt` what moving a hidden line from segment `was` to each of `could`
-- changes: the hunk it moves to where the drawn reading has it hide nothing, and `was`
-- where that was its only hidden line and the drawn reading has it hide
---@param segs differ.model.Segment[]
---@param was integer
---@param could table<integer, true>  -- segments, 0 for none
---@param owned table<integer, integer>  -- segment -> its hidden lines
---@param hides table<integer, true>
---@param doubt table<integer, true>
local function flag_moves(segs, was, could, owned, hides, doubt)
    local was_hunk = segs[was] and segs[was].hunk
    for c in pairs(could) do
        if c ~= was then
            local to = segs[c] and segs[c].hunk
            if to and not hides[to] then
                doubt[to] = true
            end
            if was_hunk and owned[was] == 1 and hides[was_hunk] then
                doubt[was_hunk] = true
            end
        end
    end
end

-- flags in `doubt` the hunks a hidden line of `w` could belong to other than as owners
-- gives it. a hidden line can take any place in its run of equal index lines at the
-- same cost, the run's held lines moving over, so each pair of held lines around or in
-- the run can be the pair it sits between; and where that pair's gap spans several
-- hunks, owners gives it to the first
---@param segs differ.model.Segment[]
---@param index string[]
---@param w differ.model.Walk
---@param hides table<integer, true>  -- the drawn reading's hiding hunks
---@param doubt table<integer, true>
local function shifted(segs, index, w, hides, doubt)
    local any_hidden = false
    for l = 1, #index do
        any_hidden = any_hidden or not w.matched[l]
    end
    if not any_hidden then
        return
    end
    local next_hunk = { [#segs + 1] = math.huge }
    for k = #segs, 1, -1 do
        next_hunk[k] = segs[k].hunk and k or next_hunk[k + 1]
    end
    local next_held, upto = {}, #segs
    for l = #index, 1, -1 do
        next_held[l] = upto
        if w.matched[l] then
            upto = w.seg_of[l]
        end
    end
    local owner = owners(segs, w.seg_of, w.matched)
    local owned = {} ---@type table<integer, integer>
    for l = 1, #index do
        if not w.matched[l] then
            owned[owner[l]] = (owned[owner[l]] or 0) + 1
        end
    end
    -- the segment a hidden line between held lines in segments p and q goes to, 0 for none
    local function owner_of(p, q)
        if segs[p] and segs[p].hunk then
            return p
        end
        if next_hunk[p + 1] <= q then
            return next_hunk[p + 1]
        end
        return 0
    end
    local prev, lo = 0, 1
    while lo <= #index do
        local hi, hidden = lo, not w.matched[lo]
        while index[hi + 1] == index[lo] do
            hi = hi + 1
            hidden = hidden or not w.matched[hi]
        end
        local held = { prev }
        for l = lo, hi do
            if w.matched[l] then
                held[#held + 1] = w.seg_of[l]
            end
        end
        if hidden then
            held[#held + 1] = next_held[hi]
            local could = {} ---@type table<integer, true>
            for k = 2, #held do
                local p, q = held[k - 1], held[k]
                could[owner_of(p, q)] = true
                local gap, first = {}, p + 1
                if segs[p] and segs[p].hunk then
                    first = p
                end
                for t = next_hunk[first], q do
                    if segs[t].hunk then
                        gap[#gap + 1] = segs[t].hunk
                    end
                end
                if #gap > 1 then
                    for _, h in ipairs(gap) do
                        doubt[h] = true
                    end
                end
            end
            for l = lo, hi do
                if not w.matched[l] then
                    flag_moves(segs, owner[l], could, owned, hides, doubt)
                end
            end
        end
        prev = held[#held - (hidden and 1 or 0)]
        lo = hi + 1
    end
end

-- the hunks where another reading of the same cost stages other lines than `read` or
-- hides otherwise, or where either walk's hidden lines could belong elsewhere
---@param hunks differ.Hunk[]
---@param segs differ.model.Segment[]
---@param index string[]
---@param read differ.model.Reading
---@param other differ.model.Reading
---@param walks differ.model.Walk[]
---@return integer[]
local function differing(hunks, segs, index, read, other, walks)
    ---@type table<integer, true>, table<integer, true>, table<integer, true>
    local hides, other_hides, doubt = {}, {}, {}
    for _, k in ipairs(read.hidden_in) do
        hides[k] = true
    end
    for _, k in ipairs(other.hidden_in) do
        other_hides[k] = true
    end
    for k in ipairs(hunks) do
        if hides[k] ~= other_hides[k] then
            doubt[k] = true
        end
    end
    for _, w in ipairs(walks) do
        shifted(segs, index, w, hides, doubt)
    end
    local out = {}
    for k, h in ipairs(hunks) do
        if doubt[k] or stages_other(h, read.marks, other.marks) then
            out[#out + 1] = k
        end
    end
    return out
end

-- the nearest hunk at or before segment `lo` and at or after `hi`, into `near`
---@param segs differ.model.Segment[]
---@param lo integer
---@param hi integer
---@param near table<integer, true>
local function hunks_around(segs, lo, hi, near)
    while segs[lo] and not segs[lo].hunk do
        lo = lo - 1
    end
    while segs[hi] and not segs[hi].hunk do
        hi = hi + 1
    end
    for _, k in ipairs({ lo, hi }) do
        if segs[k] then
            near[segs[k].hunk] = true
        end
    end
end

-- the nearest hunk each side of what any of `walks` hides outside every hunk: an
-- unchanged line it misses, or an index line no hunk owns (owners)
---@param segs differ.model.Segment[]
---@param walks differ.model.Walk[]
---@return integer[]  -- ascending
local function unowned_in(segs, walks)
    local near = {} ---@type table<integer, true>
    for _, w in ipairs(walks) do
        for _, m in ipairs(w.missed) do
            hunks_around(segs, m - 1, m + 1, near)
        end
        local owner = owners(segs, w.seg_of, w.matched)
        for l, o in ipairs(owner) do
            if not w.matched[l] and not (segs[o] and segs[o].hunk) then
                hunks_around(segs, o, o + 1, near)
            end
        end
    end
    local out = {}
    for k in pairs(near) do
        out[#out + 1] = k
    end
    table.sort(out)
    return out
end

-- the index read against HEAD<->worktree's rows: unchanged lines held or missing, each
-- hunk's old lines kept or dropped and new lines held or not in any interleaving,
-- other index lines hidden. unchanged lines are first matched line for line
-- (matched_runs); in each window between, the cheapest reading hides fewest lines,
-- then reads fewest hunks other than as one whole side (new, then old), then follows a
-- walk from the top taking keep old, hold new, match, drop old, pass new, leave, miss,
-- hide. a hunk with nothing hidden reads its slice as of_blocks does where that holds
-- every line. with `doubt`, `doubt_in` holds the hunks another reading of the same cost
-- reads otherwise (differing), and `unowned_in` the hunks either side of what it hides
-- outside every hunk (unowned_in). nil past MAX_CELLS
---@param hunks differ.Hunk[]  -- ended
---@param head string[]        -- ended lines
---@param index string[]       -- ended lines
---@param doubt? boolean
---@return differ.model.Reading|nil
function M.reading(hunks, head, index, doubt)
    local segs = segments(hunks, head)
    local runs = matched_runs(hunks, head, segs, index)
    local first, reversed = walk_windows(hunks, segs, index, runs, doubt == true)
    if not first then
        return nil
    end
    local read = read_walk(hunks, segs, index, first)
    if not doubt then
        return read
    end
    local other, walks = read, { first }
    if reversed and first.tied then
        other, walks = read_walk(hunks, segs, index, reversed), { first, reversed }
    end
    read.doubt_in = differing(hunks, segs, index, read, other, walks)
    read.unowned_in = unowned_in(segs, walks)
    return read
end

-- a hunk's real lines on one side, [start, stop). a zero-count hunk has none
---@param h differ.Hunk
---@param side "old"|"new"
---@return integer start, integer stop
local function span(h, side)
    local at, n = h[side .. "_start"], h[side .. "_count"]
    return at, at + n
end

-- whether two hunks meet on the sides given: lines in common, or an insertion that
-- sits inside the other's lines or at either edge of them. an insertion's start names
-- the line it follows
---@param a differ.Hunk
---@param a_side "old"|"new"
---@param b differ.Hunk
---@param b_side "old"|"new"
---@return boolean
function M.meets(a, a_side, b, b_side)
    local as, an = a[a_side .. "_start"], a[a_side .. "_count"]
    local bs, bn = b[b_side .. "_start"], b[b_side .. "_count"]
    if an > 0 and bn > 0 then
        return as < bs + bn and bs < as + an
    end
    if an == 0 and bn == 0 then
        return as == bs
    end
    if an == 0 then
        return as >= bs - 1 and as <= bs + bn - 1
    end
    return bs >= as - 1 and bs <= as + an - 1
end

-- another HEAD<->worktree hunk that a pair hunk meeting `anchor` also meets, or nil.
-- staging takes pair hunks whole, so one of these would carry the op into that hunk too.
-- HEAD<->worktree hunks never meet each other, so the one `anchor` meets is itself
---@param head_work differ.Hunk[]
---@param anchor differ.Hunk
---@param pair differ.Hunk[]
---@param side "old"|"new"  -- the side HEAD<->worktree and the pair share
---@return integer|nil
function M.shared_with(head_work, anchor, pair, side)
    for _, p in ipairs(pair) do
        if M.meets(p, side, anchor, side) then
            for j, u in ipairs(head_work) do
                if M.meets(p, side, u, side) and not M.meets(u, side, anchor, side) then
                    return j
                end
            end
        end
    end
    return nil
end

-- the HEAD<->index hunks that touch a HEAD<->worktree hunk
---@param h differ.Hunk             -- HEAD<->worktree
---@param head_index differ.Hunk[]  -- HEAD<->index
---@return differ.Hunk[]
local function touching(h, head_index)
    local out = {}
    for _, c in ipairs(head_index) do
        if M.meets(h, "old", c, "old") then
            out[#out + 1] = c
        end
    end
    return out
end

---@param lines string[]
---@return string
local function bag(lines)
    table.sort(lines)
    return table.concat(lines, "\n")
end

-- the HEAD<->worktree hunks whose lines, read as the marks say, don't hold what the index
-- does there. by content, so a hunk whose index lines differ only in order isn't counted
---@param head string[]             -- HEAD's lines
---@param head_work differ.Hunk[]   -- HEAD<->worktree
---@param head_index differ.Hunk[]  -- HEAD<->index
---@param marks differ.model.Marks
---@return integer[]
function M.hidden_in(head, head_work, head_index, marks)
    local out = {}
    for i, h in ipairs(head_work) do
        local in_head_work, in_head_index, region = {}, {}, {}
        local ua, ub = span(h, "old")
        for l = ua, ub - 1 do
            in_head_work[l], region[l] = true, true
        end
        local actual = {}
        for _, c in ipairs(touching(h, head_index)) do
            local ca, cb = span(c, "old")
            for l = ca, cb - 1 do
                in_head_index[l], region[l] = true, true
            end
            for _, line in ipairs(c.new_lines or {}) do
                actual[#actual + 1] = line
            end
        end
        local implied = {}
        for l in pairs(region) do
            if not in_head_index[l] then
                actual[#actual + 1] = head[l]
            end
            if not in_head_work[l] or not marks.old[l] then
                implied[#implied + 1] = head[l]
            end
        end
        local na = h.new_start
        for k, line in ipairs(h.new_lines or {}) do
            if marks.new[na + k - 1] then
                implied[#implied + 1] = line
            end
        end
        if bag(actual) ~= bag(implied) then
            out[#out + 1] = i
        end
    end
    return out
end

-- whether index<->worktree hunk `h` puts back lines HEAD<->index hunk `c` deleted outright
---@param h differ.Hunk  -- index<->worktree
---@param c differ.Hunk  -- HEAD<->index
---@return boolean
local function puts_back(h, c)
    if not (h.old_count == 0 and c.new_count == 0 and h.old_start == c.new_start) then
        return false
    end
    return table.concat(h.new_lines or {}, "\n") == table.concat(c.old_lines or {}, "\n")
end

-- the index<->worktree hunks that change staged content again: one that rewrites or drops
-- a line the index added, or puts back lines the index deleted. what they undo is
-- staged content the HEAD<->worktree diff can't show
---@param index_work differ.Hunk[]  -- index<->worktree
---@param head_index differ.Hunk[]  -- HEAD<->index
---@return integer[]
function M.restaged(index_work, head_index)
    local added = covered(head_index, "new")
    local out = {}
    for i, h in ipairs(index_work) do
        local hit = false
        for l = h.old_start, h.old_start + h.old_count - 1 do
            hit = hit or added[l] == true
        end
        for _, c in ipairs(head_index) do
            hit = hit or puts_back(h, c)
        end
        if hit then
            out[#out + 1] = i
        end
    end
    return out
end

-- how far line `lnum` on side `from` moves on the other side: the net lines the hunks
-- ending before it add there
---@param hunks differ.Hunk[]
---@param lnum integer
---@param from "old"|"new"
---@return integer
function M.shift(hunks, lnum, from)
    local to = from == "old" and "new" or "old"
    local out = 0
    for _, h in ipairs(hunks) do
        local start, count = h[from .. "_start"], h[from .. "_count"]
        local last = count == 0 and start or start + count - 1
        if last >= lnum then
            break
        end
        out = out + h[to .. "_count"] - count
    end
    return out
end

-- the HEAD line an index line sits at, for a line HEAD<->index leaves alone
---@param head_index differ.Hunk[]  -- HEAD<->index
---@param lnum integer              -- index line
---@return integer
local function head_line(head_index, lnum)
    return lnum + M.shift(head_index, lnum, "new")
end

-- whether a HEAD<->worktree diff shows all of a file's half-staged content. it cannot
-- show index content that differs from HEAD and worktree both: stage a change and then
-- put the worktree back or edit it again, or let the two diffs align a run of repeated
-- lines differently, and the change is real but off-screen. a false puts the note on
-- the winbar, which says how many hunks hold some of it rather than why
---@param head_work differ.Hunk[]
---@param head_index differ.Hunk[]
---@param index_work differ.Hunk[]
---@return boolean
function M.complete(head_work, head_index, index_work)
    -- the index differs from HEAD and the worktree matches it
    if #head_work == 0 and (#head_index > 0 or #index_work > 0) then
        return false
    end
    -- unstaged or staged content sitting outside every hunk
    local shows_new = covered(head_work, "new")
    for _, h in ipairs(index_work) do
        for l = h.new_start, h.new_start + h.new_count - 1 do
            if not shows_new[l] then
                return false
            end
        end
    end
    local shows_old = covered(head_work, "old")
    for _, h in ipairs(head_index) do
        for l = h.old_start, h.old_start + h.old_count - 1 do
            if not shows_old[l] then
                return false
            end
        end
    end
    -- an index line the worktree replaces shows only as the HEAD line it still is: one
    -- the index added (or rewrote) reaches neither side, and one whose HEAD line the
    -- HEAD<->worktree leaves as context is shown as committed
    local added = covered(head_index, "new")
    for _, h in ipairs(index_work) do
        for l = h.old_start, h.old_start + h.old_count - 1 do
            if added[l] then
                return false -- a line only the index holds
            end
            if not shows_old[head_line(head_index, l)] then
                return false -- a line the worktree replaced, outside every hunk
            end
        end
    end
    -- the view implies an index of HEAD's context plus the marked lines. HEAD's length
    -- cancels out of comparing that with HEAD<->index's net change, so the counts check
    -- from hunks alone; a mismatch is a line the two pairs align differently
    local shown, net = 0, 0
    local m = M.classify(head_work, head_index, index_work)
    for _, h in ipairs(head_work) do
        shown = shown - h.old_count
        for l = h.old_start, h.old_start + h.old_count - 1 do
            if not m.old[l] then
                shown = shown + 1
            end
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            if m.new[l] then
                shown = shown + 1
            end
        end
    end
    for _, h in ipairs(head_index) do
        net = net + h.new_count - h.old_count
    end
    if shown ~= net then
        return false -- the marked lines don't add up to the index
    end
    return true
end

return M
