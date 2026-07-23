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
