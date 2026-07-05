-- render dispatch: the frozen signature is render(model, opts) -> RenderResult.
-- renderers are pure functions over the hunk model; a layout toggle is a re-render.
--
-- a render is N index-aligned columns, each its own buffer content + LineMap:
-- stacked is one "unified" column (old/new interleaved, dual-rail gutter), split
-- is two columns ("old" left, "new" right) with filler keeping rows aligned. the
-- view layer creates one buffer per column and scroll-binds when N > 1

---@alias differ.ColumnSide "old"|"new"|"unified"

---@class differ.FoldRange
---@field first integer -- 1-based buffer line, inclusive
---@field last integer
---@field gap? integer -- boundary index this gap sits at (0 = before the first hunk,
-- hi = between hunk hi and hi+1), stable across a context change
-- regardless of whether the gap folds at any given context.
-- merge.lua's regions-based folds don't set this

---@class differ.Column
---@field lines string[]            -- this column's buffer content (filler rows = "")
---@field map differ.LineMap        -- this column's line map
---@field side differ.ColumnSide
---@field folds differ.FoldRange[]  -- unchanged regions to collapse as native folds

---@class differ.RenderResult
---@field columns differ.Column[] -- one per buffer; all share `rows`
---@field rows integer            -- aligned row count

---@alias differ.Layout "stacked"|"split"

---@alias differ.Renderer fun(model: differ.DiffModel, opts: table): differ.RenderResult

local M = {}

---@type table<differ.Layout, string>
local RENDERERS = {
    stacked = "differ.render.stacked",
    split = "differ.render.split",
}

-- render a model under the given layout
---@param model differ.DiffModel
---@param opts { layout: differ.Layout, context: integer, deep_diff: table }
---@return differ.RenderResult
function M.render(model, opts)
    local mod = RENDERERS[opts.layout]
    if not mod then
        error(("differ: unknown layout %q"):format(tostring(opts.layout)))
    end
    ---@type differ.Renderer
    local renderer = require(mod).render
    return renderer(model, opts)
end

return M
