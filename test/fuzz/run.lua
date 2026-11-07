-- nvim --clean -l test/fuzz/run.lua [--cmp=<rev>] [--detail] [seed] [count] [selections] [staged] [edited] [alphabet]
package.path = "./lua/?.lua;./lua/?/init.lua;./?.lua;" .. package.path

local args, rev, detail = {}, nil, false
for _, a in ipairs(arg) do
    local named = a:match("^%-%-cmp=(.+)$")
    if named then
        rev = named
    elseif a == "--detail" then
        detail = true
    else
        args[#args + 1] = a
    end
end

local opts = {
    seed = tonumber(args[1]) or 1,
    count = tonumber(args[2]) or 1000,
    selections = tonumber(args[3]),
    staged = tonumber(args[4]),
    edited = tonumber(args[5]),
    alphabet = tonumber(args[6]),
}
local started = vim.uv.hrtime()
io.write(("seed %d, %d random HEAD / index / worktree files\n\n"):format(opts.seed, opts.count))
local failed = false
if rev then
    local cmp = require("test.fuzz.cmp")
    io.write(cmp.format(cmp.run(opts, rev)), "\n")
else
    local fuzz = require("test.fuzz.stage")
    local report = fuzz.run(opts)
    io.write(fuzz.format(report, detail), "\n")
    failed = #fuzz.wrong(report) > 0
end
io.write(("\n%.1fs\n"):format((vim.uv.hrtime() - started) / 1e9))
if failed then
    os.exit(1)
end
