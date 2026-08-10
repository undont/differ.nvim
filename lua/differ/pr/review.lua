-- the pending-review draft lifecycle: start/reattach a draft, submit it as one
-- batch with an event, or discard it. while session.review_id is set, comments compose
-- as drafts (pr/comment.lua); submit/discard clear it and return to immediate mode.
-- every mutation carries the session head as expected_head for the TOCTOU guard,
-- and reacts to a conflict by refreshing rather than auto-retrying

local client = require("differ.pr.client")
local guard = require("differ.pr.guard")

local M = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- re-fetch threads so the overlay reflects a draft/submit/discard authoritatively (the
-- sidecar invalidates its thread cache on each mutation)
---@param session table
local function repaint_threads(session)
    session.threads = nil
    require("differ.pr.threads").refresh(session)
end

-- a diff column window for the compose split to anchor to (the summary has no line
-- anchor of its own, so it just rides off a visible diff column)
---@param session table
---@return integer|nil
local function diff_win(session)
    for _, col in ipairs((session.view and session.view.columns) or {}) do
        if col.winid and vim.api.nvim_win_is_valid(col.winid) then
            return col.winid
        end
    end
end

-- :Differ pr review - start (or reattach to) the viewer's pending draft. idempotent in
-- the sidecar, so this never orphans a second draft. a session that's already drafting
-- reattaches instead of refusing, so the one gesture always lands you in the review
---@param session table
---@param opts { jump?: boolean }|nil  -- jump=false when the caller already positioned
function M.start(session, opts)
    if session.review_id then
        return M.reattach(session, opts)
    end
    client.start_review(session.pr, function(err, res)
        if not guard.owns(session) then
            return
        end
        if err then
            return require("differ.pr").notify_err(err)
        end
        session.review_id = res and res.review_id
        notify("review started - comments are drafts until you submit")
    end)
end

-- :Differ pr review resume - reattach the current session to its pending draft and land
-- on the first file still unviewed, since resuming asks what's left to review rather
-- than what was last said. also the path `start` takes when a draft already exists.
-- opts.jump = false leaves the cursor alone for a caller that already positioned (the
-- overview's thread rows). a no-op notice when there's no draft
---@param session table
---@param opts { jump?: boolean }|nil
function M.reattach(session, opts)
    client.get_pending_review(session.pr, function(err, res)
        if not guard.owns(session) then
            return
        end
        if err then
            return require("differ.pr").notify_err(err)
        end
        -- a PR with no draft decodes review_id as null -> vim.NIL (userdata, truthy),
        -- so guard on the string type rather than truthiness
        local review_id = res and res.review_id
        if type(review_id) ~= "string" or review_id == "" then
            return notify("no pending review to resume on this PR")
        end
        session.review_id = review_id
        if not (opts and opts.jump == false) then
            -- nothing unviewed means nothing left to resume onto, so the panel's
            -- current selection stands and the cursor stays put
            local next_up =
                require("differ.pr.viewed").next_unviewed(session.entries or {}, 0, "next")
            if next_up and session.panel then
                session.panel:goto_path(session.entries[next_up].path)
            end
        end
        notify("resumed your pending review - comments are drafts")
    end)
end

-- :Differ pr review submit - finalise the draft as one batch. pick an event, author a summary
-- in the compose float, then submit with the session head guard. on success the drafts
-- become published (re-fetched) and immediate mode resumes
---@param session table
function M.submit(session)
    if not session.review_id then
        return notify("no active review to submit; start one with :Differ pr review")
    end
    vim.ui.select({ "COMMENT", "APPROVE", "REQUEST_CHANGES" }, {
        prompt = "Submit review as",
    }, function(event)
        if not event then
            return -- cancelled the pick; nothing submitted
        end
        require("differ.ui.compose").open({
            title = "Review summary · " .. event,
            layout = session.view and session.view.layout,
            anchor_win = diff_win(session),
            on_submit = function(body)
                M._do_submit(session, event, body)
            end,
        })
    end)
end

---@param session table
---@param event string
---@param body string
function M._do_submit(session, event, body)
    client.submit_review(session.pr, {
        review_id = session.review_id,
        event = event,
        body = body,
        expected_head = session.pr_meta.head_sha,
    }, function(err, _)
        if not guard.owns(session) then
            return
        end
        if err then
            if err.code == "conflict" then
                return require("differ.pr").handle_conflict(function()
                    notify("re-submit your review against the refreshed head", vim.log.levels.WARN)
                end)
            end
            return require("differ.pr").notify_err(err)
        end
        session.review_id = nil
        repaint_threads(session)
        notify("review submitted · " .. event)
    end)
end

-- :Differ pr review discard - drop the pending draft and its unsubmitted comments. destructive,
-- so it confirms first; the draft threads then vanish from the overlay
---@param session table
function M.discard(session)
    if not session.review_id then
        return notify("no active review to discard")
    end
    if
        vim.fn.confirm("Discard the pending review and its draft comments?", "&Yes\n&No", 2) ~= 1
    then
        return
    end
    client.discard_review(session.pr, session.review_id, function(err, _)
        if not guard.owns(session) then
            return
        end
        if err then
            return require("differ.pr").notify_err(err)
        end
        session.review_id = nil
        repaint_threads(session)
        notify("review discarded")
    end)
end

return M
