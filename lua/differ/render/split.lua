-- side-by-side renderer from the same hunk model and map contract as stacked.
-- pure function over the hunk model (no nvim API).
--
-- real code lines must stay yankable/searchable, so side-by-side is two columns
-- (two buffers), not one buffer of "old | new" cells. this renderer emits two
-- index-aligned line sequences plus a LineMap per side (each conforming to the
-- frozen contract verbatim). filler cells (hunk padding) are kind=="meta" rows
-- with empty text so both columns stay row-aligned; unchanged regions are emitted
-- in full and collapsed by native folds, not dropped

local LineMap = require("differ.render.linemap")
local text_util = require("differ.util.text")
local spans = require("differ.worddiff.spans")
local pair = require("differ.worddiff.pair")
local walk = require("differ.render.walk")

local M = {}

local BINARY_NOTICE = "Binary file not shown"

-- render a model into two index-aligned columns ("old" left, "new" right). both
-- columns share the same fold ranges since their rows are aligned
---@param model differ.DiffModel
---@param opts { context: integer, deep_diff?: table }
---@return differ.RenderResult
function M.render(model, opts)
    local old_map, new_map = LineMap.new(), LineMap.new()
    local old_lines, new_lines = {}, {}
    local folds = {}
    local fold_start = nil
    local gap = 0 -- boundary index: 0 before the first hunk, hi between hunk hi and hi+1

    -- push one aligned row, keeping both columns the same length
    ---@param ltext string|nil
    ---@param lrail differ.RailLine
    ---@param rtext string|nil
    ---@param rrail differ.RailLine
    local function push_row(ltext, lrail, rtext, rrail)
        old_lines[#old_lines + 1] = ltext or ""
        new_lines[#new_lines + 1] = rtext or ""
        old_map:push(lrail)
        new_map:push(rrail)
    end

    -- extend/close the running fold run over the aligned rows
    local function mark(foldable)
        if foldable then
            fold_start = fold_start or #old_lines
        elseif fold_start then
            folds[#folds + 1] = { first = fold_start, last = #old_lines - 1, gap = gap }
            fold_start = nil
        end
    end

    local function result()
        return {
            columns = {
                { lines = old_lines, map = old_map, side = "old", folds = folds },
                { lines = new_lines, map = new_map, side = "new", folds = folds },
            },
            rows = #old_lines,
        }
    end

    -- a binary file isn't diffed (it would blow up the word pass); show a placeholder
    -- on both sides so the columns stay row-aligned
    if model.binary then
        push_row(BINARY_NOTICE, { kind = "meta" }, BINARY_NOTICE, { kind = "meta" })
        return result()
    end

    if #model.hunks == 0 then
        return result()
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
            push_row(
                old_all[o],
                { kind = "context", old = o, new = n },
                old_all[o],
                { kind = "context", old = o, new = n }
            )
            mark(foldable)
        end,
        -- side-by-side aligns old/new on similarity-matched anchor rows so an
        -- inserted or deleted line opens filler at its real position instead of
        -- shifting every row below it out of register. anchors split the hunk into
        -- change segments; within a segment the leftover deletions and insertions
        -- align row-by-row (substitution) and the shorter side pads with filler
        hunk = function(h, hi)
            local pairs_ = pair.pair(h.old_lines, h.new_lines, threshold)
            local mate = {}
            for _, p in ipairs(pairs_) do
                if p.old and p.new then
                    mate[p.old] = p.new
                end
            end

            -- push one row carrying an old line, a new line, or both (with spans)
            local function row(oi, ni)
                local lspan, rspan
                if deep_on and oi and ni then
                    local s = spans.emit(h.old_lines[oi], h.new_lines[ni], mode)
                    lspan, rspan = s.old, s.new
                end
                local lrail = oi
                        and { kind = "old", old = h.old_start + oi - 1, hunk = hi, spans = lspan }
                    or { kind = "meta" }
                local rrail = ni
                        and { kind = "new", new = h.new_start + ni - 1, hunk = hi, spans = rspan }
                    or { kind = "meta" }
                push_row(oi and h.old_lines[oi] or nil, lrail, ni and h.new_lines[ni] or nil, rrail)
                mark(false)
            end

            -- align a change segment's deletions against its insertions, padding
            -- the shorter side with filler rows
            local function flush(dels, inss)
                for k = 1, math.max(#dels, #inss) do
                    row(dels[k], inss[k])
                end
            end

            local no = 1
            local dels, inss = {}, {}
            for oi = 1, h.old_count do
                local ni = mate[oi]
                if ni then
                    for k = no, ni - 1 do
                        inss[#inss + 1] = k
                    end
                    flush(dels, inss)
                    dels, inss = {}, {}
                    row(oi, ni)
                    no = ni + 1
                else
                    dels[#dels + 1] = oi
                end
            end
            for k = no, h.new_count do
                inss[#inss + 1] = k
            end
            flush(dels, inss)
            gap = hi -- entering the gap between this hunk and the next
        end,
    })
    if fold_start then
        folds[#folds + 1] = { first = fold_start, last = #old_lines, gap = gap }
    end

    return result()
end

return M
