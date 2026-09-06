-- runs under headless nvim: drives the Panel component through a real window
-- (rendering, selection callback, fold, and the runtime listing/position API).
-- fed plain FileEntry lists (no git), since the panel is source-agnostic
local Panel = require("differ.panel")

local function fe(path, status, add, del)
    return { path = path, status = status or "M", additions = add or 0, deletions = del or 0 }
end

local function lines(p)
    return vim.api.nvim_buf_get_lines(p.bufnr, 0, -1, false)
end

local function panel(entries, opts)
    vim.cmd("silent! only")
    local picked = {}
    local p = Panel.new(vim.tbl_extend("force", {
        sections = { { entries = entries } },
        on_select = function(e)
            picked[#picked + 1] = e
        end,
    }, opts or {}))
    return p, picked
end

describe("panel rendering", function()
    it("renders a folded tree, dirs before files, cursor on first file", function()
        local p = panel({ fe("a.lua"), fe("src/b.lua") })
        p:open()
        assert.are.same({ "▾ src/", " M b.lua", "M a.lua" }, lines(p)) -- one-space indent
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.winid)[1]) -- first file row
        p:close()
    end)

    it("strips a 2+ level common prefix to a header subtitle in tree mode", function()
        local p = panel({ fe("a/b/c/x.lua"), fe("a/b/d/y.lua") }, { root = "/repo" })
        p:open()
        -- "a/b/" is shared and 2 levels deep: stripped, shown as a bare subtitle
        -- line (the helper's section has no title); c/ and d/ become the top dirs
        local body = vim.list_slice(lines(p), 4) -- past the 3-line header
        assert.are.same({ "a/b/", "▾ c/", " M x.lua", "▾ d/", " M y.lua" }, body)
        p:close()
    end)

    it("toggle_listing toggles tree <-> name", function()
        local p = panel({ fe("a.lua"), fe("src/b.lua") })
        p:open()
        p:toggle_listing() -- name: basename-first with a dimmed parent trailer
        assert.are.same({ "M b.lua  ·src/", "M a.lua" }, lines(p))
        p:toggle_listing() -- back to tree
        assert.are.same({ "▾ src/", " M b.lua", "M a.lua" }, lines(p))
        p:close()
    end)
end)

