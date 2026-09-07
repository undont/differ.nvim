local thread = require("differ.ui.thread")

-- inject a deterministic reltime so the golden chunks don't depend on the clock
local function build(t, collapsed)
    return thread.build(t, {
        collapsed = collapsed,
        reltime = function(ts)
            return ts
        end,
    })
end

-- flatten a row's chunks to its text, for the cases that only assert layout
local function text(row)
    local s = {}
    for _, chunk in ipairs(row) do
        s[#s + 1] = chunk[1]
    end
    return table.concat(s)
end

local OPEN = {
    resolved = false,
    is_pending = false,
    comments = {
        { author = "alice", body = "needs a null check here", created_at = "3d ago" },
        { author = "bob", body = "good catch, fixing it", created_at = "2d ago" },
    },
}

describe("ui.thread.build (expanded)", function()
    it("renders header rule, spine bodies, blank separator, and footer", function()
        local rows = build(OPEN)
        assert.are.equal("┌─ @alice · 3d ago", text(rows[1]))
        assert.are.equal("│  needs a null check here", text(rows[2]))
        assert.are.equal("│", text(rows[3]))
        assert.are.equal("│  @bob · 2d ago", text(rows[4]))
        assert.are.equal("│  good catch, fixing it", text(rows[5]))
        assert.are.equal("└─ open", text(rows[6]))
    end)

    it("colours the chrome with the open state group and meta separately", function()
        local header = build(OPEN)[1]
        assert.are.same({ "┌─ ", "differThread" }, header[1])
        assert.are.same({ "@alice", "differThread" }, header[2])
        assert.are.same({ " · 3d ago", "differThreadMeta" }, header[3])
        local body = build(OPEN)[2]
        assert.are.same({ "│  ", "differThread" }, body[1])
        assert.are.same({ "needs a null check here", "differThreadBody" }, body[2])
    end)

    -- the replies are rendered right above the footer, so a count beside them would
    -- read as a there-is-more affordance. the collapsed line carries the total instead
    it("the footer is the state alone, however many replies are on show", function()
        local t = {
            comments = {
                { author = "a", body = "x", created_at = "t" },
                { author = "b", body = "y", created_at = "t" },
                { author = "c", body = "z", created_at = "t" },
            },
        }
        local rows = build(t)
        assert.are.equal("│  @c · t", text(rows[#rows - 2]))
        assert.are.equal("│  z", text(rows[#rows - 1]))
        assert.are.equal("└─ open", text(rows[#rows]))
    end)

    it("a single comment reads the same, just the open tag", function()
        local t = { comments = { { author = "a", body = "x", created_at = "t" } } }
        local rows = build(t)
        assert.are.equal("┌─ @a · t", text(rows[1]))
        assert.are.equal("│  x", text(rows[2]))
        assert.are.equal("└─ open", text(rows[3]))
    end)

    it("keeps a body line per source newline", function()
        local t = { comments = { { author = "a", body = "one\ntwo", created_at = "t" } } }
        local rows = build(t)
        assert.are.equal("│  one", text(rows[2]))
        assert.are.equal("│  two", text(rows[3]))
    end)
end)

describe("ui.thread.build (resolved + pending state)", function()
    it("tags the footer resolved in green, greys the chrome, drops the open tag", function()
        local t = { resolved = true, is_pending = false, comments = OPEN.comments }
        local rows = build(t)
        assert.are.equal("┌─ @alice · 3d ago", text(rows[1])) -- state moved off the header
        assert.are.same({ "┌─ ", "differThreadResolved" }, rows[1][1])
        assert.are.equal("└─ ✓ resolved", text(rows[#rows]))
        -- the resolved tag rides its own green group, separate from the meta chrome
        assert.are.same({ "✓ resolved", "differThreadResolvedTag" }, rows[#rows][#rows[#rows]])
    end)

    it("a resolved single-comment thread still shows the resolved tag on the footer", function()
        local rows = build({
            resolved = true,
            comments = { { author = "a", body = "x", created_at = "t" } },
        })
        assert.are.equal("└─ ✓ resolved", text(rows[#rows]))
    end)

    it("marks a pending draft and uses the pending group", function()
        local t =
            { is_pending = true, comments = { { author = "a", body = "wip", created_at = "t" } } }
        local rows = build(t)
        assert.are.equal("┌─ @a · t (draft)", text(rows[1]))
        assert.are.same({ " (draft)", "differThreadPending" }, rows[1][#rows[1]])
    end)
end)

describe("ui.thread.build (collapsed)", function()
    it("renders a one-line summary with comment count and a snippet", function()
        local rows = build(OPEN, true)
        assert.are.equal(1, #rows)
        assert.are.equal('└─ 2 comments · @alice: "needs a null check here"', text(rows[1]))
    end)

    it("uses the singular for one comment and truncates a long snippet", function()
        local long = string.rep("x", 80)
        local rows = build({ comments = { { author = "a", body = long, created_at = "t" } } }, true)
        local summary = text(rows[1])
        assert.is_truthy(summary:find("1 comment · ", 1, true))
        assert.is_truthy(summary:find("…", 1, true))
    end)
end)
