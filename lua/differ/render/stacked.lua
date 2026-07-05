-- stacked dual-rail renderer: old/new interleaved per hunk on one scroll surface.
-- pure function over the hunk model (no nvim API) so it stays testable without nvim.
-- buffer lines are raw code (search/yank/motions work); +/- styling and line
-- numbers are painted later from the map, never baked into the text

local LineMap = require("differ.render.linemap")
local text_util = require("differ.util.text")
local spans = require("differ.worddiff.spans")
local walk = require("differ.render.walk")

local M = {}

local BINARY_NOTICE = "Binary file not shown"

-- render a model into a single "unified" column: interleaved buffer lines plus
-- a populated line map and the fold ranges (buffer coords) the view collapses
---@param model differ.DiffModel
---@param opts { context: integer, deep_diff?: table }
---@return differ.RenderResult
function M.render(model, opts)
    local map = LineMap.new()
    local lines = {}
    local folds = {}
    local fold_start = nil
    local gap = 0 -- boundary index: 0 before the first hunk, hi between hunk hi and hi+1

    -- extend/close the running fold run as lines are pushed; foldable context
    -- lines accumulate, anything else closes the run at the previous line
    local function mark(foldable)
        if foldable then
            fold_start = fold_start or #lines
        elseif fold_start then
            folds[#folds + 1] = { first = fold_start, last = #lines - 1, gap = gap }
            fold_start = nil
        end
    end

    -- a binary file isn't diffed (it would blow up the word pass); show a placeholder
    if model.binary then
        map:push({ kind = "meta" })
        return {
            columns = { { lines = { BINARY_NOTICE }, map = map, side = "unified", folds = folds } },
            rows = 1,
        }
    end

    -- identical content produces no hunks; nothing to show
    if #model.hunks == 0 then
        return {
            columns = { { lines = lines, map = map, side = "unified", folds = folds } },
            rows = 0,
        }
    end

    local context = opts.context or 3
    local deep = opts.deep_diff or {}
    local deep_on = deep.enabled ~= false
    local threshold = deep.similarity_threshold or 0.5
    local mode = deep.granularity or "word"

    -- context lines are identical on both sides, so old_all supplies their text
    local old_all = text_util.to_lines(model.old_text)

    walk.walk(model, context, #old_all, {
        context = function(o, n, foldable)
            lines[#lines + 1] = old_all[o]
            map:push({ kind = "context", old = o, new = n })
            mark(foldable)
        end,
        -- a hunk shows its old (deleted) lines as a block, then its new (added) lines
        hunk = function(h, hi)
            local old_spans, new_spans = {}, {}
            if deep_on then
                old_spans, new_spans = spans.for_hunk(h, threshold, mode)
            end
            for k = 1, h.old_count do
                lines[#lines + 1] = h.old_lines[k]
                map:push({
                    kind = "old",
                    old = h.old_start + k - 1,
                    hunk = hi,
                    spans = old_spans[k],
                })
                mark(false)
            end
            for k = 1, h.new_count do
                lines[#lines + 1] = h.new_lines[k]
                map:push({
                    kind = "new",
                    new = h.new_start + k - 1,
                    hunk = hi,
                    spans = new_spans[k],
                })
                mark(false)
            end
            gap = hi -- entering the gap between this hunk and the next
        end,
    })
    if fold_start then
        folds[#folds + 1] = { first = fold_start, last = #lines, gap = gap }
    end

    return {
        columns = { { lines = lines, map = map, side = "unified", folds = folds } },
        rows = #lines,
    }
end

return M
