-- canonical hunk model built from vim.diff(); buffers are projections of this

---@class differ.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field old_lines string[]
---@field new_lines string[]
---@field pairs differ.LinePair[]|nil

---@class differ.DiffModel
---@field path string
---@field old_rev string
---@field new_rev string
---@field hunks differ.Hunk[]
---@field old_text string
---@field new_text string
---@field head string|nil  -- git branch, for the synthetic buffer's statusline (set by the frontend)
---@field root string|nil  -- repo root (absolute), so jump-to-file can resolve the real file (set by the frontend)
---@field binary boolean|nil  -- either side is binary: no hunks, renderers show a placeholder

local text_util = require("differ.util.text")
local to_lines = text_util.to_lines
local ensure_trailing_nl = text_util.ensure_trailing_nl
local is_binary = text_util.is_binary

local M = {}

-- slice a 1-based inclusive range out of a line array
---@param lines string[]
---@param start integer
---@param count integer
---@return string[]
local function slice(lines, start, count)
    local out = {}
    for i = start, start + count - 1 do
        out[#out + 1] = lines[i]
    end
    return out
end

---@class differ.model.BuildOpts
---@field path string
---@field old_rev string
---@field new_rev string
---@field old_text string
---@field new_text string
---@field head? string  -- git branch, for the buffer statusline
---@field root? string  -- repo root (absolute), for jump-to-file

-- build a DiffModel from old/new file contents
---@param opts differ.model.BuildOpts
---@return differ.DiffModel
function M.build(opts)
    -- binary content has no line structure: stray 0x0a bytes would split it into
    -- pathological pseudo-lines and drive the word-diff pairing into O(n*m) over
    -- megabytes (an OOM that takes the editor down). detect it up front, skip the
    -- diff entirely, and let the renderers show a placeholder
    if is_binary(opts.old_text) or is_binary(opts.new_text) then
        return {
            path = opts.path,
            old_rev = opts.old_rev,
            new_rev = opts.new_rev,
            hunks = {},
            old_text = opts.old_text,
            new_text = opts.new_text,
            head = opts.head,
            root = opts.root,
            binary = true,
        }
    end

    local old_lines = to_lines(opts.old_text)
    local new_lines = to_lines(opts.new_text)

    local raw =
        vim.text.diff(ensure_trailing_nl(opts.old_text), ensure_trailing_nl(opts.new_text), {
            result_type = "indices",
            algorithm = "histogram",
        })

    ---@cast raw integer[][]
    local hunks = {}
    for _, h in ipairs(raw) do
        local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
        hunks[#hunks + 1] = {
            old_start = old_start,
            old_count = old_count,
            new_start = new_start,
            new_count = new_count,
            old_lines = slice(old_lines, old_start, old_count),
            new_lines = slice(new_lines, new_start, new_count),
        }
    end

    return {
        path = opts.path,
        old_rev = opts.old_rev,
        new_rev = opts.new_rev,
        hunks = hunks,
        old_text = opts.old_text,
        new_text = opts.new_text,
        head = opts.head,
        root = opts.root,
    }
end

-- the new side's text with hunk `idx` undone: its old lines put back where its new
-- lines sit. only the new side ever moves, in both diff directions (a revert rewrites
-- the worktree on an index↔worktree diff, the index on a head↔index one), so there's
-- one case here rather than two
---@param model differ.DiffModel
---@param h differ.Hunk
---@return string
local function reverted_text(model, h)
    local lines = to_lines(model.new_text)
    -- a zero-count hunk occupies nothing on the new side, and `new_start` names the
    -- line it sits *after*, so the restored lines go in after it rather than over it
    local at = h.new_count > 0 and h.new_start or h.new_start + 1
    local out = {}
    for i = 1, at - 1 do
        out[#out + 1] = lines[i]
    end
    vim.list_extend(out, h.old_lines)
    for i = at + h.new_count, #lines do
        out[#out + 1] = lines[i]
    end

    -- whichever side supplies the result's last line supplies its terminator too:
    -- a hunk reaching the end of the new side leaves no tail behind it, so the old
    -- side's ending wins. getting this wrong would re-diff as a phantom eof hunk
    local last = h.new_count > 0 and (h.new_start + h.new_count - 1) or h.new_start
    local source = last == #lines and model.old_text or model.new_text
    local text = table.concat(out, "\n")
    if #out > 0 and source:sub(-1) == "\n" then
        text = text .. "\n"
    end
    return text
end

-- a model with hunk `idx` reverted on the new side. rebuilt from the spliced text
-- rather than patched in place, so the hunk list can never drift from the text it
-- describes; callers hold the result as their new frozen model. the rebuild
-- renumbers and re-derives boundaries, so surviving hunks keep their content but not
-- their index, and callers holding per-hunk state must re-key it
---@param model differ.DiffModel
---@param idx integer
---@return differ.DiffModel
function M.revert_hunk(model, idx)
    local h = assert(model.hunks[idx], "revert_hunk: no hunk at index " .. tostring(idx))
    return M.build({
        path = model.path,
        old_rev = model.old_rev,
        new_rev = model.new_rev,
        old_text = model.old_text,
        new_text = reverted_text(model, h),
        head = model.head,
        root = model.root,
    })
end

return M
