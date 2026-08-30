-- the shared compose window: a real split window over a markdown scratch buffer
-- for authoring a comment, a reply, or a submit-review body. a split (not a float) so
-- the statusline shows the editing mode and the window behaves like any other. stacked
-- opens it below the diff (like the df edit window); split opens it on the far left
-- (octo-style), so the side-by-side columns stay put. the title rides the winbar, so
-- the draft-vs-immediate mode stays visible the whole time. the caller passes
-- on_submit/on_cancel; the window closes before the callback runs, so a mutation can
-- reopen it cleanly on error

local M = {}

-- window-local keys: <CR> submits normal mode, default behaviour in insert mode
-- <C-s> submits from insert, q cancels (:q too, via the autocmd below).
local SUBMIT_N = "<CR>"
local SUBMIT_I = "<C-s>"
local CANCEL = "q"

-- open the compose split and put `buf` in it. stacked -> a horizontal split below the
-- anchor (diff) window; split -> a vertical split on the far left
---@param buf integer
---@param layout string|nil  -- "split" | "stacked"
---@param anchor_win integer|nil  -- the diff window to anchor the stacked split below
---@return integer win
local function open_split(buf, layout, anchor_win)
    if layout == "split" then
        vim.cmd("topleft vsplit")
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        local width = math.max(40, math.min(60, math.floor(vim.o.columns * 0.3)))
        vim.api.nvim_win_set_width(win, width)
        return win
    end
    if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
        vim.api.nvim_set_current_win(anchor_win)
    end
    vim.cmd("rightbelow split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    local height = math.max(8, math.min(16, math.floor(vim.o.lines * 0.35)))
    vim.api.nvim_win_set_height(win, height)
    return win
end

---@class differ.ComposeOpts
---@field title string
---@field initial? string
---@field layout? string        -- "split" | "stacked"
---@field anchor_win? integer   -- diff window the stacked split anchors below
---@field on_submit fun(text: string)
---@field on_cancel? fun()

-- open the compose window and return a handle with :close() so a caller can dismiss it
-- after a mutation acks
---@param opts differ.ComposeOpts
---@return { close: fun() }
function M.open(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    if opts.initial and opts.initial ~= "" then
        vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            vim.split(opts.initial, "\n", { plain = true })
        )
    end

    local win = open_split(buf, opts.layout, opts.anchor_win)
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    -- the title + submit hint live on the winbar so the mode (draft vs immediate) and
    -- the keys stay visible while editing; %% escapes for the winbar's statusline syntax
    vim.wo[win].winbar = opts.title:gsub("%%", "%%%%") .. "   (<CR> submit · q cancel)"

    local closed = false
    local function shut()
        if closed then
            return
        end
        closed = true
        vim.cmd("stopinsert") -- submitting from insert mode must not leave the diff in insert
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        if buf and vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    local function submit()
        if closed then
            return
        end
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        shut()
        opts.on_submit(vim.trim(text))
    end
    local function cancel()
        shut()
        if opts.on_cancel then
            opts.on_cancel()
        end
    end

    vim.keymap.set("n", SUBMIT_N, submit, { buffer = buf, nowait = true, desc = "differ: submit" })
    vim.keymap.set("i", SUBMIT_I, submit, { buffer = buf, desc = "differ: submit" })
    vim.keymap.set("n", CANCEL, cancel, { buffer = buf, nowait = true, desc = "differ: cancel" })
    -- a wipe from any other path (e.g. :q) counts as a cancel, so the caller's state
    -- doesn't get stranded waiting on a submit that never comes. if instead a picker /
    -- :edit swapped another buffer into the compose window (the window survives holding
    -- a foreign buffer), end the whole session and carry that file out, rather than
    -- silently cancelling the comment
    vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
        buffer = buf,
        once = true,
        callback = function()
            if closed then
                return
            end
            local foreign
            if win and vim.api.nvim_win_is_valid(win) then
                local cur = vim.api.nvim_win_get_buf(win)
                if cur ~= buf and vim.api.nvim_buf_is_valid(cur) then
                    foreign = cur
                end
            end
            cancel()
            if foreign then
                vim.schedule(function()
                    require("differ.git").navigate_away(foreign)
                end)
            end
        end,
    })

    vim.cmd("startinsert")
    return { close = shut }
end

return M
