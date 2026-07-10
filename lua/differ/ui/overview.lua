-- pure builder for the PR overview page. data in -> { lines, highlights, anchors }
-- out, no vim state, so it's unit-tested like ui/thread.lua. the timeline merges
-- comments, review verdicts and code threads and sorts by created_at; relative time is
-- injected (opts.reltime) to keep the builder deterministic. a thread item carries its
-- code anchor (path/side/line) and `anchors` records the row span of each, so the vim
-- layer can jump from a timeline row into the review. scope guard: comments, verdicts
-- and threads only — no reactions, labels, assignees, or events

local M = {}

local RULE = string.rep("─", 60)

-- review state -> the verdict label + highlight group
---@type table<string, { label: string, hl: string }>
local VERDICT = {
    APPROVED = { label = "approved", hl = "differOverviewApproved" },
    CHANGES_REQUESTED = { label = "requested changes", hl = "differOverviewChanges" },
    COMMENTED = { label = "commented", hl = "differOverviewMeta" },
    DISMISSED = { label = "review dismissed", hl = "differOverviewMeta" },
}

-- the PR state word -> its highlight group (no dedicated state groups in so the
-- open/merged states ride the approved green and a closed PR the changes orange)
---@type table<string, string>
local STATE_HL = {
    OPEN = "differOverviewApproved",
    MERGED = "differOverviewApproved",
    CLOSED = "differOverviewChanges",
}

