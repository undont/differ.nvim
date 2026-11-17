-- busted helper for the headless-nvim suite (wired via .busted `nvim.helper`)
-- captures notifications into `_G.notifs` so they don't leak into the progress
-- output; specs can inspect the table if they ever need to assert on a message

-- every git this process starts, fixtures and differ's own, reads test/gitconfig in
-- place of the machine's global and system config. set before the first spawn
local here = vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, "S").source:sub(2)))
vim.env.GIT_CONFIG_GLOBAL = vim.fs.joinpath(vim.fs.dirname(here), "gitconfig")
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_CONFIG_COUNT = nil
vim.env.GIT_CONFIG_PARAMETERS = nil

_G.notifs = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
    _G.notifs[#_G.notifs + 1] = { msg = msg, level = level }
end

-- a panel stages and reverts in the repo it opened on: the current file's repo, else
-- cwd's. a spec that opens one without a file of its throwaway repo focused lands on
-- the repo the suite runs from, so that fails here before any key can write to it
local suite_root = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })[1]
local suite_label = vim.fn.fnamemodify(suite_root, ":~") -- the form Panel.root holds
local git = require("differ.git")
local panel = git.panel
---@diagnostic disable-next-line: duplicate-set-field
git.panel = function(opts)
    local out = panel(opts)
    local p = require("differ.panel").current()
    if p and p.root == suite_label then
        p:close()
        error("a spec opened a panel on the repo the suite runs from")
    end
    return out
end

-- a spec that throws before its own close leaves the panel open, and every spec after
-- it would run against that stale session. busted calls a helper that returns a
-- function with its instance
---@param busted table
return function(busted)
    busted.subscribe({ "test", "end" }, function()
        local open = require("differ.panel").current()
        if open then
            open:close()
        end
        return nil, true -- keep publishing to the output handlers
    end)
    return true
end
