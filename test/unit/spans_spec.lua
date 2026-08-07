local spans = require("differ.worddiff.spans")

describe("worddiff.spans.emit (word)", function()
    it("emits no spans for identical lines", function()
        local s = spans.emit("local x = 1", "local x = 1", "word")
        assert.are.same({}, s.old)
        assert.are.same({}, s.new)
    end)

    it("isolates a single changed identifier", function()
        -- "local foo = 1" -> "local bar = 1"; only foo/bar differ
        local s = spans.emit("local foo = 1", "local bar = 1", "word")
        assert.are.same({ { col_start = 6, col_end = 9 } }, s.old)
        assert.are.same({ { col_start = 6, col_end = 9 } }, s.new)
    end)

    it("marks a pure insertion only on the new side", function()
        local s = spans.emit("a c", "a b c", "word")
        assert.are.same({}, s.old)
        -- inserted "b " sits at cols [2,4): the new word and the space after it
        assert.are.same({ { col_start = 2, col_end = 4 } }, s.new)
    end)

    it("merges adjacent changed tokens into one span", function()
        local s = spans.emit("xy", "ab", "word")
        assert.are.same({ { col_start = 0, col_end = 2 } }, s.old)
        assert.are.same({ { col_start = 0, col_end = 2 } }, s.new)
    end)

    it("ignores a whitespace-only change (gofmt realignment)", function()
        -- field name and type are identical; only the alignment padding widened
        local s = spans.emit("ctx     context.Context", "ctx       context.Context", "word")
        assert.are.same({}, s.old)
        assert.are.same({}, s.new)
    end)

    it("drops an isolated realignment gap but keeps the real change", function()
        -- the widened gap before '=' is alignment churn; only the type token changed
        local s = spans.emit("foo = string", "foo    = transcript", "word")
        assert.are.same({ { col_start = 6, col_end = 12 } }, s.old)
        assert.are.same({ { col_start = 9, col_end = 19 } }, s.new)
    end)

    it("keeps changes either side of an unchanged token separate", function()
        -- "a X b" -> "Z X Y": 'a'->'Z' and 'b'->'Y', the middle " X " survives
        local s = spans.emit("a X b", "Z X Y", "word")
        assert.are.same({ { col_start = 0, col_end = 1 }, { col_start = 4, col_end = 5 } }, s.old)
        assert.are.same({ { col_start = 0, col_end = 1 }, { col_start = 4, col_end = 5 } }, s.new)
    end)
end)

describe("worddiff.spans.emit (char)", function()
    it("narrows to the changed characters", function()
        local s = spans.emit("kitten", "kitsen", "char")
        assert.are.same({ { col_start = 3, col_end = 4 } }, s.old)
        assert.are.same({ { col_start = 3, col_end = 4 } }, s.new)
    end)
end)

describe("worddiff.spans.for_hunk", function()
    it("attaches spans to paired lines and skips unpaired ones", function()
        local hunk = {
            old_start = 1,
            old_count = 2,
            new_start = 1,
            new_count = 2,
            old_lines = { "local foo = 1", "totally unrelated" },
            new_lines = { "local bar = 1", "nothing alike here" },
        }
        local old_spans, new_spans = spans.for_hunk(hunk, 0.5, "word")
        -- line 1 pairs (high similarity) -> word span on foo/bar
        assert.are.same({ { col_start = 6, col_end = 9 } }, old_spans[1])
        assert.are.same({ { col_start = 6, col_end = 9 } }, new_spans[1])
        -- line 2 has no partner above threshold -> no spans (whole-line highlight)
        assert.is_nil(old_spans[2])
        assert.is_nil(new_spans[2])
    end)
end)

describe("worddiff.spans.emit size ceiling", function()
    it("keeps tight spans on a huge line whose edit is small", function()
        -- the ceiling is on the trimmed middle, not the line: a minified line with one
        -- changed token trims to almost nothing, so it must still get a precise span
        -- rather than degrading the way a raw line-length cap would make it
        -- the spaces around the marker keep it its own token; without them `[%w_]+`
        -- would run it into the filler's leading `var`
        local filler = string.rep("var a1=1;", 3000) -- 27000 bytes either side
        local s =
            spans.emit(filler .. " KEEP_OLD " .. filler, filler .. " KEEP_NEW " .. filler, "word")
        assert.are.same({ { col_start = 27001, col_end = 27009 } }, s.old)
        assert.are.same({ { col_start = 27001, col_end = 27009 } }, s.new)
    end)

    it("still grids a middle that sits on the ceiling", function()
        -- 500 disjoint words is 999 tokens a side, and 999^2 stays under the ceiling, so
        -- every changed word keeps its own span instead of merging
        local old_words, new_words = {}, {}
        for i = 1, 500 do
            old_words[i] = "a" .. i
            new_words[i] = "b" .. i
        end
        local s = spans.emit(table.concat(old_words, " "), table.concat(new_words, " "), "word")
        assert.are.equal(500, #s.old)
        assert.are.equal(500, #s.new)
        assert.are.same({ col_start = 0, col_end = 2 }, s.old[1])
    end)

    it("collapses to one span when the middle is too large to grid", function()
        -- disjoint tokens either side, so nothing trims and the middle stays the whole
        -- line: 1001 words is 2001 tokens a side, and 2001^2 clears the ceiling
        local old_words, new_words = {}, {}
        for i = 1, 1001 do
            old_words[i] = "a" .. i
            new_words[i] = "b" .. i
        end
        local old_line, new_line = table.concat(old_words, " "), table.concat(new_words, " ")
        local s = spans.emit(old_line, new_line, "word")
        assert.are.same({ { col_start = 0, col_end = #old_line } }, s.old)
        assert.are.same({ { col_start = 0, col_end = #new_line } }, s.new)
    end)
end)
