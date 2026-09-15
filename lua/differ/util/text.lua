-- shared text helpers, pure lua, no nvim API

local M = {}

-- split text into lines, tolerating a missing trailing newline.
-- a terminating newline does not yield a trailing empty line; an unterminated
-- final line is kept. pure, so renderers stay testable without nvim
---@param text string
---@return string[]
function M.to_lines(text)
    if text == "" then
        return {}
    end
    local lines = {}
    local start = 1
    while true do
        local nl = text:find("\n", start, true)
        if nl then
            lines[#lines + 1] = text:sub(start, nl - 1)
            start = nl + 1
        else
            local rest = text:sub(start)
            if rest ~= "" then
                lines[#lines + 1] = rest
            end
            break
        end
    end
    return lines
end

-- a NUL byte in the first 8kb marks the content as binary, mirroring git's own
-- heuristic. binary blobs have no line structure, so the line/word diff would split
-- them on stray 0x0a bytes into pathological pseudo-lines and blow up; callers skip
-- diffing them. pure, so it stays testable without nvim
---@param text string
---@return boolean
function M.is_binary(text)
    local head = #text > 8000 and text:sub(1, 8000) or text
    return head:find("\0", 1, true) ~= nil
end

-- right-truncate `s` to at most `max` columns, keeping the front (the part that
-- distinguishes one filename from another) with a trailing "…". byte-based, so it
-- approximates for multibyte (filenames are ASCII in practice). returns `s`
-- unchanged when it fits or `max` is too small to hold a char plus the "…"
---@param s string
---@param max integer
---@return string
function M.truncate_end(s, max)
    if #s <= max or max < 2 then
        return s
    end
    return s:sub(1, max - 1) .. "…" -- "…" is one display column
end

return M
