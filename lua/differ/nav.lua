-- hunk navigation: pure scans over a LineMap for the next/prev hunk boundary.
-- no nvim API, so the motion logic is unit-testable; the View binds these to
-- ]c / [c and moves the cursor. every scan takes an optional `want` filter that
-- narrows it to hunks in a given state, which is how the staging review flow
-- searches for the next hunk left to stage rather than the next hunk

local M = {}

-- the start of each hunk block: the first line whose `hunk` index differs from the
-- line above it, paired with that index. ascending by lnum
---@param map differ.LineMap
---@return { lnum: integer, hunk: integer }[]
local function hunk_starts(map)
    local starts = {}
    local prev = nil
    for i, line in ipairs(map.lines) do
        if line.hunk and line.hunk ~= prev then
            starts[#starts + 1] = { lnum = i, hunk = line.hunk }
        end
        prev = line.hunk
    end
    return starts
end

-- first hunk start strictly after `lnum`, or nil if cursor is in/after the last
-- hunk. does not wrap (unfiltered, this matches vim diff-mode ]c)
---@param map differ.LineMap
---@param lnum integer
---@param want? fun(hunk: integer): boolean  -- default: any hunk
---@return integer|nil
function M.next_hunk(map, lnum, want)
    for _, s in ipairs(hunk_starts(map)) do
        if s.lnum > lnum and (not want or want(s.hunk)) then
            return s.lnum
        end
    end
    return nil
end

-- last hunk start strictly before `lnum`, or nil if cursor is in/before the
-- first hunk. does not wrap
---@param map differ.LineMap
---@param lnum integer
---@param want? fun(hunk: integer): boolean  -- default: any hunk
---@return integer|nil
function M.prev_hunk(map, lnum, want)
    local best = nil
    for _, s in ipairs(hunk_starts(map)) do
        if s.lnum >= lnum then
            break
        end
        if not want or want(s.hunk) then
            best = s.lnum
        end
    end
    return best
end

-- the first/last matching hunk start in the whole map, for landing on a file rather
-- than stepping within one (the review flow's file seam, and the open-on-file focus)
---@param map differ.LineMap
---@param want? fun(hunk: integer): boolean  -- default: any hunk
---@return integer|nil
function M.first_hunk(map, want)
    return M.next_hunk(map, 0, want)
end

---@param map differ.LineMap
---@param want? fun(hunk: integer): boolean  -- default: any hunk
---@return integer|nil
function M.last_hunk(map, want)
    return M.prev_hunk(map, #map.lines + 1, want)
end

-- the real-file (new-side) line for jump-to-file: the cursor line's own
-- `new` if it has one, else the nearest following line's `new` (a deleted/meta
-- line maps forward to the next live new line), else the nearest preceding new
-- (cursor sitting past the last new line). nil when the map has no new side at
-- all, e.g. a pure deletion
---@param map differ.LineMap
---@param lnum integer
---@return integer|nil
function M.file_line(map, lnum)
    local line = map.lines[lnum]
    if line and line.new then
        return line.new
    end
    for i = lnum + 1, #map.lines do
        if map.lines[i].new then
            return map.lines[i].new
        end
    end
    for i = lnum - 1, 1, -1 do
        if map.lines[i].new then
            return map.lines[i].new
        end
    end
    return nil
end

return M
