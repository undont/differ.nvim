-- inline thread overlay: fetch the PR's review threads once per session, anchor
-- each to a derived buffer row through the line map, stack same-row threads oldest
-- first, and paint them as extmark `virt_lines` below the anchor (plus a range
-- background for multi-line threads). the overlay is extmark-only: it never touches the
-- map and never re-renders the buffer, so a refresh just re-applies marks. the pure
-- bits (side, anchor row, stacking) are split out for unit tests; apply/refresh own the
-- vim surface

local client = require("differ.pr.client")
local thread_ui = require("differ.ui.thread")

local M = {}

-- lazy so the module loads under busted (no nvim runtime) for the pure-helper tests;
-- the namespace is only ever needed once apply/refresh run inside nvim
local ns
local function namespace()
    ns = ns or vim.api.nvim_create_namespace("differ.pr.threads")
    return ns
end

-- ── pure helpers (unit-tested) ──────────────────────────────────────────────────

-- github anchors a thread on a side; map LEFT/RIGHT to the column side the line map
-- keys on (from_old / from_new)
---@param t table
---@return "old"|"new"
function M.side_of(t)
    return t.side == "LEFT" and "old" or "new"
end

-- the derived buffer row for source line `line` in `index` (a from_old/from_new map).
-- an out-of-context anchor (no exact key) degrades to the nearest rendered line rather
-- than being dropped; nil only when nothing is rendered on that side
---@param index table<integer, integer>
---@param line integer
---@return integer|nil
function M.anchor_row(index, line)
    if index[line] then
        return index[line]
    end
    local best_dist, best_row
    for ln, row in pairs(index) do
        local dist = math.abs(ln - line)
        if not best_dist or dist < best_dist or (dist == best_dist and row < best_row) then
            best_dist, best_row = dist, row
        end
    end
    return best_row
end

-- a thread's ordering key: its first comment's creation time. ISO-8601/RFC3339 UTC
-- sorts lexically as chronologically, so a string compare is the explicit oldest-first
-- order (never trust API order)
---@param t table
---@return string
local function created_key(t)
    local first = (t.comments or {})[1]
    return (first and first.created_at) or ""
end

-- sort threads sharing a row oldest first, in place; returns the list for chaining
---@param threads table[]
---@return table[]
function M.stack_sort(threads)
    table.sort(threads, function(a, b)
        return created_key(a) < created_key(b)
    end)
    return threads
end

-- ── state ───────────────────────────────────────────────────────────────────────

-- a thread's effective collapsed state: an explicit per-thread toggle wins (gc, slice
-- 3); otherwise threads collapse by default and only expand while their anchor row is
-- under the cursor (peek), so the file stays scannable
---@param session table
---@param t table
---@param group_active boolean  -- the cursor is on this thread's anchor row
---@return boolean
local function thread_collapsed(session, t, group_active)
    local override = session.thread_collapsed and session.thread_collapsed[t.thread_id]
    if override ~= nil then
        return override
    end
    return not group_active
end

