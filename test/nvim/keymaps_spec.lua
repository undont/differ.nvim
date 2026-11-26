-- runs under headless nvim: the session verbs (close / toggle_panel / toggle_layout)
-- bind only on the surfaces that can perform them, and honour a `false` override. also
-- keymap.hold/release on a shared buffer unwind to the buffer's own map in any order
local diff = require("differ.model.diff")
local View = require("differ.view")
local Panel = require("differ.panel")
local History = require("differ.history")

local function lhs_set(bufnr)
    local got = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        got[m.lhs] = m.desc or ""
    end
    return got
end

local function view(opts)
    local v = View.new(
        diff.build({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "a\nB\n",
        }),
        vim.tbl_extend("force", { layout = "stacked", context = 3 }, opts or {})
    )
    v:open()
    return v
end

local function panel(opts)
    local p = Panel.new(vim.tbl_extend("force", {
        sections = {
            { entries = { { path = "a.lua", status = "M", additions = 1, deletions = 0 } } },
        },
        on_select = function() end,
    }, opts or {}))
    p:open()
    return p
end

describe("session verb keymaps", function()
    after_each(function()
        vim.cmd("silent! only")
    end)

    it("binds close, panel toggle and layout toggle on the diff", function()
        local km = lhs_set(view().columns[1].bufnr)
        assert.are.equal("differ: close the session", km["dc"])
        assert.are.equal("differ: toggle the file panel", km["dd"])
        assert.are.equal("differ: toggle the layout", km["dl"])
        -- q is never differ's on a session surface; the pr overview's own q (back into
        -- the review) is the only one in the plugin
        assert.is_nil(km["q"])
    end)

    it("binds close and panel toggle on the panel, but not layout", function()
        local km = lhs_set(panel().bufnr)
        assert.are.equal("differ panel: close the session", km["dc"])
        assert.are.equal("differ panel: toggle the file panel", km["dd"])
        assert.is_nil(km["dl"]) -- layout belongs to the diff view
    end)

    it("binds only close on history: there's no panel to toggle", function()
        local h =
            History.new({ mode = "file", path = "a.lua", commits = {}, on_select = function() end })
        h:open()
        local km = lhs_set(h.bufnr)
        assert.are.equal("differ history: close the session", km["dc"])
        assert.is_nil(km["dd"])
        assert.is_nil(km["dl"])
    end)

    it("drops a verb the user disables with false", function()
        local km =
            lhs_set(view({ keymaps = { close = false, toggle_layout = "gL" } }).columns[1].bufnr)
        assert.is_nil(km["dc"])
        assert.is_nil(km["dl"])
        assert.are.equal("differ: toggle the layout", km["gL"])
    end)
end)

describe("keymap.hold over a buffer we don't own", function()
    local keymap = require("differ.util.keymap")

    local function desc_of(buf)
        return lhs_set(buf)["g?"] or "<unmapped>"
    end

    ---@return integer buf, table first, table second
    local function stacked()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.keymap.set("n", "g?", function() end, { buffer = buf, desc = "own" })
        local first = keymap.hold(buf, "g?", function() end, "first")
        local second = keymap.hold(buf, "g?", function() end, "second")
        return buf, first, second
    end

    it("puts the buffer's own map back when the top hold releases first", function()
        local buf, first, second = stacked()
        keymap.release(buf, second)
        assert.are.equal("first", desc_of(buf))
        keymap.release(buf, first)
        assert.are.equal("own", desc_of(buf))
    end)

    it("puts the buffer's own map back when the lower hold releases first", function()
        local buf, first, second = stacked()
        keymap.release(buf, first)
        assert.are.equal("second", desc_of(buf)) -- the live hold stays on top
        keymap.release(buf, second)
        assert.are.equal("own", desc_of(buf))
    end)

    it("leaves nothing mapped when the buffer had no map of its own", function()
        local buf = vim.api.nvim_create_buf(true, false)
        local first = keymap.hold(buf, "g?", function() end, "first")
        local second = keymap.hold(buf, "g?", function() end, "second")
        keymap.release(buf, first)
        keymap.release(buf, second)
        assert.are.equal("<unmapped>", desc_of(buf))
    end)
end)
