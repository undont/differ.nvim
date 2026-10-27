-- nvim --clean -l test/fuzz/run.lua [--cmp=<rev>] [seed] [count] [selections] [staged] [edited]
package.path = "./lua/?.lua;./lua/?/init.lua;./?.lua;" .. package.path

local args, rev = {}, nil
for _, a in ipairs(arg) do
    local named = a:match("^%-%-cmp=(.+)$")
    if named then
        rev = named
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
}
local started = vim.uv.hrtime()
print(("seed %d, %d triples"):format(opts.seed, opts.count))
if rev then
    local cmp = require("test.fuzz.cmp")
    print(cmp.format(cmp.run(opts, rev)))
else
    local fuzz = require("test.fuzz.stage")
    print(fuzz.format(fuzz.run(opts)))
end
print(("%.1fs"):format((vim.uv.hrtime() - started) / 1e9))
