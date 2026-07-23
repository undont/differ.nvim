-- the 3-way merge renderer: a MergeModel becomes one column per visible side
-- plus the result spine. pure (no nvim API), so the column assembly + slab location are
-- unit-tested. unlike the diff renderers each merge column is a real single-source file
-- (a stage, or the worktree result), so the session highlights it natively and only
-- needs the per-region line ranges this returns
--
-- input columns show the full stage files; a region's slab is located by an ordered
-- forward search (slabs appear in file order), so a unique run highlights and a
-- not-found run simply doesn't — no highlight beats a wrong highlight

local to_lines = require("differ.util.text").to_lines

---@class differ.merge.ColumnRegion
---@field index integer  -- the source region's 1-based index
---@field first integer  -- 1-based buffer line, inclusive
---@field last integer   -- inclusive

---@class differ.merge.RenderColumn
---@field side "ours"|"base"|"theirs"|"result"
---@field lines string[]
---@field regions differ.merge.ColumnRegion[]
---@field folds differ.FoldRange[]  -- unchanged spans outside the slabs, foldable on demand

---@class differ.merge.RenderResult
---@field columns differ.merge.RenderColumn[]
---@field result_index integer -- index into columns of the editable result spine

local M = {}

-- lead/tail context kept unfolded around each slab/block (file boundaries aren't padded)
local FOLD_CONTEXT = 3

-- the unchanged spans of a column = the gaps outside its located slabs, trimmed by a
-- lead/tail context (no trim against the file's top/bottom boundary). reuses the diff
-- renderer's inclusive {first,last} FoldRange so the session folds them the same way. pure
---@param total integer  -- the column's line count
---@param regions differ.merge.ColumnRegion[]  -- ordered, non-overlapping
---@return differ.FoldRange[]
local function fold_ranges(total, regions)
    local folds, pos = {}, 1 -- pos: first line not yet covered by a slab
    for i, r in ipairs(regions) do
        local first = pos + (i == 1 and 0 or FOLD_CONTEXT) -- no lead trim at the file top
        local last = r.first - 1 - FOLD_CONTEXT
        if last >= first then
            folds[#folds + 1] = { first = first, last = last }
        end
        pos = r.last + 1
    end
    local first = pos + (#regions == 0 and 0 or FOLD_CONTEXT)
    if total >= first then -- trailing span to EOF, no tail trim at the file bottom
        folds[#folds + 1] = { first = first, last = total }
    end
    return folds
end

-- first 1-based start at or after `from` where `slab` matches `lines` run-for-run, or nil
---@param lines string[]
---@param slab string[]
---@param from integer
---@return integer|nil
local function find_run(lines, slab, from)
    for start = from, #lines - #slab + 1 do
        local hit = true
        for k = 1, #slab do
            if lines[start + k - 1] ~= slab[k] then
                hit = false
                break
            end
        end
        if hit then
            return start
        end
    end
    return nil
end

-- locate each region's `key` slab (ours/base/theirs) inside a stage file's lines, in
-- order; an empty or unlocated slab contributes no region (so it stays unhighlighted)
---@param lines string[]
---@param regions differ.merge.Region[]
---@param key "ours"|"base"|"theirs"
---@return differ.merge.ColumnRegion[]
local function locate_regions(lines, regions, key)
    local out, from = {}, 1
    for _, r in ipairs(regions) do
        local slab = r[key]
        if slab and #slab > 0 then
            local s = find_run(lines, slab, from)
            if s then
                out[#out + 1] = { index = r.index, first = s, last = s + #slab - 1 }
                from = s + #slab
            end
        end
    end
    return out
end

-- build the merge columns. base is shown only under the diff4 layout (it's read
-- + carried regardless, so the toggle costs nothing); the result column is always last
---@param model differ.MergeModel
---@param opts { layout?: "default"|"diff4" }|nil
---@return differ.merge.RenderResult
function M.render(model, opts)
    opts = opts or {}
    local show_base = opts.layout == "diff4"

    local ours = to_lines(model.ours_text)
    local theirs = to_lines(model.theirs_text)
    local result = to_lines(model.result_text)

    local ours_regions = locate_regions(ours, model.regions, "ours")
    local columns = {
        {
            side = "ours",
            lines = ours,
            regions = ours_regions,
            folds = fold_ranges(#ours, ours_regions),
        },
    }
    if show_base then
        local base = to_lines(model.base_text)
        local base_regions = locate_regions(base, model.regions, "base")
        columns[#columns + 1] = {
            side = "base",
            lines = base,
            regions = base_regions,
            folds = fold_ranges(#base, base_regions),
        }
    end
    local theirs_regions = locate_regions(theirs, model.regions, "theirs")
    columns[#columns + 1] = {
        side = "theirs",
        lines = theirs,
        regions = theirs_regions,
        folds = fold_ranges(#theirs, theirs_regions),
    }

    -- the result regions are exact: each marker block's line span (markers included)
    local result_regions = {}
    for _, r in ipairs(model.regions) do
        result_regions[#result_regions + 1] =
            { index = r.index, first = r.result_start, last = r.result_end }
    end
    columns[#columns + 1] = {
        side = "result",
        lines = result,
        regions = result_regions,
        folds = fold_ranges(#result, result_regions),
    }

    return { columns = columns, result_index = #columns }
end

return M
