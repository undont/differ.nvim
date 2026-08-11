-- commenting from a diff gesture: turn the cursor (single line) or a visual
-- selection (range) into a github anchor, author the body in the compose float, and post
-- it. a comment joins the pending draft when session.review_id is set and posts
-- immediately otherwise. replies attach to the thread under the cursor by its node id.
-- the anchor-from-gesture helpers are pure (map + rows in, anchor out) so they unit-test
-- without nvim; compose/post own the vim + IPC surface

local client = require("differ.pr.client")
local guard = require("differ.pr.guard")

local M = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- ── anchor from gesture (pure, unit-tested) ───────────────────────────────────────

-- a single buffer row -> a github anchor { side, line }, or nil + reason. a split
-- column is single-sided (its side is fixed); the unified/stacked column reads the
-- row's kind: a deletion anchors LEFT/old, anything else commentable anchors RIGHT/new.
-- a meta/filler row (no diff line) is rejected
---@param map differ.LineMap
---@param row integer
---@param colside "old"|"new"|"unified"
---@return table|nil anchor, string|nil err
function M.row_anchor(map, row, colside)
    local e = map and map.lines and map.lines[row]
    if not e or e.kind == "meta" then
        return nil, "no commentable line here"
    end
    if colside == "old" then
        if e.old then
            return { side = "LEFT", line = e.old }
        end
    elseif colside == "new" then
        if e.new then
            return { side = "RIGHT", line = e.new }
        end
    else -- unified
        if e.kind == "old" and e.old then
            return { side = "LEFT", line = e.old }
        elseif e.new then
            return { side = "RIGHT", line = e.new }
        elseif e.old then
            return { side = "LEFT", line = e.old }
        end
    end
    return nil, "no commentable line here"
end

-- a visual selection (two rows) -> a range anchor with start_* + end, or a single
-- anchor when the rows collapse. a same-side range needs start_line < line; the LEFT→
-- RIGHT replacement range is allowed (Go validates membership); a RIGHT→LEFT selection
-- is something github can't represent and is rejected client-side, before the wire
---@param map differ.LineMap
---@param row1 integer
---@param row2 integer
---@param colside "old"|"new"|"unified"
---@return table|nil anchor, string|nil err
function M.range_anchor(map, row1, row2, colside)
    local lo, hi = math.min(row1, row2), math.max(row1, row2)
    local a, err = M.row_anchor(map, lo, colside)
    if not a then
        return nil, err
    end
    local b, err2 = M.row_anchor(map, hi, colside)
    if not b then
        return nil, err2
    end
    if lo == hi then
        return b
    end
    if a.side == b.side then
        if a.line >= b.line then
            return b -- degenerate same-side span; anchor the end line
        end
        return { start_side = a.side, start_line = a.line, side = b.side, line = b.line }
    end
    if a.side == "LEFT" and b.side == "RIGHT" then
        return { start_side = "LEFT", start_line = a.line, side = "RIGHT", line = b.line }
    end
    return nil, "mixed-side selection GitHub can't represent"
end

-- ── gesture entry points (vim surface) ────────────────────────────────────────────

-- the diff column the cursor is in (its bufnr matches), with the window, or nil
---@param session table
---@return table|nil column, integer|nil win
local function active_column(session)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    for _, col in ipairs((session.view and session.view.columns) or {}) do
        if col.bufnr == buf then
            return col, win
        end
    end
end

-- the file the gesture was made against. the compose window is a real split, so the
-- diff can move (or close) before the body is submitted; the anchor's path is fixed
-- at the same instant as its side/line
---@param session table
---@return string|nil
local function gesture_path(session)
    local model = session.view and session.view.model
    return model and model.path
end

-- ga (normal): comment on the line under the cursor
---@param session table
function M.comment(session)
    local col, win = active_column(session)
    if not col then
        return notify("place the cursor in the diff to comment")
    end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local anchor, err = M.row_anchor(col.map, row, col.side)
    if not anchor then
        return notify(err or "no commentable line here")
    end
    M.compose(session, { anchor = anchor, anchor_win = win, path = gesture_path(session) })
end

-- ga (visual): comment on the selected range. reads the visual marks before leaving
-- visual mode, then composes against the resolved range anchor
---@param session table
function M.comment_range(session)
    local col, win = active_column(session)
    if not col then
        return notify("select inside the diff to comment")
    end
    local r1 = vim.fn.line("v")
    local r2 = vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local anchor, err = M.range_anchor(col.map, r1, r2, col.side)
    if not anchor then
        return notify(err or "no commentable line here")
    end
    M.compose(session, { anchor = anchor, anchor_win = win, path = gesture_path(session) })
end

