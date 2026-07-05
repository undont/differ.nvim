-- history panel: a sidebar listing commits, newest first. it owns *which
-- commit/file*; the View owns *how the diff renders*, so a selection re-sources the
-- single driven View (the separation the file panel uses). two modes:
--   file  — single-file history: each commit is one diff (commit vs its parent)
--   range — branch-range history: commits expand to their files (lazy); a file is
--           one diff. ]f/[f walk files across commits
-- commit-shaped, so it doesn't reuse panel/tree.lua; it keeps its own per-line meta

local set_wo = require("differ.util.win").set_local
local date_util = require("differ.util.date")
local bind = require("differ.util.keymap").bind

local ns = vim.api.nvim_create_namespace("differ.history")
local CTRL_D = vim.api.nvim_replace_termcodes("<C-d>", true, false, true)
local CTRL_U = vim.api.nvim_replace_termcodes("<C-u>", true, false, true)

local HEADER_LINES = 2 -- path/range + the "Help: g?" hint, before the commit rows
local AUTHOR_MAX = 18 -- cap the author column so a long name can't shove subjects off-screen

-- file-row status letter colours (mirrors the file panel's palette)
---@type table<string, string>
local STATUS_HL = {
    A = "differPanelAdd",
    M = "differPanelModify",
    D = "differPanelDelete",
    R = "differPanelRename",
    C = "differPanelRename",
    T = "differPanelModify",
}

---@type differ.History|nil -- the live history panel, for the runtime API
local current = nil

---@class differ.history.Meta
---@field kind "commit"|"file"
---@field ci integer            -- commit index
---@field fi integer|nil        -- file index within the commit (file rows)
---@field entry differ.FileEntry|nil

---@class differ.History
---@field bufnr integer
---@field winid integer|nil
---@field origin_win integer|nil
---@field return_tab integer|nil
---@field commits differ.git.Commit[]
---@field mode "file"|"range"
---@field index integer            -- selected commit
---@field file_index integer|nil   -- selected file within the commit (range mode)
---@field expanded table<string, boolean> -- per-sha fold state (range mode)
---@field files table<string, differ.FileEntry[]> -- per-sha lazy file cache (range)
---@field on_select fun(commit: differ.git.Commit)|nil   -- file mode
---@field expand fun(commit: differ.git.Commit): differ.FileEntry[]|nil -- range mode
---@field on_file fun(commit: differ.git.Commit, entry: differ.FileEntry)|nil -- range mode
---@field commit_message fun(commit: differ.git.Commit): string|nil -- full message for the details float
---@field on_close fun()|nil
---@field path string              -- file path (file mode) or range (range mode), for the header
---@field keymaps table<string, string|string[]|false>
---@field relative_dates boolean
---@field position string
---@field height integer
---@field width integer
---@field lines string[]
---@field meta (differ.history.Meta|false)[]
local History = {}
History.__index = History

---@class differ.history.Opts
---@field commits differ.git.Commit[]
---@field mode? "file"|"range"
---@field on_select? fun(commit: differ.git.Commit)
---@field expand? fun(commit: differ.git.Commit): differ.FileEntry[]
---@field on_file? fun(commit: differ.git.Commit, entry: differ.FileEntry)
---@field commit_message? fun(commit: differ.git.Commit): string -- full message for the details float
---@field on_close? fun()
---@field path string
---@field keymaps? table<string, string|string[]|false> -- resolved history action -> lhs
---@field relative_dates? boolean
---@field position? "bottom"|"top"|"left"|"right"
---@field height? integer
---@field width? integer

-- build a history panel (buffer only; the window is created on :open, so it's
-- headless-constructible for tests)
---@param opts differ.history.Opts
---@return differ.History
function History.new(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "differhistory"
    vim.bo[bufnr].modifiable = false
    if not pcall(vim.api.nvim_buf_set_name, bufnr, "differ://history") then
        pcall(vim.api.nvim_buf_set_name, bufnr, "differ://history#" .. bufnr)
    end
    return setmetatable({
        bufnr = bufnr,
        commits = opts.commits,
        mode = opts.mode or "file",
        index = 1,
        file_index = nil,
        expanded = {},
        files = {},
        on_select = opts.on_select,
        expand = opts.expand,
        on_file = opts.on_file,
        commit_message = opts.commit_message,
        on_close = opts.on_close,
        path = opts.path,
        keymaps = vim.tbl_extend(
            "force",
            require("differ.config").defaults.keymaps,
            opts.keymaps or {}
        ),
        relative_dates = opts.relative_dates or false,
        position = opts.position or "bottom",
        height = opts.height or 10,
        width = opts.width or 40,
        lines = {},
        meta = {},
    }, History)
end

-- continuation-line indent (two-line mode): line 2 sits this far past the sha so it
-- reads as a wrapped child of line 1
local CONT_INDENT = 2

-- truncate to `w` bytes, marking the cut with an ellipsis
---@param s string
---@param w integer
---@return string
local function truncate(s, w)
    if #s <= w then
        return s
    end
    return s:sub(1, w - 1) .. "…"
end

-- shift highlight span columns by `off` bytes (after prefixing a row), in place
---@param spans { [1]: integer, [2]: integer, [3]: string }[]
---@param off integer
---@return { [1]: integer, [2]: integer, [3]: string }[]
local function shift(spans, off)
    for _, s in ipairs(spans) do
        s[1], s[2] = s[1] + off, s[2] + off
    end
    return spans
end

---@class differ.history.CommitCell
---@field sha string
---@field date string
---@field author string
---@field add integer
---@field del integer
---@field subject string
---@field refs string|nil

-- assemble a commit row from its cells, left-aligned and padded to the shared
-- column widths. returns the body plus highlight spans ({ col, end_col, hl }); the
-- count cell colours its +N and -M apart, and refs (range mode) trail the subject
---@param cells differ.history.CommitCell
---@param w { sha: integer, date: integer, count: integer, author: integer }
---@return string body, { [1]: integer, [2]: integer, [3]: string }[] spans
local function build_commit(cells, w)
    local parts, spans, col = {}, {}, 0
    local function emit(text)
        parts[#parts + 1] = text
        col = col + #text
    end
    local function cell(text, width, hl)
        local start = col
        emit(text)
        spans[#spans + 1] = { start, col, hl }
        if #text < width then
            emit(string.rep(" ", width - #text))
        end
        emit("  ")
    end
    cell(cells.sha, w.sha, "differPanelDir")
    cell(cells.date, w.date, "differPanelHelp")
    local add, del = "+" .. cells.add, "-" .. cells.del
    local cs = col
    local astart = col
    emit(add)
    spans[#spans + 1] = { astart, col, "differPanelCountAdd" }
    emit(" ")
    local dstart = col
    emit(del)
    spans[#spans + 1] = { dstart, col, "differPanelCountDelete" }
    if col - cs < w.count then
        emit(string.rep(" ", w.count - (col - cs)))
    end
    emit("  ")
    cell(cells.author, w.author, "differHistoryAuthor")
    emit(cells.subject) -- subject takes the rest, default colour
    if cells.refs then
        emit("  ")
        local rstart = col
        emit(cells.refs)
        spans[#spans + 1] = { rstart, col, "differHistoryRef" }
    end
    return table.concat(parts), spans
end

-- two-line mode (narrow left/right panels): line 1 is the metadata
-- "<sha> <date>  +N -M  <author>", with the fixed-width sha/date/+N-M cells aligning
-- down the panel and the author trailing. the subject gets the whole continuation
-- line to itself. nothing is truncated: an overrun just clips at the window edge (no
-- ellipsis), and the full message is a keypress away in the details float
---@param cells differ.history.CommitCell
---@param w { sha: integer, date: integer }
---@return string body, { [1]: integer, [2]: integer, [3]: string }[] spans
local function build_meta_line(cells, w)
    local parts, spans, col = {}, {}, 0
    local function emit(text)
        parts[#parts + 1] = text
        col = col + #text
    end
    local function cell(text, width, hl)
        local start = col
        emit(text)
        spans[#spans + 1] = { start, col, hl }
        if #text < width then
            emit(string.rep(" ", width - #text))
        end
        emit("  ")
    end
    cell(cells.sha, w.sha, "differPanelDir")
    cell(cells.date, w.date, "differPanelHelp")
    local astart = col
    emit("+" .. cells.add)
    spans[#spans + 1] = { astart, col, "differPanelCountAdd" }
    emit(" ")
    local dstart = col
    emit("-" .. cells.del)
    spans[#spans + 1] = { dstart, col, "differPanelCountDelete" }
    emit("  ")
    local rstart = col
    emit(cells.author)
    spans[#spans + 1] = { rstart, col, "differHistoryAuthor" }
    return table.concat(parts), spans
end

-- two-line mode: the continuation line "<indent><subject> [refs]". the subject owns
-- the line; it isn't truncated, so a long subject just clips at the window edge
---@param cells differ.history.CommitCell
---@param indent integer
---@return string body, { [1]: integer, [2]: integer, [3]: string }[] spans
local function build_cont_line(cells, indent)
    local parts, spans, col = {}, {}, 0
    local function emit(text)
        parts[#parts + 1] = text
        col = col + #text
    end
    emit(string.rep(" ", indent))
    emit(cells.subject) -- subject, default colour
    if cells.refs then
        emit("  ")
        local rstart = col
        emit(cells.refs)
        spans[#spans + 1] = { rstart, col, "differHistoryRef" }
    end
    return table.concat(parts), spans
end

-- assemble a nested file row (range mode): "<status> <path>  +N -M"
---@param entry differ.FileEntry
---@return string body, { [1]: integer, [2]: integer, [3]: string }[] spans
local function build_file(entry)
    local parts, spans, col = {}, {}, 0
    local function emit(text)
        parts[#parts + 1] = text
        col = col + #text
    end
    spans[#spans + 1] = { col, col + #entry.status, STATUS_HL[entry.status] or "differPanelModify" }
    emit(entry.status)
    emit(" ")
    emit(entry.path)
    emit("  ")
    local add = "+" .. entry.additions
    spans[#spans + 1] = { col, col + #add, "differPanelCountAdd" }
    emit(add)
    emit(" ")
    local del = "-" .. entry.deletions
    spans[#spans + 1] = { col, col + #del, "differPanelCountDelete" }
    emit(del)
    return table.concat(parts), spans
end

---@param ci integer
---@return boolean
function History:_is_expanded(ci)
    return self.expanded[self.commits[ci].sha] == true
end

---@param ci integer
---@param v boolean
function History:_set_expanded(ci, v)
    self.expanded[self.commits[ci].sha] = v or nil
end

-- the (lazily loaded, cached) file list for commit `ci` (range mode)
---@param ci integer
---@return differ.FileEntry[]
function History:_files(ci)
    local sha = self.commits[ci].sha
    if not self.files[sha] then
        self.files[sha] = (self.expand and self.expand(self.commits[ci])) or {}
    end
    return self.files[sha]
end

-- repaint the buffer and rebuild the line meta: a two-line header then one row per
-- commit (sha · date · +N/-M · author · subject). top/bottom panels fit the row on
-- one line; narrow left/right panels split it across two (grid line + author/subject).
-- range mode adds fold arrows, optional ref tags, and the expanded commits' files beneath
function History:render()
    local cells, w = {}, { sha = 0, date = 0, count = 0, author = 0 }
    for _, c in ipairs(self.commits) do
        local cell = {
            sha = c.short,
            date = date_util.format(c.epoch, { relative = self.relative_dates }),
            author = truncate(c.author, AUTHOR_MAX),
            add = c.additions,
            del = c.deletions,
            subject = c.subject,
            refs = (self.mode == "range" and c.refs ~= "") and c.refs or nil,
        }
        cells[#cells + 1] = cell
        w.sha = math.max(w.sha, #cell.sha)
        w.date = math.max(w.date, #cell.date)
        w.count = math.max(w.count, #("+" .. cell.add .. " -" .. cell.del))
        w.author = math.max(w.author, #cell.author)
    end

    -- vertical (left/right) panels are too narrow for the full row, so each commit
    -- spans two lines: the fixed-width sha/date/+N-M grid + author, then the subject
    -- beneath. top/bottom keep the single line. nothing truncates; an overrun clips
    -- at the window edge
    local two_line = self.position == "left" or self.position == "right"

    local lines, meta, spans_by_line = { self.path, "Help: g?" }, { false, false }, {}
    local function push(line, m, spans)
        lines[#lines + 1] = line
        meta[#meta + 1] = m
        spans_by_line[#lines] = spans
    end
    -- render one commit's row(s): a single line, or the two-line variant. range mode
    -- prepends the fold arrow to the first line; the continuation indents past it. both
    -- physical lines carry the same commit meta, so the cursor selects from either
    ---@param ci integer
    ---@param cell differ.history.CommitCell
    local function push_commit(ci, cell)
        local arrow = self.mode == "range" and ((self:_is_expanded(ci) and "▾" or "▸") .. " ")
            or ""
        local m = { kind = "commit", ci = ci }
        if two_line then
            local l1, s1 = build_meta_line(cell, w)
            if arrow ~= "" then
                shift(s1, #arrow)
                table.insert(s1, 1, { 0, #arrow - 1, "differPanelHelp" })
            end
            push(arrow .. l1, m, s1)
            -- the fold arrow is one display cell + a space, but multibyte; indent the
            -- continuation by display width (not byte length) so it aligns under the sha
            local arrow_cols = arrow == "" and 0 or 2
            local l2, s2 = build_cont_line(cell, arrow_cols + CONT_INDENT)
            push(l2, m, s2)
        else
            local body, spans = build_commit(cell, w)
            if arrow ~= "" then
                shift(spans, #arrow)
                table.insert(spans, 1, { 0, #arrow - 1, "differPanelHelp" }) -- the fold arrow
            end
            push(arrow .. body, m, spans)
        end
    end
    for ci, cell in ipairs(cells) do
        push_commit(ci, cell)
        if self.mode == "range" and self:_is_expanded(ci) then
            for fi, entry in ipairs(self:_files(ci)) do
                local fbody, fspans = build_file(entry)
                shift(fspans, 4)
                push("    " .. fbody, { kind = "file", ci = ci, fi = fi, entry = entry }, fspans)
            end
        end
    end
    self.lines, self.meta = lines, meta

    vim.bo[self.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    vim.bo[self.bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
    local function paint(row, col, end_col, hl)
        vim.api.nvim_buf_set_extmark(self.bufnr, ns, row, col, { end_col = end_col, hl_group = hl })
    end
    paint(0, 0, #lines[1], "differPanelRoot")
    paint(1, 0, #lines[2], "differPanelHelp")
    for lnum = HEADER_LINES + 1, #lines do
        for _, s in ipairs(spans_by_line[lnum] or {}) do
            paint(lnum - 1, s[1], s[2], s[3])
        end
    end
end

-- a non-history window to render diffs in: the origin window if still valid, else
-- any other window, else a fresh split carved off this panel (mirrors the panel)
---@return integer
function History:_ensure_origin()
    if
        self.origin_win
        and self.origin_win ~= self.winid
        and vim.api.nvim_win_is_valid(self.origin_win)
    then
        return self.origin_win
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= self.winid then
            self.origin_win = w
            return w
        end
    end
    vim.api.nvim_set_current_win(self.winid)
    vim.cmd("aboveleft split")
    self.origin_win = vim.api.nvim_get_current_win()
    return self.origin_win
end

-- move the panel cursor to `lnum` (clamped/guarded), without changing focus
---@param lnum integer|nil
function History:_move_cursor(lnum)
    if lnum and self:is_open() then
        pcall(vim.api.nvim_win_set_cursor, self.winid, { lnum, 0 })
    end
end

-- the meta record under the cursor, or nil on a header row
---@return differ.history.Meta|nil
function History:_cursor_meta()
    local m = self.winid and self.meta[vim.api.nvim_win_get_cursor(self.winid)[1]]
    return m or nil
end

-- buffer line of a commit / file row, found via the meta (range rows aren't contiguous)
---@param ci integer
---@return integer|nil
function History:_commit_line(ci)
    for i, m in ipairs(self.meta) do
        if m and m.kind == "commit" and m.ci == ci then
            return i
        end
    end
end

---@param ci integer
---@param fi integer
---@return integer|nil
function History:_file_line(ci, fi)
    for i, m in ipairs(self.meta) do
        if m and m.kind == "file" and m.ci == ci and m.fi == fi then
            return i
        end
    end
end

-- file mode: render commit `i`'s diff in the main window. by default focus returns
-- to the panel; `keep_focus` leaves it in the diff window (in-view ]f/[f stepping)
---@param i integer
---@param keep_focus boolean|nil
function History:_open(i, keep_focus)
    self.index = i
    vim.api.nvim_set_current_win(self:_ensure_origin())
    self.on_select(self.commits[i])
    if not keep_focus and self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_set_current_win(self.winid)
    end
end

-- range mode: render the `fi`-th file of commit `ci` (expanding the commit first so
-- the row is visible), parking the panel cursor on it. `keep_focus` keeps focus in
-- the diff window
---@param ci integer
---@param fi integer
---@param keep_focus boolean|nil
function History:_open_file(ci, fi, keep_focus)
    self:_set_expanded(ci, true)
    local files = self:_files(ci)
    if #files == 0 then
        return
    end
    fi = math.max(1, math.min(fi, #files))
    self.index, self.file_index = ci, fi
    self:render()
    self:_move_cursor(self:_file_line(ci, fi))
    vim.api.nvim_set_current_win(self:_ensure_origin())
    self.on_file(self.commits[ci], files[fi])
    if not keep_focus and self:is_open() then
        vim.api.nvim_set_current_win(self.winid)
    end
end

-- <CR>/o: file mode opens the commit under the cursor; range mode toggles a commit's
-- fold (no diff opened) or opens the file under the cursor, mirroring the file panel
---@param keep_focus boolean|nil
function History:select(keep_focus)
    local m = self:_cursor_meta()
    if not m then
        return
    end
    if self.mode == "file" then
        return self:_open(m.ci, keep_focus)
    end
    if m.kind == "commit" then
        self:toggle_fold()
    else
        self:_open_file(m.ci, m.fi, keep_focus)
    end
end

-- za: toggle the fold of the commit under the cursor (or the file row's parent
-- commit), keeping the cursor on the commit line. range mode only
function History:toggle_fold()
    local m = self:_cursor_meta()
    if not m then
        return
    end
    self:_set_expanded(m.ci, not self:_is_expanded(m.ci))
    self:render()
    self:_move_cursor(self:_commit_line(m.ci))
end

-- c: collapse the commit under the cursor (or the parent commit of a file row),
-- landing the cursor on it. range mode only, mirroring the file panel's close_node
function History:close_node()
    local m = self:_cursor_meta()
    if not m then
        return
    end
    self:_set_expanded(m.ci, false)
    self:render()
    self:_move_cursor(self:_commit_line(m.ci))
end

-- O / C: expand or collapse every commit's files, keeping the cursor on its commit.
-- expand-all lazily loads each commit's file list. range mode only
---@param collapsed boolean
function History:set_all_folds(collapsed)
    local m = self:_cursor_meta()
    local ci = (m and m.ci) or self.index
    for i = 1, #self.commits do
        self:_set_expanded(i, not collapsed)
    end
    self:render()
    self:_move_cursor(self:_commit_line(ci))
end

-- ]] / [[: move the cursor to the next/previous commit header without opening it. in
-- range mode this skips file rows; in file mode every row is already a commit. [[ from
-- below a commit's header (a file row or its continuation line) lands on that header
-- first, only stepping to the previous commit once the cursor is already on it
---@param direction "next"|"prev"
function History:step_commit(direction)
    local m = self:_cursor_meta()
    local ci = (m and m.ci) or self.index
    if direction == "prev" then
        local header = self:_commit_line(ci)
        local cur = self:is_open() and vim.api.nvim_win_get_cursor(self.winid)[1]
        if header and cur and cur > header then
            return self:_move_cursor(header)
        end
        ci = ci - 1
    else
        ci = ci + 1
    end
    if ci < 1 or ci > #self.commits then
        return
    end
    self:_move_cursor(self:_commit_line(ci))
end

-- gg / G: move the cursor to the first / last commit without opening it
---@param edge "first"|"last"
function History:cursor_to_edge(edge)
    self:_move_cursor(self:_commit_line(edge == "first" and 1 or #self.commits))
end

-- ]f / [f. file mode: step to the next/previous commit. range mode: step file rows,
-- crossing into the adjacent commit (auto-expanded) at a boundary. `keep_focus`
-- keeps focus in the diff window (in-view stepping). returns whether it actually
-- stepped (false at the first/last commit or file row)
---@param direction "next"|"prev"
---@param keep_focus boolean|nil
---@return boolean moved
function History:step(direction, keep_focus)
    local fwd = direction == "next"
    if self.mode == "file" then
        local i = self.index + (fwd and 1 or -1)
        if i < 1 or i > #self.commits then
            return false
        end
        self:_move_cursor(self:_commit_line(i))
        self:_open(i, keep_focus)
        return true
    end

    local ci = self.index
    local fi = (self.file_index or 1) + (fwd and 1 or -1)
    if fi >= 1 and fi <= #self:_files(ci) then
        self:_open_file(ci, fi, keep_focus)
        return true
    end
    -- crossed the commit boundary: find the adjacent commit that has files
    local step = fwd and 1 or -1
    local ti = ci + step
    while ti >= 1 and ti <= #self.commits do
        local files = self:_files(ti)
        if #files > 0 then
            self:_open_file(ti, fwd and 1 or #files, keep_focus)
            return true
        end
        ti = ti + step
    end
    return false
end

-- ]c / [c overflow (the goto_hunk fallback): step to the next/prev file within
-- the current commit only, stopping at its edges rather than crossing into the
-- adjacent commit like ]f / [f does. range mode only; file mode has no
-- sub-commit files to step through, so it's always a no-op there
---@param direction "next"|"prev"
---@param keep_focus boolean|nil
---@return boolean moved
function History:step_within_commit(direction, keep_focus)
    if self.mode ~= "range" then
        return false
    end
    local fi = (self.file_index or 1) + (direction == "next" and 1 or -1)
    if fi < 1 or fi > #self:_files(self.index) then
        return false
    end
    self:_open_file(self.index, fi, keep_focus)
    return true
end

-- goto_hunk's fallback at a hunk-nav boundary, shared by the diff window's own
-- ]c/[c (view.lua) and the history panel's copy: steps within the current commit,
-- then (stepping backward, having landed on a different file) focuses that file's
-- last hunk so the flow continues the same way the panel's does. at the commit's own
-- edge (file mode has none to step to; range mode's file list is exhausted), notifies
-- with the commit-specific wording instead of falling through to goto_hunk's generic
-- "no next/previous hunk" — always handled here, so the caller never notifies itself
---@param direction "next"|"prev"
---@param view differ.View|nil the driven view, to focus its last hunk going backward
---@return true handled -- goto_hunk should not also notify
function History:goto_hunk_fallback(direction, view)
    if self:step_within_commit(direction, true) then
        if direction == "prev" and view then
            view:_focus_last_hunk()
        end
        return true
    end
    vim.notify(
        direction == "next" and "differ: no more hunks in this commit"
            or "differ: no previous hunks in this commit",
        vim.log.levels.INFO
    )
    return true
end

-- scroll the *diff view* a quarter page (the origin window), not the panel list,
-- mirroring the file panel (default f / b)
---@param direction "down"|"up"
function History:scroll(direction)
    local win = self.origin_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local n = math.max(1, math.floor(vim.api.nvim_win_get_height(win) / 4))
    vim.api.nvim_win_call(win, function()
        vim.cmd("normal! " .. n .. (direction == "down" and CTRL_D or CTRL_U))
    end)
end

-- g?: a floating keymap cheatsheet, dismissed with <Esc> / q / g?
function History:show_help()
    local lines = {}
    if self.mode == "range" then
        vim.list_extend(lines, {
            " <CR> / o   toggle fold / open file",
            " za         toggle fold",
            " O / C      expand / collapse all",
            " c          collapse commit",
            " ]f / [f    next / previous file",
            " ]] / [[    next / previous commit",
            " gg / G     first / last commit",
        })
    else
        vim.list_extend(lines, {
            " <CR> / o   show commit",
            " ]f / [f    next / previous commit",
            " ]] / [[    move between commits",
            " gg / G     first / last commit",
        })
    end
    vim.list_extend(lines, {
        " ]c / [c    next / previous hunk",
        " f / b      scroll diff down / up",
        " K          commit details",
        " g?         this help",
    })
    require("differ.ui.help").show(lines, { title = " Differ: history " })
end

-- K: float the full commit message (subject + body) plus author/date for the commit
-- under the cursor, so a subject the narrow list clipped is still fully readable.
-- dismissed with q / <Esc>
function History:show_details()
    local m = self:_cursor_meta()
    if not m then
        return
    end
    local c = self.commits[m.ci]
    local lines = {
        (" %s  %s  %s"):format(c.short, c.author, date_util.format(c.epoch, { relative = false })),
    }
    if c.refs and c.refs ~= "" then
        lines[#lines + 1] = " " .. c.refs
    end
    lines[#lines + 1] = ""
    local msg = (self.commit_message and self.commit_message(c)) or c.subject
    for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
        lines[#lines + 1] = " " .. l
    end
    require("differ.ui.help").show(lines, { title = " Differ: commit " })
end

-- window appearance + buffer-local keymaps
function History:_setup_window()
    local win = self.winid
    set_wo(win, "number", false)
    set_wo(win, "relativenumber", false)
    set_wo(win, "signcolumn", "no")
    set_wo(win, "foldcolumn", "0")
    set_wo(win, "wrap", false)
    set_wo(win, "cursorline", true)
    if self.position == "left" or self.position == "right" then
        set_wo(win, "winfixwidth", true)
    else
        set_wo(win, "winfixheight", true)
    end

    local km = self.keymaps
    local function map(spec, fn, desc)
        bind(self.bufnr, spec, fn, "differ history: " .. desc)
    end
    local item = self.mode == "range" and "file" or "commit"
    map(km.select, function()
        self:select()
    end, "open " .. item)
    map(km.next_file, function()
        self:step("next")
    end, "next " .. item)
    map(km.prev_file, function()
        self:step("prev")
    end, "previous " .. item)
    map(km.next_section, function()
        self:step_commit("next")
    end, "next commit")
    map(km.prev_section, function()
        self:step_commit("prev")
    end, "previous commit")
    map(km.first_file, function()
        self:cursor_to_edge("first")
    end, "first commit")
    map(km.last_file, function()
        self:cursor_to_edge("last")
    end, "last commit")
    if self.mode == "range" then
        map(km.toggle_fold, function()
            self:toggle_fold()
        end, "toggle fold")
        map(km.close_node, function()
            self:close_node()
        end, "collapse commit")
        map(km.close_all, function()
            self:set_all_folds(true)
        end, "collapse all commits")
        map(km.open_all, function()
            self:set_all_folds(false)
        end, "expand all commits")
    end
    -- past the last/first hunk: overflow into the next/prev file within the commit
    -- (range mode; file mode's fallback is always a no-op, so it just stops)
    local function hunk_fallback(direction)
        return self:goto_hunk_fallback(direction, require("differ").active_view())
    end
    map(km.next_hunk, function()
        require("differ").goto_hunk("next", { fallback = hunk_fallback })
    end, "next hunk")
    map(km.prev_hunk, function()
        require("differ").goto_hunk("prev", { fallback = hunk_fallback })
    end, "previous hunk")
    map(km.details, function()
        self:show_details()
    end, "commit details")
    map(km.help, function()
        self:show_help()
    end, "help")
    map(km.scroll_down, function()
        self:scroll("down")
    end, "scroll down a quarter page")
    map(km.scroll_up, function()
        self:scroll("up")
    end, "scroll up a quarter page")
end

-- create the split in the configured position, bind the buffer, set window opts
function History:_open_window()
    if self.position == "top" then
        vim.cmd(("topleft %dsplit"):format(self.height))
    elseif self.position == "left" then
        vim.cmd(("topleft %dvsplit"):format(self.width))
    elseif self.position == "right" then
        vim.cmd(("botright %dvsplit"):format(self.width))
    else -- bottom (default)
        vim.cmd(("botright %dsplit"):format(self.height))
    end
    self.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winid, self.bufnr)
    self:_setup_window()
end

-- open the panel, render, select the newest commit (range: expand it + open its
-- first file), and by default land the cursor in the diff. returns self
---@param keep_focus boolean|nil  -- leave focus in the diff window (default true)
---@return differ.History
function History:open(keep_focus)
    self.origin_win = vim.api.nvim_get_current_win()
    self:_open_window()
    current = self
    if self.mode == "range" then
        self:_set_expanded(1, true)
        self:render()
        self:_open_file(1, 1, keep_focus ~= false)
    else
        self:render()
        self:_move_cursor(self:_commit_line(1))
        self:_open(1, keep_focus ~= false)
    end
    return self
end

---@return boolean
function History:is_open()
    return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

-- close the panel window but keep the buffer + state (for repositioning)
function History:_close_window()
    if self:is_open() then
        pcall(vim.api.nvim_win_close, self.winid, true)
    end
    self.winid = nil
end

-- close the panel window, wipe its buffer, and tear down the driven view via
-- on_close. ends the history session
function History:close()
    self:_close_window()
    if vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
    if current == self then
        current = nil
    end
    if self.on_close then
        self.on_close()
    end
end

-- move the history panel to a new edge live, preserving the buffer, commit/fold
-- state, the driven view, and the main (origin) window. mirrors Panel:set_position
---@param position "bottom"|"top"|"left"|"right"
function History:set_position(position)
    self.position = position
    if not self:is_open() then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
    local origin = self.origin_win
    self:_close_window()
    if origin and vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
    end
    self:_open_window()
    self.origin_win = origin
    self:render()
    self:_move_cursor(lnum)
end

-- flip absolute <-> relative dates live, keeping the cursor put (runtime control;
-- the default comes from config.relative_dates)
function History:toggle_relative_dates()
    self.relative_dates = not self.relative_dates
    if self:is_open() then
        local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
        self:render()
        pcall(vim.api.nvim_win_set_cursor, self.winid, { lnum, 0 })
    end
end

-- the live history panel, if one is open
---@return differ.History|nil
function History.current()
    return current
end

return History
