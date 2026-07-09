-- runs under headless nvim: exercises the overview<->review navigation loop (thread
-- jump, go-to-overview, e/q round-trips) against a stubbed sidecar. same harness
-- pattern as pr_spec.lua: stub differ.sidecar.request per-method, boot a real session,
-- fire buffer-local keymaps, poll observable state with vim.wait (never sleep)

require("differ").setup({})

local sidecar = require("differ.sidecar")
local pr = require("differ.pr")

---@param responses table<string, { result: any, err: table|nil }>
local function stub_sidecar(responses)
    local real = sidecar.request
    sidecar.request = function(method, _params, cb)
        local r = responses[method]
        vim.schedule(function()
            if r then
                cb(r.err, r.result)
            else
                cb(nil, {})
            end
        end)
    end
    return function()
        sidecar.request = real
    end
end

local PR = { owner = "acme", repo = "widget", number = 7 }

-- one file, one unresolved thread anchored on the changed (new-side) line 2
local THREAD_LINE = 2

---@param overrides table|nil
local function get_pr_result(overrides)
    return vim.tbl_extend("force", {
        title = "add widget",
        body = "",
        author = "octocat",
        base_sha = "aaa1111",
        head_sha = "bbb2222",
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
        },
    }, overrides or {})
end

local function threads_result()
    return {
        {
            id = "t1",
            thread_id = "th_1",
            path = "a.txt",
            side = "RIGHT",
            line = THREAD_LINE,
            resolved = false,
            is_pending = false,
            comments = {
                {
                    id = "c1",
                    node_id = "gid1",
                    author = "reviewer",
                    body = "please fix",
                    created_at = "2026-01-01T00:00:00Z",
                },
            },
        },
    }
end

-- the standard fixture set for a session with one unresolved thread on a.txt:2
local function default_responses()
    return {
        get_pr = { result = get_pr_result() },
        get_file_versions = {
            result = { base = { content = "a\nb\nc\n" }, head = { content = "a\nB\nc\n" } },
        },
        get_threads = { result = threads_result() },
        get_timeline = { result = { comments = {}, reviews = {} } },
        get_checks = { result = { rollup = "SUCCESS", checks = {} } },
    }
end

-- fire a buffer-local keymap by its description (mergetool_spec.lua / pr_spec.lua)
local function fire(buf, desc)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.desc == desc and m.callback then
            m.callback()
            return true
        end
    end
    return false
end

