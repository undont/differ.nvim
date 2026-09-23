-- the text a diff's two sides splice into: each hunk takes its new block when applied
-- and its old block otherwise, with the unchanged lines between read from one side.
-- staging writes the result whole, so it only ever applies whole hunks; pure lua, no vim API

local text = require("differ.util.text")
local to_lines = text.to_lines

local M = {}

---@param model differ.DiffModel
---@param applied table<integer, boolean>  -- hunk index -> take its new block
---@param base? "old"|"new"  -- the side the unchanged lines and their ending come from; default "old"
---@return string
function M.splice(model, applied, base)
    base = base or "old"
    local lines = to_lines(base == "new" and model.new_text or model.old_text)
    local out, next_line, tail = {}, 1, base
    for i, h in ipairs(model.hunks) do
        local start, count = h[base .. "_start"], h[base .. "_count"]
        -- a hunk with no lines on `base` sits after the line `start` names
        local first = count > 0 and start or start + 1
        for l = next_line, first - 1 do
            out[#out + 1] = lines[l]
        end
        local side = applied[i] and "new" or "old"
        for _, line in ipairs(h[side .. "_lines"]) do
            out[#out + 1] = line
        end
        next_line = first + count
        if next_line > #lines then
            tail = side -- nothing follows the hunk, so the file ends as its side does
        end
    end
    for l = next_line, #lines do
        out[#out + 1] = lines[l]
    end
    if #out == 0 then
        return ""
    end
    local ending = tail == "new" and model.new_text or model.old_text
    return table.concat(out, "\n") .. (ending:sub(-1) == "\n" and "\n" or "")
end

---@param lines string[]
---@param start integer
---@param count integer
---@return string[]
local function slice(lines, start, count)
    local out = {}
    for l = start, start + count - 1 do
        out[#out + 1] = lines[l]
    end
    return out
end

-- `model` with its hunks' lines as text.ended_lines reads each side, so a hunk reaching
-- an unterminated end holds that side's last line with NO_EOL on it
---@param model differ.DiffModel
---@return differ.DiffModel
function M.ended(model)
    local old, new = text.ended_lines(model.old_text), text.ended_lines(model.new_text)
    local hunks = {}
    for i, h in ipairs(model.hunks) do
        hunks[i] = {
            old_start = h.old_start,
            old_count = h.old_count,
            old_lines = slice(old, h.old_start, h.old_count),
            new_start = h.new_start,
            new_count = h.new_count,
            new_lines = slice(new, h.new_start, h.new_count),
        }
    end
    local out = {}
    for k, v in pairs(model) do
        out[k] = v
    end
    out.hunks = hunks
    return out
end

-- the model's unchanged old lines with `blocks` at its hunks. every line is an ended
-- line (M.ended's side lines, or marks.blocks over ended lines), so the file ends
-- without a newline exactly when its last line carries NO_EOL
---@param model differ.DiffModel
---@param blocks string[][]  -- hunk index -> the lines at that hunk
---@return string
function M.join(model, blocks)
    local lines = text.ended_lines(model.old_text)
    local out, next_line = {}, 1
    for i, h in ipairs(model.hunks) do
        local first = h.old_count > 0 and h.old_start or h.old_start + 1
        for l = next_line, first - 1 do
            out[#out + 1] = lines[l]
        end
        for _, line in ipairs(blocks[i]) do
            out[#out + 1] = line
        end
        next_line = first + h.old_count
    end
    for l = next_line, #lines do
        out[#out + 1] = lines[l]
    end
    return text.ended_text(out)
end

return M
