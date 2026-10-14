-- foldtext for collapsed unchanged regions: differ's wording plus the first folded
-- line (diffview-style), e.g. "⋯ 404 unchanged lines: local function foo()"

local M = {}

---@return string
function M.render()
    local count = vim.v.foldend - vim.v.foldstart + 1
    local first = vim.fn.getline(vim.v.foldstart):gsub("^%s+", "")
    local lines = require("differ.util.text").plural(count, "unchanged line")
    return ("\u{22ef} %s: %s"):format(lines, first)
end

return M
