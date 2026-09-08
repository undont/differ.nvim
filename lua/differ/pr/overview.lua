-- the PR overview home: a pre-review page with the PR summary + a minimal timeline
-- (conversation comments, submitted review verdicts, and code threads) that ga and gp
-- write back to. it is a step *before* the review proper — no file panel, just a
-- dedicated page filling the session tab. e enters the review (builds the panel +
-- diff), r enters and also starts a github draft review, <CR> on a thread row enters at
-- that thread's file/line, q backs into an in-progress review. the pure layout lives in
-- ui/overview.lua; this owns the vim surface (buffer, window, extmarks,
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

-- what a wrapped row indents past, under breakindentopt=list:-1: a thread box's spine,
-- so a wrapped body stays inside its box, then a markdown list marker, so a wrapped
-- bullet hangs under its own text. plain prose matches neither and wraps flush left
local WRAP_INDENT_PAT = "^"
    .. vim.trim(ui.SPINE)
    .. "\\s*\\|^\\s*[-*+]\\s\\+\\|^\\s*\\d\\+[\\]:.)}\\t ]\\s*"

-- a body string as its lines, for quoting it back
---@param body string|nil
---@return string[]
local function split_body(body)
    return vim.split(body or "", "\n", { plain = true })
end

-- drop a thread box's left spine from a picked line, so a selection inside a box quotes
-- as the comment text it is rather than as the drawing around it
---@param line string
---@return string
local function strip_chrome(line)
    return (line:gsub("^" .. vim.trim(ui.SPINE) .. "%s*", ""))
end

local GUARD = "differ.pr.overview.guard"

-- the page's scratch-buffer name, owned here; the review's on_repurpose asks
-- M.owns_buffer rather than matching this literal itself
local BUFNAME = "differ://overview"

-- one reusable scratch buffer for the page; keymaps act on the live session via
-- pr.current_session(), so the buffer survives a session swap. `anchors` is the last
-- built row->thread-anchor index (<CR> reads it at press time)
local buf = nil
local anchors = nil
local quotes = nil

-- thread node id -> true for each box showing its replies. lives with the page buffer
-- (teardown clears it), since it's a reading state, not something the session owns
local expanded = {}

-- the data the page last rendered, so a change to how it reads (gc) rebuilds without
-- re-fetching. cleared with the buffer
local last = nil

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

-- whether `b` is the page's scratch buffer, by its stable name. the review's
-- on_repurpose asks this to re-enter the page rather than end the session on a jump back
---@param b integer|nil
---@return boolean
function M.owns_buffer(b)
    return b ~= nil and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == BUFNAME
end

-- monotonic page token. a page render is several async hops long, and the session can
-- leave the page while they run: entering the files disarms, and render would otherwise
-- take the window back, close the diff just built and hide the panel
local page_gen = 0

-- drop the navigate-away guard. the page window becomes the diff's on entry, so the
-- guard must not fire when the view repurposes it, and any render still in flight is
-- for a surface the session has already left
function M.disarm()
    page_gen = page_gen + 1
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
    buf, anchors, quotes, expanded, last = nil, nil, nil, {}, nil
end

-- end the session when the page window is closed: pre-review that's the only exit (q
-- is inert there); with a live review it matches the diff's close guard, so :q on the
-- layered page leaves the PR rather than stranding a hidden panel. deferred like the
-- view's guard, tab/panel teardown isn't allowed inside WinClosed. entering the review
-- disarms first (the window is repurposed, not closed)
---@param session table
---@param win integer
local function arm_guard(session, win)
    local group = vim.api.nvim_create_augroup(GUARD, { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(win),
        callback = function()
            vim.schedule(function()
                -- re-check at run time: teardown or a session swap may have won the race
                if require("differ.pr").current_session() == session then
                    require("differ.pr").end_session()
                end
            end)
        end,
    })
end

