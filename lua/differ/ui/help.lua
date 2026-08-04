-- floating keymap cheatsheet shared by the panel, history, diff and merge surfaces.
-- `lines` renders {lhs, description} rows from the resolved keymaps; `show` opens a
-- centred minimal float, dismissed with q / <Esc> / g? (or the caller's own keys)

local M = {}

-- a keymaps spec as a help lhs: a string, a list joined with " / ", or nil when the
-- action is disabled (false), which drops the row
---@param spec string|string[]|false|nil
---@return string|nil
function M.fmt(spec)
    if not spec then
        return nil
    end
    return type(spec) == "table" and table.concat(spec, " / ") or tostring(spec)
end

-- two related actions sharing a row ("]c / [c"), keeping whichever side is enabled
---@param a string|string[]|false|nil
---@param b string|string[]|false|nil
---@return string|nil
function M.pair(a, b)
    local first, second = M.fmt(a), M.fmt(b)
    if first and second then
        return first .. " / " .. second
    end
    return first or second
end

-- align {lhs, description} rows into help lines. a nil lhs means the action is
-- disabled, so the row is skipped and doesn't pad the column either
---@param rows { [1]: string|nil, [2]: string }[]
---@return string[]
function M.lines(rows)
    local keyw = 0
    for _, r in ipairs(rows) do
        if r[1] then
            keyw = math.max(keyw, #r[1])
        end
    end
    local out = {}
    for _, r in ipairs(rows) do
        if r[1] then
            out[#out + 1] = (" %-" .. keyw .. "s   %s"):format(r[1], r[2])
        end
    end
    return out
end

---@param lines string[]
---@param opts? { title?: string, dismiss?: string[] }
function M.show(lines, opts)
    opts = opts or {}
    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, #l)
    end
    -- one blank row of breathing space above and below the keymap rows
    local padded = { "" }
    vim.list_extend(padded, lines)
    padded[#padded + 1] = ""
    lines = padded
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width + 1,
        height = #lines,
        row = math.floor((vim.o.lines - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = opts.title or " Differ ",
    })
    local function close()
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    for _, lhs in ipairs(opts.dismiss or { "q", "<Esc>", "g?" }) do
        vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true })
    end
end

return M
