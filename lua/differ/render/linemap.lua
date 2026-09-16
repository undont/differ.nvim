-- line map: the frozen contract everything reads
-- pure lua, no nvim API, so renderers that produce maps are testable without nvim

---@class differ.SubSpan
---@field col_start integer  -- byte col, 0-based inclusive
---@field col_end integer    -- byte col, 0-based exclusive

---@alias differ.RailKind "context"|"old"|"new"|"meta"

---@class differ.RailLine
---@field kind differ.RailKind
---@field old integer|nil
---@field new integer|nil
---@field hunk integer|nil           -- index into DiffModel.hunks
---@field spans differ.SubSpan[]|nil -- word-level changed regions (old/new only)
---@field no_eol boolean|nil         -- a side's last line, with no newline after it

---@class differ.LineMap
---@field lines differ.RailLine[]          -- indexed by buffer lnum (1-based)
---@field from_old table<integer, integer> -- old lnum -> buffer lnum
---@field from_new table<integer, integer> -- new lnum -> buffer lnum
local LineMap = {}
LineMap.__index = LineMap

-- create an empty map for a renderer to populate
---@return differ.LineMap
function LineMap.new()
    return setmetatable({ lines = {}, from_old = {}, from_new = {} }, LineMap)
end

-- append a rail line and keep the reverse indices in sync
---@param line differ.RailLine
---@return integer buf_lnum
function LineMap:push(line)
    local lnum = #self.lines + 1
    self.lines[lnum] = line
    if line.old and (line.kind == "old" or line.kind == "context") then
        self.from_old[line.old] = lnum
    end
    if line.new and (line.kind == "new" or line.kind == "context") then
        self.from_new[line.new] = lnum
    end
    return lnum
end

-- number of derived-buffer lines
---@return integer
function LineMap:len()
    return #self.lines
end

return LineMap