-- split on newlines, dropping a single trailing newline so a github-style "body\n"
-- doesn't add a blank row. vim-free (the builder runs under busted, no nvim runtime)
---@param s string
---@return string[]
local function split_lines(s)
    local out = {}
    for line in ((s or ""):gsub("\n$", "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    return out
end

-- merge comments + reviews + code threads into one chronological list of { kind,
-- author, body, ts, state?, path?, side?, line?, resolved?, replies? }, sorted
-- ascending by created_at (lexical sort is correct for ISO-8601 UTC). a thread rides
-- its first comment (author/body/ts) plus the code anchor; a pending draft thread is
-- the viewer's WIP, not a timeline entry (like a PENDING review)
---@param tl { comments: table[], reviews: table[], threads: table[]|nil }
---@return table[]
local function timeline(tl)
    local items = {}
    for _, c in ipairs(tl.comments or {}) do
        items[#items + 1] =
            { kind = "comment", author = c.author, body = c.body, ts = c.created_at }
    end
    for _, r in ipairs(tl.reviews or {}) do
        items[#items + 1] = {
            kind = "review",
            author = r.author,
            body = r.body,
            ts = r.created_at,
            state = r.state,
        }
    end
    for _, t in ipairs(tl.threads or {}) do
        if not t.is_pending then
            local first = (t.comments or {})[1] or {}
            items[#items + 1] = {
                kind = "thread",
                author = first.author,
                body = first.body,
                ts = first.created_at,
                path = t.path,
                side = t.side,
                line = t.line,
                resolved = t.resolved == true, -- vim.NIL-safe
                replies = math.max(0, #(t.comments or {}) - 1),
            }
        end
    end
    table.sort(items, function(a, b)
        return (a.ts or "") < (b.ts or "")
    end)
    return items
end

M.timeline = timeline

-- an item's verdict label + highlight: a review maps through VERDICT (an unknown state
-- falls back to its lowercased word in meta), a conversation comment reads "commented"
---@param item table
---@return { label: string, hl: string }
local function verdict_of(item)
    if item.kind == "review" then
        return VERDICT[item.state or ""]
            or { label = (item.state or "reviewed"):lower(), hl = "differOverviewMeta" }
    end
    return { label = "commented", hl = "differOverviewMeta" }
end

-- build the overview buffer content. `anchors` maps each thread item to its 1-based
-- row span ({ row_start, row_end, path, side, line }), so <CR> anywhere in the section
-- can jump to the code anchor. a highlight is { row, col_start, col_end, hl }, 0-based
---@param data { meta: table, checks: table|nil, unresolved: integer, total_threads: integer, timeline: table }
---@param opts { reltime?: fun(ts: string): string }|nil
---@return { lines: string[], highlights: table[], anchors: table[] }
function M.build(data, opts)
    opts = opts or {}
    local reltime = opts.reltime or function(ts)
        return ts or ""
    end
    local meta = data.meta or {}

    local lines, highlights = {}, {}

    -- emit one line from { text, hl } chunks, pushing a span per chunk that carries a
    -- highlight and real text (hl may be nil for plain separators)
    ---@param chunks table[]
    local function push(chunks)
        local col, parts = 0, {}
        for _, c in ipairs(chunks) do
            local text = c[1] or ""
            parts[#parts + 1] = text
            local bytes = #text
            if c[2] and bytes > 0 then
                highlights[#highlights + 1] =
                    { row = #lines, col_start = col, col_end = col + bytes, hl = c[2] }
            end
            col = col + bytes
        end
        lines[#lines + 1] = table.concat(parts)
    end

    -- header: title, the state/author/mergeable meta line, the checks + threads + help line
    local number = meta.number and ("#" .. meta.number .. " ") or ""
    push({ { number .. (meta.title or "untitled"), "differOverviewTitle" } })

    local state_word = meta.draft and "draft" or (meta.state or "open"):lower()
    local state_hl = meta.draft and "differOverviewMeta"
        or (STATE_HL[(meta.state or ""):upper()] or "differOverviewMeta")
    local mergeable = (meta.mergeable or ""):lower()
    local meta_line = {
        { state_word, state_hl },
        { " · ", "differOverviewMeta" },
        { "@" .. (meta.author or "?"), "differOverviewAuthor" },
    }
    if mergeable ~= "" then
        meta_line[#meta_line + 1] = { " · ", "differOverviewMeta" }
        meta_line[#meta_line + 1] = { mergeable, "differOverviewMeta" }
    end
    push(meta_line)

    local rollup = data.checks and data.checks.rollup
    local rollup_word = (rollup ~= nil and rollup ~= "") and tostring(rollup):lower() or "n/a"
    push({
        {
            ("checks: %s · threads: %d unresolved / %d · help: g?"):format(
                rollup_word,
                data.unresolved or 0,
                data.total_threads or 0
            ),
            "differOverviewMeta",
        },
    })

    push({ { RULE, "differOverviewMeta" } })

    -- body: one buffer line per source line (markdown buffer renders it), empty body
    -- emits no rows so the page doesn't carry a blank block
    if meta.body and meta.body ~= "" then
        for _, line in ipairs(split_lines(meta.body)) do
            push({ { line, "differOverviewBody" } })
        end
    end

    push({ { RULE, "differOverviewMeta" } })

    -- timeline: one section per item, a blank row between sections. a thread section's
    -- row span is recorded so the vim layer can jump from any of its rows to the anchor
    local anchors = {}
    for i, item in ipairs(timeline(data.timeline or {})) do
        if i > 1 then
            push({ { "", "differOverviewBody" } })
        end
        local row_start = #lines + 1
        if item.kind == "thread" then
            push({
                { "── ", "differOverviewMeta" },
                { "@" .. (item.author or "?"), "differOverviewAuthor" },
                { " commented on ", "differOverviewMeta" },
                { (item.path or "?") .. ":" .. (item.line or 0), "differOverviewBody" },
                {
                    item.resolved and " · resolved" or " · unresolved",
                    item.resolved and "differOverviewMeta" or "differOverviewChanges",
                },
                { " · " .. reltime(item.ts or "") .. " ──", "differOverviewMeta" },
            })
        else
            local v = verdict_of(item)
            push({
                { "── ", "differOverviewMeta" },
                { "@" .. (item.author or "?"), "differOverviewAuthor" },
                { " ", "differOverviewMeta" },
                { v.label, v.hl },
                { " · " .. reltime(item.ts or "") .. " ──", "differOverviewMeta" },
            })
        end
        if item.body and item.body ~= "" then
            for _, line in ipairs(split_lines(item.body)) do
                push({ { line, "differOverviewBody" } })
            end
        end
        if item.kind == "thread" then
            if item.replies and item.replies > 0 then
                push({
                    {
                        ("… %d repl%s"):format(item.replies, item.replies == 1 and "y" or "ies"),
                        "differOverviewMeta",
                    },
                })
            end
            anchors[#anchors + 1] = {
                row_start = row_start,
                row_end = #lines,
                path = item.path,
                side = item.side,
                line = item.line,
            }
        end
    end

    return { lines = lines, highlights = highlights, anchors = anchors }
end

return M
