-- pure parser for git conflict markers in a working-tree file. no nvim API,
-- so it runs under test/unit. recognises the default `merge` style (ours/theirs only)
-- and `diff3`/`zdiff3` (a base slab between ||||||| and =======). marker lines are
-- matched on their leading 7-char run, the ref label after them ignored

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

---@param line string
---@param ch string  -- the marker char
---@return boolean
local function marker(line, ch)
    return line:sub(1, 7) == ch:rep(7)
end

-- the ref label after a marker's 7 chars, trimmed. `=======` carries none. pure
---@param line string
---@return string
local function label(line)
    return (line:sub(8):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- parse line-split file content into ordered conflict regions. an unterminated region
-- (EOF before `>>>>>>>`, which git never emits) is discarded rather than half-emitted,
-- and a stray `<<<<<<<` inside a region counts as content (markers don't nest)
---@param lines string[]
---@return differ.merge.Region[]
function M.parse(lines)
    local regions = {}
    local cur, slot
    for lnum, line in ipairs(lines) do
        if not cur then
            if marker(line, "<") then
                cur = { result_start = lnum, label_ours = label(line), ours = {}, theirs = {} }
                slot = "ours"
            end
        elseif slot == "ours" and marker(line, "|") then
            cur.base = {}
            cur.mark_base = lnum
            slot = "base"
        elseif (slot == "ours" or slot == "base") and marker(line, "=") then
            cur.mark_sep = lnum
            slot = "theirs"
        elseif slot == "theirs" and marker(line, ">") then
            cur.result_end = lnum
            cur.label_theirs = label(line)
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
