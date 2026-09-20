-- diff highlight layer: line-level backgrounds and word-level spans for one
-- column's buffer, applied as extmarks from its map. idempotent, clears the
-- namespace first, so it doubles as a refresh after a re-render or overlay change.
-- buffer content and the map are never touched here (invariant 2)

local M = {}

---@type table<differ.RailKind, string>
local LINE_HL = { old = "differLineDelete", new = "differLineAdd" }
---@type table<differ.RailKind, string>
local WORD_HL = { old = "differWordDelete", new = "differWordAdd" }

-- paint a column's buffer. `ns` is the caller's extmark namespace
---@param bufnr integer
---@param ns integer
---@param column differ.Column
function M.apply(bufnr, ns, column)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for i, line in ipairs(column.map.lines) do
        local row = i - 1
        -- split's filler: a meta row with no text, padding the column opposite an
        -- inserted/deleted block. fill it with dashes (columns wide, clipped to the
        -- pane) so the empty side reads as "no line here", not a blank void. anchored
        -- at window col 0; the binary-notice meta row carries text, so it's excluded
        if line.kind == "meta" and (column.lines[i] == nil or column.lines[i] == "") then
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
                virt_text = { { string.rep("-", vim.o.columns), "differFiller" } },
                virt_text_win_col = 0,
                priority = 100,
            })
        end
        local line_hl = LINE_HL[line.kind]
        if line_hl then
            -- char-level full-line fill, not line_hl_group: a line_hl_group bg wins
            -- over a character hl_group bg regardless of priority, which buries the
            -- word spans. hl_eol extends the fill past EOL so it still spans the row
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
                end_row = row + 1,
                end_col = 0,
                hl_group = line_hl,
                hl_eol = true,
                priority = 100,
            })
        end
        local word_hl = WORD_HL[line.kind]
        if word_hl and line.spans then
            for _, span in ipairs(line.spans) do
                vim.api.nvim_buf_set_extmark(bufnr, ns, row, span.col_start, {
                    end_col = span.col_end,
                    hl_group = word_hl,
                    priority = 200,
                })
            end
        end
    end
end

return M
