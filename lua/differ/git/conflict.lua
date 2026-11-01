-- pure parser for git conflict markers in a working-tree file. no nvim API,
-- so it runs under test/unit. recognises the default `merge` style (ours/theirs only)
-- and `diff3`/`zdiff3` (a base slab between ||||||| and =======). a marker line is
-- git's `diff --check` shape: exactly `size` marker chars (the path's
-- `conflict-marker-size` attribute, 7 by default), then whitespace or end of line. the
-- ref label after them is ignored

---@class differ.merge.Region
---@field index integer         -- 1-based, conflict order in the file
---@field result_start integer  -- line of the `<<<<<<<` marker (1-based)
---@field result_end integer    -- line of the `>>>>>>>` marker
---@field mark_base integer|nil -- line of the `|||||||` marker (diff3/zdiff3 only)
---@field mark_sep integer      -- line of the `=======` marker
---@field label_ours string     -- ref label after `<<<<<<<` (e.g. "HEAD")
---@field label_theirs string   -- ref label after `>>>>>>>` (e.g. "feature")
---@field ours string[]         -- ours slab (<<<<<<< .. ||||||| / =======)
---@field base string[]|nil     -- base slab (||||||| .. =======), nil under default style
---@field theirs string[]       -- theirs slab (======= .. >>>>>>>)

local M = {}

local DEFAULT_SIZE = 7

---@param line string
---@param ch string  -- the marker char
---@param size integer
---@return boolean
local function marker(line, ch, size)
    if line:sub(1, size) ~= ch:rep(size) then
        return false
    end
    return #line == size or line:sub(size + 1, size + 1):match("%s") ~= nil
end

-- the ref label after a marker's chars, trimmed. `=======` carries none
---@param line string
---@param size integer
---@return string
local function label(line, size)
    return (line:sub(size + 1):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- parse line-split file content into ordered conflict regions. an unterminated region
-- (EOF before `>>>>>>>`, which git never emits) is discarded rather than half-emitted,
-- and a stray `<<<<<<<` inside a region counts as content (markers don't nest)
---@param lines string[]
---@param size integer|nil  -- marker length, 7 when nil
---@return differ.merge.Region[]
function M.parse(lines, size)
    size = size or DEFAULT_SIZE
    local regions = {}
    local cur, slot
    for lnum, line in ipairs(lines) do
        if not cur then
            if marker(line, "<", size) then
                cur =
                    { result_start = lnum, label_ours = label(line, size), ours = {}, theirs = {} }
                slot = "ours"
            end
        elseif slot == "ours" and marker(line, "|", size) then
            cur.base = {}
            cur.mark_base = lnum
            slot = "base"
        elseif (slot == "ours" or slot == "base") and marker(line, "=", size) then
            cur.mark_sep = lnum
            slot = "theirs"
        elseif slot == "theirs" and marker(line, ">", size) then
            cur.result_end = lnum
            cur.label_theirs = label(line, size)
            cur.index = #regions + 1
            regions[#regions + 1] = cur
            cur, slot = nil, nil
        else
            local slab = slot == "ours" and cur.ours or slot == "base" and cur.base or cur.theirs
            slab[#slab + 1] = line
        end
    end
    return regions
end

-- line numbers of the marker lines no parsed region uses, ascending. covers a region
-- missing one of its markers and a stray marker inside a complete region
---@param lines string[]
---@param size integer|nil  -- marker length, 7 when nil
---@return integer[]
function M.orphans(lines, size)
    size = size or DEFAULT_SIZE
    local used = {}
    for _, r in ipairs(M.parse(lines, size)) do
        used[r.result_start] = true
        used[r.result_end] = true
        used[r.mark_sep] = true
        if r.mark_base then
            used[r.mark_base] = true
        end
    end
    local found = {}
    for lnum, line in ipairs(lines) do
        local ch = line:sub(1, 1)
        local is_marker = (ch == "<" or ch == "|" or ch == "=" or ch == ">")
            and marker(line, ch, size)
        if is_marker and not used[lnum] then
            found[#found + 1] = lnum
        end
    end
    return found
end

-- a clean conflict marker sits at column 0; a format-on-save that ignores the buffer's
-- disable_autoformat opt-out reflows the whole region and indents the markers with it. the
-- parser then can't see the region (it matches at column 0), so it would read as resolved
-- and stage a file that still has markers. an indented <<<<<<< / >>>>>>> run is the tell;
-- `<`/`>` only, since a stray indented ======= can be decorative
---@param lines string[]
---@return boolean
function M.reformatted(lines)
    for _, line in ipairs(lines) do
        local ch = line:match("^%s+([<>])")
        if ch then
            local run = line:match("^%s+(%" .. ch .. "+)")
            if run and #run >= 7 then
                return true
            end
        end
    end
    return false
end

return M
