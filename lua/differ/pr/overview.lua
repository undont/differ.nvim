-- the PR overview home: a read-only pre-review page with the PR summary + a
-- minimal timeline (conversation comments, submitted review verdicts, and code
-- threads). it is a step *before* the review proper — no file panel, just a dedicated
-- page filling the session tab. e/r enter the review (build the panel + diff), <CR> on
-- a thread row enters it at that thread's file/line, q backs out. the pure layout
-- lives in ui/overview.lua; this owns the vim surface (buffer, window, extmarks,
-- fetches). get_timeline is a round-trip and threads are ensured (shared, PR-wide,
-- also feeding the header count) — the meta comes from session.pr_meta (enriched in
-- pr/init), checks reuse slice 5

local client = require("differ.pr.client")
local ui = require("differ.ui.overview")

local M = {}

local ns
local function namespace()
    ns = ns or vim.api.nvim_create_namespace("differ.pr.overview")
    return ns
end

local GUARD = "differ.pr.overview.guard"

-- one reusable scratch buffer for the page; keymaps act on the live session via
-- pr.current_session(), so the buffer survives a session swap. `anchors` is the last
-- built row->thread-anchor index (<CR> reads it at press time)
local buf = nil
local anchors = nil

-- a timestamp -> the display string, honouring the configured relative/absolute mode
---@return fun(ts: string): string
local function time_formatter()
    local date = require("differ.util.date")
    local relative = require("differ").get_config().relative_dates
    return function(ts)
        local epoch = date.parse_iso(ts)
        return epoch and date.format(epoch, { relative = relative, time = true }) or (ts or "")
    end
end

-- unresolved / total submitted threads (a pending draft thread isn't a real count entry)
---@param threads table[]|nil
---@return integer unresolved, integer total
local function thread_counts(threads)
    local unresolved, total = 0, 0
    for _, t in ipairs(threads or {}) do
        if not t.is_pending then
            total = total + 1
            if not t.resolved then
                unresolved = unresolved + 1
            end
        end
    end
    return unresolved, total
end

-- the live session, or nil when this session is no longer the open one (torn down while
-- a fetch was in flight). the module-local in pr/init is nil after teardown
---@param session table
---@return boolean
local function still_live(session)
    return require("differ.pr").current_session() == session
end

-- drop the navigate-away guard. the page window becomes the diff's on entry, so the
-- guard must not fire when the view repurposes it
function M.disarm()
    pcall(vim.api.nvim_del_augroup_by_name, GUARD)
end

-- wipe the reused scratch buffer + its anchor index on session teardown. the buffer is
-- bufhidden=hide and outlives the window, so without this a Ctrl-O jump can resurface a
-- stale page whose <CR>/gx act on current_session() (nil after teardown -> "no PR url",
-- or a since-swapped session). paint rebuilds a fresh buffer for the next session
function M.teardown()
    M.disarm()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    buf, anchors = nil, nil
end

-- end the session if the page window is closed while still pre-review (no panel built).
-- once the review is entered the window is the diff's, so the guard is disarmed first
---@param session table
---@param win integer
local function arm_guard(session, win)
    local group = vim.api.nvim_create_augroup(GUARD, { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(win),
        callback = function()
            local s = require("differ.pr").current_session()
            if s == session and not s.panel then
                require("differ.pr").end_session()
            end
        end,
    })
end

-- buffer-local keymaps; they read the live session each time so the reused buffer never
-- acts on a stale session. e enters the review (files), r enters + starts a review, q
-- backs into the review when one is open (else out of the PR), gx opens the PR url.
-- <CR> on a thread row enters the review at that thread's file/line; elsewhere it
-- opens the url. g? floats the keymap cheatsheet
---@param b integer
local function set_keymaps(b)
    local function live()
        return require("differ.pr").current_session()
    end
    local function open_url()
        local s = live()
        local url = s and s.pr_meta and s.pr_meta.url
        if url and url ~= "" then
            vim.ui.open(url)
        else
            require("differ.pr").notify("no PR url", vim.log.levels.WARN)
        end
    end
    -- the thread anchor whose row span covers the cursor, or nil off a thread section
    local function anchor_at_cursor()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        for _, a in ipairs(anchors or {}) do
            if row >= a.row_start and row <= a.row_end then
                return a
            end
        end
    end
    local function select_or_url()
        local a = anchor_at_cursor()
        if a and live() then
            return require("differ.pr").enter_at({ path = a.path, side = a.side, line = a.line })
        end
        open_url()
    end
    -- e/r: enter the review. on a thread row, jump into that thread's file/line (like
    -- <CR>) so the comment's diff opens directly; elsewhere enter at the panel's file. r
    -- also starts a review either way
    local function enter(review)
        local s = live()
        if not s then
            return
        end
        local a = anchor_at_cursor()
        if a then
            return require("differ.pr").enter_at(
                { path = a.path, side = a.side, line = a.line },
                review
            )
        end
        if review then
            require("differ.pr").review({ number = s.pr.number })
        else
            require("differ.pr").view({ number = s.pr.number })
        end
    end
    -- g?: a floating keymap cheatsheet, dismissed with <Esc> / q / g?
    local function show_help()
        require("differ.ui.help").show({
            " e / r      enter review / enter + start a review (thread row: at its file)",
            " <CR>       thread row: jump into the review here, else open the PR url",
            " gx         open the PR in the browser",
            " q          back into the review / end the session",
            " g?         this help",
        }, { title = " Differ: overview " })
    end
    local opts = { buffer = b, nowait = true, silent = true }
    vim.keymap.set("n", "gx", open_url, opts)
    vim.keymap.set("n", "<CR>", select_or_url, opts)
    vim.keymap.set("n", "e", function()
        enter(false)
    end, opts)
    vim.keymap.set("n", "r", function()
        enter(true)
    end, opts)
    vim.keymap.set("n", "g?", show_help, opts)
    -- q layers like a child page: arrived from the review (a panel exists), it backs
    -- into the review (the stashed position restores); pre-review it ends the session.
    -- only q, not <Esc>: <Esc> is too easy to fumble into an accidental exit
    vim.keymap.set("n", "q", function()
        local s = live()
        if s and s.panel then
            return require("differ.pr").view({ number = s.pr.number })
        end
        require("differ.pr").end_session()
    end, opts)
