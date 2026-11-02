local staging = require("differ.git.staging")

describe("git.staging.partly_staged", function()
    local partly_staged = staging.new({}).partly_staged

    it("holds for a row with a staged change and more on top", function()
        assert.is_true(partly_staged({ path = "a", status = "M", x = "M", y = "M" }))
    end)

    it("is false for a rev-pair row, which carries no status letters", function()
        assert.is_false(partly_staged({ path = "a", status = "M" }))
        assert.is_false(partly_staged({ path = "a", status = "R", previous_path = "b" }))
    end)
end)
