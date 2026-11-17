-- the draw fuzz at a fixed seed: where the index doesn't cut into blocks, every wrong
-- draw is a tie the view flags, never a reading bug. `make lua-fuzz` runs it large
local draw = require("test.fuzz.draw")

describe("draw fuzz", function()
    it("draws no wrong mark a reading bug explains", function()
        local plain, hidden = draw.run({ seed = 1, count = 100 })
        assert.is_true(plain.unclean > 0)
        assert.are.equal(0, draw.bugs(plain, hidden), draw.format(plain, hidden))
    end)
end)
