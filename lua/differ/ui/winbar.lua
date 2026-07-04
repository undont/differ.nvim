-- winbar widgets: the diff window's hunk counter and the file panel's progress
-- meter. both are `%!` winbar expressions, so they redraw on cursor move with no
-- autocmds; each reads g:statusline_winid (set during winbar eval) to find its window

local M = {}

-- nvim-web-devicons doubles as the "user has a nerd font" signal (the panel keys its
-- file icons off the same presence). cached once: the winbar re-evals on every redraw
local has_nerd = pcall(require, "nvim-web-devicons")
-- the hunk-counter marker: a git "diff" glyph (nf-oct-diff) when a nerd font is
-- available, else a plain diamond that renders everywhere
local HUNK_MARK = has_nerd and vim.fn.nr2char(0xf440) or "◆"

-- escape statusline-special percent signs in interpolated text (a path can hold one)
---@param s string
---@return string
local function esc(s)
    return (s:gsub("%%", "%%%%"))
end

-- the 1-based hunk the cursor sits in or just past: the count of hunk blocks
-- starting at or before `lnum`, so a trailing-context line still reads as its hunk
---@param map differ.LineMap
---@param lnum integer
---@return integer
function M.hunk_at(map, lnum)
    local k, prev = 0, nil
    for i = 1, math.min(lnum, #map.lines) do
        local h = map.lines[i].hunk
        if h and h ~= prev then
            k = k + 1
        end
        prev = h
    end
    return k
end

-- diff-window winbar: "<file>  <mark> hunk K/N", file on the left, the hunk count
-- right-aligned (the marker is a nerd git-diff glyph, else a plain diamond). empty
-- when the drawn window isn't a differ diff
---@return string
function M.diff()
    local win = vim.g.statusline_winid
    if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
        return ""
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local view = require("differ.view").for_buf(buf)
    if not view then
        return ""
    end
    local map
    for _, c in ipairs(view.columns) do
        if c.bufnr == buf then
            map = c.map
            break
        end
    end
    if not map then
        return ""
    end
    if view.model.binary then
        return (" %s %%=binary "):format(esc(vim.fn.fnamemodify(view.model.path, ":t")))
    end
    local total = #view.model.hunks
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local k = math.max(M.hunk_at(map, lnum), total > 0 and 1 or 0)
    -- a pending-review badge when this is a PR diff with an active draft, right-aligned
    -- next to the hunk counter in a bold warning colour so the draft state stands out
    -- while reviewing (not just in the compose window)
    local draft = require("differ.pr").review_status(buf)
    local badge = draft and ("%#differReviewDraft#● " .. draft .. "%*   ") or ""
    return (" %s %%=%s%s hunk %d/%d "):format(
        esc(vim.fn.fnamemodify(view.model.path, ":t")),
        badge,
        HUNK_MARK,
        k,
        total
    )
end

-- panel winbar: a bar plus "file K/N" for the cursor's position in the file list
---@return string
function M.panel()
    local win = vim.g.statusline_winid
    if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
        return ""
    end
    local panel = require("differ.panel").current()
    if not (panel and panel.winid == win) then
        return ""
    end
    -- total = every file in the change set (fold-independent), not just the rows
    -- currently visible; idx = the fold-independent number of the file at/before the
    -- cursor, so the meter stays accurate when dirs are collapsed
    local total = panel.file_total or 0
    if total == 0 then
        return ""
    end
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    local idx
    for i = math.min(cur, #panel.meta), 1, -1 do
        local m = panel.meta[i]
        if m and m.kind == "file" then
            idx = m.file_index
            break
        end
    end
    idx = math.max(idx or 1, 1)
    local width = 12
    local filled = math.floor(width * idx / total + 0.5)
    local bar = string.rep("█", filled) .. string.rep("░", width - filled)
    return (" ▕%s▏ file %d/%d "):format(bar, idx, total)
end

return M
