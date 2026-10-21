local tokenize = require("differ.worddiff.tokenize")

local function texts(tokens)
    local out = {}
    for i, t in ipairs(tokens) do
        out[i] = t.text
    end
    return out
end

describe("worddiff.tokenize.word", function()
    it("keeps snake_case as one token", function()
        assert.are.same({ "foo_bar" }, texts(tokenize.word("foo_bar")))
    end)

    it("keeps camelCase as one token", function()
        assert.are.same({ "fooBar" }, texts(tokenize.word("fooBar")))
    end)

    it("splits identifiers, whitespace, and punctuation", function()
        assert.are.same(
            { "a", " ", "=", " ", "b", "(", "c", ")" },
            texts(tokenize.word("a = b(c)"))
        )
    end)

    it("reports byte columns", function()
        local t = tokenize.word("ab cd")
        assert.are.same(
            { col_start = 0, col_end = 2 },
            { col_start = t[1].col_start, col_end = t[1].col_end }
        )
        assert.are.same(
            { col_start = 3, col_end = 5 },
            { col_start = t[3].col_start, col_end = t[3].col_end }
        )
    end)
end)

describe("worddiff.tokenize.char", function()
    it("emits one token per byte", function()
        assert.are.same({ "a", "b", "c" }, texts(tokenize.char("abc")))
    end)
end)