end

-- the page's window-local chrome: a clean reading surface (no diff gutter), markdown
-- conceal on, wrapping for long body lines
---@param win integer
local function setup_window(win)
    local set_wo = require("differ.util.win").set_local
    set_wo(win, "number", false)
    set_wo(win, "relativenumber", false)
    set_wo(win, "signcolumn", "no")
    set_wo(win, "foldcolumn", "0")
    set_wo(win, "cursorline", false)
    set_wo(win, "wrap", true)
    set_wo(win, "conceallevel", 2)
    set_wo(win, "list", false)
end

-- (re)build the scratch buffer, paint the built lines + highlight spans, keep the
-- fresh thread-anchor index for <CR>
---@param built { lines: string[], highlights: table[], anchors: table[] }
local function paint(built)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "hide"
        vim.bo[buf].filetype = "markdown"
        pcall(vim.api.nvim_buf_set_name, buf, "differ://overview")
        set_keymaps(buf)
    end
    anchors = built.anchors
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, built.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace(), 0, -1)
    for _, h in ipairs(built.highlights) do
        vim.api.nvim_buf_set_extmark(buf, namespace(), h.row, h.col_start, {
            end_col = h.col_end,
            hl_group = h.hl,
        })
    end
end

-- the window the page takes over: the pre-review page window, or — coming back from the
-- review (:Differ pr overview) — the content window, closing the diff + hiding the panel
-- so the page fills the tab again (safe teardown keeps the session alive)
---@param session table
---@return integer|nil
local function target_window(session)
    if session.panel then
        local win = session.panel:content_win()
        if session.view and session.view:is_open() then
            session.view:close(win)
        end
        session.view = nil
        require("differ.pr.threads").close_peek()
        if session.panel:is_open() then
            session.panel:hide()
        end
        return win
    end
    local win = session.overview_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        win = vim.api.nvim_get_current_win()
    end
    return win
end

-- assemble data, build the page, take over the session's window
---@param session table
---@param timeline table  -- get_timeline result { comments, reviews }
---@param checks table|nil
local function render(session, timeline, checks)
    local meta = session.pr_meta or {}
    local unresolved, total = thread_counts(session.threads)
    local built = ui.build({
        meta = {
            number = session.pr and session.pr.number,
            title = meta.title,
            body = meta.body,
            author = meta.author,
            state = meta.state,
            draft = meta.draft,
            mergeable = meta.mergeable,
        },
        checks = checks,
        unresolved = unresolved,
        total_threads = total,
        timeline = {
            comments = timeline.comments,
            reviews = timeline.reviews,
            threads = session.threads, -- ensured by open; nil degrades to none
        },
    }, { reltime = time_formatter() })

    local win = target_window(session)
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    paint(built)
    session.overview_win = win
    vim.api.nvim_win_set_buf(win, buf)
    setup_window(win)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    arm_guard(session, win)
end

-- M.open(session): fetch the timeline, ensure threads (shared with the diff overlay;
-- feeds the header count + the timeline's thread sections), reuse cached checks, render
-- the page. guards the session is still live at every async hop (it can be torn down
-- mid-fetch); threads and checks degrade rather than block the page
---@param session table|nil
function M.open(session)
    if not session then
        return require("differ.pr").notify("open a PR first")
    end
    client.get_timeline(session.pr, function(err, tl)
        if not still_live(session) then
            return -- session torn down while the timeline was in flight
        end
        if err then
            return require("differ.pr").notify_err(err)
        end
        -- a PR with no comments/reviews decodes to vim.NIL fields; normalise to tables
        local timeline = {
            comments = type(tl) == "table" and type(tl.comments) == "table" and tl.comments or {},
            reviews = type(tl) == "table" and type(tl.reviews) == "table" and tl.reviews or {},
        }
        require("differ.pr.threads").ensure(session, function()
            if not still_live(session) then
                return
            end
            if session.checks then
                return render(session, timeline, session.checks)
            end
            -- no cached checks: fetch once, cache on the session, then render (degrade
            -- to nil if the fetch fails — the rollup line just reads "n/a")
            client.get_checks(session.pr, function(cerr, checks)
                if not still_live(session) then
                    return
                end
                if not cerr and type(checks) == "table" then
                    session.checks = checks
                end
                render(session, timeline, session.checks)
            end)
        end)
    end)
end

return M
