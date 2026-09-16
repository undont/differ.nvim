local paint = require("differ.ui.paint")
local render = require("differ.render")
local diff = require("differ.model.diff")

describe("paint no_eol", function()
    it("notes a changed last line with no newline after it", function()
        local model = diff.build({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb",
            new_text = "a\nb\n",
        })
        local col = render.render(model, { layout = "stacked", context = math.huge }).columns[1]
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, col.lines)
        local ns = vim.api.nvim_create_namespace("differ_paint_spec")
        paint.apply(buf, ns, col)

        local notes = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
            local chunks = mark[4].virt_text
            if chunks and mark[4].virt_text_pos == "eol" then
                notes[#notes + 1] = { row = mark[2], text = vim.trim(chunks[1][1]) }
            end
        end
        vim.api.nvim_buf_delete(buf, { force = true })
        -- rows: a (context), b (old, unterminated), b (new)
        assert.are.same({ { row = 1, text = "no newline at end of file" } }, notes)
    end)
end)
