-- git's editor while differ runs an operation, run as `nvim --clean -l shim.lua <file>`:
-- asks the nvim in $NVIM to open the file, then exits once it says the buffer closed:
-- 0 when it was written, else 1 so git drops that commit. never required as a module

local addr = vim.env.NVIM
if not addr or addr == "" then
    io.stderr:write("differ: no nvim to edit the message in\n")
    os.exit(1)
end
local mode = "pipe"
if addr:match("^[%w.-]+:%d+$") then
    mode = "tcp"
end
local ok, chan = pcall(vim.fn.sockconnect, mode, addr, { rpc = true })
if not ok or chan == 0 then
    io.stderr:write(("differ: can't reach nvim at %s\n"):format(addr))
    os.exit(1)
end

-- set by the parent through nvim_exec_lua once the message buffer closes
_G.differ_closed = false
_G.differ_written = false
local own = vim.rpcrequest(chan, "nvim_get_api_info")[1]
vim.rpcrequest(
    chan,
    "nvim_exec_lua",
    "require('differ.git.editor').open(...)",
    { vim.fn.fnamemodify(_G.arg[1], ":p"), own, tonumber(vim.env.DIFFER_FLOAT) }
)
while not _G.differ_closed do
    vim.wait(1000, function()
        return _G.differ_closed
    end)
    -- the socket closes with the parent, and a request on it then fails
    if not _G.differ_closed and not pcall(vim.rpcrequest, chan, "nvim_get_api_info") then
        os.exit(1)
    end
end
if not _G.differ_written then
    os.exit(1)
end
os.exit(0)
