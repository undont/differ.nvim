-- which lines of a HEAD↔worktree diff the index already holds.
-- each real pair shares one side with the union (HEAD↔index shares HEAD, index↔worktree
-- shares the worktree), so a displayed line is classified by whichever pair shares its
-- side and the two never have to be composed. pure lua, no nvim API

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

-- classify every line of a HEAD↔worktree diff as staged or not. a HEAD line the union
-- deletes is staged when HEAD↔index deletes it too (the index has already dropped it);
-- a worktree line the union adds is staged unless index↔worktree adds it (anything
-- that pair leaves as context is in the index already)
---@param union differ.Hunk[]     -- HEAD↔worktree
---@param cached differ.Hunk[]    -- HEAD↔index
---@param unstaged differ.Hunk[]  -- index↔worktree
---@return differ.model.Marks
function M.classify(union, cached, unstaged)
    local dropped = covered(cached, "old")
    local fresh = covered(unstaged, "new")
    local marks = { old = {}, new = {} }
    for _, h in ipairs(union) do
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

-- the HEAD line a union hunk's lines start at, and the first HEAD line after them
---@param h differ.Hunk
---@return integer first, integer after
local function old_bounds(h)
    local first = h.old_count > 0 and h.old_start or h.old_start + 1
    return first, first + h.old_count
end

