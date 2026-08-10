-- command registration; loaded once on startup

if vim.g.loaded_differ then
    return
end
vim.g.loaded_differ = true

-- 0.12 is a hard floor: model/diff.lua calls vim.text.diff on the path of every diff
-- bail before registering, so the message is the only thing the user gets
if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify(
        ("differ.nvim requires nvim 0.12+ (vim.text.diff); this is %s"):format(vim.version()),
        vim.log.levels.ERROR
    )
    return
end

require("differ.command").register("Differ", "differ diff viewer")
