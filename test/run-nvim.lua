-- nvim -l test/run-nvim.lua
-- runs each headless-nvim spec file in its own busted process, up to one per core.
-- a failing file's output prints whole once every file has finished

local specs = vim.fn.glob("test/nvim/**/*_spec.lua", false, true)
-- largest first, so the slow files don't start late
table.sort(specs, function(a, b)
    return vim.uv.fs_stat(a).size > vim.uv.fs_stat(b).size
end)
local jobs = vim.uv.available_parallelism()
local outputs = {} ---@type table<string, string>
local failed = {} ---@type string[]
local next_spec, running = 1, 0

local function start()
    local spec = specs[next_spec]
    next_spec = next_spec + 1
    running = running + 1
    local started = vim.uv.hrtime()
    vim.system({ "busted", "--lua=nlua", "--run", "nvim", spec }, { text = true }, function(res)
        local secs = math.floor((vim.uv.hrtime() - started) / 1e9)
        if res.code == 0 then
            io.stdout:write(("\27[0;32m✓\27[0m %s (%ds)\n"):format(spec, secs))
        else
            io.stdout:write(("\27[0;31m✗\27[0m %s (%ds)\n"):format(spec, secs))
            outputs[spec] = res.stdout .. res.stderr
            failed[#failed + 1] = spec
        end
        running = running - 1
    end)
end

while next_spec <= #specs or running > 0 do
    while next_spec <= #specs and running < jobs do
        start()
    end
    local busy = running
    vim.wait(1000, function()
        return running < busy
    end, 10)
end

if #failed == 0 then
    os.exit(0)
end

table.sort(failed)
for _, spec in ipairs(failed) do
    io.stdout:write(("\n\27[0;31m── %s\27[0m\n%s"):format(spec, outputs[spec]))
end
io.stdout:write("\n\27[0;31mfailed:\27[0m\n")
for _, spec in ipairs(failed) do
    io.stdout:write(("  %s\n"):format(spec))
end
os.exit(1)
