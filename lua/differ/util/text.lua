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

-- set on a last line with no newline after it, so `c` and `c\n` compare unequal as they
-- do in git's diff. a NUL never reaches a line: is_binary text isn't read by line
M.NO_EOL = "\0"

-- `text`'s lines, the last carrying NO_EOL when the text doesn't end in a newline
---@param text string
---@return string[]
function M.ended_lines(text)
    local lines = M.to_lines(text)
    if #lines > 0 and text:sub(-1) ~= "\n" then
        lines[#lines] = lines[#lines] .. M.NO_EOL
    end
    return lines
end

-- the text ended_lines reads `lines` from: a newline after each line but one that
-- carries NO_EOL
---@param lines string[]
---@return string
function M.ended_text(lines)
    if #lines == 0 then
        return ""
    end
    local out = {}
    for i, line in ipairs(lines) do
        if line:sub(-1) == M.NO_EOL then
            line = line:sub(1, -2)
        end
        out[i] = line
    end
    local text = table.concat(out, "\n")
    if lines[#lines]:sub(-1) == M.NO_EOL then
        return text
    end
    return text .. "\n"
end

return M
