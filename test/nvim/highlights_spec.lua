-- runs under headless nvim: the groups are set through nvim_set_hl, and the
-- termguicolors warning reads a real option. the module's warn-once state is
-- file-local, so each case reloads it

local function reload()
    package.loaded["differ.ui.highlights"] = nil
    return require("differ.ui.highlights")
end

-- run `fn` with vim.notify captured, returning the WARN messages it emitted
---@param fn fun(hl: table)
---@return string[]
local function warnings_from(fn)
    local real, seen = vim.notify, {}
    vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
            seen[#seen + 1] = msg
        end
    end
    local ok, err = pcall(fn, reload())
    vim.notify = real
    assert(ok, err)
    return seen
end

describe("highlights termguicolors guard", function()
    local saved

    before_each(function()
        saved = vim.o.termguicolors
    end)

    after_each(function()
        vim.o.termguicolors = saved
    end)

    it("warns when termguicolors is off, since the palette groups are gui-only", function()
        local seen = warnings_from(function(hl)
            vim.o.termguicolors = false
            hl.setup()
        end)
        assert.are.equal(1, #seen)
        assert.is_truthy(seen[1]:find("termguicolors", 1, true))
    end)

    it("stays quiet when termguicolors is on", function()
        local seen = warnings_from(function(hl)
            vim.o.termguicolors = true
            hl.setup()
        end)
        assert.are.equal(0, #seen)
    end)

    it("warns once, not on every session", function()
        local seen = warnings_from(function(hl)
            vim.o.termguicolors = false
            hl.setup()
            hl.setup()
            hl.setup()
        end)
        assert.are.equal(1, #seen)
    end)

    it("still defines the groups rather than bailing", function()
        warnings_from(function(hl)
            vim.o.termguicolors = false
            hl.setup()
        end)
        assert.is_truthy(vim.api.nvim_get_hl(0, { name = "differLineAdd" }).bg)
        assert.is_truthy(vim.api.nvim_get_hl(0, { name = "differMergeOurs" }).bg)
    end)
end)
