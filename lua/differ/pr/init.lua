-- the PR frontend session: pick a PR, list its files in the reused file
-- panel (with a viewed column), and diff each file from the sidecar's base/head
-- blobs. it mirrors git/init.lua's module-local session shape, owning the session
-- tab + panel + the one driven View; the panel and View are source-agnostic, so this
-- only swaps the model source (blobs over IPC) for git's local reads. every sidecar
-- call is async (cb(err, result)); the client already schedules its dispatch

local repo = require("differ.pr.repo")
local client = require("differ.pr.client")
local guard = require("differ.pr.guard")
local viewed = require("differ.pr.viewed")
local tab_util = require("differ.util.tab")
local open_session_tab, close_session_tab = tab_util.open_session, tab_util.close_session

local M = {}

-- the live session: coords, pr coords + meta (incl. pinned base/head shas), the panel
-- and driven View, and a per-path blob memo. base/head are pinned for the session, so
-- a path's versions can't go stale; the memo is the seam phase-6 prefetch writes into
---@type table|nil
local session = nil

-- monotonic open token. two `:Differ pr` opens in flight together resolve in whatever
-- order github answers, and response time scales with the file list, so the larger PR
-- can land last; only the most recent open is allowed to build a session
local open_gen = 0

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- a typed sidecar error -> a single notification, with an actionable hint for the
-- codes the user can fix
---@type table<string, string>
local CODE_HINT = {
    auth = "run gh auth login",
    gh_missing = "install gh or set GH_TOKEN",
    rate_limited = "github rate limit hit, retry shortly",
}

---@param secs integer
---@return string
local function wait_for(secs)
    if secs < 60 then
        return secs .. "s"
    end
    return math.ceil(secs / 60) .. "m"
end

-- github only sends a retry-after on a primary rate limit
---@param err table|nil
---@return string|nil
function M.error_hint(err)
    local code = err and err.code
    local secs = err and err.retry_after
    if code == "rate_limited" and type(secs) == "number" and secs > 0 then
        return "github rate limit hit, retry in " .. wait_for(secs)
    end
    return CODE_HINT[code]
end

---@param err table|nil
local function notify_err(err)
    local code = (err and err.code) or "internal"
    local msg = (err and err.message) or code
    local hint = M.error_hint(err)
    notify(hint and (msg .. " (" .. hint .. ")") or msg, vim.log.levels.ERROR)
end

-- exposed for the review/comment modules, which share the same typed-error treatment
M.notify = notify
M.notify_err = notify_err

---@param sha string|nil
---@return string
local function short(sha)
    return sha and sha:sub(1, 7) or "?"
end

-- the cwd's repo, but only when it is a clone of the pr's own repo. an unrelated
-- checkout has its own files at the same paths, so the edit verbs would open those as
-- "the real file" and checkout would fetch into it; nil disables both instead
---@param coords { owner: string, repo: string }
---@return string|nil
local function local_root(coords)
    local root = require("differ.git").root(vim.fn.getcwd())
    if root and require("differ.pr.repo").has_remote(root, coords) then
        return root
    end
    return nil
end

-- github's file-status words -> the single-letter codes the panel keys highlights on
-- (panel/init.lua STATUS_HL). the sidecar forwards the REST status verbatim, so the
-- translation lives here
---@type table<string, string>
local STATUS = {
    added = "A",
    removed = "D",
    modified = "M",
    renamed = "R",
    copied = "C",
    changed = "M",
    unchanged = "M",
}

-- map get_pr `files` to panel FileEntry[]. pure, so the mapping is unit-tested:
-- counts/previous_path pass through, status collapses to its letter code, and
-- viewed_state collapses to the boolean the panel renders as a checkbox (VIEWED and
-- DISMISSED both count as viewed)
---@param files table[]
---@return differ.FileEntry[]
function M.map_files(files)
    local out = {}
    for _, f in ipairs(files or {}) do
        out[#out + 1] = {
            path = f.path,
            status = STATUS[f.status] or f.status,
            additions = f.additions or 0,
            deletions = f.deletions or 0,
            previous_path = f.previous_path,
            viewed = f.viewed_state == "VIEWED" or f.viewed_state == "DISMISSED",
        }
    end
    return out
end

---@param ts string|nil
---@return string
local function reltime(ts)
    if type(ts) ~= "string" or ts == "" then
        return ""
    end
    local date = require("differ.util.date")
    local epoch = date.parse_iso(ts)
    if not epoch then
        return ts
    end
    return date.relative(epoch)
end

-- handle_conflict moves the pins on the live session rather than replacing it, so a blob
-- issued before a head move still passes `guard.owns`
---@param s table
---@param refs { base: string|nil, head: string|nil }
---@return boolean
local function pins_hold(s, refs)
    return s.pr_meta.base_sha == refs.base and s.pr_meta.head_sha == refs.head
end

