-- canonical hunk model built from vim.diff(); buffers are projections of this

---@class differ.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field old_lines string[]
---@field new_lines string[]

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
---@field notice string|nil  -- why a zero-hunk diff has nothing to show; rendered in place of the diff
---@field banner string|nil  -- a note the winbar carries over the diff

local text_util = require("differ.util.text")
local to_lines = text_util.to_lines
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

    -- a last line with and without its newline differ, as in git
    local raw = vim.text.diff(opts.old_text, opts.new_text, {
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

-- why a zero-hunk model has nothing to show, from its two texts alone. nil when only
-- the frontend knows (a mode change, a rename)
---@param model differ.DiffModel
---@return "empty"|"identical"|nil
function M.empty_reason(model)
    if #model.hunks > 0 or model.binary or model.old_text ~= model.new_text then
        return nil
    end
    return model.old_text == "" and "empty" or "identical"
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
    assert(model.hunks[idx], "revert_hunk: no hunk at index " .. tostring(idx))
    -- only the new side moves: the worktree on an index↔worktree diff, the index on a
    -- HEAD↔index one
    local applied = {}
    for i in ipairs(model.hunks) do
        applied[i] = i ~= idx
    end
    return M.build({
        path = model.path,
        old_rev = model.old_rev,
        new_rev = model.new_rev,
        old_text = model.old_text,
        new_text = require("differ.model.apply").splice(model, applied, "new"),
        head = model.head,
        root = model.root,
    })
end

return M
