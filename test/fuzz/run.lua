-- nvim --clean -l test/fuzz/run.lua [seed] [count] [selections] [staged] [edited]
package.path = "./lua/?.lua;./lua/?/init.lua;./?.lua;" .. package.path

local fuzz = require("test.fuzz.stage")

local opts = {
    seed = tonumber(arg[1]) or 1,
    count = tonumber(arg[2]) or 1000,
    selections = tonumber(arg[3]),
    staged = tonumber(arg[4]),
    edited = tonumber(arg[5]),
}
local started = vim.uv.hrtime()
local report = fuzz.run(opts)
print(("seed %d, %d triples"):format(opts.seed, opts.count))
print(fuzz.format(report))
print(("%.1fs"):format((vim.uv.hrtime() - started) / 1e9))