-- predictive prefetch (phase 6, minimal slice): warm the immediate neighbours of
-- the shown file into the per-path memo so sequential ]f/[f / ]u/[u don't wait on a
-- round-trip. best-effort and silent: a speculative read, not a user-initiated one, so
-- a failure just leaves the memo cold (the on-demand path fetches it later) and never
-- notifies. window of 1 each side; shas are pinned, so warmed blobs can't go stale
local LOOKAHEAD = 1
---@param entry differ.FileEntry
local function prefetch_around(entry)
    local s = session
    if not s then
        return
    end
    local idx = viewed.index_of(s.entries, entry)
    if not idx then
        return
    end
    s.prefetching = s.prefetching or {}
    for _, dir in ipairs({ -1, 1 }) do
        for step = 1, LOOKAHEAD do
            local nb = s.entries[idx + dir * step]
            if nb and not s.versions[nb.path] and not s.prefetching[nb.path] then
                local path = nb.path
                s.prefetching[path] = true
                local refs = { base = s.pr_meta.base_sha, head = s.pr_meta.head_sha }
                client.get_file_versions(s.pr, nb, refs, function(err, vers)
                    if not guard.owns(s) then
                        return -- session torn down (or replaced) while it was in flight
                    end
                    s.prefetching[path] = nil
                    if not err and vers and pins_hold(s, refs) then
                        s.versions[path] = vers
                    end
                end)
            end
        end
    end
end

-- (re)source the one driven View for a file. base/head shas are pinned for the
-- session, so the per-path memo makes re-visits instant (no IPC hop); `focus_line`
-- holds the cursor across an in-place refresh of the same file
---@param entry differ.FileEntry
---@param focus_line integer|nil
local function show_file(entry, focus_line)
    local s = session
    if not s then
        return
    end
    local function render(vers)
        local base, head = vers.base or {}, vers.head or {}
        local model = require("differ.model.diff").build({
            path = entry.path,
            old_rev = short(session.pr_meta.base_sha),
            new_rev = short(session.pr_meta.head_sha),
            old_text = (base.missing and "") or base.content or "",
            new_text = (head.missing and "") or head.content or "",
            root = session.root,
        })
        if session.view and session.view:is_open() then
            session.view:set_source(model, nil, focus_line and { focus_line = focus_line } or nil)
        else
            session.view = require("differ").diff_model(model, {
                can_stage = false, -- read-only pr diff, no hunk staging

                extra_keymaps = session.diff_extra_keymaps, -- ]u/[u on the diff surface
                -- re-apply the thread overlay after a layout/context re-render, and
                -- expand the thread under the cursor as it moves
                on_rerender = function()
                    require("differ.pr.threads").apply(s)
                end,
                on_cursor = function()
                    require("differ.pr.threads").on_cursor(s)
                end,
                -- a Ctrl-O jump (or :edit) can swap the overview page back into the diff
                -- window; it's a live surface of this session, so re-enter it in place
                -- (like `go`) rather than letting the diff's close guard end the session
                on_repurpose = function(buf)
                    if not (session and require("differ.pr.overview").owns_buffer(buf)) then
                        return false
                    end
                    M.overview()
                    return true
                end,
            })
        end
        prefetch_around(entry) -- warm the neighbours so the next step is instant
        require("differ.pr.threads").refresh(s) -- (re)paint inline comment threads
        -- anchor position restore (resume / overview jump / overview hop): once the
        -- target file is rendered, drop the cursor on the anchor's mapped row, then
        -- clear the one-shot focus. anchor_row degrades an out-of-context line to the
        -- nearest rendered one, so an anchor outside the diff context still lands close
        local pf = session.pending_focus
        if pf and pf.path == entry.path and session.view and session.view:is_open() then
            session.pending_focus = nil
            local side = pf.side == "LEFT" and "old" or "new"
            local col = session.view:column_for(side)
            local idx = col and (side == "old" and col.map.from_old or col.map.from_new)
            local row = idx and require("differ.pr.threads").anchor_row(idx, pf.line)
            if row and col.winid and vim.api.nvim_win_is_valid(col.winid) then
                vim.api.nvim_win_set_cursor(col.winid, { row, 0 })
            end
        end
    end

    local cached = session.versions[entry.path]
    if cached then
        return render(cached)
    end
    -- the pinned shas skip the sidecar's prRefs round-trip (latency discipline); the
    -- entry rides along whole so a rename's base side is read from its previous_path
    local refs = { base = session.pr_meta.base_sha, head = session.pr_meta.head_sha }
    client.get_file_versions(session.pr, entry, refs, function(err, vers)
        if not guard.owns(s) then
            return -- session torn down (or replaced) while the blob was in flight
        end
        if err then
            return notify_err(err)
        end
        if not pins_hold(s, refs) then
            return -- the head moved in flight; handle_conflict's re-source owns the refetch
        end
        -- the memo is keyed on pinned shas, so it stands whether or not the panel is showing
        s.versions[entry.path] = vers
        -- the render additionally waits on a visible sidebar (the overview hop hides it)
        -- and on `entry` still being the shown file: a blob for a file stepped away from
        -- mid-flight would otherwise land over the one stepped to
        local cur = s.panel and s.panel:is_open() and s.panel:current_entry()
        if cur and cur.path == entry.path then
            render(vers)
        end
    end)
end

-- flip a file's viewed flag optimistically, repaint, then reconcile to the server's
-- returned viewed_state (roll back + flag on error). cheap and idempotent, so
-- the one optimistic update phase 4 allows. a no-op if already at `target`
---@param entry differ.FileEntry
---@param target boolean
local function mark_viewed(entry, target)
    if not (session and session.panel) or entry.viewed == target then
        return
    end
    local s = session
    local prev = entry.viewed
    entry.viewed = target
    s.panel:repaint()
    client.set_file_viewed(s.pr, entry.path, target, function(err, res)
        if not guard.owns(s) then
            return -- session torn down (or replaced) while the mutation was in flight
        end
        if err then
            entry.viewed = prev
            s.panel:repaint()
            return notify_err(err)
        end
        -- reconcile: DISMISSED counts as viewed, like map_files
        local server = res and (res.viewed_state == "VIEWED" or res.viewed_state == "DISMISSED")
        if server ~= nil and server ~= entry.viewed then
            entry.viewed = server
            s.panel:repaint()
        end
    end)
end

-- <Tab>: flip the viewed checkbox of the file under the panel cursor
local function toggle_viewed()
    local entry = session and session.panel and session.panel:current_entry()
    if entry then
        mark_viewed(entry, not entry.viewed)
    end
end

-- ]u/[u: jump to the nearest unviewed file (no wrap; notify when none remain).
-- forward nav marks the file being left as viewed, like ]f; backward never does
---@param direction "next"|"prev"
---@param keep_focus boolean  -- true when invoked from the diff (stay in the diff window)
local function nav_unviewed(direction, keep_focus)
    if not (session and session.panel) then
        return
    end
    local cur = session.panel:current_entry()
    local from = viewed.index_of(session.entries, cur) or 0
    local target = viewed.next_unviewed(session.entries, from, direction)
    if not target then
        return notify(
            direction == "next" and "no more unviewed files" or "no previous unviewed files"
        )
    end
    if direction == "next" and cur then
        mark_viewed(cur, true)
    end
    session.panel:goto_path(session.entries[target].path, keep_focus)
