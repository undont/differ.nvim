-- the old side's text with only part of a diff applied, for staging a selection of
-- lines rather than a whole hunk. the caller re-diffs the result against the real file
-- and patches from that, so a selection never hand-builds a patch body: a diff of two
-- real texts always applies, where a hand-built body can place an added line on the
-- wrong side of a context line and land a silently wrong index.
--
-- a hunk carries two blocks and no correspondence between them, so a partial hunk is
-- only splittable where the mapping is unambiguous: an insertion, a deletion, or a
-- replacement of equal length. anything else is refused rather than guessed at.
-- pure lua, no vim API

local to_lines = require("differ.util.text").to_lines

local M = {}

---@class differ.model.Selection
---@field old table<integer, boolean>|nil  -- old-side line numbers picked
---@field new table<integer, boolean>|nil  -- new-side line numbers picked

---@param hunk differ.Hunk
---@param sel differ.model.Selection
---@return integer picked, integer total
local function tally(hunk, sel)
    local picked, total = 0, hunk.old_count + hunk.new_count
    for k = 0, hunk.old_count - 1 do
        if sel.old[hunk.old_start + k] then
            picked = picked + 1
        end
    end
    for k = 0, hunk.new_count - 1 do
        if sel.new[hunk.new_start + k] then
            picked = picked + 1
        end
    end
    return picked, total
end

-- what one hunk's block becomes. the second return says whether its last line came
-- from the new side, which decides the file's terminator when the hunk sits at the end
---@param hunk differ.Hunk
---@param sel differ.model.Selection
---@return string[]|nil lines, boolean|string tail_from_new  -- a reason in place of the flag on refusal
local function region(hunk, sel)
    local picked, total = tally(hunk, sel)
    if picked == 0 then
        return hunk.old_lines, false
    end
    if picked == total then
        return hunk.new_lines, true
    end
    local out = {}
    if hunk.old_count == 0 then
        for k = 1, hunk.new_count do
            if sel.new[hunk.new_start + k - 1] then
                out[#out + 1] = hunk.new_lines[k]
            end
        end
        return out, true
    end
    if hunk.new_count == 0 then
        for k = 1, hunk.old_count do
            if not sel.old[hunk.old_start + k - 1] then
                out[#out + 1] = hunk.old_lines[k]
            end
        end
        return out, false
    end
    if hunk.old_count ~= hunk.new_count then
        local why = "a hunk replacing %d lines with %d can't be split"
        return nil, why:format(hunk.old_count, hunk.new_count)
    end
    -- equal blocks pair up by position, which is how a line edited in place reads on
    -- screen. either side of a pair being picked takes the new line, so a selection
    -- dragged over one column alone still means the change on that row
    local from_new = false
    for k = 1, hunk.old_count do
        local take = sel.old[hunk.old_start + k - 1] or sel.new[hunk.new_start + k - 1]
        out[#out + 1] = take and hunk.new_lines[k] or hunk.old_lines[k]
        from_new = take or false
    end
    return out, from_new
end

---@param text string
---@return boolean
local function terminated(text)
    return text == "" or text:sub(-1) == "\n"
end

-- `model`'s old-side text with the lines `sel` names applied, or nil and a reason when
-- the selection lands inside a hunk whose blocks don't pair up. an empty selection
-- returns the old text, a full one the new text
---@param model differ.DiffModel
---@param sel differ.model.Selection|nil
---@return string|nil text, string|nil reason
function M.partial(model, sel)
    sel = { old = (sel and sel.old) or {}, new = (sel and sel.new) or {} }
    local old = to_lines(model.old_text)
    local out, tail_new, hi = {}, false, 1

    -- a hunk with no old lines sits after the line `old_start` names, so it is emitted
    -- once that line has been, not in place of one
    ---@param after integer
    ---@return string|nil reason
    local function insertions_after(after)
        while true do
            local h = model.hunks[hi]
            if not (h and h.old_count == 0 and h.old_start == after) then
                return nil
            end
            local lines, flag = region(h, sel)
            if not lines then
                return flag --[[@as string]]
            end
            for _, l in ipairs(lines) do
                out[#out + 1] = l
            end
            if #lines > 0 then
                tail_new = flag --[[@as boolean]]
            end
            hi = hi + 1
        end
    end

    local reason = insertions_after(0)
    if reason then
        return nil, reason
    end
    local i = 1
    while i <= #old do
        local h = model.hunks[hi]
        if h and h.old_count > 0 and h.old_start == i then
            local lines, flag = region(h, sel)
            if not lines then
                return nil, flag --[[@as string]]
            end
            for _, l in ipairs(lines) do
                out[#out + 1] = l
            end
            if #lines > 0 then
                tail_new = flag --[[@as boolean]]
            end
            i = i + h.old_count
            hi = hi + 1
        else
            out[#out + 1] = old[i]
            tail_new = false
            i = i + 1
        end
        reason = insertions_after(i - 1)
        if reason then
            return nil, reason
        end
    end

    if #out == 0 then
        return ""
    end
    local keep_nl
    if tail_new then
        keep_nl = terminated(model.new_text)
    else
        keep_nl = terminated(model.old_text)
    end
    return table.concat(out, "\n") .. (keep_nl and "\n" or "")
end

return M
