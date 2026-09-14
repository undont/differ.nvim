-- the text a diff's two sides splice into: each hunk takes its new block when applied
-- and its old block otherwise, with the unchanged lines between read from one side.
-- staging writes the result whole, so it only ever applies whole hunks; pure lua, no vim API

local to_lines = require("differ.util.text").to_lines

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

---@param a string[]
---@param b string[]
---@return boolean
local function same_lines(a, b)
    if #a ~= #b then
        return false
    end
    for i, line in ipairs(a) do
        if b[i] ~= line then
            return false
        end
    end
    return true
end

-- the text a file ends as when hunk `h`, holding `block`, reaches its end: a side's
-- text when the block is that side's lines, else `text`
---@param model differ.DiffModel
---@param h differ.Hunk
---@param block string[]
---@param text string
---@return string
local function ending_at(model, h, block, text)
    if same_lines(block, h.new_lines) then
        return model.new_text
    end
    if same_lines(block, h.old_lines) then
        return model.old_text
    end
    return text
end

-- the model's unchanged old lines with `blocks` at its hunks. the file ends as `text`
-- does, unless the last hunk reaches the end holding one side's lines
---@param model differ.DiffModel
---@param blocks string[][]  -- hunk index -> the lines at that hunk
---@param text string        -- the text the ending comes from otherwise
---@return string
function M.join(model, blocks, text)
    local lines = to_lines(model.old_text)
    local out, next_line, ending = {}, 1, text
    for i, h in ipairs(model.hunks) do
        local first = h.old_count > 0 and h.old_start or h.old_start + 1
        for l = next_line, first - 1 do
            out[#out + 1] = lines[l]
        end
        for _, line in ipairs(blocks[i]) do
            out[#out + 1] = line
        end
        next_line = first + h.old_count
        if next_line > #lines then
            ending = ending_at(model, h, blocks[i], text)
        end
    end
    for l = next_line, #lines do
        out[#out + 1] = lines[l]
    end
    if #out == 0 then
        return ""
    end
    return table.concat(out, "\n") .. (ending:sub(-1) == "\n" and "\n" or "")
end

return M
