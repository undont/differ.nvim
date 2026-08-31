local config = require("differ.config")

describe("config.resolve_keymaps", function()
    it("applies the shared defaults to every surface", function()
        local km = config.resolve_keymaps(nil)
        for _, surface in ipairs({ "diff", "panel", "history" }) do
            assert.are.equal("]c", km[surface].next_hunk)
            assert.are.equal("f", km[surface].scroll_down)
            assert.are.same({ "<CR>", "o" }, km[surface].select)
        end
    end)

    it("lets a top-level override reach all surfaces", function()
        local km = config.resolve_keymaps({ next_hunk = "gh" })
        assert.are.equal("gh", km.diff.next_hunk)
        assert.are.equal("gh", km.panel.next_hunk)
        assert.are.equal("gh", km.history.next_hunk)
    end)

    it("scopes a per-surface override to that surface only", function()
        local km = config.resolve_keymaps({ panel = { stage = "ga" } })
        assert.are.equal("ga", km.panel.stage)
        assert.are.equal("s", km.diff.stage) -- diff keeps the default
        assert.are.equal("s", km.history.stage)
    end)

    it("disables an action with false", function()
        local km = config.resolve_keymaps({ scroll_down = false, panel = { discard = false } })
        assert.is_false(km.diff.scroll_down)
        assert.is_false(km.panel.scroll_down) -- top-level reaches the panel too
        assert.is_false(km.panel.discard)
        assert.is_false(km.history.scroll_down)
    end)

    it("replaces a multi-lhs list wholesale (no index merge)", function()
        local km = config.resolve_keymaps({ select = { "x" } })
        assert.are.same({ "x" }, km.panel.select) -- not { "x", "o" }
    end)

    it("a per-surface override wins over a top-level one", function()
        local km = config.resolve_keymaps({ next_hunk = "gh", diff = { next_hunk = "gn" } })
        assert.are.equal("gn", km.diff.next_hunk)
        assert.are.equal("gh", km.panel.next_hunk)
    end)
end)

describe("config.validate", function()
    it("passes a valid config, and the defaults themselves", function()
        assert.are.same({}, config.validate(nil))
        assert.are.same({}, config.validate({}))
        assert.are.same({}, config.validate(config.defaults))
        assert.are.same(
            {},
            config.validate({
                layout = "split",
                panel = { position = "left", width = 40, icons = false },
                history = { position = "top" },
                merge = { layout = "diff4" },
                deep_diff = { granularity = "char" },
                comments = { inline = false },
                keymaps = { next_hunk = "gh", panel = { stage = "ga" } },
            })
        )
    end)

    it("accepts the options that default to nil", function()
        assert.are.same(
            {},
            config.validate({ base = "main", sidecar_bin = "/tmp/x", command_alias = "D" })
        )
    end)

    it("flags an unknown top-level key", function()
        assert.are.same({ 'unknown option "pannel"' }, config.validate({ pannel = {} }))
    end)

    it("flags an unknown key one level down", function()
        assert.are.same(
            { 'unknown option "panel.positon"' },
            config.validate({ panel = { positon = "left" } })
        )
    end)

    it("flags a value outside a closed set", function()
        assert.are.same(
            { 'panel.position must be one of "bottom", "top", "left", "right" (got "middle")' },
            config.validate({ panel = { position = "middle" } })
        )
        assert.are.same(
            { 'layout must be one of "stacked", "split" (got "sideways")' },
            config.validate({ layout = "sideways" })
        )
        assert.are.same(
            { 'deep_diff.granularity must be one of "word", "char" (got true)' },
            config.validate({ deep_diff = { granularity = true } })
        )
    end)

    it("flags a misspelled keymap action, top-level and per-surface", function()
        assert.are.same(
            { 'unknown keymap action "keymaps.next_hunkk"' },
            config.validate({ keymaps = { next_hunkk = "gh" } })
        )
        assert.are.same(
            { 'unknown keymap action "keymaps.panel.stag"' },
            config.validate({ keymaps = { panel = { stag = "s" } } })
        )
    end)

    it("does not mistake a surface subtable for an action", function()
        assert.are.same({}, config.validate({ keymaps = { merge = { choose_ours = "x" } } }))
    end)

    it("flags a section given a non-table", function()
        assert.are.same(
            { "panel must be a table (got string)" },
            config.validate({ panel = "left" })
        )
        assert.are.same(
            { "keymaps must be a table (got string)" },
            config.validate({ keymaps = "none" })
        )
        assert.are.same(
            { "keymaps.panel must be a table of actions (got string)" },
            config.validate({ keymaps = { panel = "s" } })
        )
    end)

    it("returns every diagnostic, sorted", function()
        assert.are.same(
            {
                'layout must be one of "stacked", "split" (got "sideways")',
                'unknown keymap action "keymaps.next_hunkk"',
                'unknown option "pannel"',
            },
            config.validate({
                layout = "sideways",
                pannel = {},
                keymaps = { next_hunkk = "g" },
            })
        )
    end)

    it("rejects a non-table opts outright", function()
        assert.are.same(
            { "setup() expects a table of options (got string)" },
            config.validate("stacked")
        )
    end)
end)

describe("config.closed", function()
    -- a renamed or dropped option would leave a dangling path here; validate() on
    -- the defaults can't see one, since it only walks keys that are actually set
    it("names a real default for every closed set", function()
        for path, allowed in pairs(config.closed) do
            local holder, key = config.locate(config.defaults, path)
            local default = holder and holder[key]
            assert.is_not_nil(default, path .. " has no default")
            local found = false
            for _, ok in ipairs(allowed) do
                found = found or default == ok
            end
            assert.is_true(found, path .. " default " .. tostring(default) .. " is outside its set")
        end
    end)
end)