describe("panel navigation", function()
    it("opens the file under the cursor via on_select", function()
        local p, picked = panel({ fe("a.lua"), fe("b.lua") })
        p:open()
        vim.api.nvim_win_set_cursor(p.winid, { 1, 0 }) -- a.lua
        p:select()
        assert.are.equal("a.lua", picked[1].path)
        p:close()
    end)

    it("]f steps to the next file and opens it", function()
        local p, picked = panel({ fe("a.lua"), fe("b.lua") })
        p:open()
        vim.api.nvim_win_set_cursor(p.winid, { 1, 0 })
        p:goto_file("next")
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.winid)[1])
        assert.are.equal("b.lua", picked[#picked].path)
        p:close()
    end)

    -- the file under the panel cursor (the entry on the cursor's meta row)
    local function cursor_path(p)
        local row = vim.api.nvim_win_get_cursor(p.winid)[1]
        return p.meta[row].entry.path
    end

    it("gg / G move the cursor to the first / last file without opening it", function()
        local p, picked =
            panel({ fe("a.lua", "M", 1, 0), fe("b.lua", "M", 1, 0), fe("c.lua", "M", 1, 0) })
        p:open()
        local opened = #picked -- the file opened on open(); the cursor moves shouldn't add to it
        p:cursor_to_edge("last")
        assert.are.equal(3, vim.api.nvim_win_get_cursor(p.winid)[1])
        p:cursor_to_edge("first")
        assert.are.equal(1, vim.api.nvim_win_get_cursor(p.winid)[1])
        assert.are.equal(opened, #picked) -- nothing opened by the cursor move
        p:close()
    end)

    -- a.lua and d.lua are pure renames (no hunks). the edge jumps move the cursor and
    -- open nothing, so there is no blank view for them to avoid;
    it("gg / G land on a content-less pure rename at the edges", function()
        local p = panel({
            fe("a.lua", "R", 0, 0),
            fe("b.lua", "M", 1, 0),
            fe("c.lua", "M", 0, 2),
            fe("d.lua", "R", 0, 0),
        })
        p:open()
        p:cursor_to_edge("first")
        assert.are.equal("a.lua", cursor_path(p))
        p:cursor_to_edge("last")
        assert.are.equal("d.lua", cursor_path(p))
        p:close()
    end)

    -- the initial open lands on one too. it shows no lines, but it is a file that still
    -- stages, unstages and discards
    it("the initial open lands on a pure rename rather than starting past it", function()
        local p = panel({
            fe("a.lua", "R", 0, 0),
            fe("b.lua", "M", 1, 0),
        })
        p:open()
        p:focus_first_changed()
        assert.are.equal("a.lua", cursor_path(p))
        p:close()
    end)

    it("gg / G visit untracked files, which also report zero counts", function()
        -- '?' files report 0/0 like a pure rename, so they used to need excluding by
        -- hand from the skip the edge jumps ran; nothing is excluded now
        local p = panel({ fe("a.lua", "R", 0, 0), fe("z.lua", "?", 0, 0) })
        p:open()
        p:cursor_to_edge("last")
        assert.are.equal("z.lua", cursor_path(p))
        p:close()
    end)

    it("gg / G land on the edges when every file is content-less", function()
        local p = panel({ fe("a.lua", "R", 0, 0), fe("b.lua", "R", 0, 0) })
        p:open()
        p:cursor_to_edge("first")
        assert.are.equal("a.lua", cursor_path(p))
        p:cursor_to_edge("last")
        assert.are.equal("b.lua", cursor_path(p))
        p:close()
    end)

    it("]] / [[ jump between sections, opening each section's first file", function()
        local p, picked = panel({}, {
            sections = {
                { title = "Staged", entries = { fe("a.lua", "M", 1, 0) } },
                { title = "Unstaged", entries = { fe("b.lua", "M", 1, 0) } },
                { title = "Untracked", entries = { fe("z.lua", "?", 0, 0) } },
            },
        })
        p:open()
        p:goto_section("next") -- from Staged -> Unstaged
        assert.are.equal("b.lua", picked[#picked].path)
        p:goto_section("next") -- Unstaged -> Untracked
        assert.are.equal("z.lua", picked[#picked].path)
        p:goto_section("next") -- no further section: stays put
        assert.are.equal("z.lua", picked[#picked].path)
        p:goto_section("prev") -- Untracked -> Unstaged
        assert.are.equal("b.lua", picked[#picked].path)
        p:close()
    end)

    it("focus_first_unstaged lands on the first unstaged file, skipping Staged", function()
        local function se(path, staged)
            return { path = path, status = "M", additions = 1, deletions = 0, staged = staged }
        end
        local p, picked = panel({}, {
            sections = {
                { title = "Staged", entries = { se("a.lua", true) } },
                { title = "Unstaged", entries = { se("b.lua", false) } },
            },
        })
        p:open()
        p:focus_first_unstaged()
        p:select(true)
        assert.are.equal("b.lua", picked[#picked].path)
        p:close()
    end)

    it("focus_first_unstaged falls back to the first file when all are staged", function()
        local function se(path)
            return { path = path, status = "M", additions = 1, deletions = 0, staged = true }
        end
        local p, picked = panel({}, {
            sections = { { title = "Staged", entries = { se("a.lua"), se("b.lua") } } },
        })
        p:open()
        p:focus_first_unstaged()
        p:select(true)
        assert.are.equal("a.lua", picked[#picked].path)
        p:close()
    end)

    it("]] / [[ are inert in a single-section panel", function()
        local p, picked = panel({ fe("a.lua", "M", 1, 0), fe("b.lua", "M", 1, 0) })
        p:open()
        p:goto_section("next")
        assert.are.equal(0, #picked)
        p:close()
    end)

    it("toggles a directory fold from its row, hiding children", function()
        local p = panel({ fe("src/a.lua"), fe("src/b.lua") })
        p:open()
        vim.api.nvim_win_set_cursor(p.winid, { 1, 0 }) -- src/
        p:select() -- dir row => toggle fold
        assert.are.same({ "▸ src/" }, lines(p))
        p:close()
    end)

    it("folds a dir per section, not by bare path, and keeps the cursor on it", function()
        vim.cmd("silent! only")
        local p = Panel.new({
            sections = {
                { title = "Unstaged", entries = { fe("src/a.lua") } },
                { title = "Untracked", entries = { fe("src/z.lua", "?") } },
            },
            on_select = function() end,
        })
        p:open()
        -- both sections carry a src/ dir; toggling one must not collapse the other
        vim.api.nvim_win_set_cursor(p.winid, { 5, 0 }) -- the Untracked src/ row
        p:select()
        assert.are.same({
            "Unstaged (1)",
            "▾ src/",
            " M a.lua",
            "Untracked (1)",
            "▸ src/", -- only this one folded
        }, lines(p))
        assert.are.equal(5, vim.api.nvim_win_get_cursor(p.winid)[1]) -- cursor stayed on it
        p:close()
    end)

    it("C collapses every dir, O expands them all", function()
        local p = panel({ fe("src/a.lua"), fe("src/sub/b.lua") })
        p:open()
        p:set_all_folds(true) -- C
        assert.are.same({ "▸ src/" }, lines(p))
        p:set_all_folds(false) -- O
        assert.are.same({ "▾ src/", " ▾ sub/", "  M b.lua", " M a.lua" }, lines(p))
        p:close()
    end)

    it("c on a file closes its parent dir and moves there", function()
        local p = panel({ fe("src/a.lua"), fe("src/sub/b.lua") })
        p:open()
        -- rows: src/(1) sub/(2) b.lua(3) a.lua(4); put the cursor on b.lua
        vim.api.nvim_win_set_cursor(p.winid, { 3, 0 })
        p:close_node()
        assert.are.same({ "▾ src/", " ▸ sub/", " M a.lua" }, lines(p))
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.winid)[1]) -- moved to sub/
        p:close()
    end)

    it("the file total stays accurate when everything is collapsed", function()
        local winbar = require("differ.ui.winbar")
        local p = panel({ fe("src/a.lua"), fe("src/sub/b.lua") })
        p:open()
        p:set_all_folds(true) -- no file rows visible now
        assert.are.equal(2, p.file_total) -- both files still counted
        vim.g.statusline_winid = p.winid
        vim.api.nvim_win_set_cursor(p.winid, { 1, 0 }) -- on a collapsed dir row
        assert.is_truthy(winbar.panel():find("/2", 1, true)) -- denominator = real total
        vim.g.statusline_winid = nil
        p:close()
    end)

    it("paints the diff --stat totals as virt_text on the help line", function()
        local p = panel({ fe("a.lua", "M", 31, 1), fe("b.lua", "M", 39, 2) }, { root = "/repo" })
        p:open()
        assert.are.equal(70, p.add_total)
        assert.are.equal(3, p.del_total)
        -- the help line (row 2) carries the totals as a right-aligned virt_text extmark
        local ns = vim.api.nvim_get_namespaces()["differ.panel"]
        local marks = vim.api.nvim_buf_get_extmarks(p.bufnr, ns, { 1, 0 }, { 1, -1 }, {
            details = true,
        })
        local texts = {}
        for _, m in ipairs(marks) do
            for _, chunk in ipairs((m[4] or {}).virt_text or {}) do
                texts[#texts + 1] = chunk[1]
            end
        end
        assert.is_truthy(vim.tbl_contains(texts, "+70"))
        assert.is_truthy(vim.tbl_contains(texts, "-3"))
        p:close()
    end)
end)

-- the panel window's position relative to the origin window it was split from
local function geom(p)
    local prow, pcol = unpack(vim.api.nvim_win_get_position(p.winid))
    local orow, ocol = unpack(vim.api.nvim_win_get_position(p.origin_win))
    return { prow = prow, pcol = pcol, orow = orow, ocol = ocol }
end

-- per position: which fixed-size flag the split carries, and which edge the panel
-- sits on (left/right compare columns, top/bottom compare rows against the origin)
local PLACEMENT = {
    left = {
        axis = "winfixwidth",
        cmp = function(g)
            return g.pcol < g.ocol
        end,
    },
    right = {
        axis = "winfixwidth",
        cmp = function(g)
            return g.pcol > g.ocol
        end,
    },
    top = {
        axis = "winfixheight",
        cmp = function(g)
            return g.prow < g.orow
        end,
    },
    bottom = {
        axis = "winfixheight",
        cmp = function(g)
            return g.prow > g.orow
        end,
    },
}

describe("panel runtime position", function()
    for _, pos in ipairs({ "left", "right", "top", "bottom" }) do
        it("opens on the " .. pos .. " edge with the right fixed-size flag", function()
            local p = panel({ fe("a.lua") }, { position = pos })
            p:open()
            local spec = PLACEMENT[pos]
            assert.is_true(vim.wo[p.winid][spec.axis])
            assert.is_true(spec.cmp(geom(p)), "wrong edge for " .. pos)
            p:close()
        end)
    end

    it("re-positions live through every edge, keeping one panel + buffer", function()
        local p = panel({ fe("a.lua") })
        p:open()
        local buf, win = p.bufnr, p.winid
        for _, pos in ipairs({ "left", "top", "right", "bottom" }) do
            p:set_position(pos)
            local spec = PLACEMENT[pos]
            assert.is_true(p:is_open(), pos)
            assert.are.equal(buf, p.bufnr) -- same buffer, just re-windowed
            assert.is_false(win == p.winid) -- new window each move
            assert.is_true(vim.wo[p.winid][spec.axis])
            assert.is_true(spec.cmp(geom(p)), "wrong edge for " .. pos)
            win = p.winid
        end
        p:close()
    end)

    it("floors the content column at the configured width for top/bottom panels", function()
        -- a top/bottom panel spans the full editor width, so the +/- counts are
        -- pinned to content_width, not the far right edge. a short list keeps the
        -- configured width as a stable floor
        local p = panel({ fe("a.lua") }, { position = "bottom", width = 30 })
        p:open()
        local full = vim.api.nvim_win_get_width(p.winid)
        assert.is_true(full > 30, "expected a full-width bottom split")
        assert.are.equal(30, p.content_width)
        p:set_position("right") -- vertical split: content fills the whole window
        assert.are.equal(vim.api.nvim_win_get_width(p.winid), p.content_width)
        p:close()
    end)

    it("grows the content column to fit long names in top/bottom panels (no truncation)", function()
        -- a name longer than the configured width must render in full, with the
        -- content column growing to anchor the pinned counts just past it
        local long = "a_very_long_filename_that_exceeds_thirty_columns.lua"
        local p = panel({ fe(long, "M", 1, 2) }, { position = "bottom", width = 30 })
        p:open()
        assert.is_true(p.content_width > 30, "content column should grow past the floor")
        assert.is_true(p.content_width <= vim.api.nvim_win_get_width(p.winid))
        assert.is_truthy(lines(p)[1]:find(long, 1, true), "long name must not be truncated")
        assert.is_falsy(lines(p)[1]:find("…", 1, true))
        p:close()
    end)

    it("truncates at the editor edge when content overflows the window", function()
        -- when even the natural width exceeds the live window, fall back to
        -- truncating at the editor edge rather than spilling off-screen
        local huge = string.rep("x", 500) .. ".lua"
        local p = panel({ fe(huge, "M", 1, 2) }, { position = "bottom", width = 30 })
        p:open()
        assert.are.equal(vim.api.nvim_win_get_width(p.winid), p.content_width)
        assert.is_truthy(lines(p)[1]:find("…", 1, true), "overflow should truncate")
        p:close()
    end)

    it("current() tracks the open panel and clears on close", function()
        local p = panel({ fe("a.lua") })
        p:open()
        assert.are.equal(p, Panel.current())
        p:close()
        assert.is_nil(Panel.current())
    end)
end)

describe("panel refresh", function()
    -- a panel whose reload returns `sections`, recording on_empty fires
    local function reloadable(entries, sections)
        local fired = {}
        local p = panel(entries, {
            actions = {
                stage = function() end,
                unstage = function() end,
                stage_all = function() end,
                unstage_all = function() end,
                discard = function() end,
                reload = function()
                    return sections
                end,
            },
            on_empty = function()
                fired[#fired + 1] = true
            end,
        })
        return p, fired
    end

    it("fires on_empty when a reload leaves no files", function()
        local p, fired = reloadable({ fe("a.lua") }, {})
        p:open()
        p:refresh()
        assert.are.equal(1, #fired)
        assert.are.equal(0, p.file_total)
        p:close()
    end)

    it("doesn't fire on_empty while files remain", function()
        local p, fired = reloadable({ fe("a.lua") }, { { entries = { fe("b.lua") } } })
        p:open()
        p:refresh()
        assert.are.equal(0, #fired)
        assert.are.same({ "M b.lua" }, lines(p))
        p:close()
    end)

    -- a hidden sidebar is still a live session driving a visible diff, so an emptying
    -- reload has to reach it too; only a closed panel stops refreshing
    it("refreshes (and can empty) with the sidebar hidden, but not once closed", function()
        local p, fired = reloadable({ fe("a.lua") }, {})
        p:open()
        p:hide()
        assert.is_false(p:is_open())
        assert.is_true(p:is_alive())
        p:refresh()
        assert.are.equal(1, #fired)

        p:close()
        assert.is_false(p:is_alive())
        p:refresh() -- a queued refresh landing after the close is a no-op
        assert.are.equal(1, #fired)
    end)
end)

-- rows shuffle on every rebuild, so a row number names a different file afterwards.
-- the panel anchors the cursor and the selection by the entry's own identity instead:
-- side + path, since a file changed on both sides holds a row in each section
describe("panel selection identity", function()
    -- the file under the cursor, by path, or nil off a file row
    local function at(p)
        local m = p.meta[vim.api.nvim_win_get_cursor(p.winid)[1]]
        return m and m.kind == "file" and m.entry.path or nil
    end

    -- the file the selection (]f / [f, the winbar count) is anchored to
    local function selected(p)
        local m = p.meta[p.selected_row]
        return m and m.kind == "file" and m.entry or nil
    end

    local function se(path, staged)
        return { path = path, status = "M", additions = 1, deletions = 0, staged = staged }
    end

    -- staging hooks the panel only needs to exist; `reload` is the half that matters
    local function acts(reload)
        return {
            stage = function() end,
            unstage = function() end,
            stage_all = function() end,
            unstage_all = function() end,
            discard = function() end,
            reload = reload,
        }
    end

    -- name mode reorders the list (b.lua rises above a.lua as the tree dir collapses
    -- away), so restoring the cursor by line number lands it on the other file
    it("holds the cursor on its file across a listing toggle", function()
        local p = panel({ fe("a.lua"), fe("src/b.lua") })
        p:open()
        vim.api.nvim_win_set_cursor(p.winid, { 2, 0 }) -- " M b.lua", under the src/ row
        assert.are.equal("src/b.lua", at(p))
        p:toggle_listing() -- name: b.lua to row 1, a.lua to row 2
        assert.are.equal("src/b.lua", at(p)) -- line 2 would have said a.lua
        p:toggle_listing()
        assert.are.equal("src/b.lua", at(p))
        p:close()
    end)

    -- a reload that drops an entry above the cursor slides every later row up one
    it("holds the cursor on its file when a row above it leaves the list", function()
        local kept = { { entries = { fe("b.lua"), fe("c.lua"), fe("d.lua") } } }
        local p = panel({ fe("a.lua"), fe("b.lua"), fe("c.lua"), fe("d.lua") }, {
            actions = acts(function()
                return kept
            end),
        })
        p:open()
        vim.api.nvim_win_set_cursor(p.winid, { 3, 0 })
        assert.are.equal("c.lua", at(p))
        p:refresh() -- a.lua gone: c.lua is row 2 now, and row 3 is d.lua
        assert.are.equal("c.lua", at(p))
        p:close()
    end)

    -- staging a file's last unstaged hunk moves its row between sections. the path is
    -- the same but the side isn't, so the selection follows it across rather than
    -- reporting the row that slid into its place
    it("follows the selected file when it moves to the other section", function()
        local after = {
            { title = "Staged", entries = { se("z.lua", true) } },
            { title = "Unstaged", entries = { se("a.lua", false) } },
        }
        local p = panel({}, {
            sections = {
                { title = "Unstaged", entries = { se("a.lua", false), se("z.lua", false) } },
            },
            actions = acts(function()
                return after
            end),
        })
        p:open()
        assert.are.same({ "Unstaged (2)", "M a.lua", "M z.lua" }, lines(p))
        p:goto_path("z.lua")
        assert.are.equal(3, p.selected_row)

        -- Staged renders first, so z.lua rises to row 2 and the old row 3 becomes the
        -- Unstaged title: a selection kept by number would name no file at all
        p:refresh()
        assert.are.same({ "Staged (1)", "M z.lua", "Unstaged (1)", "M a.lua" }, lines(p))
        local sel = selected(p)
        assert.are.equal("z.lua", sel.path)
        assert.is_true(sel.staged) -- and on the staged side it moved to
        p:close()
    end)

    -- the session re-sources the view itself when a file's last unstaged hunk is
    -- staged, so the panel only has to agree on what's selected
    it("mark_selected moves the selection without re-opening the file", function()
        local p, picked = panel({ fe("a.lua"), fe("b.lua") })
        p:open()
        p:goto_path("a.lua")
        assert.are.equal(1, #picked)

        p:mark_selected(p.meta[2].entry) -- b.lua
        assert.are.equal("b.lua", selected(p).path)
        assert.are.equal("b.lua", at(p)) -- the sidebar cursor agrees
        assert.are.equal(1, #picked) -- but on_select never fired again
        p:close()
    end)

    -- a row number kept after its file left names whatever slid into it, or sits past
    -- the end of a shorter list, which the review walk then reads as a wrap
    it("clears the selection when its file leaves the change set", function()
        local kept = { { entries = { fe("b.lua") } } }
        local p = panel({ fe("a.lua"), fe("b.lua") }, {
            actions = acts(function()
                return kept
            end),
        })
        p:open()
        p:goto_path("a.lua")
        assert.is_not_nil(p.selected_row)
        p:refresh()
        assert.is_nil(p.selected_row)
        p:close()
    end)

    -- a stale entry reports itself through on_select and refreshes the list; the walk
    -- has somewhere else to go, so it carries on rather than claiming to have moved
    -- (which strands the review) or that there's nothing left (which is a lie)
    it("step_review carries on past an entry whose open fails", function()
        vim.cmd("silent! only")
        local opened = {}
        local p = Panel.new({
            sections = {
                {
                    title = "Unstaged",
                    entries = { se("a.lua", false), se("m.lua", false), se("z.lua", false) },
                },
            },
            on_select = function(e)
                if e.path == "m.lua" then
                    return false -- nothing left to diff here
                end
                opened[#opened + 1] = e.path
                return true
            end,
        })
        p:open()
        p:goto_path("a.lua")
        assert.are.same({ "a.lua" }, opened)

        assert.is_true(p:step_review("next", false, true))
        assert.are.same({ "a.lua", "z.lua" }, opened) -- m.lua stepped over, not landed on
        p:close()
    end)

    it("step_review reports the walk over when every candidate is stale", function()
        vim.cmd("silent! only")
        local p = Panel.new({
            sections = {
                {
                    title = "Unstaged",
                    entries = { se("a.lua", false), se("m.lua", false), se("z.lua", false) },
                },
            },
            on_select = function(e)
                return e.path == "a.lua"
            end,
        })
        p:open()
        p:goto_path("a.lua")
        assert.is_false(p:step_review("next", false, true))
        p:close()
    end)

    -- nothing to anchor to: the entry left the change set entirely
    it("mark_selected is inert for an entry that isn't in the list", function()
        local p = panel({ fe("a.lua"), fe("b.lua") })
        p:open()
        p:goto_path("a.lua")
        local before = p.selected_row
        p:mark_selected(fe("gone.lua"))
        assert.are.equal(before, p.selected_row)
        p:close()
    end)
end)
