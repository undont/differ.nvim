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

-- flag the changed line a side ends on without a newline, the line git follows with
-- `\ No newline at end of file`
---@param model differ.DiffModel
---@param result differ.RenderResult
local function flag_no_eol(model, result)
    local to_lines = require("differ.util.text").to_lines
    local last = {} ---@type table<differ.RailKind, integer>
    for _, side in ipairs({ "old", "new" }) do
        local text = model[side .. "_text"]
        if text ~= "" and text:sub(-1) ~= "\n" then
            last[side] = #to_lines(text)
        end
    end
    for _, col in ipairs(result.columns) do
        for _, line in ipairs(col.map.lines) do
            if last[line.kind] and line[line.kind] == last[line.kind] then
                line.no_eol = true
            end
        end
    end
end

-- render a model under the given layout
---@param model differ.DiffModel
---@param opts { layout: differ.Layout, context: number, deep_diff: table }
---@return differ.RenderResult
function M.render(model, opts)
    local mod = RENDERERS[opts.layout]
    if not mod then
        error(("differ: unknown layout %q"):format(tostring(opts.layout)))
    end
    ---@type differ.Renderer
    local renderer = require(mod).render
    local result = renderer(model, opts)
    flag_no_eol(model, result)
    return result
end

return M