-- fire a buffer-local keymap by its lhs (the overview's <CR>/e/q carry no desc)
local function fire_lhs(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == lhs and m.callback then
            m.callback()
            return true
        end
    end
    return false
end

---@return integer  -- -1 when the buffer doesn't exist yet
local function overview_buf()
    return vim.fn.bufnr("^differ://overview$")
end

-- the overview buffer's changedtick, or -1 before it first exists. the page is a
-- single reused scratch buffer (differ.pr.overview), so a fresh render is only
-- detectable by tick, not by content: a go-hop repaints the same text
---@return integer
local function overview_tick()
    local buf = overview_buf()
    return buf ~= -1 and vim.api.nvim_buf_get_changedtick(buf) or -1
end

-- the row of the first buffer line containing `needle`, or nil
---@param buf integer
---@param needle string
---@return integer|nil
local function row_containing(buf, needle)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
        if l:find(needle, 1, true) then
            return i
        end
    end
    return nil
end

-- wait for the overview buffer to (re)paint past `before`'s tick, landing the
-- thread section + header
---@param before integer
local function wait_overview(before)
    assert.is_true(vim.wait(1000, function()
        local buf = overview_buf()
        return buf ~= -1
            and vim.api.nvim_buf_get_changedtick(buf) ~= before
            and row_containing(buf, "threads:") ~= nil
    end))
end

-- land a fresh session on the overview home, waiting for the timeline + thread
-- section to finish painting
---@param responses table
---@return fun() restore
local function open_overview(responses)
    local before = overview_tick()
    local restore = stub_sidecar(responses)
    pr.show(PR, { land = "overview" })
    wait_overview(before)
    return restore
end

-- from a live overview, enter the review at the thread anchor via <CR>, waiting for
-- the diff to land and the one-shot focus to be consumed
local function enter_at_thread()
    local buf = overview_buf()
    local row = row_containing(buf, "commented on a.txt:" .. THREAD_LINE)
    assert.is_truthy(row)
    vim.api.nvim_win_set_cursor(pr.current_session().overview_win, { row, 0 })
    assert.is_true(fire_lhs(buf, "<CR>"))
    assert.is_true(vim.wait(1000, function()
        local s = pr.current_session()
        return s ~= nil and s.view ~= nil and s.view:is_open() and s.pending_focus == nil
    end))
end

describe("pr overview <-> review navigation loop", function()
    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
    end)

    it("lands on the overview with the thread section and a correct header count", function()
        local restore = open_overview(default_responses())

        local buf = overview_buf()
        assert.is_truthy(row_containing(buf, "threads: 1 unresolved / 1"))
        assert.is_truthy(row_containing(buf, "commented on a.txt:" .. THREAD_LINE))
        assert.is_truthy(row_containing(buf, "unresolved"))

        restore()
    end)

    it("<CR> on a thread row enters the review with the cursor on the anchored diff row", function()
        local restore = open_overview(default_responses())

        enter_at_thread()

        local s = pr.current_session()
        local col = s.view:column_for("new")
        local want = col.map.from_new[THREAD_LINE]
        assert.is_truthy(want)
        assert.are.equal(want, vim.api.nvim_win_get_cursor(col.winid)[1])

        restore()
    end)

    it("go from the diff lands back on the overview, session alive, panel closed", function()
        local restore = open_overview(default_responses())
        enter_at_thread()

        local s = pr.current_session()
        local diff_buf = s.view:column_for("new").bufnr
        local before = overview_tick()
        assert.is_true(fire(diff_buf, "PR overview"))
        wait_overview(before)

        assert.are.equal(s, pr.current_session())
        assert.is_false(s.panel:is_open())

        restore()
    end)

    it("re-entering via e restores the stashed diff position", function()
        local restore = open_overview(default_responses())

        -- e: enter the files at the panel's current (first) file, no thread jump
        assert.is_true(fire_lhs(overview_buf(), "e"))
        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s ~= nil and s.view ~= nil and s.view:is_open()
        end))

        local s = pr.current_session()
        local col = s.view:column_for("new")
        local target_row = col.map.from_new[3] -- the unchanged "c" line, distinct from the thread line
        assert.is_truthy(target_row)
        vim.api.nvim_win_set_cursor(col.winid, { target_row, 0 })

        local before = overview_tick()
        assert.is_true(fire(col.bufnr, "PR overview"))
        wait_overview(before)

        assert.is_true(fire_lhs(overview_buf(), "e"))
        assert.is_true(vim.wait(1000, function()
            return s.view ~= nil and s.view:is_open() and s.pending_focus == nil
        end))

        -- the view re-sources on re-entry, so re-read the column rather than reusing `col`
        local reentered = s.view:column_for("new")
        assert.are.equal(reentered.map.from_new[3], vim.api.nvim_win_get_cursor(reentered.winid)[1])

        restore()
    end)

    it("q ends a fresh pre-review session, but re-enters the review after a go-hop", function()
        local restore = open_overview(default_responses())
        assert.is_true(fire_lhs(overview_buf(), "q"))
        assert.is_nil(pr.current_session())
        restore()

        restore = open_overview(default_responses())
        assert.is_true(fire_lhs(overview_buf(), "e")) -- build the panel
        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s ~= nil and s.view ~= nil and s.view:is_open()
        end))
        local s = pr.current_session()
        local before = overview_tick()
        assert.is_true(fire(s.view:column_for("new").bufnr, "PR overview")) -- go-hop
        wait_overview(before)

        assert.is_true(fire_lhs(overview_buf(), "q"))
        assert.is_true(vim.wait(1000, function()
            return pr.current_session() == s and s.panel ~= nil and s.panel:is_open()
        end))

        restore()
    end)
end)
