-- typed wrappers over the generic sidecar request. each forwards cb(err,
-- result); no caching or retry here (that lives in Go). the `pr` shorthand is
-- {owner, repo, number}, but the sidecar decodes those fields flat (the handlers
-- embed them, not a nested `pr` object), so every method sends owner/repo/number at
-- the top level. result shapes are fixed by

local sidecar = require("differ.sidecar")

local M = {}

-- list_prs result: [{number, title, author, head_ref, updated_at, draft}]
---@param coords { owner: string, repo: string }
---@param filter string|nil  -- open|mine|review_requested (defaults to open)
---@param cb fun(err: table|nil, result: any)
function M.list_prs(coords, filter, cb)
    sidecar.request(
        "list_prs",
        { owner = coords.owner, repo = coords.repo, filter = filter or "open" },
        cb
    )
end

-- get_pr result: {title, body, author, base_sha, head_sha, head_ref, url, state,
-- draft, mergeable, files: [{path, status, additions, deletions, previous_path?,
-- viewed_state}]}
---@param pr { owner: string, repo: string, number: integer }
---@param cb fun(err: table|nil, result: any)
function M.get_pr(pr, cb)
    sidecar.request("get_pr", { owner = pr.owner, repo = pr.repo, number = pr.number }, cb)
end

-- get_file_versions result: {base: {content, missing?}, head: {content, missing?},
-- truncated?}. the sidecar fetches `path` at both the base and head refs. pass the
-- pinned `refs` ({base, head} from get_pr) so the sidecar skips the prRefs round-trip
-- and fetches the exact session blobs; omit to let the sidecar resolve them
---@param pr { owner: string, repo: string, number: integer }
---@param path string
---@param refs { base?: string, head?: string }|nil
---@param cb fun(err: table|nil, result: any)
function M.get_file_versions(pr, path, refs, cb)
    refs = refs or {}
    sidecar.request("get_file_versions", {
        owner = pr.owner,
        repo = pr.repo,
        number = pr.number,
        path = path,
        base = refs.base,
        head = refs.head,
    }, cb)
end

-- set_file_viewed result: {viewed_state} (VIEWED|DISMISSED|UNVIEWED). flips the
-- github "Viewed" checkbox for `path` on the PR
---@param pr { owner: string, repo: string, number: integer }
---@param path string
---@param viewed boolean
---@param cb fun(err: table|nil, result: any)
function M.set_file_viewed(pr, path, viewed, cb)
    sidecar.request(
        "set_file_viewed",
        { owner = pr.owner, repo = pr.repo, number = pr.number, path = path, viewed = viewed },
        cb
    )
end

-- get_threads result: [{id, thread_id, path, side, line, start_side?, start_line?,
-- resolved, is_pending, comments_truncated, newest_comment?:{node_id, body},
-- comments:[{id, node_id, author, body, created_at}]}]. PR-wide; the frontend keeps it
-- per session and filters to the current file's path when painting. comments is capped
-- (comments_truncated says so); newest_comment is the thread's last one regardless
---@param pr { owner: string, repo: string, number: integer }
---@param cb fun(err: table|nil, result: any)
function M.get_threads(pr, cb)
    sidecar.request("get_threads", { owner = pr.owner, repo = pr.repo, number = pr.number }, cb)
end

-- resolve_thread result: {resolved}. `thread_id` is the graphql node id from
-- get_threads; the pr coords are still sent (the sidecar validates them and keys its
-- thread-cache invalidation on them)
---@param pr { owner: string, repo: string, number: integer }
---@param thread_id string
---@param resolved boolean
---@param cb fun(err: table|nil, result: any)
function M.resolve_thread(pr, thread_id, resolved, cb)
    sidecar.request("resolve_thread", {
        owner = pr.owner,
        repo = pr.repo,
        number = pr.number,
        thread_id = thread_id,
        resolved = resolved,
    }, cb)
end

-- get_timeline result: {comments:[{author, body, created_at}], reviews:[{author,
-- state, body, created_at}]}. PR-level conversation comments + submitted review
-- verdicts (keeps reactions/labels/events out); the overview builder merges + sorts
---@param pr { owner: string, repo: string, number: integer }
---@param cb fun(err: table|nil, result: any)
function M.get_timeline(pr, cb)
    sidecar.request("get_timeline", { owner = pr.owner, repo = pr.repo, number = pr.number }, cb)
