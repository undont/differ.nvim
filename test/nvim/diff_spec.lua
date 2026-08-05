-- runs under headless nvim (vim.diff available); invoked via the nvim-test target
local diff = require("differ.model.diff")

describe("model.diff.build", function()
    it("produces no hunks for identical text", function()
        local m = diff.build({
            path = "x.lua",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "a\nb\nc\n",
            new_text = "a\nb\nc\n",
        })
        assert.are.equal(0, #m.hunks)
    end)

    it("materializes changed lines per hunk", function()
        local m = diff.build({
            path = "x.lua",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "a\nb\nc\n",
            new_text = "a\nB\nc\n",
        })
        assert.are.equal(1, #m.hunks)
        assert.are.same({ "b" }, m.hunks[1].old_lines)
        assert.are.same({ "B" }, m.hunks[1].new_lines)
    end)

    it("handles add-only and missing trailing newline", function()
        local m = diff.build({
            path = "x.lua",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "a",
            new_text = "a\nb",
        })
        assert.are.equal(1, #m.hunks)
        assert.are.same({ "b" }, m.hunks[1].new_lines)
    end)

    it("flags binary content and skips diffing it", function()
        -- a modified binary file (NUL bytes both sides) must not be diffed: the word
        -- pass over megabyte pseudo-lines is an OOM. it carries no hunks, just a flag
        local m = diff.build({
            path = "demo.gif",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "GIF89a\0\1\2\3",
            new_text = "GIF89a\0\4\5\6",
        })
        assert.is_true(m.binary)
        assert.are.equal(0, #m.hunks)
    end)
end)

describe("model.diff.revert_hunk", function()
    ---@param old string
    ---@param new string
    ---@return differ.DiffModel
    local function model(old, new)
        return diff.build({
            path = "x.lua",
            old_rev = "INDEX",
            new_rev = "WORKTREE",
            old_text = old,
            new_text = new,
        })
    end

    it("restores the old side exactly when the only hunk goes", function()
        local m = model("a\nb\nc\n", "a\nB\nc\n")
        assert.are.equal(1, #m.hunks)

        local r = diff.revert_hunk(m, 1)
        assert.are.equal("a\nb\nc\n", r.new_text)
        assert.are.equal(0, #r.hunks)
        assert.are.equal(m.old_text, r.old_text) -- the old side never moves
    end)

    it("leaves the untouched hunk in place", function()
        local m = model("a\nb\nc\nd\ne\n", "a\nB\nc\nD\ne\n")
        assert.are.equal(2, #m.hunks)

        local r = diff.revert_hunk(m, 1)
        assert.are.equal("a\nb\nc\nD\ne\n", r.new_text)
        assert.are.equal(1, #r.hunks)
        assert.are.same({ "d" }, r.hunks[1].old_lines)
        assert.are.same({ "D" }, r.hunks[1].new_lines)
    end)

    it("drops the added lines of a pure insertion", function()
        local m = model("a\nc\n", "a\nb1\nb2\nc\n")
        assert.are.equal(0, m.hunks[1].old_count)

        local r = diff.revert_hunk(m, 1)
        assert.are.equal("a\nc\n", r.new_text)
        assert.are.equal(0, #r.hunks)
    end)

    -- a deletion holds no lines on the new side, so `new_start` names the line it
    -- follows rather than one it covers; restoring has to insert after, not over
    it("puts back the removed lines of a pure deletion", function()
        local m = model("a\nb\nc\n", "a\nc\n")
        assert.are.equal(0, m.hunks[1].new_count)

        local r = diff.revert_hunk(m, 1)
        assert.are.equal("a\nb\nc\n", r.new_text)
        assert.are.equal(0, #r.hunks)
    end)

    it("puts back lines deleted from the very top of the file", function()
        local m = model("a\nb\nc\n", "b\nc\n")
        assert.are.equal(0, m.hunks[1].new_start) -- follows the line before the first

        local r = diff.revert_hunk(m, 1)
        assert.are.equal("a\nb\nc\n", r.new_text)
        assert.are.equal(0, #r.hunks)
    end)

    -- the terminator follows whichever side supplies the last line, or the revert
    -- re-diffs as a phantom hunk on the final line
    it("takes the old side's missing final newline when the hunk reaches eof", function()
        local r = diff.revert_hunk(model("a\nb", "a\nB\n"), 1)
        assert.are.equal("a\nb", r.new_text)
        assert.are.equal(0, #r.hunks)
    end)

    it("keeps the new side's ending when the hunk stops short of eof", function()
        local r = diff.revert_hunk(model("a\nb\nc", "A\nb\nc"), 1)
        assert.are.equal("a\nb\nc", r.new_text)
        assert.are.equal(0, #r.hunks)
    end)

    -- hunks are always parted by at least one unchanged line, and a revert doesn't
    -- remove those, so the survivors stay distinct; only their indices move
    it("keeps neighbouring hunks separate and renumbers them", function()
        local m = model("a\nx\nb\ny\nc\n", "A\nx\nB\ny\nC\n")
        assert.are.equal(3, #m.hunks)

        local r = diff.revert_hunk(m, 2)
        assert.are.equal("A\nx\nb\ny\nC\n", r.new_text)
        assert.are.equal(2, #r.hunks)
        assert.are.same({ "C" }, r.hunks[2].new_lines) -- was hunk 3
    end)

    it("carries the model's identity fields through the rebuild", function()
        local m = diff.build({
            path = "x.lua",
            old_rev = "HEAD",
            new_rev = "INDEX",
            old_text = "a\nb\n",
            new_text = "a\nB\n",
            head = "main",
            root = "/repo",
        })

        local r = diff.revert_hunk(m, 1)
        assert.are.equal("x.lua", r.path)
        assert.are.equal("HEAD", r.old_rev)
        assert.are.equal("INDEX", r.new_rev)
        assert.are.equal("main", r.head)
        assert.are.equal("/repo", r.root)
    end)
end)