-- extend every row of a stacked block to the block's max display width with a
-- panel-tinted pad, so the overlay reads as a clean rectangle rather than ragged text
---@param rows table[]
---@return table[]
local function pad_block(rows)
    local width = 0
    local function row_width(r)
        local w = 0
        for _, c in ipairs(r) do
            w = w + vim.api.nvim_strwidth(c[1])
        end
        return w
    end
    for _, r in ipairs(rows) do
        width = math.max(width, row_width(r))
    end
    for _, r in ipairs(rows) do
        local pad = width - row_width(r)
        if pad > 0 then
            r[#r + 1] = { string.rep(" ", pad), "differThreadBody" }
        end
    end
    return rows
end

-- ── apply (extmark-only) ──────────────────────────────────────────────────────────

-- paint the range background over start_line..line on the thread's side, for an
-- expanded multi-line thread. single-line threads have no range
---@param view table
---@param t table
local function paint_range(view, t)
    if not (t.start_line and t.start_line > 0 and t.start_line < t.line) then
        return
    end
    local side = M.side_of(t)
    local col = view:column_for(side)
    if not col then
        return
    end
    local index = side == "old" and col.map.from_old or col.map.from_new
    for ln = t.start_line, t.line do
        local row = index[ln]
        if row then
            vim.api.nvim_buf_set_extmark(col.bufnr, namespace(), row - 1, 0, {
                line_hl_group = "differThreadRange",
            })
        end
    end
end

-- a config-aware relative/absolute time formatter for the thread headers. threads
-- carry the HH:MM time alongside the date (a comment's time of day is useful context),
-- so the absolute form is "YYYY-MM-DD HH:MM"
---@return fun(ts: string): string
local function time_formatter()
    local date = require("differ.util.date")
    local relative = require("differ").get_config().relative_dates
    return function(ts)
        local epoch = date.parse_iso(ts)
        return epoch and date.format(epoch, { relative = relative, time = true }) or (ts or "")
    end
end

-- (re)paint the thread overlays for the file the view currently shows. clears the
-- thread namespace on every column buffer first, then sets one virt_lines extmark per
-- anchored row (stacked threads concatenated oldest first) and any range backgrounds.
-- records the anchored rows on the session for ]t/[t nav (slice 3)
---@param session table
function M.apply(session)
    local view = session and session.view
    if not (view and view.model and view.columns) then
        return
    end
    local path = view.model.path
    for _, col in ipairs(view.columns) do
        vim.api.nvim_buf_clear_namespace(col.bufnr, namespace(), 0, -1)
    end

    -- group this file's threads by the buffer row they anchor to
    local groups = {}
    for _, t in ipairs(session.threads or {}) do
        if t.path == path then
            local side = M.side_of(t)
            local col = view:column_for(side)
            local index = col and (side == "old" and col.map.from_old or col.map.from_new)
            local row = index and M.anchor_row(index, t.line)
            if col and row then
                local key = col.bufnr .. ":" .. row
                groups[key] = groups[key]
                    or { key = key, bufnr = col.bufnr, row = row, threads = {} }
                table.insert(groups[key].threads, t)
            end
        end
    end

    -- split would desync the side-by-side alignment and clip the text, so it gets a
    -- compact end-of-line marker instead of the inline box (option A); the full
    -- thread reads in stacked. stacked renders the boxes inline
    local split = view.layout == "split"
    local reltime = time_formatter()
    local anchors = {}
    for _, g in pairs(groups) do
        M.stack_sort(g.threads)
        if split then
            M.apply_marker(g)
        else
            M.apply_box(session, view, g, reltime)
        end
        anchors[#anchors + 1] = { key = g.key, bufnr = g.bufnr, row = g.row, threads = g.threads }
    end
    table.sort(anchors, function(a, b)
        return a.row < b.row
    end)
    session.thread_anchors = anchors
    -- split shows the thread under the cursor in a float, not inline; keep it in sync
    -- with the fresh anchors (state changes, file switch) or close it when the layout
    -- has no float
    if split then
        M.sync_peek(session)
    else
        M.close_peek()
    end
end

-- ── cursor actions (unit-tested where pure) ───────────────────────────────────────

-- the anchor group on (bufnr, row), or nil. the cursor actions (toggle / resolve) use
-- it to find the thread(s) on the line. pure over the recorded anchor list
---@param session table
---@param bufnr integer
---@param row integer
---@return table|nil  -- { key, bufnr, row, threads }
function M.anchor_at(session, bufnr, row)
    for _, a in ipairs(session.thread_anchors or {}) do
        if a.bufnr == bufnr and a.row == row then
            return a
        end
    end
end

-- the next/prev anchored row for `bufnr` strictly past `row` (no wrap). pure over the
-- anchor list so ]t/[t nav is unit-tested; nil when none remain that direction
---@param anchors table[]  -- { bufnr, row } list, any order
---@param bufnr integer
---@param row integer
---@param direction "next"|"prev"
---@return integer|nil
function M.next_anchor(anchors, bufnr, row, direction)
    local best
    for _, a in ipairs(anchors or {}) do
        if a.bufnr == bufnr then
            if direction == "next" and a.row > row and (not best or a.row < best) then
                best = a.row
            elseif direction == "prev" and a.row < row and (not best or a.row > best) then
                best = a.row
            end
        end
    end
    return best
end

-- flip the explicit collapse override for every thread in `anchor`'s group, to the
-- opposite of the group's current effective state, so one gc toggles a group together
--. the default expanded baseline differs by layout: stacked expands the row the
-- cursor peeks; split shows the float by default while the cursor is on the row. so gc
-- collapses the inline box (stacked) or hides the float (split), and back. re-applying
-- the overlay is the caller's job
---@param session table
---@param anchor table  -- { key, threads }
function M.toggle_group(session, anchor)
    local split = session.view and session.view.layout == "split"
    local group_active = split or session.thread_active == anchor.key
    local target = not thread_collapsed(session, anchor.threads[1], group_active)
    session.thread_collapsed = session.thread_collapsed or {}
    for _, t in ipairs(anchor.threads) do
        session.thread_collapsed[t.thread_id] = target
    end
end

-- split: a quiet marker at the end of the anchor line, coloured by the group's state
-- (any unresolved -> active). no virt_lines, so the two columns stay aligned
---@param g table  -- { bufnr, row, threads }
function M.apply_marker(g)
    local any_open = false
    for _, t in ipairs(g.threads) do
        any_open = any_open or not t.resolved
    end
    vim.api.nvim_buf_set_extmark(g.bufnr, namespace(), g.row - 1, 0, {
        virt_text = {
            {
                (" 💬 %d"):format(#g.threads),
                any_open and "differThread" or "differThreadResolved",
            },
        },
        virt_text_pos = "eol",
    })
end

-- stacked: the inline box(es) below the anchor, stacked oldest first, padded to a clean
-- panel rectangle. expands the thread under the cursor (peek), collapses the rest
---@param session table
---@param view table
---@param g table  -- { key, bufnr, row, threads }
---@param reltime fun(ts: string): string
function M.apply_box(session, view, g, reltime)
    local group_active = session.thread_active == g.key
    local virt = {}
    for i, t in ipairs(g.threads) do
        if i > 1 then
            virt[#virt + 1] = { { "", "differThreadBody" } } -- blank tinted row between stacked threads
        end
        local collapsed = thread_collapsed(session, t, group_active)
        for _, rowchunks in ipairs(thread_ui.build(t, { collapsed = collapsed, reltime = reltime })) do
            virt[#virt + 1] = rowchunks
        end
        if not collapsed then
            paint_range(view, t)
        end
    end
    vim.api.nvim_buf_set_extmark(g.bufnr, namespace(), g.row - 1, 0, {
        virt_lines = pad_block(virt),
        virt_lines_above = false,
    })
end

-- ensure the PR's threads are fetched (once, PR-wide), then paint the current file.
-- threads are additive, so a fetch error notifies but never blocks the diff. called on
-- every show_file render so a file switch re-anchors from the cached list
---@param session table
function M.refresh(session)
    if not (session and session.view) then
        return
    end
    if session.threads then
        return M.apply(session)
    end
    if session.threads_loading then
        return -- a fetch is in flight; its callback paints the then-current file
    end
    session.threads_loading = true
    client.get_threads(session.pr, function(err, list)
        if not session then
            return -- session torn down while the fetch was in flight
        end
        session.threads_loading = false
        if err then
            return require("differ.pr").notify_err(err)
        end
        -- a PR with no threads decodes to vim.NIL (userdata, truthy), so guard on type
        -- rather than `list or {}`
        session.threads = type(list) == "table" and list or {}
        M.apply(session)
    end)
end

-- ── split peek float ──────────────────────────────────────────────────────────────
-- split can't carry inline boxes without desyncing the columns, so the thread under
-- the cursor reads in a floating popover instead. one reusable float per session,
-- re-pointed as the cursor moves and closed when it leaves a thread row. it reuses the
-- ui.thread builder and the differThread* groups, so it matches the stacked overlay

local peek = { win = nil, buf = nil, key = nil }
local PEEK_AUGROUP = "differ.pr.peek"

-- whether `group`'s float is collapsed (hidden) by an explicit gc override. the float
-- shows by default while the cursor is on the row, so the baseline is group_active=true
---@param session table
---@param group table  -- { threads }
---@return boolean
local function peek_collapsed(session, group)
    return thread_collapsed(session, group.threads[1], true)
end

-- close the peek float (keeping its scratch buffer for reuse) and drop its window guard
function M.close_peek()
    if peek.win and vim.api.nvim_win_is_valid(peek.win) then
        pcall(vim.api.nvim_win_close, peek.win, true)
    end
    peek.win, peek.key = nil, nil
    pcall(vim.api.nvim_del_augroup_by_name, PEEK_AUGROUP)
end

-- while the float is open, close it as soon as focus enters a window that isn't a diff
-- column. the diff's cursor hook is buffer-local, so leaving to the panel (or any other
-- window) wouldn't otherwise fire it and the float would orphan over the layout
---@param session table
local function arm_peek_guard(session)
    local group = vim.api.nvim_create_augroup(PEEK_AUGROUP, { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
        group = group,
        callback = function()
            local buf = vim.api.nvim_get_current_buf()
            for _, col in ipairs((session.view and session.view.columns) or {}) do
                if col.bufnr == buf then
                    return -- still in a diff column; the buffer-local hook takes it
                end
            end
            M.close_peek()
        end,
    })
end

-- the window currently displaying `bufnr` (the column the cursor is on, else any),
-- so the float anchors to the right side even when apply runs off a callback
---@param bufnr integer
---@return integer|nil
local function win_for_buf(bufnr)
    if vim.api.nvim_win_get_buf(0) == bufnr then
        return vim.api.nvim_get_current_win()
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then
            return w
        end
    end
end

-- flatten a group's built chunk rows into buffer lines + per-chunk highlight spans
-- (the float needs real lines, not virt_lines). expanded, stacked oldest first
---@param group table  -- { threads }
---@param reltime fun(ts: string): string
---@return string[], table[]
local function peek_content(group, reltime)
    local lines, hls = {}, {}
    local function push(chunks)
        local col, parts = 0, {}
        for _, c in ipairs(chunks) do
            parts[#parts + 1] = c[1]
            local bytes = #c[1]
            if c[2] and bytes > 0 then
                hls[#hls + 1] = { row = #lines, col = col, end_col = col + bytes, hl = c[2] }
            end
            col = col + bytes
        end
        lines[#lines + 1] = table.concat(parts)
    end
    for i, t in ipairs(group.threads) do
        if i > 1 then
            push({ { "", "differThreadBody" } }) -- blank tinted row between stacked threads
        end
        for _, rowchunks in ipairs(thread_ui.build(t, { collapsed = false, reltime = reltime })) do
            push(rowchunks)
        end
    end
    return lines, hls
end

-- open (or re-point) the peek float over `group`'s anchor row. positions just below the
-- line, in the column the thread sits on, non-focusable so the cursor never enters it
---@param session table
---@param group table  -- { key, bufnr, row, threads }
local function peek_open(session, group)
    local host = win_for_buf(group.bufnr)
    if not host then
        return M.close_peek()
    end
    local lines, hls = peek_content(group, time_formatter())
    if #lines == 0 then
        return M.close_peek()
    end
    local width = 1
    for _, l in ipairs(lines) do
        width = math.max(width, vim.api.nvim_strwidth(l))
    end

    if not (peek.buf and vim.api.nvim_buf_is_valid(peek.buf)) then
        peek.buf = vim.api.nvim_create_buf(false, true)
    end
    vim.bo[peek.buf].modifiable = true
    vim.api.nvim_buf_set_lines(peek.buf, 0, -1, false, lines)
    vim.bo[peek.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(peek.buf, namespace(), 0, -1)
    for _, h in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(peek.buf, namespace(), h.row, h.col, {
            end_col = h.end_col,
            hl_group = h.hl,
        })
    end

    local cfg = {
        relative = "win",
        win = host,
        bufpos = { group.row - 1, 0 },
        row = 1,
        col = 0,
        width = width,
        height = #lines,
        style = "minimal",
        border = "rounded",
        focusable = false,
        noautocmd = true,
        zindex = 50,
    }
    if peek.win and vim.api.nvim_win_is_valid(peek.win) then
        vim.api.nvim_win_set_config(peek.win, cfg)
    else
        peek.win = vim.api.nvim_open_win(peek.buf, false, cfg)
        vim.wo[peek.win].winhl = "Normal:differThreadBody,FloatBorder:differThread"
        vim.wo[peek.win].wrap = false
    end
    peek.key = group.key
    arm_peek_guard(session) -- close the float if focus leaves the diff columns
end

-- re-render the open float against the current anchors after an apply (resolve state
-- change, file switch): re-point if its group still exists, else close it
---@param session table
function M.sync_peek(session)
    if not (peek.win and vim.api.nvim_win_is_valid(peek.win) and peek.key) then
        return
    end
    for _, a in ipairs(session.thread_anchors or {}) do
        if a.key == peek.key then
            if peek_collapsed(session, a) then
                return M.close_peek() -- gc hid it; honour the override
            end
            return peek_open(session, a)
        end
    end
    M.close_peek()
end

-- cursor-driven peek. stacked: expand the thread under the cursor inline and collapse
-- the rest (re-apply only when the active anchor changes, so plain motion stays cheap).
-- split: open the float over the thread under the cursor, closing it off a thread row
---@param session table
function M.on_cursor(session)
    if not (session and session.view and session.view.columns) then
        return
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local in_diff = false
    for _, col in ipairs(session.view.columns) do
        in_diff = in_diff or col.bufnr == buf
    end

    if session.view.layout == "split" then
        if not in_diff then
            return M.close_peek() -- focus left the diff; drop the float
        end
        local row = vim.api.nvim_win_get_cursor(win)[1]
        local group = M.anchor_at(session, buf, row)
        if not group or peek_collapsed(session, group) then
            return M.close_peek() -- off a thread row, or gc hid this one
        end
        if peek.key ~= group.key or not (peek.win and vim.api.nvim_win_is_valid(peek.win)) then
            peek_open(session, group)
        end
        return
    end

    if not in_diff then
        return -- focus is in the panel or elsewhere; leave the overlay as is
    end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local active
    for _, a in ipairs(session.thread_anchors or {}) do
        if a.bufnr == buf and a.row == row then
            active = a.key
            break
        end
    end
    if active ~= session.thread_active then
        session.thread_active = active
        M.apply(session)
    end
end

return M
