local date = require("differ.util.date")

-- a fixed baseline so the relative buckets are deterministic
local NOW = 1781349032
local MIN, HOUR, DAY, WEEK = 60, 3600, 86400, 604800

describe("util.date.relative", function()
    it("counts seconds, minutes, hours", function()
        assert.are.equal("5 seconds ago", date.relative(NOW - 5, NOW))
        assert.are.equal("1 minute ago", date.relative(NOW - MIN, NOW))
        assert.are.equal("3 minutes ago", date.relative(NOW - 3 * MIN, NOW))
        assert.are.equal("2 hours ago", date.relative(NOW - 2 * HOUR, NOW))
    end)

    it("counts days, weeks, months, years", function()
        assert.are.equal("1 day ago", date.relative(NOW - DAY, NOW))
        assert.are.equal("3 days ago", date.relative(NOW - 3 * DAY, NOW))
        assert.are.equal("2 weeks ago", date.relative(NOW - 2 * WEEK, NOW))
        assert.are.equal("3 months ago", date.relative(NOW - 95 * DAY, NOW))
        assert.are.equal("2 years ago", date.relative(NOW - 800 * DAY, NOW))
    end)

    it("singularises a count of one", function()
        assert.are.equal("1 second ago", date.relative(NOW - 1, NOW))
        assert.are.equal("1 hour ago", date.relative(NOW - HOUR, NOW))
    end)

    it("clamps a future timestamp to zero", function()
        assert.are.equal("0 seconds ago", date.relative(NOW + DAY, NOW))
    end)
end)

describe("util.date.format", function()
    it("returns YYYY-MM-DD when not relative", function()
        local s = date.format(NOW, { relative = false })
        assert.is_truthy(s:match("^%d%d%d%d%-%d%d%-%d%d$"))
    end)

    it("returns a relative string when relative", function()
        assert.are.equal("1 day ago", date.format(NOW - DAY, { relative = true, now = NOW }))
    end)

    it("defaults to absolute with no opts", function()
        assert.is_truthy(date.format(NOW):match("^%d%d%d%d%-%d%d%-%d%d$"))
    end)

    it("appends HH:MM when opts.time is set", function()
        local s = date.format(NOW, { time = true })
        assert.is_truthy(s:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$"))
    end)

    it("ignores opts.time in the relative form", function()
        assert.are.equal(
            "1 day ago",
            date.format(NOW - DAY, { relative = true, time = true, now = NOW })
        )
    end)
end)
