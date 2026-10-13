-- window helpers, runtime-only (uses the nvim API)

local M = {}

-- set a window-local option without disturbing the global default. plain
-- `vim.wo[win].opt = v` omits scope, so it sets the global value too (like :set,
-- not :setlocal), which leaks a window's dressing (gutter, folds, cursorline) onto
-- every other window in the session
---@param win integer
---@param opt string
---@param val any
function M.set_local(win, opt, val)
    vim.api.nvim_set_option_value(opt, val, { scope = "local", win = win })
end

-- a minimal, rounded float of `width` x `height` in the middle of the editor, focused
---@param buf integer
---@param width integer
---@param height integer
---@param opts table|nil extra win config, e.g. the title
---@return integer win
function M.open_centred(buf, width, height, opts)
    local config = vim.tbl_extend("force", {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
    }, opts or {})
    return vim.api.nvim_open_win(buf, true, config)
end

return M