end

-- the flat pr coords every review/comment call sends (the sidecar decodes owner/repo/
-- number at the top level), merged with the call's own args
---@param pr { owner: string, repo: string, number: integer }
---@param args table|nil
---@return table
local function with_pr(pr, args)
    return vim.tbl_extend(
        "force",
        { owner = pr.owner, repo = pr.repo, number = pr.number },
        args or {}
    )
end

-- start_review result: {review_id}. idempotent: replaying it reattaches to the viewer's
-- existing pending draft rather than orphaning a second one
---@param pr { owner: string, repo: string, number: integer }
---@param cb fun(err: table|nil, result: any)
function M.start_review(pr, cb)
    sidecar.request("start_review", with_pr(pr), cb)
end

-- discard_review result: {}. drops the pending draft and its unsubmitted comments
---@param pr { owner: string, repo: string, number: integer }
---@param review_id string
---@param cb fun(err: table|nil, result: any)
function M.discard_review(pr, review_id, cb)
    sidecar.request("discard_review", with_pr(pr, { review_id = review_id }), cb)
end

-- get_pending_review result: {review_id, comments?:[{id, path, side, line, start_*?,
-- body}]}. review_id is null when the viewer has no draft; the comments drive resume's
-- position restore
---@param pr { owner: string, repo: string, number: integer }
---@param cb fun(err: table|nil, result: any)
function M.get_pending_review(pr, cb)
    sidecar.request("get_pending_review", with_pr(pr), cb)
end

-- post_comment result: {id, thread_id}. a reply when args.in_reply_to is set, else a
-- new thread (a draft when args.review_id is set, immediate when it isn't). args:
-- path/side/line/body, start_side?/start_line? (range), in_reply_to?, review_id?,
-- expected_head? (the session head for the TOCTOU guard)
---@param pr { owner: string, repo: string, number: integer }
---@param args table
---@param cb fun(err: table|nil, result: any)
function M.post_comment(pr, args, cb)
    sidecar.request("post_comment", with_pr(pr, args), cb)
end

-- submit_review result: {id}. finalises the draft as one batch with an event. args:
-- review_id/event (APPROVE|REQUEST_CHANGES|COMMENT)/body, expected_head?
---@param pr { owner: string, repo: string, number: integer }
---@param args table
---@param cb fun(err: table|nil, result: any)
function M.submit_review(pr, args, cb)
    sidecar.request("submit_review", with_pr(pr, args), cb)
end

-- delete_comment result: {}. removes a single review comment (draft or published) by
-- its graphql node id; deleting a thread's root comment cascades to the whole thread
---@param pr { owner: string, repo: string, number: integer }
---@param comment_id string  -- the comment's graphql node id (node_id from get_threads)
---@param cb fun(err: table|nil, result: any)
function M.delete_comment(pr, comment_id, cb)
    sidecar.request("delete_comment", with_pr(pr, { comment_id = comment_id }), cb)
end

-- get_checks result: {rollup, checks:[{name, status, conclusion, url, started_at?}]}.
-- the status-check rollup plus each normalised check; read-only
---@param pr { owner: string, repo: string, number: integer }
---@param cb fun(err: table|nil, result: any)
function M.get_checks(pr, cb)
    sidecar.request("get_checks", with_pr(pr), cb)
end

-- merge_pr result: {merged, sha?}. args: method (squash|merge|rebase), delete_branch?,
-- subject?, body?. the sidecar pre-checks mergeability and returns a `conflict` error
-- rather than firing a doomed merge, so the caller surfaces "not mergeable"
---@param pr { owner: string, repo: string, number: integer }
---@param args table  -- { method, delete_branch?, subject?, body? }
---@param cb fun(err: table|nil, result: any)
function M.merge_pr(pr, args, cb)
    sidecar.request("merge_pr", with_pr(pr, args), cb)
end

-- set_pr_state result: {state}. transitions the lifecycle: state is ready|draft|closed|
-- open and the result echoes the PR's condition after the transition
---@param pr { owner: string, repo: string, number: integer }
---@param state string  -- ready|draft|closed|open
---@param cb fun(err: table|nil, result: any)
function M.set_pr_state(pr, state, cb)
    sidecar.request("set_pr_state", with_pr(pr, { state = state }), cb)
end

return M
