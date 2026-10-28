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

-- the columns `style = "minimal"` turns off, off again on `win`: a buffer swapped into a
-- minimal float gets whatever columns BufWinEnter hooks set for it
---@param win integer
function M.no_columns(win)
    M.set_local(win, "number", false)
    M.set_local(win, "relativenumber", false)
    M.set_local(win, "signcolumn", "no")
    M.set_local(win, "foldcolumn", "0")
    M.set_local(win, "statuscolumn", "")
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

-- a normal window beside `panel` to open content in: `origin` if it still is one, else
-- another normal window in the panel's tabpage, else a fresh split carved off the panel
-- (off the current window while the panel is hidden)
---@param panel integer|nil nil while the sidebar is hidden
---@param origin integer|nil
---@return integer
function M.ensure_origin(panel, origin)
    local shown = panel and vim.api.nvim_win_is_valid(panel)
    local tab = vim.api.nvim_get_current_tabpage()
    if shown then
        tab = vim.api.nvim_win_get_tabpage(panel)
    end
    local function usable(w)
        return w ~= panel
            and vim.api.nvim_win_is_valid(w)
            and vim.api.nvim_win_get_tabpage(w) == tab
            and vim.fn.win_gettype(w) == ""
    end
    if origin and usable(origin) then
        return origin
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if usable(w) then
            return w
        end
    end
    if shown then
        vim.api.nvim_set_current_win(panel)
    end
    vim.cmd("aboveleft split")
    return vim.api.nvim_get_current_win()
end

return M
