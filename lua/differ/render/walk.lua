-- shared region walk for renderers: visits unchanged regions (collapsing far
-- gaps to a separator) and hunks in document order, via callbacks. pure lua.
-- this is the single home for the vim.text.diff index convention so the subtle
-- off-by-one lives in exactly one place

local M = {}

-- context: one unchanged line (old lnum o, new lnum n); foldable marks a line in
-- the collapsible middle of a gap. hunk: a changed block
---@class differ.WalkCallbacks
---@field context fun(o: integer, n: integer, foldable: boolean)
---@field hunk fun(h: differ.Hunk, hi: integer)

-- drive the walk. `old_line_count` is #to_lines(old_text); `context` may be
-- math.huge for whole-file view. callers handle the empty (no-hunk) case.
-- every unchanged line is emitted (the buffer holds full content); the middle of
-- a gap that exceeds `context` lead/tail is flagged `foldable` so the renderer can
-- mark it for a native fold rather than dropping it
---@param model differ.DiffModel
---@param context number
---@param old_line_count integer
---@param cb differ.WalkCallbacks
function M.walk(model, context, old_line_count, cb)
    -- emit an unchanged region [old_from..] / [new_from..] of length `len`,
    -- keeping `lead` context lines at the start and `tail` at the end (0 at a
    -- file boundary) and flagging the middle foldable when it exceeds them
    local function emit_gap(old_from, new_from, len, has_prev, has_next)
        if len <= 0 then
            return
        end
        local lead = math.min(has_prev and context or 0, len)
        local tail = math.min(has_next and context or 0, len)
        for k = 0, len - 1 do
            local foldable = k >= lead and k < len - tail
            cb.context(old_from + k, new_from + k, foldable)
        end
    end

    local cursor_old, cursor_new = 1, 1
    for hi, h in ipairs(model.hunks) do
        -- vim.text.diff reports pure insertions as old_count==0 with old_start at
        -- the preceding old line (deletions mirror it on the new side), so derive
        -- the last unchanged line before the hunk from the count, not the start
        local gap_old_end = h.old_count > 0 and (h.old_start - 1) or h.old_start
        emit_gap(cursor_old, cursor_new, gap_old_end - cursor_old + 1, hi > 1, true)
        cb.hunk(h, hi)
        cursor_old = h.old_count > 0 and (h.old_start + h.old_count) or (h.old_start + 1)
        cursor_new = h.new_count > 0 and (h.new_start + h.new_count) or (h.new_start + 1)
    end
    emit_gap(cursor_old, cursor_new, old_line_count - cursor_old + 1, true, false)
end

return M