end

-- panel on_step: a forward ]f/[f step marks the file just left as viewed.
-- backward never marks, and a plain select (which never steps) marks nothing
---@param direction "next"|"prev"
---@param left differ.FileEntry|nil
local function on_step(direction, left)
    if direction == "next" and left then
        mark_viewed(left, true)
    end
end

-- the thread anchor group under the cursor in the diff, or nil. all four thread
-- actions key off the cursor row, so they read the same way from a keymap or a script
---@return table|nil  -- { key, bufnr, row, threads }
local function cursor_anchor()
    if not (session and session.view and session.view:is_open()) then
        return
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return require("differ.pr.threads").anchor_at(session, buf, row)
end

-- gc: collapse/expand the thread group under the cursor. an explicit toggle
-- overrides the cursor-peek default until toggled back; re-apply swaps the boxes in
-- place (stacked) or shows/hides the float (split), and a no-op off a thread row
function M.toggle_thread()
    local s = session
    local anchor = cursor_anchor()
    if not s or not anchor then
        return notify("no thread on this line")
    end
    local threads = require("differ.pr.threads")
    threads.toggle_group(s, anchor)
    threads.apply(s)
    threads.on_cursor(s) -- reopen/close the peek float to match the new state
end

-- ]t/[t: move the cursor to the next/prev thread anchor in the current diff column,
-- scanning the overlay index rather than the map so thread blocks (virt_lines, not
-- real rows) never enter ]c hunk motion. no wrap; notify when none remain
---@param direction "next"|"prev"
local function nav_thread(direction)
    if not (session and session.view and session.view:is_open()) then
        return
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local target =
        require("differ.pr.threads").next_anchor(session.thread_anchors, buf, row, direction)
    if not target then
        return notify(direction == "next" and "no more threads" or "no previous threads")
    end
    vim.api.nvim_win_set_cursor(win, { target, 0 })
end

function M.next_thread()
    nav_thread("next")
end

function M.prev_thread()
    nav_thread("prev")
end

-- gr: toggle the resolved state of the thread under the cursor (a cursor-context keymap,
-- not an ex-command). optimistic - flip + re-apply (highlight swap) immediately, then
-- reconcile to the
-- server's returned state, rolling back + flagging on error. one line can stack
-- several threads, so it acts on the first open one (else the first, to unresolve);
-- the sidecar flushes its thread cache after the mutation
function M.resolve()
    local s = session
    local anchor = cursor_anchor()
    if not s or not anchor then
        return notify("no thread on this line")
    end
    local target
    for _, t in ipairs(anchor.threads) do
        if not t.resolved then
            target = t
            break
        end
    end
    target = target or anchor.threads[1]
    if target.is_pending or not target.thread_id then
        return notify("this thread can't be resolved yet")
    end
    local threads = require("differ.pr.threads")
    local new_state = not target.resolved
    target.resolved = new_state
    threads.apply(s)
    client.resolve_thread(s.pr, target.thread_id, new_state, function(err, res)
        if not guard.owns(s) then
            return -- session torn down (or replaced) while the mutation was in flight
        end
        if err then
            target.resolved = not new_state
            threads.apply(s)
            return notify_err(err)
        end
        if res and res.resolved ~= nil and res.resolved ~= target.resolved then
            target.resolved = res.resolved
            threads.apply(s)
        end
    end)
end

-- shared conflict recovery: a mutation hit a moved head. re-fetch the PR
-- (fresh base/head sha), drop the blob memo + thread cache (both were pinned to the old
-- shas), re-source the current file + overlay, and flag the staleness. it never
-- auto-retries the mutation; the caller re-prompts the user against the refreshed head
---@param on_ready fun()|nil
function M.handle_conflict(on_ready)
    if not (session and session.panel) then
        return
    end
    local s = session
    client.get_pr(s.pr, function(err, detail)
        if not guard.owns(s) then
            return -- session torn down (or replaced) while the refetch was in flight
        end
        if err then
            return notify_err(err)
        end
        s.pr_meta.base_sha = detail.base_sha
        s.pr_meta.head_sha = detail.head_sha
        s.pr_meta.head_ref = detail.head_ref
        s.versions = {} -- the blob memo was pinned to the old shas
        require("differ.pr.threads").invalidate(s) -- refetch against the fresh head
        -- the memo drop above is the reconciliation; re-sourcing is a ui touch, so it
        -- waits on a visible sidebar and a hidden one just refetches on re-entry
        local cur = s.panel:is_open() and s.panel:current_entry()
        if cur then
            show_file(cur) -- re-source the diff + overlay at the new head
        end
        notify(
            "the PR head moved; refreshed to the latest - review and re-submit",
            vim.log.levels.WARN
        )
        if on_ready then
            on_ready()
        end
    end)