-- buffer-local keymaps; they read the live session each time so the reused buffer never
-- acts on a stale session. e enters the review (panel + diff), r enters and also starts
-- a github draft review, q backs into the review when one is open, gx opens the PR url.
-- <CR> on a thread row enters the review at that thread's file/line; elsewhere it opens
-- the url. ga comments on the PR and gp answers whatever is under the cursor: a plain
-- reply into a thread, which needs no quote to say what it answers, and a quoting one
-- where there is no thread (visual gp quotes the selection either way). ]t/[t hop
-- between thread boxes; g? floats the cheatsheet
---@param b integer
local function set_keymaps(b)
    local function live()
        return require("differ.pr").current_session()
    end
    -- stash the page cursor on the session before entering the review; render consumes
    -- the one-shot, so a go/C-o hop back lands where the page was left
    ---@param s table
    local function stash_cursor(s)
        s.overview_cursor = vim.api.nvim_win_get_cursor(0)
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
    -- the thread anchor whose row span covers `row`, or nil off a thread section
    ---@param row integer
    ---@return table|nil
    local function anchor_at_row(row)
        for _, a in ipairs(anchors or {}) do
            if row >= a.row_start and row <= a.row_end then
                return a
            end
        end
    end
    local function anchor_at_cursor()
        return anchor_at_row(vim.api.nvim_win_get_cursor(0)[1])
    end
    local function select_or_url()
        local a = anchor_at_cursor()
        local s = live()
        if a and s then
            stash_cursor(s)
            return require("differ.pr").enter_at({ path = a.path, side = a.side, line = a.line })
        end
        open_url()
    end
    -- e/r: enter the review (panel + diff). on a thread row, jump into that thread's
    -- file/line (like <CR>) so the comment's diff opens directly; elsewhere enter at the
    -- panel's file. r also starts a github draft review either way, so comments become
    -- drafts submitted as one batch rather than posting on the spot
    local function enter(review)
        local s = live()
        if not s then
            return
        end
        stash_cursor(s)
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
    -- ]t/[t: hop the cursor between thread boxes (their top rules), mirroring the
    -- diff's thread nav. no wrap; [t inside a box lands on its own header first
    ---@param direction "next"|"prev"
    local function goto_thread(direction)
        local row = vim.api.nvim_win_get_cursor(0)[1]
        -- reuse the diff's pure nav: feed each thread's top row keyed on this buffer so
        -- the nearest-past/no-wrap scan is the one code path (differ.pr.threads)
        local rows = {}
        for _, a in ipairs(anchors or {}) do
            rows[#rows + 1] = { bufnr = b, row = a.row_start }
        end
        local best = require("differ.pr.threads").next_anchor(rows, b, row, direction)
        if best then
            vim.api.nvim_win_set_cursor(0, { best, 0 })
        end
    end
    -- g?: a floating keymap cheatsheet, dismissed with <Esc> / q / g?
    local function show_help()
        require("differ.ui.help").show({
            " e / r      enter review / enter + start a draft review (thread row: at its file)",
            " <CR>       thread row: jump into the review here, else open the PR url",
            " ga         comment on the PR",
            " gp         reply into the thread here, or quote a plain comment into a new one",
            " v_gp       the same, quoting the selection rather than the whole comment",
            " gc         show / hide the replies of the thread under the cursor",
            " ]t / [t    next / previous thread",
            " gx         open the PR in the browser",
            " q          back into the review (when one is in progress)",
            " g?         this help",
        }, { title = " Differ: overview " })
    end
    -- compose a body and hand it to `send`, then re-open the page so the new comment
    -- renders from github rather than being patched in locally. the stashed cursor keeps
    -- the reading position across the rebuild (render consumes it as a one-shot)
    ---@param s table
    ---@param spec { title: string, done: string, initial?: string, send: fun(body: string, cb: fun(err: table|nil)) }
    local function compose(s, spec)
        stash_cursor(s)
        require("differ.ui.compose").open({
            title = spec.title,
            initial = spec.initial,
            anchor_win = s.overview_win,
            on_submit = function(body)
                if body == "" then
                    return require("differ.pr").notify("empty comment discarded")
                end
                spec.send(body, function(err)
                    if not require("differ.pr.guard").owns(s) then
                        return -- session torn down (or replaced) while the post was in flight
                    end
                    if err then
                        return require("differ.pr").notify_err(err)
                    end
                    require("differ.pr").notify(spec.done)
                    M.open(s)
                end)
            end,
        })
    end
    -- ga: a PR-level conversation comment. github has no draft for these, so it posts
    -- immediately even mid-review, and there is no diff anchor for the head to shift under
    local function comment()
        local s = live()
        if not s then
            return
        end
        compose(s, {
            title = "Comment on the PR (posts immediately)",
            done = "comment posted",
            send = function(body, cb)
                client.post_issue_comment(s.pr, body, cb)
            end,
        })
    end
    -- the flat timeline section whose row span covers `row`, or nil. these are the
    -- quote targets: github doesn't thread conversation comments or review verdicts, so
    -- an answer is a new comment that says what it is answering
    ---@param row integer
    ---@return table|nil
    local function quote_at(row)
        for _, q in ipairs(quotes or {}) do
            if row >= q.row_start and row <= q.row_end then
                return q
            end
        end
    end
    -- `lines` as a markdown blockquote attributed to @author, ready to type under. the
    -- page is chronological, so a reply lands at the bottom and the attribution is the
    -- only thing saying what it answers
    ---@param author string|nil
    ---@param lines string[]
    ---@return string
    local function quoted(author, lines)
        local out = { ("> @%s wrote:"):format(author or "?") }
        for _, l in ipairs(lines) do
            out[#out + 1] = vim.trim(l) == "" and ">" or ("> " .. l)
        end
        out[#out + 1] = ""
        out[#out + 1] = ""
        return table.concat(out, "\n")
    end
    -- reply into `thread_id`, prefilled with `initial` when quoting. joins the draft
    -- when a review is in progress, like the diff's gp
    ---@param s table
    ---@param thread_id string
    ---@param initial string|nil
    local function reply_to_thread(s, thread_id, initial)
        local draft = s.review_id and s.review_id ~= ""
        compose(s, {
            title = draft and "Reply (draft)" or "Reply (posts immediately)",
            done = draft and "reply added to your review draft" or "reply posted",
            initial = initial,
            send = function(body, cb)
                local args = { in_reply_to = thread_id, body = body }
                if draft then
                    args.review_id = s.review_id
                end
                client.post_comment(s.pr, args, function(err, res)
                    if not err then
                        -- the page re-reads threads on open, and the list is cached per
                        -- TTL window, so without this the reply lands invisibly
                        require("differ.pr.threads").invalidate(s)
                    end
                    cb(err, res)
                end)
            end,
        })
    end
    -- answer a flat section: a new conversation comment opening with the quote
    ---@param s table
    ---@param initial string
    local function quote_reply(s, initial)
        compose(s, {
            title = "Quote reply (posts immediately)",
            done = "comment posted",
            initial = initial,
            send = function(body, cb)
                client.post_issue_comment(s.pr, body, cb)
            end,
        })
    end
    -- gp: answer whatever the cursor is on. a thread box replies into the thread; a
    -- conversation comment or review verdict has no thread to reply into, so it quotes
    -- into a new comment instead
    local function reply()
        local s = live()
        if not s then
            return
        end
        local a = anchor_at_cursor()
        if a and a.thread_id then
            return reply_to_thread(s, a.thread_id)
        end
        local q = quote_at(vim.api.nvim_win_get_cursor(0)[1])
        if not q then
            return require("differ.pr").notify("nothing here to reply to; ga comments on the PR")
        end
        quote_reply(s, quoted(q.author, split_body(q.body)))
    end
    -- gp (visual): quote just the selected lines rather than the whole comment, then
    -- route as above. the box chrome is stripped so a selection inside a thread reads as
    -- the comment text it is
    local function reply_selection()
        local s = live()
        if not s then
            return
        end
        local r1, r2 = vim.fn.line("v"), vim.fn.line(".")
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
            "n",
            false
        )
        local lo, hi = math.min(r1, r2), math.max(r1, r2)
        local picked = {}
        for _, l in ipairs(vim.api.nvim_buf_get_lines(b, lo - 1, hi, false)) do
            picked[#picked + 1] = strip_chrome(l)
        end
        local a = anchor_at_row(lo)
        if a and a.thread_id then
            return reply_to_thread(s, a.thread_id, quoted(a.author, picked))
        end
        local q = quote_at(lo)
        if not q then
            return require("differ.pr").notify("nothing here to reply to; ga comments on the PR")
        end
        quote_reply(s, quoted(q.author, picked))
    end
    -- gc: show or hide the replies of the thread box under the cursor, matching the
    -- diff's collapse key. the page is rebuilt from what it already holds, so no fetch
    local function toggle_replies()
        local s = live()
        local a = anchor_at_cursor()
        if not (s and a and a.thread_id) then
            return require("differ.pr").notify("no thread here to expand")
        end
        expanded[a.thread_id] = not expanded[a.thread_id] or nil
        stash_cursor(s)
        M.repaint(s)
    end
    local opts = { buffer = b, nowait = true, silent = true }
    vim.keymap.set("n", "gc", toggle_replies, opts)
    vim.keymap.set("n", "gx", open_url, opts)
    vim.keymap.set("n", "ga", comment, opts)
    vim.keymap.set("n", "gp", reply, opts)
    vim.keymap.set("x", "gp", reply_selection, opts)
    vim.keymap.set("n", "<CR>", select_or_url, opts)
    vim.keymap.set("n", "e", function()
        enter(false)
    end, opts)
    vim.keymap.set("n", "r", function()
        enter(true)
    end, opts)
    vim.keymap.set("n", "]t", function()
        goto_thread("next")
    end, opts)
    vim.keymap.set("n", "[t", function()
        goto_thread("prev")
    end, opts)
    vim.keymap.set("n", "g?", show_help, opts)
    -- q dismisses the page back into the review when one is open (the stashed position
    -- restores); pre-review it does nothing, :q is the exit there (the WinClosed guard
    -- ends the session)
    vim.keymap.set("n", "q", function()
        local s = live()
        if s and s.panel then
            stash_cursor(s)
            require("differ.pr").view({ number = s.pr.number })
        end
    end, opts)
end

-- the page's window-local chrome: a clean reading surface (no diff gutter), markdown
-- conceal on, word-wrapping for long body lines
---@param win integer
local function setup_window(win)
    local set_wo = require("differ.util.win").set_local
    set_wo(win, "number", false)
    set_wo(win, "relativenumber", false)
    set_wo(win, "signcolumn", "no")
    set_wo(win, "foldcolumn", "0")
    -- the window is taken over from another surface, so mirror the global rather
    -- than inherit whatever local cursorline it was left with
    set_wo(win, "cursorline", vim.go.cursorline)
    set_wo(win, "wrap", true)
    -- break at a word rather than mid-token, and indent a continuation per line rather
    -- than per window (WRAP_INDENT_PAT), so a box body clears its spine while plain
    -- prose still wraps flush left
    set_wo(win, "linebreak", true)
    set_wo(win, "breakindent", true)
    set_wo(win, "breakindentopt", "list:-1")
    set_wo(win, "conceallevel", 2)
    set_wo(win, "list", false)
end

-- (re)build the scratch buffer, paint the built lines + highlight spans + the
-- treesitter pass over the hunk snippets, keep the fresh thread-anchor index for <CR>
---@param built { lines: string[], highlights: table[], anchors: table[], quotes: table[], hunks: table[] }
local function paint(built)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "hide"
        vim.bo[buf].filetype = "markdown"
        vim.bo[buf].formatlistpat = WRAP_INDENT_PAT
        pcall(vim.api.nvim_buf_set_name, buf, BUFNAME)
        set_keymaps(buf)
    end
    anchors, quotes = built.anchors, built.quotes
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, built.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace(), 0, -1)
    for _, h in ipairs(built.highlights) do
        -- a full-width line tint (the hunk's +/- rows, mirroring the diff) vs a
        -- column span (everything else)
        if h.line_hl then
            vim.api.nvim_buf_set_extmark(buf, namespace(), h.row, 0, {
                line_hl_group = h.line_hl,
            })
        else
            vim.api.nvim_buf_set_extmark(buf, namespace(), h.row, h.col_start, {
                end_col = h.col_end,
                hl_group = h.hl,
            })
        end
    end
    -- treesitter over the hunk code (parsed from the stripped source, never the page)
    require("differ.syntax").apply_snippets(buf, built.hunks)
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
    last = { timeline = timeline, checks = checks }
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
    }, { reltime = time_formatter(), expanded = expanded })

    local win = target_window(session)
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    paint(built)
    session.overview_win = win
    vim.api.nvim_win_set_buf(win, buf)
    setup_window(win)
    vim.api.nvim_set_current_win(win)
    -- a hop back from the review restores the stashed page cursor; a fresh open lands
    -- at the top. row clamped (the rebuilt page can shrink), col pcall'd the same way
    local cur = session.overview_cursor
    session.overview_cursor = nil
    local row = math.min(cur and cur[1] or 1, vim.api.nvim_buf_line_count(buf))
    if not pcall(vim.api.nvim_win_set_cursor, win, { row, cur and cur[2] or 0 }) then
        vim.api.nvim_win_set_cursor(win, { row, 0 })
    end
    arm_guard(session, win)
end

-- rebuild and repaint from the data the page last rendered, for a change that is only
-- how it reads (gc). a page that has never rendered has nothing to redraw
---@param session table
function M.repaint(session)
    if last then
        render(session, last.timeline, last.checks)
    end
end

-- M.open(session): fetch the timeline and the checks, ensure threads (shared with the
-- diff overlay; feeds the header count + the timeline's thread sections), render the
-- page. guards the session is still live at every async hop (it can be torn down
-- mid-fetch); threads and checks degrade rather than block the page
---@param session table|nil
function M.open(session)
    if not session then
        return require("differ.pr").notify("open a PR first")
    end
    require("differ.ui.highlights").ensure() -- the page is reachable without any diff view
    -- claim the page: a later open supersedes this one, and so does entering the files
    page_gen = page_gen + 1
    local gen = page_gen
    ---@return boolean
    local function ours()
        return still_live(session) and page_gen == gen
    end
    client.get_timeline(session.pr, function(err, tl)
        if not ours() then
            return -- session torn down, or it left the page, while the timeline was in flight
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
            if not ours() then
                return
            end
            -- fetched per open, never memoised: the rollup is the most time-sensitive
            -- thing on the page, and a kept copy would disagree with :Differ pr checks
            client.get_checks(session.pr, function(cerr, checks)
                -- the checks fetch is the longest hop, so this is the likeliest place to
                -- find the session already in the files
                if not ours() then
                    return
                end
                if cerr or type(checks) ~= "table" then
                    checks = nil -- if we couldn't fetch checks, don't block the call
                end
                render(session, timeline, checks)
            end)
        end)
    end)
end

return M
