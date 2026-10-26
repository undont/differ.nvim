-- runs a git command in a float set up as in_float sets one up and writes what on_stdout
-- gets to <name>.raw here. needs a ui, so run it from the repo root in an 80x24 terminal:
--   nvim --clean -c 'luafile test/unit/fixtures/pty/capture.lua' -- <name> <repo> <cmd...>

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
vim.opt.rtp:prepend(vim.fn.fnamemodify(here, ":h:h:h:h"))

local args = vim.list_slice(vim.v.argv, vim.fn.index(vim.v.argv, "--") + 2)
local name, repo = args[1], args[2]
local cmd = vim.list_slice(args, 3)

local buf = vim.api.nvim_create_buf(false, true)
local width = math.floor(vim.o.columns * 0.8)
local height = math.floor(vim.o.lines * 0.6)
require("differ.util.win").open_centred(buf, width, height, { title = " capture " })

local stream = {}
local job =
    vim.fn.jobstart(vim.list_extend({ "sh", "-c", 'GPG_TTY=$(tty) exec "$@"', "sh" }, cmd), {
        term = true,
        cwd = repo,
        on_stdout = function(_, data)
            stream[#stream + 1] = table.concat(data, "\n")
        end,
        on_exit = function()
            vim.schedule(function()
                local fd = assert(io.open(here .. "/" .. name .. ".raw", "wb"))
                fd:write(table.concat(stream))
                fd:close()
                vim.cmd("qa!")
            end)
        end,
    })
assert(job > 0, "couldn't start " .. table.concat(cmd, " "))
vim.cmd.startinsert()