end

-- select a file + drop the cursor on a (side, line) anchor, mapped after the file
-- renders (used by resume position-restore and the overview's thread jump). a one-shot
-- via session.pending_focus; false when the path isn't in the panel (focus cleared)
---@param target { path: string, side: string, line: integer }
---@return boolean
function M.goto_anchor(target)
    if not (session and session.panel) then
        return false
    end
    session.pending_focus = target
    local landed = session.panel:goto_path(target.path, true) -- sources the file; render applies the focus
    if not landed then
        session.pending_focus = nil
    end
    return landed
end

-- warn when the local checkout isn't the PR head, once per session: the worktree file
-- the edit verbs open can then differ from the pinned blob the diff shows
-- (:Differ pr checkout aligns them). re-checked on every edit (HEAD can move
-- mid-session); the flag only silences repeats after a warning has fired
local function warn_head_mismatch()
    if not session or session.head_warned or not session.root then
        return
    end
    local local_head = require("differ.git").head_sha(session.root)
    local pr_head = session.pr_meta.head_sha
    if local_head and pr_head and local_head ~= pr_head then
        session.head_warned = true
        notify(
            "local checkout isn't the PR head; the file on disk may differ from the diff"
                .. " (:Differ pr checkout)",
            vim.log.levels.WARN
        )
    end
end

-- the shared guards for the pr edit verbs: an open diff and a local checkout
---@return table|nil view
local function editable_view()
    if not (session and session.view and session.view:is_open()) then
        notify("no active pull request diff")
        return nil
    end
    if not session.root then
        notify(
            ("editing needs a local clone of %s/%s"):format(
                session.coords.owner,
                session.coords.repo
            ),
            vim.log.levels.WARN
        )
        return nil
    end
    warn_head_mismatch()
    return session.view
end

-- df on the pr diff: edit the worktree file in a split beside the pinned-blob diff,
-- keeping the session. the diff keeps showing the pinned head (what the remote has);
-- the edit shows on the PR once pushed and the head moves
function M.edit_split()
    local view = editable_view()
    if view then
        view:edit_beside()
    end
end

-- de on the pr diff: zoom-edit the worktree file in its own tab; closing it (:q)
-- returns to the review exactly as left. overrides the generic jump_to_file bind,
-- which would tear the session down (leave-and-go is almost never right mid-review)
function M.edit_zoom()
    local view = editable_view()
    if view then
        view:edit_tab()
    end
end

-- the diff cursor as a one-shot anchor { path, side, line }, or nil without an open
-- diff. reads the new-side column's window cursor (valid even when focus is on the
-- panel) and maps the row to its nearest new-side source line, so a back-to-overview
-- hop can restore the position on re-entry
---@param s table
---@return table|nil
local function diff_anchor(s)
    local view = s.view
    if not (view and view:is_open() and view.model) then
        return nil
    end
    local col = view:column_for("new")
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return nil
    end
    -- the diff window may already show a foreign buffer (a Ctrl-O jump swapped the
    -- overview back in): its cursor row is meaningless against the diff's line map, so
    -- there's no diff position to stash
    if vim.api.nvim_win_get_buf(col.winid) ~= col.bufnr then
        return nil
    end
    local row = vim.api.nvim_win_get_cursor(col.winid)[1]
    local line = require("differ.nav").file_line(col.map, row)
    if not line then
        return nil
    end
    return { path = view.model.path, side = "RIGHT", line = line }
end

-- thin, scriptable wrappers over the review/comment modules, acting on the live session
function M.comment()
    if session then
        require("differ.pr.comment").comment(session)
    end
end
function M.comment_range()
    if session then
        require("differ.pr.comment").comment_range(session)
    end
end
function M.reply()
    if session then
        require("differ.pr.comment").reply(session)
    end
end
function M.delete_comment()
    if session then
        require("differ.pr.comment").delete(session)
    end
end

-- a short label for the diff winbar when `bufnr` is this PR session's diff and a pending
-- review is active, else nil (git diffs and immediate mode show nothing). lets the
-- draft state stay visible while reviewing, not just in the compose window
---@param bufnr integer
---@return string|nil
function M.review_status(bufnr)
    if not (session and session.review_id and session.view) then
        return nil
    end
    for _, col in ipairs(session.view.columns or {}) do
        if col.bufnr == bufnr then
            return "review draft"
        end
    end
    return nil
end
function M.submit()
    if not session then
        return notify("no active pull request")
    end
    require("differ.pr.review").submit(session)
end
function M.discard_review()
    if not session then
        return notify("no active pull request")
    end
    require("differ.pr.review").discard(session)
end

-- on open, adopt an existing pending review so commenting reflects draft mode from the
-- start: github allows one pending review per PR, so new comments join it as drafts
-- rather than posting immediately. a null review_id decodes to vim.NIL (truthy), so
-- guard on the string type
---@param pr { owner: string, repo: string, number: integer }
local function adopt_pending_review(pr)
    local s = session
    client.get_pending_review(pr, function(err, res)
        if err or not guard.owns(s) then
            return -- fetch failed, or the session was replaced/closed meanwhile
        end
        local review_id = res and res.review_id
        if type(review_id) == "string" and review_id ~= "" then
            s.review_id = review_id
            notify(
                "you have a pending review here - comments are drafts (:Differ pr review resume to manage)"
            )
        end
    end)
end

