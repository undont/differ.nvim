-- dual-rail gutter: a statuscolumn function reading the active buffer's line map
-- map lookup is O(1); rail strings are pre-formatted at render time

local M = {}

local STAGED_GLYPH = "▌"
local HIDDEN_GLYPH = "!"

---@type table<integer, string[]> -- bufnr -> pre-formatted rail string per lnum
local rails = {}

---@type table<integer, table<integer, boolean>> -- bufnr -> set of staged lnums
local staged = {}

---@type table<integer, table<integer, boolean>> -- bufnr -> lnums opening a hunk marked `!`
local hidden = {}

-- pre-format the gutter string for every line of a column from its map. pure, so
-- the statuscolumn callback only does an O(1) index per redraw. a unified
-- column shows both rails (old left / new right); a side column shows only its
-- own number; absent sides and meta/filler rows render as blanks
---@param column differ.Column
---@return string[]
function M.format(column)
    local lines = column.map.lines
    local wo, wn = 1, 1
    for _, l in ipairs(lines) do
        if l.old then
            wo = math.max(wo, #tostring(l.old))
        end
        if l.new then
            wn = math.max(wn, #tostring(l.new))
        end
    end
    local function cell(num, width)
        if not num then
            return string.rep(" ", width)
        end
        local s = tostring(num)
        return string.rep(" ", width - #s) .. s
    end
    local out = {}
    for i, l in ipairs(lines) do
        if column.side == "old" then
            out[i] = cell(l.old, wo) .. " "
        elseif column.side == "new" then
            out[i] = cell(l.new, wn) .. " "
        else
            out[i] = cell(l.old, wo) .. " " .. cell(l.new, wn) .. " "
        end
    end
    return out
end

-- store pre-formatted rail strings for a buffer after a render
---@param bufnr integer
---@param strings string[]
function M.set(bufnr, strings)
    rails[bufnr] = strings
end

-- register a buffer's staged lines (hunk staging). presence of an entry (even
-- empty) reserves a one-cell staged gutter so the rail width is stable as hunks
-- toggle; the glyph paints on staged lines. unset for non-staging views
---@param bufnr integer
---@param lines table<integer, boolean>|nil
function M.set_staged(bufnr, lines)
    staged[bufnr] = lines
end

-- register the lines that open a hunk marked `!`; they take the staged cell's place
---@param bufnr integer
---@param lines table<integer, boolean>|nil
function M.set_hidden(bufnr, lines)
    hidden[bufnr] = lines
end

-- drop a buffer's cached rail strings
---@param bufnr integer
function M.clear(bufnr)
    rails[bufnr] = nil
    staged[bufnr] = nil
    hidden[bufnr] = nil
end

-- statuscolumn callback: return the rail string for the current line, prefixed by
-- the staged-gutter cell when this is a staging-capable view
---@return string
function M.render()
    -- virtual lines (our thread overlay's virt_lines) reuse the anchor's lnum; without
    -- this they'd echo the anchor's gutter number. v:virtnum is non-zero on them
    if vim.v.virtnum ~= 0 then
        return ""
    end
    local buf = vim.g.statusline_winid and vim.api.nvim_win_get_buf(vim.g.statusline_winid)
    local cache = buf and rails[buf]
    if not cache then
        return ""
    end
    local s = cache[vim.v.lnum] or ""
    local sset = buf and staged[buf]
    if not sset then
        return s
    end
    local hset = hidden[buf]
    if hset and hset[vim.v.lnum] then
        return "%#differHiddenSign#" .. HIDDEN_GLYPH .. "%*" .. s
    end
    return (sset[vim.v.lnum] and ("%#differStagedSign#" .. STAGED_GLYPH .. "%*") or " ") .. s
end

return M
