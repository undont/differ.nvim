-- buffer lookup, runtime-only (uses the nvim API)

local M = {}

-- the buffer whose name is `path`, else nil. `vim.fn.bufnr()` can't be used for this:
-- it treats its argument as a file-pattern, so a path holding a regex metacharacter
-- resolves to whichever buffer the pattern happens to match (a literal `a[1].lua` finds
-- a buffer named `a1.lua`), and a name that merely *contains* the string matches too.
-- nvim stores a buffer's name symlink-resolved (`:edit /var/x` on macOS names the buffer
-- `/private/var/x`), so an unresolved caller path is compared against its real path as
-- well; resolving once here rather than per buffer keeps it to a single stat
---@param path string  -- absolute
---@return integer|nil
function M.find(path)
    local real = (vim.uv or vim.loop).fs_realpath(path) or path -- nil once the file is gone
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" and (name == path or name == real) then
            return b
        end
    end
    return nil
end

return M