-- the block lengths to try for hunk `h` with `left` index lines to go: its own two
-- sides first, then the rest shortest first
---@param h differ.Hunk
---@param left integer
---@return integer[]
local function block_lengths(h, left)
    local out, seen = {}, {}
    for _, n in ipairs({ h.new_count, h.old_count }) do
        if n <= left and not seen[n] then
            out[#out + 1], seen[n] = n, true
        end
    end
    for n = 0, left do
        if not seen[n] then
            out[#out + 1] = n
        end
    end
    return out
end

-- the index's lines at each union hunk, when the index holds every unchanged line
-- between them; nil when it doesn't. where unchanged lines repeat, a hunk's block
-- ends at the first length that lets the rest of the index through
---@param union differ.Hunk[]  -- HEAD↔worktree
---@param head string[]        -- HEAD's lines
---@param index string[]       -- the index's lines
---@return string[][]|nil
function M.blocks(union, head, index)
    local out = {}
    local stuck = {} ---@type table<string, boolean>  -- "hunk:index line" with no way through
    ---@param i integer     -- the next union hunk
    ---@param from integer  -- the next HEAD line
    ---@param at integer    -- the next index line
    ---@return boolean
    local function walk(i, from, at)
        local key = i .. ":" .. at
        if stuck[key] then
            return false
        end
        local h = union[i]
        local first, after = #head + 1, #head + 1
        if h then
            first, after = old_bounds(h)
        end
        for l = from, first - 1 do
            if index[at] ~= head[l] then
                stuck[key] = true
                return false
            end
            at = at + 1
        end
        if not h then
            return at == #index + 1
        end
        for _, n in ipairs(block_lengths(h, #index - at + 1)) do
            -- the unchanged line after the block, when there is one, has to come next
            local fits = after > #head or index[at + n] == head[after]
            if fits and walk(i + 1, after, at + n) then
                local block = {}
                for l = at, at + n - 1 do
                    block[#block + 1] = index[l]
                end
                out[i] = block
                return true
            end
        end
        stuck[key] = true
        return false
    end
    if not walk(1, 1, 1) then
        return nil
    end
    return out
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

-- mark one hunk's lines from its index block. a block line is HEAD's where it pairs
-- with an old line, else the worktree's where it pairs with a new one
---@param h differ.Hunk
---@param block string[]
---@param marks differ.model.Marks
---@return boolean compared  -- false for a hunk too big to compare
---@return boolean hidden    -- a block line neither side has
local function mark_block(h, block, marks)
    local kept, used = common(h.old_lines, block)
    if not (kept and used) then
        return false, false
    end
    local rest = {}
    for k, line in ipairs(block) do
        if not used[k] then
            rest[#rest + 1] = line
        end
    end
    local held, placed = common(h.new_lines, rest)
    if not (held and placed) then
        return false, false
    end
    for k = 1, h.old_count do
        marks.old[h.old_start + k - 1] = not kept[k]
    end
    local paired = 0
    for k = 1, h.new_count do
        marks.new[h.new_start + k - 1] = held[k] == true
        if held[k] then
            paired = paired + 1
        end
    end
    return true, paired < #rest
end

-- marks for the union hunks from the index's block at each, and the hunks whose block
-- holds a line neither side has. nil when a hunk is too big to compare
---@param union differ.Hunk[]
---@param blocks string[][]
---@return differ.model.Marks|nil marks, integer[] hidden
function M.of_blocks(union, blocks)
    local marks = { old = {}, new = {} }
    local hidden = {}
    for i, h in ipairs(union) do
        local compared, extra = mark_block(h, blocks[i], marks)
        if not compared then
            return nil, {}
        end
        if extra then
            hidden[#hidden + 1] = i
        end
    end
    return marks, hidden
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

-- another union hunk that a pair hunk meeting `anchor` also meets, or nil. staging
-- takes pair hunks whole, so one of these would carry the op into that hunk too.
-- union hunks never meet each other, so the one `anchor` meets is itself
---@param union differ.Hunk[]
---@param anchor differ.Hunk
---@param pair differ.Hunk[]
---@param side "old"|"new"  -- the side union and pair share
---@return integer|nil
function M.shared_with(union, anchor, pair, side)
    for _, p in ipairs(pair) do
        if M.meets(p, side, anchor, side) then
            for j, u in ipairs(union) do
                if M.meets(p, side, u, side) and not M.meets(u, side, anchor, side) then
                    return j
                end
            end
        end
    end
    return nil
end

-- the HEAD↔index hunks that touch a HEAD↔worktree hunk
---@param h differ.Hunk        -- HEAD↔worktree
---@param cached differ.Hunk[] -- HEAD↔index
---@return differ.Hunk[]
local function touching(h, cached)
    local out = {}
    for _, c in ipairs(cached) do
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

-- the HEAD↔worktree hunks whose lines, read as the marks say, don't hold what the index
-- does there. by content, so a hunk whose index lines differ only in order isn't counted
---@param head string[]           -- HEAD's lines
---@param union differ.Hunk[]     -- HEAD↔worktree
---@param cached differ.Hunk[]    -- HEAD↔index
---@param marks differ.model.Marks
---@return integer[]
function M.hidden_in(head, union, cached, marks)
    local out = {}
    for i, h in ipairs(union) do
        local in_union, in_cached, region = {}, {}, {}
        local ua, ub = span(h, "old")
        for l = ua, ub - 1 do
            in_union[l], region[l] = true, true
        end
        local actual = {}
        for _, c in ipairs(touching(h, cached)) do
            local ca, cb = span(c, "old")
            for l = ca, cb - 1 do
                in_cached[l], region[l] = true, true
            end
            for _, line in ipairs(c.new_lines or {}) do
                actual[#actual + 1] = line
            end
        end
        local implied = {}
        for l in pairs(region) do
            if not in_cached[l] then
                actual[#actual + 1] = head[l]
            end
            if not in_union[l] or not marks.old[l] then
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

-- whether index↔worktree hunk `h` puts back lines HEAD↔index hunk `c` deleted outright
---@param h differ.Hunk  -- index↔worktree
---@param c differ.Hunk  -- HEAD↔index
---@return boolean
local function puts_back(h, c)
    if not (h.old_count == 0 and c.new_count == 0 and h.old_start == c.new_start) then
        return false
    end
    return table.concat(h.new_lines or {}, "\n") == table.concat(c.old_lines or {}, "\n")
end

-- the index↔worktree hunks that change staged content again: one that rewrites or drops
-- a line the index added, or puts back lines the index deleted. what they undo is
-- staged content the HEAD↔worktree diff can't show
---@param unstaged differ.Hunk[]  -- index↔worktree
---@param cached differ.Hunk[]    -- HEAD↔index
---@return integer[]
function M.restaged(unstaged, cached)
    local added = covered(cached, "new")
    local out = {}
    for i, h in ipairs(unstaged) do
        local hit = false
        for l = h.old_start, h.old_start + h.old_count - 1 do
            hit = hit or added[l] == true
        end
        for _, c in ipairs(cached) do
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

-- the HEAD line an index line sits at, for a line HEAD↔index leaves alone
---@param cached differ.Hunk[]  -- HEAD↔index
---@param lnum integer          -- index line
---@return integer
local function head_line(cached, lnum)
    return lnum + M.shift(cached, lnum, "new")
end

-- whether a HEAD↔worktree diff shows all of a file's half-staged content. it cannot
-- show index content that differs from HEAD and worktree both: stage a change and then
-- put the worktree back or edit it again, or let the two diffs align a run of repeated
-- lines differently, and the change is real but off-screen. a false puts a notice on
-- the view
---@param union differ.Hunk[]
---@param cached differ.Hunk[]
---@param unstaged differ.Hunk[]
---@return boolean complete, string|nil reason
function M.complete(union, cached, unstaged)
    if #union == 0 and (#cached > 0 or #unstaged > 0) then
        return false, "the index differs from HEAD and the worktree matches it"
    end
    local shows_new = covered(union, "new")
    for _, h in ipairs(unstaged) do
        for l = h.new_start, h.new_start + h.new_count - 1 do
            if not shows_new[l] then
                return false, "unstaged content sits outside every hunk"
            end
        end
    end
    local shows_old = covered(union, "old")
    for _, h in ipairs(cached) do
        for l = h.old_start, h.old_start + h.old_count - 1 do
            if not shows_old[l] then
                return false, "staged content sits outside every hunk"
            end
        end
    end
    -- an index line the worktree replaces shows only as the HEAD line it still is: one
    -- the index added (or rewrote) reaches neither side, and one whose HEAD line the
    -- union leaves as context is shown as committed
    local added = covered(cached, "new")
    for _, h in ipairs(unstaged) do
        for l = h.old_start, h.old_start + h.old_count - 1 do
            if added[l] then
                return false, "the index holds a line neither HEAD nor the worktree has"
            end
            if not shows_old[head_line(cached, l)] then
                return false, "a line the worktree replaced sits outside every hunk"
            end
        end
    end
    -- the view implies an index of HEAD's context plus the marked lines. HEAD's length
    -- cancels out of comparing that with HEAD↔index's net change, so the counts check
    -- from hunks alone; a mismatch is a line the two pairs align differently
    local shown, net = 0, 0
    local m = M.classify(union, cached, unstaged)
    for _, h in ipairs(union) do
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
    for _, h in ipairs(cached) do
        net = net + h.new_count - h.old_count
    end
    if shown ~= net then
        return false, "the marked lines don't add up to the index"
    end
    return true, nil
end

return M
