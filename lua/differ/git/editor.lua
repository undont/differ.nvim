-- the editor git gets in differ's terminal float: git/shim.lua, which asks this nvim to
-- open the message in the float and waits until the buffer closes. as with any editor,
-- git then reads the file, and an emptied message drops that commit

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

-- the float's window, reopened when nothing shows the terminal
---@param float integer
---@return integer
local function float_win(float)
    require("differ.git.operation").show(float)
    return vim.fn.bufwinid(float)
end

-- called by the shim over rpc: show `path` in place of terminal buffer `float` and tell
-- channel `chan` once it closes. returns at once, since the shim's request blocks until
-- it does
---@param path string
---@param chan integer
---@param float integer
function M.open(path, chan, float)
    local function closed()
        pcall(vim.rpcnotify, chan, "nvim_exec_lua", "_G.differ_closed = true", {})
    end
    -- the stopped commit's message, asked for before git moves past the stop
    local accept = vim.b[float].differ_accept
    vim.b[float].differ_accept = nil
    if accept and accept.stop == require("differ.git.operation").stop(accept.root) then
        return closed()
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
    vim.api.nvim_set_current_win(win)
    vim.cmd.stopinsert()
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    require("differ.git.operation").title_float(win, float, "commit message")
    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = buf,
        once = true,
        callback = function()
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(float) then
                    vim.b[float].differ_message = nil
                    local back = float_win(float)
                    require("differ.git.operation").title_float(back, float)
                    vim.api.nvim_win_set_buf(back, float)
                    vim.api.nvim_set_current_win(back)
                    vim.cmd.startinsert()
                end
                closed()
            end)
        end,
    })
end

return M
