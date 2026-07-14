local tree = require("differ.panel.tree")
local render = require("differ.panel.render")

local function entry(path, status, add, del)
    return { path = path, status = status or "M", additions = add or 0, deletions = del or 0 }
end

describe("panel.render.lines", function()
    it("prefixes a header (root path + Help + blank) when given one", function()
        local root = tree.build({ entry("a.lua") })
        local out = render.lines(
            { { title = "Changes", rows = tree.rows(root, "tree", {}) } },
            { path = "~/repo", help = "g?" }
        )
        assert.are.same({ "~/repo", "Help: g?", "", "Changes (1)", "M a.lua" }, out.lines)
        assert.are.equal("root", out.meta[1].kind)
        assert.are.equal("help", out.meta[2].kind)
        assert.are.equal("blank", out.meta[3].kind)
        assert.are.equal("header", out.meta[4].kind)
    end)

    it("appends a 'Showing changes for:' footer when given a rev", function()
        local root = tree.build({ entry("a.lua") })
        local out = render.lines({ { rows = tree.rows(root, "tree", {}) } }, nil, nil, "main...")
        assert.are.same({ "M a.lua", "", "Showing changes for:", "main..." }, out.lines)
        assert.are.equal("blank", out.meta[2].kind)
        assert.are.equal("foothead", out.meta[3].kind)
        assert.are.equal("footrev", out.meta[4].kind)
    end)

    it("renders a section header with the file count", function()
        local root = tree.build({ entry("a.lua"), entry("b.lua") })
        local out = render.lines({ { title = "Unstaged", rows = tree.rows(root, "tree", {}) } })
        assert.are.equal("Unstaged (2)", out.lines[1])
        assert.are.equal("header", out.meta[1].kind)
    end)

    it("uses the supplied count for the header, not the visible file rows", function()
        -- collapse src so no file rows are visible; the header count must still be 2
        local root = tree.build({ entry("src/a.lua"), entry("src/b.lua") })
        local rows = tree.rows(root, "tree", { ["src"] = true })
        local out = render.lines({ { title = "Unstaged", count = 2, rows = rows } })
        assert.are.equal("Unstaged (2)", out.lines[1])
    end)

    it("carries the section +/- aggregate onto the header meta", function()
        -- block.add/block.del ride the header meta so the runtime layer can pin them
        -- to the right edge (like the per-file counts); they never enter the line text
        local root = tree.build({ entry("a.lua", "M", 3, 1), entry("b.lua", "M", 5, 0) })
        local out = render.lines({
            { title = "Staged", add = 8, del = 1, rows = tree.rows(root, "tree", {}) },
        })
        assert.are.equal("Staged (2)", out.lines[1])
        local m = out.meta[1]
        assert.are.equal("header", m.kind)
        assert.are.equal(8, m.add_total)
        assert.are.equal(1, m.del_total)
    end)

    it("leaves the header aggregate nil when the block omits add/del", function()
        local root = tree.build({ entry("a.lua") })
        local out = render.lines({ { title = "Unstaged", rows = tree.rows(root, "tree", {}) } })
        assert.is_nil(out.meta[1].add_total)
        assert.is_nil(out.meta[1].del_total)
    end)

    it("separates consecutive sections with a blank line, none before the first", function()
        local a = tree.build({ entry("a.lua") })
        local b = tree.build({ entry("b.lua") })
        local out = render.lines({
            { title = "Staged", rows = tree.rows(a, "tree", {}) },
            { title = "Unstaged", rows = tree.rows(b, "tree", {}) },
        })
        -- no leading blank (no top header precedes the first section)
        assert.are.same({ "Staged (1)", "M a.lua", "", "Unstaged (1)", "M b.lua" }, out.lines)
        assert.are.equal("blank", out.meta[3].kind)
    end)

    it("does not double-blank a section that follows the top header's blank", function()
        local root = tree.build({ entry("a.lua") })
        local out = render.lines(
            { { title = "Staged", rows = tree.rows(root, "tree", {}) } },
            { path = "~/repo", help = "g?" }
        )
        -- top header ends in a blank; the section must not add a second one
        assert.are.same({ "~/repo", "Help: g?", "", "Staged (1)", "M a.lua" }, out.lines)
    end)

    it("renders a file row with status letter and points cols at it", function()
        local root = tree.build({ entry("a.lua", "M") })
        local out = render.lines({ { title = nil, rows = tree.rows(root, "tree", {}) } })
        assert.are.equal("M a.lua", out.lines[1])
        local m = out.meta[1]
        assert.are.equal("file", m.kind)
        assert.are.equal("M", m.status)
        assert.are.equal(0, m.status_col) -- "M" at col 0
        assert.are.equal(2, m.name_col) -- name after "M "
    end)

    it("keeps counts out of the line text; carries them on the entry", function()
        -- the runtime layer pins +/- to the right edge as a virt_text extmark, so
        -- the line text is just the name; the counts ride the FileEntry in meta
        local root = tree.build({ entry("a.lua", "M", 3, 1) })
        local out = render.lines({ { rows = tree.rows(root, "tree", {}) } })
        assert.are.equal("M a.lua", out.lines[1])
        local m = out.meta[1]
        assert.are.equal(3, m.entry.additions)
        assert.are.equal(1, m.entry.deletions)
    end)

    it("paints a devicon between the status letter and the name", function()
        local root = tree.build({ entry("a.lua", "M", 3, 1) })
        local icon_for = function()
            return ">", "DevIconLua"
        end
        local out = render.lines({ { rows = tree.rows(root, "tree", {}) } }, nil, icon_for)
        assert.are.equal("M > a.lua", out.lines[1])
        local m = out.meta[1]
        assert.are.equal("DevIconLua", m.icon_hl)
        assert.are.equal(">", out.lines[1]:sub(m.icon_col + 1, m.icon_end))
        assert.are.equal("a.lua", out.lines[1]:sub(m.name_col + 1, m.name_col + 5))
    end)

    it("renders a collapsed dir with a closed fold arrow and trailing slash", function()
        local root = tree.build({ entry("src/a.lua"), entry("src/b.lua") })
        local out = render.lines({ { rows = tree.rows(root, "tree", { ["src"] = true }) } })
        assert.are.equal("▸ src/", out.lines[1])
        assert.are.equal("dir", out.meta[1].kind)
        assert.is_true(out.meta[1].collapsed)
    end)

    it("indents nested rows by depth", function()
        local root = tree.build({ entry("src/a.lua"), entry("src/b.lua") })
        local out = render.lines({ { rows = tree.rows(root, "tree", {}) } })
        assert.are.equal("▾ src/", out.lines[1])
        assert.are.equal(" M a.lua", out.lines[2]) -- depth 1 => one-space indent
    end)

    it("renders a dimmed common-prefix subtitle on the header", function()
        local root = tree.build({ entry("a/b/c/x.lua") }, "a/b/")
        local out = render.lines({
            { title = "Changes", prefix = "a/b/", rows = tree.rows(root, "tree", {}) },
        })
        assert.are.equal("Changes (1) · a/b/", out.lines[1])
        local m = out.meta[1]
        assert.are.equal("header", m.kind)
        assert.are.equal(" · a/b/", out.lines[1]:sub(m.prefix_col + 1, m.prefix_end))
    end)

    it("front-truncates a long name to fit the width, reserving count room", function()
        local root = tree.build({ entry("a-very-long-filename.lua", "M", 3, 1) })
        local out = render.lines({ { rows = tree.rows(root, "tree", {}) } }, nil, nil, nil, 16)
        assert.is_true(out.lines[1]:find("…", 1, true) ~= nil)
        assert.is_true(out.lines[1]:find("M a%-very", 1, false) ~= nil) -- keeps the front
        -- width 16: prefix "M " (2) + reserve "+3 -1 " (6) leaves 8 cols for the name.
        -- "…" is 3 bytes but one column, so measure display width via a 1-byte stand-in
        local disp = (out.lines[1]:gsub("…", "."))
        assert.is_true(#disp <= 16 - 6)
    end)

    it("skips truncation when no width is given (headless)", function()
        local root = tree.build({ entry("a-very-long-filename.lua", "M", 3, 1) })
        local out = render.lines({ { rows = tree.rows(root, "tree", {}) } })
        assert.are.equal("M a-very-long-filename.lua", out.lines[1])
    end)

    it("renders the dimmed parent trailer in name mode with its byte cols", function()
        local root = tree.build({ entry("src/sub/b.lua", "M", 0, 0) })
        local out = render.lines({ { rows = tree.rows(root, "name", {}) } })
        assert.are.equal("M b.lua  ·sub/", out.lines[1])
        local m = out.meta[1]
        assert.are.equal("·sub/", out.lines[1]:sub(m.context_col + 1, m.context_end))
    end)

    it("keeps the name-mode parent visible at a tight width by truncating the name", function()
        -- a long basename AND a long parent must not push the parent off the right
        -- edge (where it would clip and silently vanish); the name truncates first
        local root =
            tree.build({ entry("calendar/appointment-detail/TerminalSummary.test.tsx", "M", 0, 7) })
        local out = render.lines({ { rows = tree.rows(root, "name", {}) } }, nil, nil, nil, 31)
        local m = out.meta[1]
        assert.is_not_nil(m.context_col) -- the parent trailer is present
        assert.is_true(out.lines[1]:find("…", 1, true) ~= nil) -- name was truncated
        local disp = (out.lines[1]:gsub("…", "."):gsub("·", "."))
        assert.is_true(#disp <= 31 - 5) -- fits within width less the "+0 -7 " reserve
    end)

    it("renders a viewed checkbox column for PR entries, pointing cols past it", function()
        local viewed = { path = "a.lua", status = "M", additions = 0, deletions = 0, viewed = true }
        local unviewed =
            { path = "b.lua", status = "A", additions = 0, deletions = 0, viewed = false }
        local root = tree.build({ viewed, unviewed })
        local out = render.lines({ { rows = tree.rows(root, "tree", {}) } })
        assert.are.equal("[x] M a.lua", out.lines[1])
        assert.are.equal("[ ] A b.lua", out.lines[2])
        local m = out.meta[1]
        assert.are.equal(4, m.status_col) -- "M" after "[x] "
        assert.are.equal("M", out.lines[1]:sub(m.status_col + 1, m.status_col + 1))
        assert.are.equal(0, m.viewed_col)
        assert.are.equal("[x]", out.lines[1]:sub(m.viewed_col + 1, m.viewed_end))
    end)

    it("omits the checkbox column for local entries (viewed == nil)", function()
        local root = tree.build({ entry("a.lua", "M") })
        local out = render.lines({ { rows = tree.rows(root, "tree", {}) } })
        assert.are.equal("M a.lua", out.lines[1])
        assert.is_nil(out.meta[1].viewed_col)
        assert.are.equal(0, out.meta[1].status_col)
    end)
end)
