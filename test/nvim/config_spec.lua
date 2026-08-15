-- runs under headless nvim: config.resolve needs vim.tbl_deep_extend, so the
-- default/merge assertions live here rather than in the pure-Lua unit suite
local config = require("differ.config")

describe("config.resolve history", function()
    it("defaults the history sidebar to the bottom strip (the wide commit row fits)", function()
        local cfg = config.resolve(nil)
        assert.are.equal("bottom", cfg.history.position)
        assert.are.equal(10, cfg.history.height)
        assert.are.equal(40, cfg.history.width)
    end)

    it("merges a user override without disturbing the rest", function()
        local cfg = config.resolve({ history = { position = "left" } })
        assert.are.equal("left", cfg.history.position)
        assert.are.equal(10, cfg.history.height) -- untouched defaults
        assert.are.equal(40, cfg.history.width)
        assert.are.equal("right", cfg.panel.position) -- the panel table is independent
    end)
end)

describe("config.resolve merge", function()
    it("defaults the merge tool to the two-input layout", function()
        assert.are.equal("default", config.resolve(nil).merge.layout)
    end)

    it("takes a diff4 override without disturbing the rest", function()
        local cfg = config.resolve({ merge = { layout = "diff4" } })
        assert.are.equal("diff4", cfg.merge.layout)
        assert.are.equal("bottom", cfg.history.position) -- the other tables are independent
        assert.are.equal("right", cfg.panel.position)
    end)
end)

describe("setup config warnings", function()
    local saved

    -- setup() also runs the highlight registration, which warns about
    -- termguicolors under headless nvim; only the config notice is ours
    local function config_notifs()
        local out = {}
        for _, n in ipairs(_G.notifs) do
            if (n.msg or ""):find("config warnings", 1, true) then
                out[#out + 1] = n
            end
        end
        return out
    end

    before_each(function()
        saved = require("differ").config
        _G.notifs = {}
    end)

    after_each(function()
        require("differ").config = saved
    end)

    it("warns once, listing every diagnostic, and still applies the valid keys", function()
        require("differ").setup({ pannel = {}, panel = { position = "middle" } })
        local warnings = config_notifs()
        assert.are.equal(1, #warnings)
        assert.are.equal(vim.log.levels.WARN, warnings[1].level)
        assert.is_truthy(warnings[1].msg:find('unknown option "pannel"', 1, true))
        assert.is_truthy(warnings[1].msg:find("panel.position must be one of", 1, true))
        -- warn, don't refuse: differ still starts on the default for the value it
        -- could not honour
        assert.are.equal("right", require("differ").get_config().panel.position)
    end)

    it("stays quiet on a valid config", function()
        require("differ").setup({ panel = { position = "left" } })
        assert.are.equal(0, #config_notifs())
    end)
end)

describe("config.resolve clamping", function()
    -- an out-of-set value used to merge verbatim, leaving no branch matching it:
    -- panel.position = "middle" opened the bottom split while rendering as a sidebar
    it("puts an out-of-set value back to its default", function()
        local cfg = config.resolve({ panel = { position = "middle" } })
        assert.are.equal("right", cfg.panel.position)
    end)

    it("clamps every closed set, at both levels", function()
        local cfg = config.resolve({
            layout = "sideways",
            panel = { position = "middle", listing = "grid" },
            history = { position = "middle" },
            merge = { layout = "diff9" },
            deep_diff = { granularity = "sentence" },
        })
        assert.are.equal("stacked", cfg.layout)
        assert.are.equal("right", cfg.panel.position)
        assert.are.equal("tree", cfg.panel.listing)
        assert.are.equal("bottom", cfg.history.position)
        assert.are.equal("default", cfg.merge.layout)
        assert.are.equal("word", cfg.deep_diff.granularity)
    end)

    it("leaves valid values and unrelated keys alone", function()
        local cfg = config.resolve({
            panel = { position = "left", width = 80 },
            deep_diff = { granularity = "char" },
        })
        assert.are.equal("left", cfg.panel.position)
        assert.are.equal(80, cfg.panel.width) -- not a closed set, untouched
        assert.are.equal("char", cfg.deep_diff.granularity)
    end)
end)
