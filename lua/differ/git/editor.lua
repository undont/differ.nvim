-- the editor git gets in differ's terminal float: git/shim.lua, which asks this nvim to
-- open the message in the float and waits until the buffer closes. git commits the file
-- only when it was written: closing it unwritten, or emptying it, drops that commit

local M = {}

local SHIM = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/shim.lua"

-- the environment git runs with in terminal buffer `float`: the shim as its editor,
-- pointed back at this nvim and that buffer
---@param float integer
---@return table<string, string>
function M.env(float)
    if vim.v.servername == "" then
        vim.fn.serverstart()
    end
    local editor = table.concat({
        vim.fn.shellescape(vim.v.progpath),
        "--clean",
        "-l",
        vim.fn.shellescape(SHIM),
    }, " ")
    return { GIT_EDITOR = editor, NVIM = vim.v.servername, DIFFER_FLOAT = tostring(float) }
end

-- what starts a comment line in the repo holding git dir `dir`; "auto" is read as "#"
---@param dir string
---@return string
local function comment_prefix(dir)
    for _, key in ipairs({ "core.commentString", "core.commentChar" }) do
        local value = require("differ.git.exec").git({ "config", "--get", key }, dir)
        value = value and vim.trim(value)
        if value and value ~= "" and value ~= "auto" then
            return value
        end
    end
    return "#"
end

-- whether `lines` hold nothing but blank and comment lines
---@param lines string[]
---@param prefix string
---@return boolean
local function emptied(lines, prefix)
    for _, line in ipairs(lines) do
        if line:match("%S") and not vim.startswith(line, prefix) then
            return false
        end
    end
    return true
end

-- the float's window, reopened when nothing shows the terminal
---@param float integer
---@return integer
local function float_win(float)
    require("differ.git.operation").show(float)
    return vim.fn.bufwinid(float)
end

-- called by the shim over rpc: show `path` in place of terminal buffer `float` and tell
-- channel `chan` once it closes, and whether it was written. returns at once, since the
-- shim's request blocks until it does. closing it unwritten, or last written with nothing
-- but comments, sets `differ_cancelled` on `float`
---@param path string
---@param chan integer
---@param float integer
function M.open(path, chan, float)
    ---@param written boolean
    local function closed(written)
        local lua = ("_G.differ_written = %s; _G.differ_closed = true"):format(written)
        pcall(vim.rpcnotify, chan, "nvim_exec_lua", lua, {})
    end
    -- the stopped commit's message, asked for before git moves past the stop
    local accept = vim.b[float].differ_accept
    vim.b[float].differ_accept = nil
    if accept and accept.stop == require("differ.git.operation").stop(accept.root) then
        return closed(true)
    end
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 then
        if vim.bo[existing].modified then
            require("differ.git.exec").notify(
                "unsaved edits to " .. path .. " were discarded",
                vim.log.levels.WARN
            )
        end
        vim.api.nvim_buf_delete(existing, { force = true })
    end
    local buf = vim.fn.bufadd(path)
    local win = float_win(float)
    vim.b[float].differ_message = true
    vim.api.nvim_win_set_buf(win, buf)
    require("differ.util.win").no_columns(win)
    vim.api.nvim_set_current_win(win)
    vim.cmd.stopinsert()
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    require("differ.git.operation").title_float(win, float, "commit message")
    local prefix = comment_prefix(vim.fn.fnamemodify(path, ":h"))
    local written, empty = false, false
    vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = buf,
        callback = function()
            written = true
            empty = emptied(vim.api.nvim_buf_get_lines(buf, 0, -1, false), prefix)
        end,
    })
    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = buf,
        once = true,
        callback = function()
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(float) then
                    vim.b[float].differ_message = nil
                    vim.b[float].differ_cancelled = not written or empty
                    local back = float_win(float)
                    require("differ.git.operation").title_float(back, float)
                    vim.api.nvim_win_set_buf(back, float)
                    require("differ.util.win").no_columns(back)
                    vim.api.nvim_set_current_win(back)
                    vim.cmd.startinsert()
                end
                closed(written)
            end)
        end,
    })
end

return M