-- open the session tab for a fetched PR. the overview is the PR home, a panel-less
-- pre-review page; the file panel + diff (the review proper) build into the same
-- tab only when the user enters the files. so the panel construction is deferred behind
-- session.build_panel, called by the files landing and the overview's e/r
---@param pr { owner: string, repo: string, number: integer }
---@param detail table  -- get_pr result
---@param opts { after?: fun(), land?: string, review?: boolean }|nil
local function open_session(pr, detail, opts)
    local entries = M.map_files(detail.files)
    if #entries == 0 then
        return notify("no changed files in this pull request")
    end

    -- one session at a time; opening a PR over an existing one (a review panel or a
    -- lingering overview page) closes it first
    if session then
        M.end_session()
    end
    local Panel = require("differ.panel")
    local existing = Panel.current()
    if existing and existing:is_open() then
        existing:close()
    end

    local cfg = require("differ").get_config()
    local panel_cfg = cfg.panel or {}
    local title = detail.title or ("#" .. pr.number)
    local return_tab, session_tab = open_session_tab()

    session = {
        coords = { owner = pr.owner, repo = pr.repo },
        pr = pr,
        -- head_sha is captured here; the mutations send it as expected_head (TOCTOU).
        -- body/author/state/draft/mergeable are carried so the overview renders
        -- without a refetch (the detail is already in hand)
        pr_meta = {
            base_sha = detail.base_sha,
            head_sha = detail.head_sha,
            head_ref = detail.head_ref,
            url = detail.url,
            title = title,
            body = detail.body,
            author = detail.author,
            state = detail.state,
            draft = detail.draft,
            mergeable = detail.mergeable,
        },
        root = local_root(pr), -- optional; for jump-to-file
        entries = entries, -- flat FileEntry[] (single section), shared by ref with the panel
        versions = {}, -- per-path blob memo; valid for the session (shas are pinned)
        prefetching = {}, -- paths with an in-flight predictive prefetch (dedupe guard)
        threads = nil, -- PR-wide review threads, fetched by pr.threads.refresh
        threads_at = nil, -- when it was fetched; pr.threads expires it on a TTL
        threads_fail = nil, -- consecutive get_threads failures; drives the retry backoff
        thread_collapsed = {}, -- per thread_id collapse override (gc); nil = cursor-driven
        thread_active = nil, -- the anchor key (bufnr:row) the cursor expands (peek)
        review_id = nil, -- the active pending-review node id; nil = immediate mode
        pending_focus = nil, -- one-shot { path, side, line } for resume position-restore
        overview_return = nil, -- one-shot diff anchor stashed by a back-to-overview hop
        overview_cursor = nil, -- one-shot page {row, col} stashed on entering the review
        session_tab = session_tab, -- the tab hosting both the overview page and the review
        overview_win = vim.api.nvim_get_current_win(), -- the page window (pre-panel)
        ---@type differ.View|nil
        view = nil,
        ---@type differ.Panel|nil
        panel = nil, -- nil until the user enters the files (build_panel below)
    }

    -- the pr-only viewed actions, bound on the pr surfaces only: toggle
    -- on the panel, unviewed nav on both. the generic panel/diff don't own them, so
    -- they reach the buffer via the extra_keymaps seam, not the fixed action set
    local panel_km, diff_km = cfg.keymaps.panel, cfg.keymaps.diff
    -- the review lifecycle verbs, bound the same on both pr surfaces. each entry point
    -- guards itself (submit picks a verdict, discard confirms), so the keys act directly
    local function lifecycle(km)
        return {
            { spec = km.review_submit, fn = M.submit, desc = "submit the review" },
            { spec = km.review_discard, fn = M.discard_review, desc = "discard the review" },
        }
    end
    local panel_extra = {
        { spec = panel_km.overview, fn = M.overview, desc = "PR overview" },
        { spec = panel_km.toggle_viewed, fn = toggle_viewed, desc = "toggle viewed" },
        {
            spec = panel_km.next_unviewed,
            fn = function()
                nav_unviewed("next", false)
            end,
            desc = "next unviewed file",
        },
        {
            spec = panel_km.prev_unviewed,
            fn = function()
                nav_unviewed("prev", false)
            end,
            desc = "previous unviewed file",
        },
    }
    vim.list_extend(panel_extra, lifecycle(panel_km))
    -- the diff surface keeps focus in the diff window when stepping (keep_focus = true);
    -- the thread actions also bind here, via the same extra_keymaps seam
    session.diff_extra_keymaps = {
        {
            spec = diff_km.next_unviewed,
            fn = function()
                nav_unviewed("next", true)
            end,
            desc = "next unviewed file",
        },
        {
            spec = diff_km.prev_unviewed,
            fn = function()
                nav_unviewed("prev", true)
            end,
            desc = "previous unviewed file",
        },
        { spec = diff_km.next_thread, fn = M.next_thread, desc = "next thread" },
        { spec = diff_km.prev_thread, fn = M.prev_thread, desc = "previous thread" },
        { spec = diff_km.toggle_thread, fn = M.toggle_thread, desc = "toggle thread" },
        { spec = diff_km.resolve_thread, fn = M.resolve, desc = "resolve thread" },
        -- commenting: ga single (normal) / range (visual), gp reply to a thread
        { spec = diff_km.comment, fn = M.comment, desc = "comment" },
        { spec = diff_km.comment, fn = M.comment_range, desc = "comment on selection", mode = "x" },
        { spec = diff_km.reply, fn = M.reply, desc = "reply to thread" },
        { spec = diff_km.delete_comment, fn = M.delete_comment, desc = "delete comment" },
        -- back to the PR home, stashing the diff position for the return trip
        { spec = diff_km.overview, fn = M.overview, desc = "PR overview" },
        -- edit-in-review on the pinned-blob diff (the generic bind is gated to
        -- uncommitted sources, so the lhs is free here)
        {
            spec = diff_km.edit_file,
            fn = M.edit_split,
            desc = "edit the real file (in review)",
        },
        -- zoom-edit in its own tab; same lhs as the generic jump_to_file bind, which
        -- extras override (they bind later)
        {
            spec = diff_km.goto_file,
            fn = M.edit_zoom,
            desc = "edit the real file (zoom tab)",
        },
    }
    vim.list_extend(session.diff_extra_keymaps, lifecycle(diff_km))

    -- build the file panel + driven diff into the session tab. deferred so the overview
    -- stays panel-less; a no-op once the panel exists (entering the files reuses it)
    session.build_panel = function()
        if session.panel then
            return
        end
        local panel = Panel.new({
            sections = { { title = ("#%d %s"):format(pr.number, title), entries = entries } },
            root = ("%s/%s"):format(pr.owner, pr.repo),
            footer = detail.url or detail.head_ref,
            keymaps = cfg.keymaps.panel --[[@as differ.KeymapSet]],
            extra_keymaps = panel_extra,
            on_step = on_step,
            listing = panel_cfg.listing,
            position = panel_cfg.position,
            height = panel_cfg.height,
            width = panel_cfg.width,
            icons = panel_cfg.icons,
            progress = panel_cfg.progress,
            on_select = function(entry)
                show_file(entry)
            end,
            on_close = function()
                require("differ.pr.threads").close_peek() -- drop the peek float, if open
                if session and session.view and session.view:is_open() then
                    session.view:close()
                end
                close_session_tab(session_tab)
                require("differ.pr.overview").teardown() -- wipe the reused page buffer
                session = nil
            end,
        }):open()
        panel.return_tab = return_tab
        session.panel = panel
    end

    -- the overview lands first (pre-review page); the files landings build the panel and
    -- open the first file's diff (DiffviewOpen-style)
    if (opts and opts.land) == "overview" then
        return require("differ.pr.overview").open(session)
    end

    session.build_panel()
    session.panel:select(true)
    if opts and opts.review then
        require("differ.pr.review").start(session) -- review <n>: start the draft
    end
    -- adopt an existing draft once: review <n> already established it via start_review
    -- (idempotent reattach), and resume reattaches in opts.after; otherwise detect one
    if opts and opts.after then
        opts.after() -- e.g. resume: reattach the pending draft + restore position
    elseif not (opts and opts.review) then
        adopt_pending_review(pr)
    end
