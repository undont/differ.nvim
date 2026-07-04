-- runs under headless nvim: drives the View through real windows/buffers and
-- asserts content, the diff highlight extmarks, and split scroll-binding
local diff = require("differ.model.diff")
local View = require("differ.view")

-- nvim_create_namespace is idempotent by name, so this is the same ns the View uses
local ns = vim.api.nvim_create_namespace("differ")

local function model(old, new)
    return diff.build({ path = "x", old_rev = "A", new_rev = "B", old_text = old, new_text = new })
end

-- collect line fills per 0-based row and word hl_group spans from the namespace.
-- the line bg is a char-level full-line fill (hl_eol) rather than a line_hl_group,
-- so it wins/loses against the word spans by priority; classify it by hl_eol
local function extmarks(bufnr)
    local line_hl, word = {}, {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        local row, d = m[2], m[4]
        if d.hl_eol then
            line_hl[row] = d.hl_group
        elseif d.hl_group then
            word[#word + 1] = { row = row, col = m[3], end_col = d.end_col, hl = d.hl_group }
        end
    end
    return line_hl, word
end

describe("view stacked", function()
    it("opens one window with rendered lines and line-level highlights", function()
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.are.equal(1, #v.columns)
        local buf = v.columns[1].bufnr
        assert.are.same({ "a", "b", "B", "c" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

        local win = v.columns[1].winid
        assert.is_false(vim.wo[win].number)
        assert.is_true(vim.wo[win].wrap) -- wrap defaults on

        local line_hl = extmarks(buf)
        assert.are.equal("differLineDelete", line_hl[1]) -- "b" (old)
        assert.are.equal("differLineAdd", line_hl[2]) -- "B" (new)
        assert.is_nil(line_hl[0]) -- "a" (context) unhighlighted
        v:close()
    end)

    it("honours wrap = false, disabling soft-wrap in the diff window", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            wrap = false,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.is_false(vim.wo[v.columns[1].winid].wrap)
        v:close()
    end)

    it("paints word-level spans for paired changed lines", function()
        local v = View.new(model("local foo = 1\n", "local bar = 1\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local _, word = extmarks(v.columns[1].bufnr)
        -- one old-side and one new-side span, both over cols [6,9)
        table.sort(word, function(x, y)
            return x.hl < y.hl
        end)
        assert.are.equal(2, #word)
        assert.are.equal("differWordAdd", word[1].hl)
        assert.are.equal(6, word[1].col)
        assert.are.equal(9, word[1].end_col)
        assert.are.equal("differWordDelete", word[2].hl)
        v:close()
    end)
end)

describe("view window options", function()
    it("sets gutter/fold options window-locally, not on the global default", function()
        local g_statuscolumn, g_number, g_wrap = vim.go.statuscolumn, vim.go.number, vim.go.wrap
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local win = v.columns[1].winid
        -- the window carries differ's dressing...
        assert.is_truthy(vim.wo[win].statuscolumn:find("differ", 1, true))
        assert.is_false(vim.wo[win].number)
        -- ...but the global defaults are untouched, so other windows are unaffected
        assert.are.equal(g_statuscolumn, vim.go.statuscolumn)
        assert.are.equal(g_number, vim.go.number)
        assert.are.equal(g_wrap, vim.go.wrap)
        v:close()
    end)
end)

describe("view split", function()
    it("opens a scroll-bound pair with per-side highlights", function()
        local v = View.new(model("a\nM\nb\n", "a\nX\nb\n"), {
            layout = "split",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.are.equal(2, #v.columns)
        local left, right = v.columns[1], v.columns[2]

        assert.are.same({ "a", "M", "b" }, vim.api.nvim_buf_get_lines(left.bufnr, 0, -1, false))
        assert.are.same({ "a", "X", "b" }, vim.api.nvim_buf_get_lines(right.bufnr, 0, -1, false))

        assert.is_true(vim.wo[left.winid].scrollbind)
        assert.is_true(vim.wo[right.winid].scrollbind)

        local left_hl = extmarks(left.bufnr)
        local right_hl = extmarks(right.bufnr)
        assert.are.equal("differLineDelete", left_hl[1]) -- old "M" on the left
        assert.are.equal("differLineAdd", right_hl[1]) -- new "X" on the right
        v:close()
    end)
end)

describe("view hunk navigation", function()
    -- two changes far apart so there are two distinct hunks to jump between
    local function two_hunk_view()
        return View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
    end

    it("moves the cursor between hunks via goto_hunk", function()
        local v = two_hunk_view()
        v:open()
        local win = v.columns[1].winid
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        v:goto_hunk("next")
        assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1]) -- first hunk
        v:goto_hunk("next")
        assert.are.equal(9, vim.api.nvim_win_get_cursor(win)[1]) -- second hunk
        v:goto_hunk("next")
        assert.are.equal(9, vim.api.nvim_win_get_cursor(win)[1]) -- last hunk, no panel to step into
        v:goto_hunk("prev")
        assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
        v:close()
    end)

    it("the diff winbar reports the file and the hunk under the cursor", function()
        local v = two_hunk_view()
        v:open()
        local win = v.columns[1].winid
        local winbar = require("differ.ui.winbar")
        vim.g.statusline_winid = win
        vim.api.nvim_win_set_cursor(win, { 2, 0 }) -- first hunk
        local s = winbar.diff()
        assert.is_truthy(s:find("x", 1, true)) -- the file basename
        assert.is_truthy(s:find("hunk 1/2", 1, true))
        vim.api.nvim_win_set_cursor(win, { 9, 0 }) -- second hunk
        assert.is_truthy(winbar.diff():find("hunk 2/2", 1, true))
        vim.g.statusline_winid = nil
        v:close()
    end)

    it("binds ]c and [c as buffer-local motions", function()
        local v = two_hunk_view()
        v:open()
        local buf = v.columns[1].bufnr
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            lhs[m.lhs] = true
        end
        assert.is_true(lhs["]c"])
        assert.is_true(lhs["[c"])
        v:close()
    end)
end)

describe("view in-view keymaps", function()
    local function maps(v)
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(v.columns[1].bufnr, "n")) do
            lhs[m.lhs] = true
        end
        return lhs
    end

    it("binds ]f/[f and (by default) f/b in the diff window", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local lhs = maps(v)
        assert.is_true(lhs["]f"])
        assert.is_true(lhs["[f"])
        assert.is_true(lhs["f"])
        assert.is_true(lhs["b"])
        v:close()
    end)

    it("omits f/b when scroll is disabled, keeping ]f/[f", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
            keymaps = { scroll_down = false, scroll_up = false },
        })
        v:open()
        local lhs = maps(v)
        assert.is_true(lhs["]f"])
        assert.is_nil(lhs["f"])
        assert.is_nil(lhs["b"])
        v:close()
    end)

    it("remaps an action to a custom lhs, dropping the default", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
            keymaps = require("differ.config").resolve_keymaps({ next_hunk = "gh" }).diff,
        })
        v:open()
        local lhs = maps(v)
        assert.is_true(lhs["gh"]) -- the custom lhs is bound
        assert.is_nil(lhs["]c"]) -- the default is gone
        v:close()
    end)
end)

describe("view layout toggle", function()
    it("drops the surplus column when going split -> stacked", function()
        local v = View.new(model("a\nM\nb\n", "a\nX\nb\n"), {
            layout = "split",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local stale = v.columns[2].bufnr
        v:rerender({ layout = "stacked", context = math.huge, deep_diff = { enabled = true } })
        assert.are.equal(1, #v.columns)
        assert.is_false(vim.api.nvim_buf_is_valid(stale))
        v:close()
    end)

    it("relays windows when toggling stacked <-> split", function()
        vim.cmd("silent! only")
        local v = View.new(model("a\nM\nb\n", "a\nX\nb\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.are.equal(1, #v.columns)

        v:toggle_layout() -- -> split
        assert.are.equal(2, #v.columns)
        assert.are.equal("old", v.columns[1].side)
        assert.are.equal("new", v.columns[2].side)
        assert.is_true(vim.api.nvim_win_is_valid(v.columns[2].winid))
        assert.is_true(vim.wo[v.columns[1].winid].scrollbind)

        v:toggle_layout() -- -> stacked
        assert.are.equal(1, #v.columns)
        assert.are.equal("unified", v.columns[1].side)
        assert.is_false(vim.wo[v.columns[1].winid].scrollbind)
        v:close()
    end)
end)

describe("view context controls", function()
    local function fold_count(view)
        return #(view.columns[1].folds or {})
    end

    -- two hunks with a 5-line gap between them
    local function gap_view()
        return View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
    end

    it("collapses context into a fold, and opens it again at full context", function()
        local v = gap_view()
        v:open()
        assert.are.equal(0, fold_count(v)) -- whole file: nothing folded
        v:set_context(1)
        assert.are.equal(1, fold_count(v)) -- the 5-line gap folds
        v:set_context(math.huge)
        assert.are.equal(0, fold_count(v))
        v:close()
    end)

    it("creates the collapsed region as an open native fold the user can close", function()
        local v = View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = 1,
            deep_diff = { enabled = true },
        })
        v:open()
        local win = v.columns[1].winid
        assert.are.equal("manual", vim.wo[win].foldmethod)
        -- buffer rows 5..7 are the foldable middle: a real fold (level >= 1) but open
        -- by default, so za/zo/zc/zm act on it and zc collapses it to its start row
        local fold = vim.api.nvim_win_call(win, function()
            local c = vim.fn.foldclosed(5)
            local l = vim.fn.foldlevel(5)
            vim.cmd("normal! 5Gzc")
            return { open = c, level = l, after_close = vim.fn.foldclosed(5) }
        end)
        assert.are.equal(-1, fold.open) -- open by default
        assert.is_true(fold.level >= 1) -- but a real fold lives there
        assert.are.equal(5, fold.after_close) -- and zc collapses it
        v:close()
    end)

    it("widens/narrows by one and no-ops at whole-file", function()
        local v = gap_view()
        v:open()
        v:set_context(2)
        v:adjust_context(-1)
        assert.are.equal(1, v.context)
        v:adjust_context(1)
        assert.are.equal(2, v.context)
        v:set_context(math.huge)
        v:adjust_context(-1) -- can't decrement infinity
        assert.are.equal(math.huge, v.context)
        v:close()
    end)
end)

describe("view re-source", function()
    it("set_source swaps the file in place, reusing the column buffer", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf = v.columns[1].bufnr
        v:set_source(model("x\ny\n", "x\nY\n"))
        assert.are.equal(buf, v.columns[1].bufnr) -- same buffer, re-rendered
        assert.are.same({ "x", "y", "Y" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        v:close()
    end)

    it("names the stacked buffer differ://<path> and renames on re-source", function()
        local function named(path)
            return diff.build({
                path = path,
                old_rev = "HEAD",
                new_rev = "WORKTREE",
                old_text = "a\n",
                new_text = "a\nb\n",
            })
        end
        local v = View.new(named("lua/a.lua"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf = v.columns[1].bufnr
        local name = vim.api.nvim_buf_get_name(buf)
        -- clean name: scheme + path only, no revs/side noise
        assert.is_truthy(name:find("differ://lua/a.lua", 1, true))
        assert.are.equal("a.lua", vim.fn.fnamemodify(name, ":t")) -- statusline shows the basename

        v:set_source(named("lua/b.lua"))
        assert.is_truthy(vim.api.nvim_buf_get_name(buf):find("differ://lua/b.lua", 1, true))
        v:close()
    end)

    it("disambiguates a split's two columns with an old/new segment", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "split",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.is_truthy(
            vim.api.nvim_buf_get_name(v.columns[1].bufnr):find("differ://old/x", 1, true)
        )
        assert.is_truthy(
            vim.api.nvim_buf_get_name(v.columns[2].bufnr):find("differ://new/x", 1, true)
        )
        v:close()
    end)

    it(
        "uses a private filetype, exposing the source filetype as a buffer var, with native syntax off",
        function()
            local function named(path)
                return diff.build({
                    path = path,
                    old_rev = "A",
                    new_rev = "B",
                    old_text = "x\n",
                    new_text = "x\ny\n",
                })
            end
            local v = View.new(named("foo.lua"), {
                layout = "stacked",
                context = math.huge,
                deep_diff = { enabled = true },
            })
            v:open()
            local buf = v.columns[1].bufnr
            -- a private filetype so foreign `FileType <lang>` consumers (lsp, lint) don't attach
            assert.are.equal("differdiff", vim.bo[buf].filetype)
            assert.are.equal("lua", vim.b[buf].differ_filetype) -- source filetype for a lualine label
            assert.are.equal("OFF", vim.bo[buf].syntax) -- differ paints its own syntax pass
            v:set_source(named("bar.py")) -- the source-filetype var tracks the re-sourced file
            assert.are.equal("differdiff", vim.bo[buf].filetype)
            assert.are.equal("python", vim.b[buf].differ_filetype)
            v:close()
        end
    )

    it("holds the cursor near the prior hunk when re-sourced with a focus_line", function()
        -- two hunks: line 2 (b->B) and line 8 (h->H)
        local old, new = "a\nb\nc\nd\ne\nf\ng\nh\n", "a\nB\nc\nd\ne\nf\ng\nH\n"
        local v = View.new(model(old, new), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local win = v.columns[1].winid

        -- a bare re-source jumps to the first hunk (row 2: the deleted "b")
        v:set_source(model(old, new))
        assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])

        -- park on the second hunk's new line, capture it, re-source preserving it: the
        -- cursor holds on that exact line (row 10, the "H"), not the hunk's top (row 9)
        vim.api.nvim_win_set_cursor(win, { 10, 0 })
        local line = v:cursor_new_line()
        assert.are.equal(8, line) -- the new-side line under the cursor ("H")
        v:set_source(model(old, new), nil, { focus_line = line })
        assert.are.equal(10, vim.api.nvim_win_get_cursor(win)[1]) -- exact line, not row 9
        v:close()
    end)

    it("focuses the exact changed line on re-source, not the hunk's top", function()
        -- one multi-line hunk: new-side lines 2,3,4 (B,C,D) all changed
        local old, new = "a\nb\nc\nd\ne\n", "a\nB\nC\nD\ne\n"
        local v = View.new(model(old, new), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local col = v.columns[1]
        v:focus_new_line(4, true) -- the "D" line, deep in the hunk
        local cur = vim.api.nvim_win_get_cursor(col.winid)[1]
        assert.are.equal(col.map.from_new[4], cur) -- landed on D's row exactly
        assert.is_true(cur > col.map.from_new[2]) -- below the top of the new block
        v:close()
    end)

    it("snaps an unchanged origin line to the nearest hunk, not the context row", function()
        -- the change is at lines 2-4 (B,C,D); line 5 ("e") is an unchanged context line
        local old, new = "a\nb\nc\nd\ne\n", "a\nB\nC\nD\ne\n"
        local v = View.new(model(old, new), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local col = v.columns[1]
        v:focus_new_line(5, true) -- parked on the "e" context line below the hunk
        local cur = vim.api.nvim_win_get_cursor(col.winid)[1]
        assert.is_not_nil(col.map.lines[cur].hunk) -- landed on the hunk, not the context row
        assert.are_not.equal(col.map.from_new[5], cur)
        v:close()
    end)

    it("origin-open can snap to a later hunk, not the file's first", function()
        -- two far-apart changes; an origin line parked next to the second one must
        -- snap to IT, not fall back to the first hunk in the file. this is the
        -- open-on-origin path (`:Differ` invoked from inside a changed file): it
        -- deliberately does not land on "the first hunk" the way a plain ]c-driven
        -- file switch does, so a subsequent ]c can correctly find no hunk left in
        -- this file and flow to the next one instead of appearing to skip a hunk
        local old = "a\nOLD_A\nctx1\nctx2\nctx3\nctx4\nctx5\nOLD_B\nz\n"
        local new = "a\nNEW_A\nctx1\nctx2\nctx3\nctx4\nctx5\nNEW_B\nz\n"
        local v = View.new(model(old, new), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local col = v.columns[1]
        assert.are.equal(2, #v.model.hunks)

        v:focus_new_line(7, true) -- "ctx5", the unchanged line right above NEW_B
        local cur = vim.api.nvim_win_get_cursor(col.winid)[1]
        assert.are.equal(2, col.map.lines[cur].hunk) -- snapped to the second hunk, not the first

        -- from there, ]c must not wrap back to the first hunk: nothing left after
        -- the second hunk in this file, so the cursor stays put (a real caller with
        -- a panel/next file would flow out instead)
        v:goto_hunk("next")
        assert.are.equal(cur, vim.api.nvim_win_get_cursor(col.winid)[1])
        v:close()
    end)
end)

describe("view jump-to-file", function()
    local function write(dir, name, text)
        vim.fn.mkdir(dir, "p")
        local fd = assert(io.open(dir .. "/" .. name, "w"))
        fd:write(text)
        fd:close()
    end

    it("opens the real file at the mapped line and tears the view down", function()
        vim.cmd("silent! only")
        local dir = vim.fn.tempname()
        write(dir, "f.txt", "a\nB\nc\n")
        local m = diff.build({
            path = "f.txt",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "a\nb\nc\n",
            new_text = "a\nB\nc\n",
            root = dir,
        })
        local v =
            View.new(m, { layout = "stacked", context = math.huge, deep_diff = { enabled = true } })
        v:open()
        local buf, win = v.columns[1].bufnr, v.columns[1].winid
        -- cursor on the added "B" (buffer line 3 -> new-side line 2)
        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        v:jump_to_file()

        local cur = vim.api.nvim_get_current_buf()
        assert.are.equal("f.txt", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur), ":t"))
        assert.are.equal("", vim.bo[cur].buftype) -- a real file, not the synthetic buffer
        assert.are.same({ "a", "B", "c" }, vim.api.nvim_buf_get_lines(cur, 0, -1, false))
        assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
        assert.is_false(vim.api.nvim_buf_is_valid(buf)) -- the diff buffer is gone
        -- differ's custom gutter is shed, so the real file's line numbers render
        assert.are.equal("", vim.wo[win].statuscolumn)
    end)

    it("notifies and stays put for a source with no root", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf = v.columns[1].bufnr
        v:jump_to_file()
        assert.is_true(vim.api.nvim_buf_is_valid(buf)) -- still open: no file-backed source
        v:close()
    end)

    it(
        "switches to an already-loaded, unsaved real-file buffer rather than :edit-reloading it",
        function()
            vim.cmd("silent! only")
            local dir = vim.fn.tempname()
            write(dir, "f.txt", "a\nb\nc\n")
            local function build()
                return diff.build({
                    path = "f.txt",
                    old_rev = "HEAD",
                    new_rev = "WORKTREE",
                    old_text = "a\nb\nc\n",
                    new_text = "a\nb\nc\n",
                    root = dir,
                })
            end
            local v1 = View.new(
                build(),
                { layout = "stacked", context = math.huge, deep_diff = { enabled = true } }
            )
            v1:open()
            v1:jump_to_file() -- first jump: loads the real file fresh

            -- edit the real buffer and leave it unsaved, as `de` -> type -> (no :w) would
            local realbuf = vim.api.nvim_get_current_buf()
            vim.api.nvim_buf_set_lines(realbuf, 1, 2, false, { "B" })
            assert.is_true(vim.bo[realbuf].modified)

            -- a second differ session over the same file, then jump_to_file again: must
            -- not try to :edit (reload) the dirty buffer, which would raise E37
            local v2 = View.new(
                build(),
                { layout = "stacked", context = math.huge, deep_diff = { enabled = true } }
            )
            v2:open()
            assert.has_no.errors(function()
                v2:jump_to_file()
            end)

            assert.are.equal(realbuf, vim.api.nvim_get_current_buf()) -- reused, not reloaded
            assert.is_true(vim.bo[realbuf].modified) -- unsaved edit survived
            assert.are.same({ "a", "B", "c" }, vim.api.nvim_buf_get_lines(realbuf, 0, -1, false))
        end
    )
end)

describe("view edit-in-review", function()
    local function write(dir, name, text)
        vim.fn.mkdir(dir, "p")
        local fd = assert(io.open(dir .. "/" .. name, "w"))
        fd:write(text)
        fd:close()
    end

    local function worktree_model(dir, path, old, new)
        return diff.build({
            path = path,
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = old,
            new_text = new,
            root = dir,
        })
    end

    it("opens the real file in a kept-alive window at the mapped line", function()
        vim.cmd("silent! only")
        local dir = vim.fn.tempname()
        write(dir, "f.txt", "a\nB\nc\n")
        local v = View.new(worktree_model(dir, "f.txt", "a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local diff_buf, diff_win = v.columns[1].bufnr, v.columns[1].winid
        vim.api.nvim_win_set_cursor(diff_win, { 3, 0 }) -- the added "B" (new-side line 2)
        v:edit_file()

        assert.is_truthy(v.edit_win)
        assert.is_true(vim.api.nvim_win_is_valid(v.edit_win))
        assert.are_not.equal(diff_win, v.edit_win) -- a separate window, not the diff's
        local cur = vim.api.nvim_get_current_buf()
        assert.are.equal("f.txt", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur), ":t"))
        assert.are.equal("", vim.bo[cur].buftype) -- the real file, editable
        assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1]) -- mapped to the new side
        assert.is_true(vim.api.nvim_buf_is_valid(diff_buf)) -- session kept: diff still alive
        v:close()
    end)

    it("drives the unstage hook for a staged source (flow C)", function()
        vim.cmd("silent! only")
        local dir = vim.fn.tempname()
        write(dir, "f.txt", "a\nB\nc\n")
        local hook_path, applied
        local m = diff.build({
            path = "f.txt",
            old_rev = "HEAD",
            new_rev = "INDEX",
            old_text = "a\nb\nc\n",
            new_text = "a\nB\nc\n",
            root = dir,
        })
        local v = View.new(m, {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
            can_stage = true,
            staging = {
                initial = "staged",
                apply = function()
                    applied = true
                    return true
                end,
                refresh = function() end,
            },
            on_edit_unstage = function(path)
                hook_path = path
            end,
        })
        v:open()
        v:edit_file()
        assert.are.equal("f.txt", hook_path) -- the frontend hook ran with the path
        assert.is_nil(applied) -- the hook supersedes the in-place unstage
        assert.is_truthy(v.edit_win) -- and the editor opened
        v:close()
    end)

    it("falls back to an in-place unstage when no hook is wired", function()
        vim.cmd("silent! only")
        local dir = vim.fn.tempname()
        write(dir, "f.txt", "a\nB\nc\n")
        local reversed = {}
        local m = diff.build({
            path = "f.txt",
            old_rev = "HEAD",
            new_rev = "INDEX",
            old_text = "a\nb\nc\n",
            new_text = "a\nB\nc\n",
            root = dir,
        })
        local v = View.new(m, {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
            can_stage = true,
            staging = {
                initial = "staged",
                apply = function(_, _, _, reverse)
                    reversed[#reversed + 1] = reverse
                    return true
                end,
                refresh = function() end,
            },
        })
        v:open()
        v:edit_file()
        assert.are.same({ true }, reversed) -- the hunk was unstaged (reverse=true)
        assert.is_truthy(v.edit_win)
        v:close()
    end)

    it("also edits a staged (index) source", function()
        vim.cmd("silent! only")
        local dir = vim.fn.tempname()
        write(dir, "f.txt", "a\nB\nc\n")
        -- a staged diff is HEAD<->INDEX; the file on disk is still editable
        local m = diff.build({
            path = "f.txt",
            old_rev = "HEAD",
            new_rev = "INDEX",
            old_text = "a\nb\nc\n",
            new_text = "a\nB\nc\n",
            root = dir,
        })
        local v =
            View.new(m, { layout = "stacked", context = math.huge, deep_diff = { enabled = true } })
        v:open()
        v:edit_file()
        assert.is_truthy(v.edit_win)
        local cur = vim.api.nvim_get_current_buf()
        assert.are.equal("f.txt", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur), ":t"))
        v:close()
    end)

    it("declines on a committed (rev) source", function()
        vim.cmd("silent! only")
        local dir = vim.fn.tempname()
        write(dir, "f.txt", "a\nB\nc\n")
        -- new side is a rev (B), not the file on disk, so editing must not open anything
        local m = diff.build({
            path = "f.txt",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\nc\n",
            new_text = "a\nB\nc\n",
            root = dir,
        })
        local v =
            View.new(m, { layout = "stacked", context = math.huge, deep_diff = { enabled = true } })
        v:open()
        local diff_buf = v.columns[1].bufnr
        v:edit_file()
        assert.is_nil(v.edit_win)
        assert.are.equal(diff_buf, vim.api.nvim_get_current_buf()) -- still on the diff
        v:close()
    end)

    it("releases an unsaved-free edit window when a different file is sourced", function()
        vim.cmd("silent! only")
        local dir = vim.fn.tempname()
        write(dir, "f.txt", "a\nB\nc\n")
        write(dir, "g.txt", "x\nY\nz\n")
        local v = View.new(worktree_model(dir, "f.txt", "a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        v:edit_file()
        local edit_win = v.edit_win
        assert.is_true(vim.api.nvim_win_is_valid(edit_win))

        v:set_source(worktree_model(dir, "g.txt", "x\ny\nz\n", "x\nY\nz\n"))
        assert.is_nil(v.edit_win) -- a file switch drops the stale edit window
        assert.is_false(vim.api.nvim_win_is_valid(edit_win))
        v:close()
    end)
end)

describe("view cursor-line overlay", function()
    local cursor_ns = vim.api.nvim_create_namespace("differ.cursorline")

    local CURSORLINE = {
        differCursorLine = true,
        differCursorLineAdd = true,
        differCursorLineDelete = true,
    }

    local function overlay_rows(buf)
        local rows = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, cursor_ns, 0, -1, { details = true })) do
            if CURSORLINE[m[4].hl_group] then
                rows[#rows + 1] = m[2]
            end
        end
        return rows
    end

    -- the cursorline hl_group at 0-based `row`, or nil
    local function overlay_hl(buf, row)
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, cursor_ns, 0, -1, { details = true })) do
            if CURSORLINE[m[4].hl_group] and m[2] == row then
                return m[4].hl_group
            end
        end
    end

    it("paints one overlay on the cursor row and follows the cursor", function()
        vim.cmd("silent! only")
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf, win = v.columns[1].bufnr, v.columns[1].winid
        -- exactly one overlay, on the row the cursor opened at
        local cur = vim.api.nvim_win_get_cursor(win)[1] - 1
        assert.are.same({ cur }, overlay_rows(buf))

        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
        assert.are.same({ 0 }, overlay_rows(buf)) -- moved with the cursor
        v:close()
    end)

    it("keeps the overlay only in the focused column in split", function()
        vim.cmd("silent! only")
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "split",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local left, right = v.columns[1], v.columns[2]
        -- focus opens on the first column; the off-side column carries no overlay
        assert.are.equal(1, #overlay_rows(left.bufnr))
        assert.are.equal(0, #overlay_rows(right.bufnr))
        v:close()
    end)

    it("tints the cursor overlay by the row's add/delete kind", function()
        vim.cmd("silent! only")
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf, win = v.columns[1].bufnr, v.columns[1].winid
        local line_hl = extmarks(buf)
        local add_row, del_row, ctx_row
        for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
            if line_hl[row] == "differLineAdd" then
                add_row = add_row or row
            elseif line_hl[row] == "differLineDelete" then
                del_row = del_row or row
            elseif line_hl[row] == nil then
                ctx_row = ctx_row or row
            end
        end
        assert.is_not_nil(add_row)
        assert.is_not_nil(del_row)

        local function hl_at(row)
            vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
            return overlay_hl(buf, row)
        end
        assert.are.equal("differCursorLineAdd", hl_at(add_row))
        assert.are.equal("differCursorLineDelete", hl_at(del_row))
        if ctx_row then
            assert.are.equal("differCursorLine", hl_at(ctx_row)) -- neutral off the change
        end
        v:close()
    end)

    it("falls back to a neutral overlay when cursorline_tint is false", function()
        vim.cmd("silent! only")
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
            cursorline_tint = false,
        })
        v:open()
        local buf, win = v.columns[1].bufnr, v.columns[1].winid
        local line_hl = extmarks(buf)
        local chg_row
        for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
            if line_hl[row] == "differLineAdd" or line_hl[row] == "differLineDelete" then
                chg_row = row
                break
            end
        end
        assert.is_not_nil(chg_row)
        vim.api.nvim_win_set_cursor(win, { chg_row + 1, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
        assert.are.equal("differCursorLine", overlay_hl(buf, chg_row)) -- no tint
        v:close()
    end)
end)

describe("view close guard", function()
    local function two_windows()
        vim.cmd("silent! only")
        vim.cmd("new") -- a second window so the diff window is never the last one
    end

    it("tears the bare view down when its diff window is closed", function()
        two_windows()
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf, win = v.columns[1].bufnr, v.columns[1].winid
        vim.api.nvim_win_close(win, true) -- a user :q on the diff window
        vim.wait(500, function()
            return not vim.api.nvim_buf_is_valid(buf)
        end)
        assert.is_false(vim.api.nvim_buf_is_valid(buf)) -- the whole view tore down
        assert.are.equal(0, #v.columns)
    end)

    it("tears down but keeps the window when a buffer is swapped into the diff window", function()
        two_windows()
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf, win = v.columns[1].bufnr, v.columns[1].winid
        local other = vim.api.nvim_create_buf(true, false) -- a file the user picks
        vim.api.nvim_win_set_buf(win, other) -- a picker / :edit into the diff window
        vim.wait(500, function()
            return not vim.api.nvim_buf_is_valid(buf)
        end)
        assert.is_false(vim.api.nvim_buf_is_valid(buf)) -- the diff tore down
        assert.are.equal(0, #v.columns)
        assert.is_true(vim.api.nvim_win_is_valid(win)) -- but the navigated window and
        assert.are.equal(other, vim.api.nvim_win_get_buf(win)) -- its buffer survive
    end)

    it("survives a layout toggle that closes one of its own windows", function()
        two_windows()
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "split",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.are.equal(2, #v.columns)
        v:toggle_layout() -- split -> stacked: closes the second column's window
        vim.wait(100) -- give any (wrongly) scheduled teardown a chance to fire
        assert.are.equal(1, #v.columns) -- still alive, just one column now
        assert.is_true(vim.api.nvim_buf_is_valid(v.columns[1].bufnr))
        v:close()
    end)
end)

describe("command router", function()
    local command = require("differ.command")

    it("dispatches layout + context against the current view", function()
        vim.cmd("silent! only")
        local v = View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        vim.api.nvim_set_current_win(v.columns[1].winid)
        assert.are.equal(v, View.current())

        command.dispatch({ "layout", "split" })
        assert.are.equal(2, #v.columns)

        command.dispatch({ "context", "1" })
        assert.are.equal(1, v.context)
        v:close()
    end)

    it("completes subcommands and values", function()
        local subs = command.complete("", "Differ ")
        table.sort(subs)
        assert.are.same({
            "base",
            "cache",
            "close",
            "context",
            "edit",
            "gofile",
            "layout",
            "log",
            "mergetool",
            "panel",
            "pr",
            "sidecar",
        }, subs)
        assert.are.same(
            { "split", "stacked" },
            (function()
                local v = command.complete("s", "Differ layout s")
                table.sort(v)
                return v
            end)()
        )
    end)
end)
