-- runs under headless nvim: a get_file_versions issued before handle_conflict must not
-- land its old-sha blob in the memo the conflict cleared, and the file refetches at the
-- fresh pins. same harness pattern as pr_nav_spec.lua: stub differ.sidecar.request per
-- method, boot a real session, hold one request in flight by capturing its cb

require("differ").setup({})

local sidecar = require("differ.sidecar")
local pr = require("differ.pr")

local PR = { owner = "acme", repo = "widget", number = 7 }

local OLD_BASE, OLD_HEAD = "aaa1111", "bbb2222"
local NEW_BASE, NEW_HEAD = "ccc3333", "ddd4444"

local BASE_CONTENT = "shared-line\n"
local OLD_HEAD_CONTENT = "shared-line\nSTALE-PRE-MOVE-LINE\n"

---@param base string
---@param head string
local function get_pr_result(base, head)
    return {
        title = "add widget",
        body = "",
        author = "octocat",
        base_sha = base,
        head_sha = head,
        head_ref = "feature",
        url = "https://example.test/acme/widget/pull/7",
        state = "open",
        draft = false,
        mergeable = "MERGEABLE",
        files = {
            {
                path = "a.txt",
                status = "modified",
                additions = 1,
                deletions = 1,
                viewed_state = "UNVIEWED",
            },
            {
                path = "b.txt",
                status = "modified",
                additions = 1,
                deletions = 1,
                viewed_state = "UNVIEWED",
            },
        },
    }
end

-- stub the sidecar, holding every get_file_versions for `hold_path` in flight: its cb
-- is captured with the refs it was issued under, for the test to fire on demand
---@param hold_path string
local function stub_sidecar(hold_path)
    local real = sidecar.request
    local held = {}
    local pr_detail = get_pr_result(OLD_BASE, OLD_HEAD)
    sidecar.request = function(method, params, cb)
        if method == "get_file_versions" and params.path == hold_path then
            held[#held + 1] = { cb = cb, base = params.base, head = params.head }
            return
        end
        vim.schedule(function()
            if method == "get_pr" then
                cb(nil, pr_detail)
            elseif method == "get_file_versions" then
                cb(nil, { base = { content = "a\n" }, head = { content = "b\n" } })
            elseif method == "get_threads" then
                cb(nil, {})
            elseif method == "get_timeline" then
                cb(nil, { comments = {}, reviews = {} })
            elseif method == "get_checks" then
                cb(nil, { rollup = "SUCCESS", checks = {} })
            else
                cb(nil, {})
            end
        end)
    end
    return {
        restore = function()
            sidecar.request = real
        end,
        -- what the next get_pr answers; handle_conflict reads the moved head from here
        move_head = function()
            pr_detail = get_pr_result(NEW_BASE, NEW_HEAD)
        end,
        held = held,
    }
end

describe("pr blob memo across a conflict refresh", function()
    local restore

    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
        if restore then
            restore() -- after the teardown, so its requests still meet the stub
        end
        restore = nil
    end)

    -- open a session on a.txt with the b.txt prefetch held in flight, then move the head
    -- and let handle_conflict refresh the pins. returns the stub handle, the live session
    -- and the held pre-move fetch
    local function conflict_over_inflight_blob()
        local h = stub_sidecar("b.txt")
        restore = h.restore
        pr.show(PR, { land = "files" })
        assert.is_true(
            vim.wait(1000, function()
                local s = pr.current_session()
                return s ~= nil and s.panel ~= nil and #h.held > 0
            end),
            "expected a held get_file_versions for b.txt"
        )

        local s = pr.current_session()
        local inflight = h.held[1]
        assert.are.equal(OLD_HEAD, inflight.head) -- issued under the original pins

        h.move_head()
        local refreshed = false
        pr.handle_conflict(function()
            refreshed = true
        end)
        assert.is_true(
            vim.wait(1000, function()
                return refreshed
            end),
            "handle_conflict never completed"
        )
        return h, s, inflight
    end

    -- answer the held fetch with what b.txt looked like before the head moved
    local function land_stale(inflight)
        inflight.cb(
            nil,
            { base = { content = BASE_CONTENT }, head = { content = OLD_HEAD_CONTENT } }
        )
        vim.wait(50)
    end

    it("drops a blob fetched at the pins the conflict replaced", function()
        local _, s, inflight = conflict_over_inflight_blob()

        assert.are.equal(NEW_HEAD, s.pr_meta.head_sha) -- pins moved
        assert.is_nil(s.versions["b.txt"]) -- the memo was cleared

        land_stale(inflight)

        assert.is_nil(s.versions["b.txt"], "a pre-move blob landed in the memo")
    end)

    it("refetches the file at the refreshed shas instead of serving the stale blob", function()
        local h, _, inflight = conflict_over_inflight_blob()
        land_stale(inflight)

        assert.is_true(pr.goto_anchor({ path = "b.txt", side = "RIGHT", line = 1 }))
        assert.is_true(
            vim.wait(1000, function()
                return #h.held > 1 -- a fresh fetch at the new pins, not a memo hit
            end),
            "b.txt was served from the memo rather than refetched"
        )
        assert.are.equal(NEW_HEAD, h.held[2].head)
    end)
end)
