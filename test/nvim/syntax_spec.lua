-- runs under headless nvim: drives the View over real lua source and asserts the
-- treesitter syntax pass projects captures onto the derived buffer through
-- the line map, in its own namespace, layered under the diff highlights
local diff = require("differ.model.diff")
local View = require("differ.view")

local ns = vim.api.nvim_create_namespace("differ.syntax")

local function model(old, new, path)
    return diff.build({
        path = path or "x.lua",
        old_rev = "A",
        new_rev = "B",
        old_text = old,
        new_text = new,
    })
end

-- syntax extmarks for a buffer: { {row, col, end_col, hl, priority}, ... }
local function syntax_marks(bufnr)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        out[#out + 1] = {
            row = m[2],
            col = m[3],
            end_col = m[4].end_col,
            hl = m[4].hl_group,
            priority = m[4].priority,
        }
    end
    return out
end

-- the first mark with `hl` on `row` (optionally starting at `col`), or nil
local function find(marks, row, hl, col)
    for _, m in ipairs(marks) do
        if m.row == row and m.hl == hl and (col == nil or m.col == col) then
            return m
        end
    end
    return nil
end

-- is there a mark with `hl` on `row` (optionally starting at `col`)?
local function has(marks, row, hl, col)
    return find(marks, row, hl, col) ~= nil
end

-- is there a mark with `hl` anywhere in the buffer?
local function has_hl(marks, hl)
    for _, m in ipairs(marks) do
        if m.hl == hl then
            return true
        end
    end
    return false
end

local function view(old, new, opts)
    return View.new(
        model(old, new, opts and opts.path),
        vim.tbl_extend(
            "force",
            { layout = "stacked", context = math.huge, deep_diff = { enabled = true } },
            opts or {}
        )
    )
end

describe("syntax pass (stacked)", function()
    it("projects captures onto both old and new lines via the map", function()
        -- single-line substitution: stacked emits old on row 0, new on row 1
        local v = view("local x = 1\n", "local y = 2\n")
        v:open()
        local marks = syntax_marks(v.columns[1].bufnr)
        -- `local` keyword highlighted on the old line (row 0) and the new line (row 1)
        assert.is_true(has(marks, 0, "@keyword.lua", 0))
        assert.is_true(has(marks, 1, "@keyword.lua", 0))
        v:close()
    end)

    it("highlights context lines too (they map from the real source)", function()
        local v = view("local a = 1\nkeep()\n", "local b = 1\nkeep()\n")
        v:open()
        -- buffer: old "local a = 1" (0), new "local b = 1" (1), context "keep()" (2)
        local marks = syntax_marks(v.columns[1].bufnr)
        assert.is_true(has(marks, 0, "@keyword.lua", 0))
        assert.is_true(has(marks, 1, "@keyword.lua", 0))
        assert.is_true(has(marks, 2, "@function.call.lua")) -- keep() on the context row
        v:close()
    end)

    it("is a no-op when the path has no treesitter language", function()
        local v = view("local x = 1\n", "local y = 1\n", { path = "x" })
        v:open()
        assert.are.same({}, syntax_marks(v.columns[1].bufnr))
        v:close()
    end)
end)

describe("syntax pass (split)", function()
    it("paints each column from its own side's source", function()
        local v = view("local x = 1\n", "local y = 1\n", { layout = "split" })
        v:open()
        local left = syntax_marks(v.columns[1].bufnr) -- old
        local right = syntax_marks(v.columns[2].bufnr) -- new
        assert.is_true(has(left, 0, "@keyword.lua", 0))
        assert.is_true(has(right, 0, "@keyword.lua", 0))
        v:close()
    end)
end)

-- injected languages: a fenced lua block in markdown. both parsers ship with nvim, so
-- this holds wherever the suite runs; astro/vue/svelte are the same shape, with the bulk
-- of the file living in injections rather than in the host tree
describe("syntax pass (injections)", function()
    -- stacked, whole-file context: "# t"(0), ""(1), "```lua"(2), old(3), new(4), "```"(5)
    local function md_view()
        return view("# t\n\n```lua\nlocal x = 1\n```\n", "# t\n\n```lua\nlocal y = 2\n```\n", {
            path = "x.md",
        })
    end

    it("highlights the embedded language, not just the host", function()
        local v = md_view()
        v:open()
        local marks = syntax_marks(v.columns[1].bufnr)
        assert.is_true(has(marks, 3, "@keyword.lua", 0)) -- `local` on the old line
        assert.is_true(has(marks, 4, "@keyword.lua", 0)) -- and on the new line
        assert.is_true(has(marks, 0, "@markup.heading.1.markdown")) -- host tree still paints
        v:close()
    end)

    it("layers an injected capture over the host's on the same row", function()
        local v = md_view()
        v:open()
        local marks = syntax_marks(v.columns[1].bufnr)
        -- markdown captures the whole fence as raw block, lua captures inside it
        local host = find(marks, 3, "@markup.raw.block.markdown")
        local injected = find(marks, 3, "@keyword.lua")
        assert.is_not_nil(host)
        assert.is_not_nil(injected)
        assert.is_true(injected.priority > host.priority)
        v:close()
    end)

    it("skips spell captures, which carry metadata rather than a highlight", function()
        local v = md_view()
        v:open()
        local marks = syntax_marks(v.columns[1].bufnr)
        assert.is_false(has_hl(marks, "@spell.markdown"))
        assert.is_false(has_hl(marks, "@nospell.markdown"))
        v:close()
    end)
end)

-- apply_snippets projects treesitter captures onto arbitrary buffer rows (the overview's
-- boxed hunk lines), parsed from the stripped source text and shifted right by col_offset
-- to clear the box spine + inset. same namespace/helpers as the View syntax pass
describe("apply_snippets (overview hunk syntax)", function()
    local syntax = require("differ.syntax")

    -- a scratch buffer wide enough at each row that the shifted extmarks land (a col past
    -- the line's end is silently dropped inside apply_snippets)
    local function scratch(lines)
        local b = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
        return b
    end

    it("projects captures onto the snippet rows, shifted by col_offset", function()
        local offset = 5
        local pad = string.rep(" ", offset)
        local b = scratch({ pad .. "local x = 1", pad .. "keep()" })
        syntax.apply_snippets(b, {
            {
                path = "x.lua",
                col_offset = offset,
                lines = {
                    { text = "local x = 1", row = 0 },
                    { text = "keep()", row = 1 },
                },
            },
        })
        local marks = syntax_marks(b)
        assert.is_true(has(marks, 0, "@keyword.lua", offset)) -- `local`, shifted past the inset
        assert.is_true(has(marks, 1, "@function.call.lua")) -- keep() on the next snippet row
    end)

    it("projects injected captures too, shifted by col_offset", function()
        local offset = 3
        local pad = string.rep(" ", offset)
        local src = { "```lua", "local x = 1", "```" }
        local b = scratch({ pad .. src[1], pad .. src[2], pad .. src[3] })
        syntax.apply_snippets(b, {
            {
                path = "x.md",
                col_offset = offset,
                lines = {
                    { text = src[1], row = 0 },
                    { text = src[2], row = 1 },
                    { text = src[3], row = 2 },
                },
            },
        })
        assert.is_true(has(syntax_marks(b), 1, "@keyword.lua", offset))
    end)

    it("is a no-op for a path with no treesitter language", function()
        local b = scratch({ "local x = 1" })
        syntax.apply_snippets(b, {
            { path = "x", col_offset = 0, lines = { { text = "local x = 1", row = 0 } } },
        })
        assert.are.same({}, syntax_marks(b))
    end)
end)