end

-- enter the review proper (panel + diff) for the live session, building the panel on
-- first entry or revealing it after a back-to-overview hop, then landing on `focus`'s
-- anchor when given (overview thread jump) or on the panel's current file. used by the
-- overview's e/r and <CR>, and by view/review re-entry on a live session
---@param review boolean|nil
---@param focus { path: string, side: string, line: integer }|nil
local function enter_files(review, focus)
    if not session then
        return
    end
    local first = not session.panel
    if first then
        session.build_panel()
    elseif not session.panel:is_open() then
        session.panel:show() -- revealing a sidebar hidden by a back-to-overview hop
    end
    require("differ.pr.overview").disarm() -- the page window is the diff's now
    -- an explicit focus (thread jump) wins over the back-hop stash; either way the
    -- stash is consumed, so a later plain entry doesn't replay a stale position
    local target = focus or session.overview_return
    session.overview_return = nil
    local positioned = target ~= nil and M.goto_anchor(target)
    if not positioned then
        session.panel:select(true)
    end
    if review then
        -- idempotent; a pending draft reattaches. it only picks the landing file when
        -- we haven't already honoured an explicit target (the overview's thread rows)
        require("differ.pr.review").start(session, { jump = not positioned })
    elseif first then
        adopt_pending_review(session.pr)
    end
end

