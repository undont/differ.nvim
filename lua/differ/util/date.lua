-- date formatting, config-driven: absolute YYYY-MM-DD or a git-`%ar`-style relative
-- string ("3 days ago"). the single place dates render across the plugin so the
-- `relative_dates` option governs every surface. pure (os.date/os.time only), so
-- `now` is injectable and the relative buckets stay unit-testable

local M = {}

local MINUTE = 60
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR
local WEEK = 7 * DAY
local MONTH = 30 * DAY
local YEAR = 365 * DAY

---@param n integer
---@param unit string
---@return string
local function ago(n, unit)
    return n .. " " .. unit .. (n == 1 and "" or "s") .. " ago"
end

-- a coarse "N <unit> ago" for `epoch`, measured against `now` (defaults to the
-- current time). future timestamps clamp to "0 seconds ago"
---@param epoch integer
---@param now integer|nil
---@return string
function M.relative(epoch, now)
    local d = (now or os.time()) - epoch
    if d < 0 then
        d = 0
    end
    if d < MINUTE then
        return ago(d, "second")
    elseif d < HOUR then
        return ago(math.floor(d / MINUTE), "minute")
    elseif d < DAY then
        return ago(math.floor(d / HOUR), "hour")
    elseif d < WEEK then
        return ago(math.floor(d / DAY), "day")
    elseif d < MONTH then
        return ago(math.floor(d / WEEK), "week")
    elseif d < YEAR then
        return ago(math.floor(d / MONTH), "month")
    end
    return ago(math.floor(d / YEAR), "year")
end

-- format an author epoch per config: relative when `opts.relative`, else the
-- absolute YYYY-MM-DD (in local time), with the HH:MM time appended when `opts.time`.
-- `opts.now` overrides the relative baseline
---@param epoch integer
---@param opts { relative?: boolean, time?: boolean, now?: integer }|nil
---@return string
function M.format(epoch, opts)
    opts = opts or {}
    if opts.relative then
        return M.relative(epoch, opts.now)
    end
    return os.date(opts.time and "%Y-%m-%d %H:%M" or "%Y-%m-%d", epoch) --[[@as string]]
end

-- parse an RFC3339 / ISO-8601 timestamp to an epoch (local-time interpretation;
-- the coarse relative buckets make the utc-vs-local offset never shift the unit).
-- accepts a bare date too. nil on an unparseable string
---@param ts string
---@return integer|nil
function M.parse_iso(ts)
    if type(ts) ~= "string" then
        return nil
    end
    local y, mo, d, h, mi, s = ts:match("^(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)")
    if not y then
        y, mo, d = ts:match("^(%d+)%-(%d+)%-(%d+)")
        h, mi, s = 0, 0, 0
    end
    if not y then
        return nil
    end
    return os.time({
        year = tonumber(y) --[[@as integer]],
        month = tonumber(mo) --[[@as integer]],
        day = tonumber(d) --[[@as integer]],
        hour = tonumber(h),
        min = tonumber(mi),
        sec = tonumber(s),
        isdst = false,
    })
end

return M