-- gp: reply to the thread under the cursor (its node id, from slice 3's overlay index)
---@param session table
function M.reply(session)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local anchor = require("differ.pr.threads").anchor_at(session, buf, row)
    if not anchor then
        return notify("no thread under the cursor to reply to")
    end
    M.compose(session, { in_reply_to = anchor.threads[1].thread_id, anchor_win = win })
end

-- gx: delete the most recent comment of the thread under the
-- cursor (usually a draft you just wrote). deleting the only/root comment removes the
-- whole thread; a later comment deletes just that reply. confirms first (destructive),
-- then re-fetches so the overlay updates
---@param session table
function M.delete(session)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local anchor = require("differ.pr.threads").anchor_at(session, buf, row)
    if not anchor then
        return notify("no thread under the cursor to delete from")
    end
    local thread = anchor.threads[1]
    local comments = thread.comments or {}
    -- comments is capped; newest_comment is the thread's last one whatever its length
    local target = thread.newest_comment
    if not (target and target.node_id and target.node_id ~= "") then
        return notify("this comment can't be deleted")
    end
    local snippet = (target.body or ""):match("[^\n]*") or ""
    if #snippet > 40 then
        snippet = snippet:sub(1, 39) .. "…"
    end
    local root = #comments == 1
    local prompt = (root and 'Delete this thread? "' or 'Delete the last reply? "')
        .. snippet
        .. '"'
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
        return
    end
    client.delete_comment(session.pr, target.node_id, function(err, _)
        if not guard.owns(session) then
            return -- session torn down (or replaced) while the delete was in flight
        end
        if err then
            return require("differ.pr").notify_err(err)
        end
        local threads = require("differ.pr.threads")
        threads.invalidate(session)
        threads.refresh(session)
        notify(root and "thread deleted" or "comment deleted")
    end)
end

-- ── compose + post ────────────────────────────────────────────────────────────────

-- where a comment attaches, and how it composes. anchor + path address a new thread and
-- are fixed together at gesture time; in_reply_to addresses an existing one instead
---@class differ.pr.CommentOpts
---@field anchor table|nil  -- { side, line } or a range's { start_side, start_line, side, line }
---@field path string|nil  -- the file the anchor is against
---@field anchor_win integer|nil  -- diff window the compose split opens below
---@field in_reply_to string|nil  -- thread node id, in place of anchor + path
---@field initial string|nil  -- pre-filled body (the conflict re-prompt)
---@field stale boolean|nil  -- the head moved under the original anchor

-- open the compose float for `opts` (a gesture anchor, or a reply target). the title
-- names the mode so a live post is never mistaken for a draft: draft when a review is
-- active, "posts immediately" otherwise
---@param session table
---@param opts differ.pr.CommentOpts
function M.compose(session, opts)
    local base = opts.in_reply_to and "Reply"
        or (session.review_id and "Comment (draft)" or "Comment (posts immediately)")
    require("differ.ui.compose").open({
        title = opts.stale and (base .. " — head moved, re-submit") or base,
        initial = opts.initial,
        layout = session.view and session.view.layout,
        anchor_win = opts.anchor_win,
        on_submit = function(text)
            if text == "" then
                return notify("empty comment discarded")
            end
            M.post(session, opts, text)
        end,
    })
end

-- post the composed body: assemble the post_comment args (a reply by node id, else the
-- new-thread anchor), attach review_id when drafting and the session head for the
-- guard, then re-fetch threads on success so the new comment renders authoritatively.
-- a conflict means the head moved: refresh + re-anchor + re-prompt, never a silent post
---@param session table
---@param opts differ.pr.CommentOpts
---@param body string
function M.post(session, opts, body)
    local args = { body = body, expected_head = session.pr_meta.head_sha }
    if opts.in_reply_to then
        args.in_reply_to = opts.in_reply_to
    else
        local a = opts.anchor
        if not opts.path then
            return notify("lost track of the file this comment anchors to; nothing posted")
        end
        args.path = opts.path
        args.side, args.line = a.side, a.line
        args.start_side, args.start_line = a.start_side, a.start_line
    end
    if session.review_id then
        args.review_id = session.review_id
    end
    client.post_comment(session.pr, args, function(err, res)
        if not guard.owns(session) then
            return -- session torn down (or replaced) while the post was in flight
        end
        if err then
            if err.code == "conflict" then
                return require("differ.pr").handle_conflict(function()
                    M.compose(
                        session,
                        vim.tbl_extend("force", {}, opts, { initial = body, stale = true })
                    )
                end)
            end
            return require("differ.pr").notify_err(err)
        end
        -- an immediate comment lands in an existing pending review when one exists
        -- (github allows one per PR); adopt it so the session knows it's drafting and
        -- submit/discard work
        if res and res.review_id and res.review_id ~= "" then
            session.review_id = res.review_id
        end
        -- the sidecar invalidated its thread cache on the post, so a fresh fetch carries
        -- the new comment (right author/draft state, correct thread grouping)
        local threads = require("differ.pr.threads")
        threads.invalidate(session)
        threads.refresh(session)
        notify(session.review_id and "comment added to your review draft" or "comment posted")
    end)
end

return M
