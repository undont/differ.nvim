-- which lines of a HEAD↔worktree diff the index already holds.
-- each real pair shares one side with the union (HEAD↔index shares HEAD, index↔worktree
-- shares the worktree), so a displayed line is classified by whichever pair shares its
-- side and the two never have to be composed. pure lua, no nvim API

local M = {}

---@alias differ.model.HunkState "staged"|"unstaged"|"partial"

---@class differ.model.Marks
---@field old table<integer, boolean>   -- HEAD lnum -> the index already dropped this line
---@field new table<integer, boolean>   -- worktree lnum -> the index already holds this line
---@field hunks differ.model.HunkState[]    -- union hunk index -> rolled-up state

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

-- classify every line of a HEAD↔worktree diff as staged or not, and roll each hunk up
-- to a tri-state. a HEAD line the union deletes is staged when HEAD↔index deletes it
-- too (the index has already dropped it); a worktree line the union adds is staged
-- unless index↔worktree adds it (anything that pair leaves as context is in the index
-- already). pure: no git, no nvim
---@param union differ.Hunk[]     -- HEAD↔worktree
---@param cached differ.Hunk[]    -- HEAD↔index
---@param unstaged differ.Hunk[]  -- index↔worktree
---@return differ.model.Marks
function M.classify(union, cached, unstaged)
    local dropped = covered(cached, "old")
    local fresh = covered(unstaged, "new")
    local marks = { old = {}, new = {}, hunks = {} }
    for i, h in ipairs(union) do
        local staged, live = 0, 0
        for l = h.old_start, h.old_start + h.old_count - 1 do
            marks.old[l] = dropped[l] or false
            if marks.old[l] then
                staged = staged + 1
            else
                live = live + 1
            end
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            marks.new[l] = not fresh[l]
            if marks.new[l] then
                staged = staged + 1
            else
                live = live + 1
            end
        end
        if live == 0 then
            marks.hunks[i] = "staged"
        elseif staged == 0 then
            marks.hunks[i] = "unstaged"
        else
            marks.hunks[i] = "partial"
        end
    end
    return marks
end

-- the HEAD line an index line sits at, for a line HEAD↔index leaves alone
---@param cached differ.Hunk[]  -- HEAD↔index
---@param lnum integer          -- index line
---@return integer
local function head_line(cached, lnum)
    local shift = 0
    for _, h in ipairs(cached) do
        local last = h.new_count == 0 and h.new_start or h.new_start + h.new_count - 1
        if last >= lnum then
            break
        end
        shift = shift + h.new_count - h.old_count
    end
    return lnum - shift
end

-- whether a HEAD↔worktree diff shows all of a file's half-staged content. it cannot
-- show index content that differs from HEAD and worktree both: stage a change and then
-- put the worktree back or edit it again, or let the two diffs align a run of repeated
-- lines differently, and the change is real but off-screen. a false sends the file
-- back to the two-pair view, where nothing is hidden
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

-- how many hunks sit in each state, for the summary line
---@param marks differ.model.Marks
---@return table<differ.model.HunkState, integer>
function M.tally(marks)
    local out = { staged = 0, unstaged = 0, partial = 0 }
    for _, state in ipairs(marks.hunks) do
        out[state] = out[state] + 1
    end
    return out
end

return M