-- enter the review at a thread anchor (the overview's <CR>/e/r on a timeline thread).
-- review starts a pending review on entry (the overview's r), like review <n>
---@param target { path: string, side: string, line: integer }
---@param review boolean|nil
function M.enter_at(target, review)
    M.with_session(function()
        enter_files(review or false, target)
    end)
end

-- M.show(pr): fetch the PR and open its session. opts threads the landing target into
-- open_session: land ("overview"|"files"), review (fire start_review after landing), and
-- after (resume uses it to reattach the pending draft once the session is built)
---@param pr { owner: string, repo: string, number: integer }
---@param opts { after?: fun(), land?: string, review?: boolean }|nil
function M.show(pr, opts)
    open_gen = open_gen + 1
    local gen = open_gen
    client.get_pr(pr, function(err, detail)
        if gen ~= open_gen then
            return -- a later open superseded this one; its error isn't the user's problem
        end
        if err then
            return notify_err(err)
        end
        open_session(pr, detail, opts)
    end)
end

-- present the list_prs picker. the one transient selector the PR flow still uses
--: a PR list is a genuine pick step with no obvious panel home. a pick lands on
-- whichever `land` the caller chose (a bare list lands on the overview, view on files)
---@param coords { owner: string, repo: string }
---@param prs table[]
---@param land_opts { land?: string, review?: boolean }|nil
local function pick(coords, prs, land_opts)
    vim.ui.select(prs, {
        prompt = "Select a pull request",
        ---@param pr table
        format_item = function(pr)
            local draft = pr.draft and " [draft]" or ""
            return ("#%d %s · @%s %s%s"):format(
                pr.number,
                pr.title,
                pr.author,
                reltime(pr.updated_at),
                draft
            )
        end,
    }, function(choice)
        if not choice then
            return
        end
        M.show({ owner = coords.owner, repo = coords.repo, number = choice.number }, land_opts)
    end)
end

-- whether the live session already is this PR (same number + repo), so a re-entry can
-- skip the refetch/rebuild and just move focus. an opts without coords matches the live
-- repo (the overview's e/r passes only a number)
---@param opts { number?: integer, coords?: { owner: string, repo: string } }
---@return boolean
local function session_matches(opts)
    if not (session and opts.number and session.pr.number == opts.number) then
        return false
    end
    if opts.coords then
        return session.coords.owner == opts.coords.owner and session.coords.repo == opts.coords.repo
    end
    return true
end

-- M.open(opts): the entry point. resolve coords, then either jump straight to a known
-- PR number or list PRs and pick one. `land` selects the landing surface (default the
-- overview home); `review` fires start_review after landing on the files
---@param opts { number?: integer, filter?: string, coords?: table, land?: string, review?: boolean }|nil
function M.open(opts)
    opts = opts or {}
    opts.land = opts.land or "overview"
    -- already on this PR's session (the overview's e/r is the common case): enter the
    -- files without a refetch/rebuild, building or revealing the panel as needed
    if opts.land == "files" and session_matches(opts) then
        return enter_files(opts.review)
    end
    repo.resolve(opts --[[@as { coords?: { owner: string, repo: string } }]], function(err, coords)
        if err then
            return notify_err(err)
        end
        if not coords then
            return
        end
        if opts.number then
            return M.show(
                { owner = coords.owner, repo = coords.repo, number = opts.number },
                { land = opts.land, review = opts.review }
            )
        end
        client.list_prs(coords, opts.filter, function(lerr, prs)
            if lerr then
                return notify_err(lerr)
            end
            if not prs or #prs == 0 then
                return notify("no pull requests for " .. coords.owner .. "/" .. coords.repo)
            end
            pick(coords, prs, { land = opts.land, review = opts.review })
        end)
    end)
end

-- thin verb wrappers the command + overview keymaps call. view enters the file diff;
-- review enters + starts a review. with no number they act on the active session (the
-- overview's PR), so `:Differ pr view`/`review` from the home enter that PR's files; with
-- no number and no session, view falls to the picker
---@param opts { number?: integer }|nil
function M.view(opts)
    local number = (opts and opts.number) or (session and session.pr.number)
    return M.open({ number = number, land = "files" })
end

---@param opts { number?: integer }|nil
function M.review(opts)
    if opts and opts.number then
        return M.open({ number = opts.number, land = "files", review = true })
    end
    if not session then
        return notify("no active pull request")
    end
    -- no number: act on the active session. on the overview (no panel) enter the files
    -- and start the review; already in the review, just start it (slice 4, no file jump)
    if session.panel then
        return require("differ.pr.review").start(session)
    end
    return M.open({ number = session.pr.number, land = "files", review = true })
end

-- :Differ pr overview (and the diff/panel `go`) - go back to the PR home from the
-- review (closes the diff + hides the panel, keeping the session), or re-show it while
-- already on the page. the diff position is stashed so re-entering the files restores
-- it; re-showing from the page keeps an earlier stash rather than clobbering it
function M.overview()
    M.with_session(function(s)
        s.overview_return = diff_anchor(s) or s.overview_return
        require("differ.pr.overview").open(s)
    end)
end

-- the live session, exposed for pr/overview.lua (the module-local is nil after teardown)
---@return table|nil
function M.current_session()
    return session
end

-- run fn with the active session, or notify and bail. the single gate the synchronous
-- session-context verbs (checks / overview / checkout / share) pass through, so "no active
-- pull request" reads the same everywhere. a session counts as active in either phase, the
-- panel-less overview page or the review proper, so the guard is just session presence (the
-- overview's verbs run before any panel exists). openers (open/view/review <n>) don't use
-- this: they create the session. the async-mutating verbs (merge / set_state / review
-- actions) keep their own guard so their in-flight teardown re-checks stay module-local
---@param fn fun(session: table)
function M.with_session(fn)
    if not session then
        return notify("no active pull request")
    end
    fn(session)
end

-- end the live session in either phase: the review panel's on_close closes the diff +
-- tab, while a pre-review overview page just drops its window + tab. exposed for the
-- overview page (its q and its navigate-away guard call it)
function M.end_session()
    if not session then
        return
    end
    require("differ.pr.overview").disarm()
    require("differ.pr.threads").close_peek()
    if session.panel then
        return session.panel:close() -- on_close closes the diff + tab and nils session
    end
    local tab = session.session_tab
    session = nil
    close_session_tab(tab)
    require("differ.pr.overview").teardown() -- wipe the reused page buffer
end

-- ── PR lifecycle ───────────────────────────────────────────────────────────────────

-- lifecycle verb -> the set_pr_state value the sidecar expects. pure, so the
-- mapping is unit-tested; an unknown verb returns nil
---@type table<string, string>
local VERB_STATE = {
    ready = "ready",
    draft = "draft",
    close = "closed",
    reopen = "open",
}

-- merge and close mutate irreversibly, so they confirm first; ready/draft/reopen
-- are reversible and act without a prompt
---@type table<string, true>
local DESTRUCTIVE = { merge = true, close = true }

---@type table<string, true>
local MERGE_METHODS = { squash = true, merge = true, rebase = true }

-- verb -> set_pr_state value, or nil for an unknown verb
---@param verb string
---@return string|nil
function M.state_for_verb(verb)
    return VERB_STATE[verb]
end

-- normalise a merge-method arg to a valid method, defaulting to squash
---@param arg string|nil
---@return string
function M.merge_method(arg)
    return (arg and MERGE_METHODS[arg]) and arg or "squash"
end

-- whether `verb` confirms before acting (merge/close)
---@param verb string
---@return boolean
function M.is_destructive(verb)
    return DESTRUCTIVE[verb] == true
end

-- a yes/no gate for destructive actions. vim.fn.confirm blocks until answered;
-- the default button is "No" so a stray <CR> never fires the action
---@param prompt string
---@param on_yes fun()
local function confirm(prompt, on_yes)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
        on_yes()
    end
end

---@return string
local function pr_title()
    return (session and session.pr_meta.title) or ("#" .. (session and session.pr.number or "?"))
end

-- :Differ pr merge [squash|merge|rebase] - confirm, then merge with the chosen method.
-- a `conflict` error means the Go side pre-check found the PR unmergeable; surface that
-- rather than treating it as an internal failure. on success the PR is merged, so the
-- session closes (its blobs are now history)
---@param method_arg string|nil
function M.merge(method_arg)
    if not session then
        return notify("no active pull request")
    end
    local method = M.merge_method(method_arg)
    confirm(('merge "%s" via %s?'):format(pr_title(), method), function()
        if not session then
            return
        end
        local s = session
        client.merge_pr(s.pr, { method = method }, function(err, res)
            if not guard.owns(s) then
                return -- session torn down (or replaced) while the merge was in flight
            end
            if err then
                if err.code == "conflict" then
                    return notify(
                        "not mergeable: " .. (err.message or "merge blocked"),
                        vim.log.levels.WARN
                    )
                end
                return notify_err(err)
            end
            local sha = res and res.sha
            notify(("merged" .. (sha and (" (" .. short(sha) .. ")") or "")))
            s.pr_meta.state = "merged"
            if guard.panel_alive(s) then
                s.panel:close() -- the PR is merged; end the session
            end
        end)
    end)
end

-- :Differ pr ready|draft|close|reopen - map the verb to a state and transition. close
-- confirms (destructive); the reversible verbs act immediately. on success the session's
-- cached state/draft flags follow the server's echoed state
---@param verb string
function M.set_state(verb)
    if not session then
        return notify("no active pull request")
    end
    local state = M.state_for_verb(verb)
    if not state then
        return notify("unknown lifecycle verb: " .. tostring(verb), vim.log.levels.WARN)
    end
    local function run()
        local s = session
        client.set_pr_state(s.pr, state, function(err, res)
            if not guard.owns(s) then
                return -- session torn down (or replaced) while the mutation was in flight
            end
            if err then
                return notify_err(err)
            end
            local new_state = (res and res.state) or state
            s.pr_meta.state = new_state
            s.pr_meta.draft = new_state == "draft"
            notify("pull request " .. new_state)
        end)
    end
    if M.is_destructive(verb) then
        confirm(('close "%s"?'):format(pr_title()), run)
    else
        run()
    end
end

-- :Differ pr checkout - local git on the session's head_ref (client-side, no
-- sidecar round-trip): fetch the ref + check it out via the local git plumbing
function M.checkout()
    M.with_session(function(s)
        local ref = s.pr_meta.head_ref
        if not ref or ref == "" then
            return notify("no head branch to check out", vim.log.levels.WARN)
        end
        local git = require("differ.git")
        -- no cwd fallback: fetching the pr's refs into an unrelated repo lands whatever
        -- its own refs/pull/<n>/head happens to be, under this pr's branch name
        local root = s.root
        if not root then
            return notify(
                ("checkout needs a local clone of %s/%s"):format(s.coords.owner, s.coords.repo),
                vim.log.levels.WARN
            )
        end
        local ok, err = git.checkout(root, ref, s.pr.number)
        if not ok then
            return notify(
                "checkout failed: " .. (err and vim.trim(err) or ref),
                vim.log.levels.ERROR
            )
        end
        notify("checked out " .. ref)
    end)
end

-- :Differ pr browser - open the PR's html url in the system browser (client-side,
-- the `url` field from get_pr; no sidecar round-trip)
function M.browser()
    M.with_session(function(s)
        local url = s.pr_meta.url
        if not url or url == "" then
            return notify("no PR url", vim.log.levels.WARN)
        end
        vim.ui.open(url)
    end)
end

-- :Differ pr url - yank the PR's html url to the system clipboard (client-side)
function M.url()
    M.with_session(function(s)
        local url = s.pr_meta.url
        if not url or url == "" then
            return notify("no PR url", vim.log.levels.WARN)
        end
        vim.fn.setreg("+", url)
        notify("yanked " .. url)
    end)
end

-- :Differ pr checks - the read-only CI checks view
function M.checks()
    M.with_session(function(s)
        require("differ.pr.checks").show(s)
    end)
end

-- M.resume(arg): reattach a pending review. a number (or owner/repo#number)
-- opens that PR then reattaches + restores position; no arg reattaches the currently
-- open PR's draft. with no arg and no session, there's nothing to target
---@param arg string|nil
function M.resume(arg)
    local function open_then_reattach(pr)
        M.show(pr, {
            after = function()
                if session then
                    require("differ.pr.review").reattach(session)
                end
            end,
        })
    end
    if arg and arg ~= "" then
        local owner, repo_name, num = arg:match("^([^/]+)/([^#]+)#(%d+)$")
        if owner then
            return open_then_reattach({ owner = owner, repo = repo_name, number = tonumber(num) })
        end
        local n = tonumber(arg)
        if not n then
            return notify("resume expects a PR number or owner/repo#number", vim.log.levels.WARN)
        end
        return repo.resolve({}, function(err, coords)
            if err then
                return notify_err(err)
            end
            open_then_reattach({ owner = coords.owner, repo = coords.repo, number = n })
        end)
    end
    if not session then
        return notify("no active pull request - open one with :Differ pr review <number>")
    end
    require("differ.pr.review").reattach(session)
end

return M
