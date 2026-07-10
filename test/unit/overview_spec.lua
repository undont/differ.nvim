local overview = require("differ.ui.overview")

-- inject a deterministic reltime so the golden lines don't depend on the clock
local function build(data)
    return overview.build(data, {
        reltime = function(ts)
            return ts
        end,
    })
end

-- the built line at `idx` (1-based), for layout assertions
local function line(built, idx)
    return built.lines[idx]
end

-- find the 1-based row index of the first line equal to `text`, or nil
local function row_of(built, text)
    for i, l in ipairs(built.lines) do
        if l == text then
            return i
        end
    end
end

-- shallow-merge `over` onto a copy of `base` (pure Lua; no vim runtime under busted)
local function extend(base, over)
    local out = {}
    for k, v in pairs(base) do
        out[k] = v
    end
    for k, v in pairs(over) do
        out[k] = v
    end
    return out
end

local BASE_META = {
    number = 42,
    title = "add the overview",
    author = "alice",
    state = "OPEN",
    draft = false,
    mergeable = "MERGEABLE",
    body = "",
}

describe("ui.overview.timeline (merge + sort)", function()
    it("merges comments + reviews and sorts ascending by ISO timestamp", function()
        local items = overview.timeline({
            comments = {
                { author = "a", body = "later", created_at = "2026-01-03T00:00:00Z" },
                { author = "b", body = "first", created_at = "2026-01-01T00:00:00Z" },
            },
            reviews = {
                {
                    author = "c",
                    state = "APPROVED",
                    body = "lgtm",
                    created_at = "2026-01-02T00:00:00Z",
                },
            },
        })
        assert.are.equal(3, #items)
        assert.are.equal("b", items[1].author) -- 01-01
        assert.are.equal("c", items[2].author) -- 01-02 (the review, interleaved)
        assert.are.equal("a", items[3].author) -- 01-03
        assert.are.equal("review", items[2].kind)
        assert.are.equal("comment", items[1].kind)
    end)

    it("interleaves code threads on their first comment's timestamp", function()
        local items = overview.timeline({
            comments = {
                { author = "a", body = "later", created_at = "2026-01-03T00:00:00Z" },
            },
            reviews = {},
            threads = {
                {
                    path = "lua/differ/init.lua",
                    side = "RIGHT",
                    line = 12,
                    resolved = false,
                    comments = {
                        { author = "t", body = "nit", created_at = "2026-01-01T00:00:00Z" },
                        { author = "a", body = "ack", created_at = "2026-01-02T00:00:00Z" },
                    },
                },
            },
        })
        assert.are.equal(2, #items)
        assert.are.equal("thread", items[1].kind) -- 01-01, before the comment
        assert.are.equal("t", items[1].author)
        assert.are.equal("nit", items[1].body)
        assert.are.equal("lua/differ/init.lua", items[1].path)
        assert.are.equal("RIGHT", items[1].side)
        assert.are.equal(12, items[1].line)
        assert.are.equal(1, items[1].replies)
    end)

    it("drops a pending draft thread", function()
        local items = overview.timeline({
            comments = {},
            reviews = {},
            threads = {
                {
                    path = "x.lua",
                    side = "RIGHT",
                    line = 1,
                    is_pending = true,
                    comments = {
                        { author = "me", body = "wip", created_at = "2026-01-01T00:00:00Z" },
                    },
                },
            },
        })
        assert.are.equal(0, #items)
    end)
end)

describe("ui.overview.build (shapes that must not error)", function()
    it("builds a comment-only PR", function()
        local built = build({
            meta = BASE_META,
            unresolved = 0,
            total_threads = 0,
            timeline = {
                comments = { { author = "a", body = "hi", created_at = "2026-01-01T00:00:00Z" } },
                reviews = {},
            },
        })
        assert.is_truthy(row_of(built, "── @a commented · 2026-01-01T00:00:00Z ──"))
    end)

    it("builds a review-only PR", function()
        local built = build({
            meta = BASE_META,
            unresolved = 0,
            total_threads = 0,
            timeline = {
                comments = {},
                reviews = {
                    {
                        author = "r",
                        state = "APPROVED",
                        body = "",
                        created_at = "2026-01-01T00:00:00Z",
                    },
                },
            },
        })
        assert.is_truthy(row_of(built, "── @r approved · 2026-01-01T00:00:00Z ──"))
    end)

    it("builds an empty PR (no timeline) without error", function()
        local built = build({
            meta = BASE_META,
            unresolved = 0,
            total_threads = 0,
            timeline = { comments = {}, reviews = {} },
        })
        assert.is_truthy(#built.lines >= 1)
        assert.are.equal("#42 add the overview", line(built, 1))
    end)
end)

describe("ui.overview.build (thread sections + anchors)", function()
    local function thread_data(over)
        local t = extend({
            path = "lua/differ/init.lua",
            side = "RIGHT",
            line = 12,
            resolved = false,
            comments = {
                {
                    author = "t",
                    body = "first line\nsecond line",
                    created_at = "2026-01-01T00:00:00Z",
                },
                { author = "a", body = "ack", created_at = "2026-01-02T00:00:00Z" },
            },
        }, over or {})
        return {
            meta = BASE_META,
            unresolved = 1,
            total_threads = 1,
            timeline = { comments = {}, reviews = {}, threads = { t } },
        }
    end

    it("renders the thread header on the box's top rule with the unresolved tag", function()
        local built = build(thread_data())
        local want = "┌─ @t commented on lua/differ/init.lua:12 · unresolved"
            .. " · 2026-01-01T00:00:00Z"
        assert.is_truthy(row_of(built, want))
    end)

    it("tags a resolved thread quietly", function()
        local built = build(thread_data({ resolved = true }))
        local want = "┌─ @t commented on lua/differ/init.lua:12 · resolved"
            .. " · 2026-01-01T00:00:00Z"
        local row = row_of(built, want)
        assert.is_truthy(row)
        -- the unresolved tag rides differOverviewChanges; resolved must not
        for _, h in ipairs(built.highlights) do
            if h.row == row - 1 then
                assert.are_not.equal("differOverviewChanges", h.hl)
            end
        end
    end)

    it("emits the first comment's body on spine rows and a reply count footer", function()
        local built = build(thread_data())
        assert.is_truthy(row_of(built, "│ first line"))
        assert.is_truthy(row_of(built, "│ second line"))
        assert.is_truthy(row_of(built, "└─ ↳ 1 reply"))
    end)

    it("records the anchor's row span covering the whole box", function()
        local built = build(thread_data())
        assert.are.equal(1, #built.anchors)
        local a = built.anchors[1]
        assert.are.equal("lua/differ/init.lua", a.path)
        assert.are.equal("RIGHT", a.side)
        assert.are.equal(12, a.line)
        local header = row_of(
            built,
            "┌─ @t commented on lua/differ/init.lua:12 · unresolved · 2026-01-01T00:00:00Z"
        )
        assert.are.equal(header, a.row_start)
        assert.are.equal(row_of(built, "└─ ↳ 1 reply"), a.row_end)
    end)

    it("returns an empty anchor list without threads", function()
        local built = build({
            meta = BASE_META,
            unresolved = 0,
            total_threads = 0,
            timeline = { comments = {}, reviews = {} },
        })
        assert.are.same({}, built.anchors)
    end)
end)

describe("ui.overview.build (thread diff hunk)", function()
    -- a thread carrying `hunk` as its root comment's diff context
    local function hunk_data(hunk)
        return {
            meta = BASE_META,
            unresolved = 1,
            total_threads = 1,
            timeline = {
                comments = {},
                reviews = {},
                threads = {
                    {
                        path = "app.py",
                        side = "RIGHT",
                        line = 13,
                        resolved = false,
                        comments = {
                            {
                                author = "t",
                                body = "needs a guard?",
                                created_at = "2026-01-01T00:00:00Z",
                                diff_hunk = hunk,
                            },
                        },
                    },
                },
            },
        }
    end

    -- the hl groups on the built row at 1-based `row`
    local function hls_on(built, row)
        local out = {}
        for _, h in ipairs(built.highlights) do
            if h.row == row - 1 then
                if h.hl then
                    out[h.hl] = true
                end
                if h.line_hl then
                    out[h.line_hl] = true
                end
            end
        end
        return out
    end

    it("renders the hunk on spine rows, line-tinting + and - like the diff", function()
        local hunk =
            "@@ -7,6 +7,9 @@ def add(a, b):\n     return a + b\n+def subtract(a, b):\n-    gone"
        local built = build(hunk_data(hunk))

        local header = row_of(built, "│ @@ -7,6 +7,9 @@ def add(a, b):")
        assert.is_truthy(header)
        assert.is_true(hls_on(built, header).differOverviewDiffContext)

        -- +/- rows reuse the diff's own full-width line tints
        local add = row_of(built, "│ +def subtract(a, b):")
        assert.is_truthy(add)
        assert.is_true(hls_on(built, add).differLineAdd)

        local del = row_of(built, "│ -    gone")
        assert.is_truthy(del)
        assert.is_true(hls_on(built, del).differLineDelete)

        -- the hunk sits above the comment body (a spine row inside the box)
        assert.is_true(add < row_of(built, "│ needs a guard?"))
    end)

    it("caps a long hunk to the tail, keeping the @@ header and a ⋯ marker", function()
        local lines = { "@@ -1,20 +1,20 @@ fn" }
        for i = 1, 20 do
            lines[#lines + 1] = "+l" .. i
        end
        local built = build(hunk_data(table.concat(lines, "\n")))

        assert.is_truthy(row_of(built, "│ @@ -1,20 +1,20 @@ fn")) -- header kept
        assert.is_truthy(row_of(built, "│ ⋯")) -- elision marker
        assert.is_truthy(row_of(built, "│ +l20")) -- last line kept
        assert.is_nil(row_of(built, "│ +l1")) -- early lines dropped
        -- MAX_HUNK rows total: @@ + ⋯ + 4 tail lines
        assert.is_truthy(row_of(built, "│ +l17"))
        assert.is_nil(row_of(built, "│ +l16"))
    end)

    it("renders no hunk rows when the thread has no diff hunk", function()
        local built = build(hunk_data(nil))
        assert.is_nil(row_of(built, "│ ⋯"))
        assert.is_truthy(row_of(built, "│ needs a guard?")) -- body still there
    end)

    it("keeps the hunk rows inside the thread's jump anchor span", function()
        local built = build(hunk_data("@@ -7,6 +7,9 @@\n+added"))
        assert.are.equal(1, #built.anchors)
        local a = built.anchors[1]
        local add = row_of(built, "│ +added")
        assert.is_truthy(add)
        assert.is_true(add >= a.row_start and add <= a.row_end)
    end)

    it("records marker-stripped code lines for the syntax snippet pass", function()
        local hunk = "@@ -7,6 +7,9 @@\n     return a + b\n+def subtract(a, b):"
        local built = build(hunk_data(hunk))

        assert.are.equal(1, #built.hunks)
        local h = built.hunks[1]
        assert.are.equal("app.py", h.path)
        -- captures shift right past "│ " plus the +/-/space marker
        assert.are.equal(#"│ " + 1, h.col_offset)
        assert.are.equal(2, #h.lines) -- the @@ header is not code
        assert.are.equal("    return a + b", h.lines[1].text)
        assert.are.equal("def subtract(a, b):", h.lines[2].text)
        -- rows are 0-based buffer rows pointing at the pushed spine rows
        assert.are.equal(row_of(built, "│      return a + b") - 1, h.lines[1].row)
        assert.are.equal(row_of(built, "│ +def subtract(a, b):") - 1, h.lines[2].row)
    end)

    it("records no snippet for a thread without a hunk", function()
        local built = build(hunk_data(nil))
        assert.are.same({}, built.hunks)
    end)
end)

describe("ui.overview.build (verdict mapping)", function()
    local CASES = {
        { state = "APPROVED", label = "approved", hl = "differOverviewApproved" },
        { state = "CHANGES_REQUESTED", label = "requested changes", hl = "differOverviewChanges" },
        { state = "COMMENTED", label = "commented", hl = "differOverviewMeta" },
        { state = "DISMISSED", label = "review dismissed", hl = "differOverviewMeta" },
    }
    for _, c in ipairs(CASES) do
        it("maps " .. c.state .. " to its label + highlight", function()
            local built = build({
                meta = BASE_META,
                unresolved = 0,
                total_threads = 0,
                timeline = {
                    comments = {},
                    reviews = {
                        {
                            author = "x",
                            state = c.state,
                            body = "note",
                            created_at = "2026-01-01T00:00:00Z",
                        },
                    },
                },
            })
            local want = ("── @x %s · 2026-01-01T00:00:00Z ──"):format(c.label)
            local row = row_of(built, want)
            assert.is_truthy(row)
            -- the verdict label rides its highlight group; find the span covering it
            local col = built.lines[row]:find(c.label, 1, true) - 1
            local found = false
            for _, h in ipairs(built.highlights) do
                if h.row == row - 1 and h.col_start == col and h.hl == c.hl then
                    found = true
                end
            end
            assert.is_true(found)
        end)
    end
end)

describe("ui.overview.build (body rendering)", function()
    it("emits one line per source line for a multi-line body", function()
        local built = build({
            meta = extend(BASE_META, { body = "line one\nline two" }),
            unresolved = 0,
            total_threads = 0,
            timeline = { comments = {}, reviews = {} },
        })
        assert.is_truthy(row_of(built, "line one"))
        assert.is_truthy(row_of(built, "line two"))
    end)

    it("emits no body rows for an empty body", function()
        local built = build({
            meta = BASE_META, -- body == ""
            unresolved = 0,
            total_threads = 0,
            timeline = { comments = {}, reviews = {} },
        })
        -- the two rules are adjacent when there's no body between them
        local rule = string.rep("─", 60)
        local first = row_of(built, rule)
        assert.is_truthy(first)
        assert.are.equal(rule, line(built, first + 1))
    end)
end)

describe("ui.overview.build (header counts + rollup)", function()
    it("reports the unresolved/total thread count and the checks rollup", function()
        local built = build({
            meta = BASE_META,
            checks = { rollup = "SUCCESS" },
            unresolved = 2,
            total_threads = 5,
            timeline = { comments = {}, reviews = {} },
        })
        assert.is_truthy(row_of(built, "checks: success · threads: 2 unresolved / 5 · help: g?"))
    end)

    it("degrades to n/a when checks are absent", function()
        local built = build({
            meta = BASE_META,
            checks = nil,
            unresolved = 0,
            total_threads = 0,
            timeline = { comments = {}, reviews = {} },
        })
        assert.is_truthy(row_of(built, "checks: n/a · threads: 0 unresolved / 0 · help: g?"))
    end)
end)

describe("ui.overview.build (highlight spans align)", function()
    it("title span covers the whole title line", function()
        local built = build({
            meta = BASE_META,
            unresolved = 0,
            total_threads = 0,
            timeline = { comments = {}, reviews = {} },
        })
        local title = "#42 add the overview"
        local span
        for _, h in ipairs(built.highlights) do
            if h.row == 0 and h.hl == "differOverviewTitle" then
                span = h
            end
        end
        assert.is_truthy(span)
        assert.are.equal(0, span.col_start)
        assert.are.equal(#title, span.col_end)
    end)
end)
