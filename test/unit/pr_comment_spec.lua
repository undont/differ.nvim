local comment = require("differ.pr.comment")

-- a fixture line map: only `.lines[row] = { kind, old, new }` is read by the anchor
-- helpers, so a plain table stands in for a rendered LineMap. a unified (stacked)
-- column interleaves context / deletion / addition; meta is filler with no diff line
local UNIFIED = {
    lines = {
        [1] = { kind = "context", old = 1, new = 1 },
        [2] = { kind = "old", old = 2 }, -- a deletion (left side only)
        [3] = { kind = "new", new = 2 }, -- an addition (right side only)
        [4] = { kind = "meta" }, -- filler, no anchor
        [5] = { kind = "context", old = 3, new = 3 },
        [6] = { kind = "new", new = 4 },
        [7] = { kind = "old", old = 4 },
    },
}

describe("pr.comment.row_anchor (single)", function()
    it("anchors an addition row to RIGHT/new", function()
        assert.are.same({ side = "RIGHT", line = 2 }, comment.row_anchor(UNIFIED, 3, "unified"))
    end)

    it("anchors a deletion row to LEFT/old", function()
        assert.are.same({ side = "LEFT", line = 2 }, comment.row_anchor(UNIFIED, 2, "unified"))
    end)

    it("prefers the new side on a context row", function()
        assert.are.same({ side = "RIGHT", line = 1 }, comment.row_anchor(UNIFIED, 1, "unified"))
    end)

    it("rejects a meta / no-partner row", function()
        local anchor, err = comment.row_anchor(UNIFIED, 4, "unified")
        assert.is_nil(anchor)
        assert.is_truthy(err)
    end)

    it("a split column is single-sided", function()
        assert.are.same({ side = "LEFT", line = 2 }, comment.row_anchor(UNIFIED, 2, "old"))
        -- the new column has no `new` on a deletion row, so it rejects
        assert.is_nil(comment.row_anchor(UNIFIED, 2, "new"))
    end)
end)

describe("pr.comment.range_anchor", function()
    it("builds a same-side range with start_line < line", function()
        local a = comment.range_anchor(UNIFIED, 3, 5, "unified") -- new/2 .. context/3 (RIGHT)
        assert.are.same({ start_side = "RIGHT", start_line = 2, side = "RIGHT", line = 3 }, a)
    end)

    it("allows a LEFT -> RIGHT replacement range", function()
        local a = comment.range_anchor(UNIFIED, 2, 3, "unified") -- old/2 .. new/2
        assert.are.same({ start_side = "LEFT", start_line = 2, side = "RIGHT", line = 2 }, a)
    end)

    it("rejects a RIGHT -> LEFT selection GitHub can't represent", function()
        local a, err = comment.range_anchor(UNIFIED, 6, 7, "unified") -- new .. old (top-down)
        assert.is_nil(a)
        assert.is_truthy(err and err:find("mixed-side", 1, true))
    end)

    it("collapses a single-row selection to a single anchor", function()
        assert.are.same(
            { side = "RIGHT", line = 2 },
            comment.range_anchor(UNIFIED, 3, 3, "unified")
        )
    end)

    it("rejects when an endpoint has no anchor", function()
        assert.is_nil(comment.range_anchor(UNIFIED, 3, 4, "unified")) -- row 4 is meta
    end)
end)

-- the compose window is a real split, not a modal, so the diff can be navigated (or
-- closed) between the gesture and the submit. the anchor's path is fixed with its
-- side/line at gesture time, and post reads that rather than whatever the view shows now
describe("pr.comment.post anchors to the gesture's file", function()
    local client = require("differ.pr.client")

    ---@return table args, fun() restore
    local function capture()
        local real = client.post_comment
        local box = {}
        ---@diagnostic disable-next-line: duplicate-set-field
        client.post_comment = function(_pr, args, _cb)
            box.args = args
        end
        return box, function()
            client.post_comment = real
        end
    end

    local function session(view_path)
        return {
            pr = { owner = "acme", repo = "widget", number = 7 },
            pr_meta = { head_sha = "bbb2222" },
            view = view_path and { model = { path = view_path } } or nil,
        }
    end

    it("posts to the gestured file even after the diff moved on", function()
        local box, restore = capture()
        local opts = { anchor = { side = "RIGHT", line = 2 }, path = "a.txt" }
        comment.post(session("b.txt"), opts, "looks wrong") -- view now shows b.txt
        assert.are.equal("a.txt", box.args.path)
        assert.are.equal("RIGHT", box.args.side)
        assert.are.equal(2, box.args.line)
        restore()
    end)

    it("posts to the gestured file even after the diff closed", function()
        local box, restore = capture()
        local opts = { anchor = { side = "RIGHT", line = 2 }, path = "a.txt" }
        comment.post(session(nil), opts, "still fine") -- no view at all
        assert.are.equal("a.txt", box.args.path)
        restore()
    end)

    -- the guard is for anchored posts: path/side/line mean something else at a moved
    -- head. a reply targets a thread node id, so pinning the head only buys it a bounced
    -- submit and a forced diff re-source every time someone pushes
    it("pins the head on a new thread but not on a reply", function()
        local box, restore = capture()
        comment.post(
            session("a.txt"),
            { anchor = { side = "RIGHT", line = 2 }, path = "a.txt" },
            "new"
        )
        assert.are.equal("bbb2222", box.args.expected_head)

        comment.post(session("a.txt"), { in_reply_to = "PRRT_1" }, "reply")
        assert.is_nil(box.args.expected_head)
        assert.are.equal("PRRT_1", box.args.in_reply_to)
        restore()
    end)

    it("carries the path through the conflict re-prompt's opts", function()
        local box, restore = capture()
        local opts = { anchor = { side = "RIGHT", line = 2 }, path = "a.txt" }
        -- the shape tbl_extend produces in the conflict path, built without vim here
        local reprompt = { initial = "body", stale = true }
        for k, v in pairs(opts) do
            reprompt[k] = v
        end
        comment.post(session("b.txt"), reprompt, "body")
        assert.are.equal("a.txt", box.args.path)
        restore()
    end)
end)
