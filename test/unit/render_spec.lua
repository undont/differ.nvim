local render = require("differ.render")

-- HEAD "a\nb", worktree "a\nb\n": one hunk, b on both sides
local model = {
    path = "x",
    old_rev = "A",
    new_rev = "B",
    old_text = "a\nb",
    new_text = "a\nb\n",
    hunks = {
        {
            old_start = 2,
            old_count = 1,
            new_start = 2,
            new_count = 1,
            old_lines = { "b" },
            new_lines = { "b" },
        },
    },
}

-- each flagged row as "kind:lnum"
local function flagged(column)
    local out = {}
    for _, line in ipairs(column.map.lines) do
        if line.no_eol then
            out[#out + 1] = line.kind .. ":" .. (line[line.kind] or "")
        end
    end
    return out
end

describe("render no_eol", function()
    it("flags the old side's last line in stacked", function()
        local r = render.render(model, { layout = "stacked", context = math.huge })
        assert.are.same({ "old:2" }, flagged(r.columns[1]))
    end)

    it("flags the old column's last line in split", function()
        local r = render.render(model, { layout = "split", context = math.huge })
        assert.are.same({ "old:2" }, flagged(r.columns[1]))
        assert.are.same({}, flagged(r.columns[2]))
    end)

    it("leaves an unterminated line alone when no hunk shows it", function()
        local context = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb",
            new_text = "A\nb",
            hunks = {
                {
                    old_start = 1,
                    old_count = 1,
                    new_start = 1,
                    new_count = 1,
                    old_lines = { "a" },
                    new_lines = { "A" },
                },
            },
        }
        local r = render.render(context, { layout = "stacked", context = math.huge })
        assert.are.same({}, flagged(r.columns[1]))
    end)
end)
