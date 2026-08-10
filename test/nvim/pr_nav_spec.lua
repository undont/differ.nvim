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

    it("e on a thread row enters the review at that thread's anchored diff row", function()
        local restore = open_overview(default_responses())

        local buf = overview_buf()
        local row = row_containing(buf, "commented on a.txt:" .. THREAD_LINE)
        assert.is_truthy(row)
        vim.api.nvim_win_set_cursor(pr.current_session().overview_win, { row, 0 })
        assert.is_true(fire_lhs(buf, "e"))
        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s ~= nil and s.view ~= nil and s.view:is_open() and s.pending_focus == nil
        end))

        local s = pr.current_session()
        local col = s.view:column_for("new")
        assert.are.equal(col.map.from_new[THREAD_LINE], vim.api.nvim_win_get_cursor(col.winid)[1])

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

    -- the page render is several async hops long, and `:Differ pr <n>` straight into
    -- `:Differ pr view` leaves the session in the files while the last hop is still out.
    -- rendering then would take the window back and close the diff just built
    it("an overview render still in flight doesn't take the window back", function()
        local responses = default_responses()
        local release -- the held get_checks callback, the last hop before render
        local real = sidecar.request
        sidecar.request = function(method, params, cb)
            if method == "get_checks" and not release then
                release = function()
                    vim.schedule(function()
                        cb(nil, responses.get_checks.result)
                    end)
                end
                return
            end
            vim.schedule(function()
                local r = responses[method]
                cb(r and r.err or nil, (r and r.result) or {})
            end)
        end

        pr.show(PR, { land = "overview" })
        assert.is_true(vim.wait(2000, function()
            return release ~= nil -- the page is one hop from rendering
        end))

        pr.view({ number = PR.number }) -- enter the files while that hop is outstanding
        local s = pr.current_session()
        assert.is_true(vim.wait(2000, function()
            return s.view ~= nil and s.view:is_open()
        end))

        release() -- the superseded page render lands
        vim.wait(300)

        assert.is_truthy(s.view and s.view:is_open()) -- the diff survived it
        assert.is_true(s.panel:is_open())
        assert.are.equal(s, pr.current_session())

        sidecar.request = real
    end)

    -- a mutation submitted from the overview can conflict, and its refetch lands with
    -- the view nil'd and the sidebar hidden: state has to reconcile, but re-sourcing the
    -- diff there would build a fresh view over the page the user is reading
    it("a conflict refetch on the overview reconciles state without rebuilding the diff", function()
        local responses = default_responses()
        local restore = open_overview(responses)
        enter_at_thread()

        local s = pr.current_session()
        local diff_buf = s.view:column_for("new").bufnr
        local before = overview_tick()
        assert.is_true(fire(diff_buf, "PR overview")) -- go-hop
        wait_overview(before)
        assert.is_nil(s.view)
        assert.is_false(s.panel:is_open())

        s.versions["a.txt"] = { base = {}, head = {} } -- a memo pinned to the old head
        responses.get_pr = { result = get_pr_result({ head_sha = "ccc3333" }) }
        pr.handle_conflict()

        assert.is_true(vim.wait(1000, function()
            return s.pr_meta.head_sha == "ccc3333"
        end))
        assert.are.same({}, s.versions) -- the stale memo dropped
        assert.is_nil(s.threads)
        assert.is_nil(s.view) -- and nothing drawn over the page
        assert.are.equal(overview_buf(), vim.api.nvim_win_get_buf(s.overview_win))

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

    it("Ctrl-O onto the overview re-enters the page, session alive", function()
        local restore = open_overview(default_responses())
        enter_at_thread()

        local s = pr.current_session()
        local col = s.view:column_for("new")
        local ov = overview_buf()
        local before = overview_tick()
        -- simulate the Ctrl-O jump: the overview buffer swaps back into the diff window,
        -- which fires the diff's BufWinLeave close guard
        vim.api.nvim_win_set_buf(col.winid, ov)
        wait_overview(before)

        assert.are.equal(s, pr.current_session()) -- not torn down
        assert.is_false(s.panel:is_open()) -- hidden; we're on the page
        assert.is_nil(s.view) -- the review view was closed on the hop

        restore()
    end)

    it("]t/[t hop the cursor between thread boxes", function()
        local responses = default_responses()
        local threads = threads_result()
        threads[2] = {
            id = "t2",
            thread_id = "th_2",
            path = "a.txt",
            side = "RIGHT",
            line = 3,
            resolved = false,
            is_pending = false,
            comments = {
                {
                    id = "c2",
                    node_id = "gid2",
                    author = "reviewer",
                    body = "and this",
                    created_at = "2026-01-02T00:00:00Z",
                },
            },
        }
        responses.get_threads = { result = threads }
        local restore = open_overview(responses)

        local buf = overview_buf()
        local first = row_containing(buf, "commented on a.txt:" .. THREAD_LINE)
        local second = row_containing(buf, "commented on a.txt:3")
        assert.is_truthy(first)
        assert.is_truthy(second)

        local win = pr.current_session().overview_win
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        assert.is_true(fire_lhs(buf, "]t"))
        assert.are.equal(first, vim.api.nvim_win_get_cursor(win)[1])
        assert.is_true(fire_lhs(buf, "]t"))
        assert.are.equal(second, vim.api.nvim_win_get_cursor(win)[1])
        assert.is_true(fire_lhs(buf, "[t"))
        assert.are.equal(first, vim.api.nvim_win_get_cursor(win)[1])

        restore()
    end)

    it("q no-ops pre-review, but re-enters the review after a go-hop", function()
        local restore = open_overview(default_responses())
        assert.is_true(fire_lhs(overview_buf(), "q"))
        assert.is_not_nil(pr.current_session())
        pr.end_session()
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

-- enter the review at the panel's first file (the overview's e), waiting for the diff
local function enter_review()
    assert.is_true(fire_lhs(overview_buf(), "e"))
    assert.is_true(vim.wait(1000, function()
        local s = pr.current_session()
        return s ~= nil and s.view ~= nil and s.view:is_open()
    end))
    return pr.current_session()
end

-- a throwaway worktree holding `rel` on disk, so the edit verbs (which open the real
-- file at model.root/path) have something readable. redirect the view's model.root here
---@param rel string
---@param content string
local function make_worktree_file(rel, content)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local abs = root .. "/" .. rel
    local f = assert(io.open(abs, "w"))
    f:write(content)
    f:close()
    return {
        root = root,
        abs = abs,
        cleanup = function()
            vim.fn.delete(root, "rf")
        end,
    }
end

describe("pr overview cursor + window-close guard", function()
    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
    end)

    it("a go-hop back restores the page cursor where the review was entered", function()
        local restore = open_overview(default_responses())
        local buf = overview_buf()
        local win = pr.current_session().overview_win
        assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(win)) -- fresh open: top

        local row = row_containing(buf, "commented on a.txt:" .. THREAD_LINE)
        assert.is_truthy(row)
        vim.api.nvim_win_set_cursor(win, { row, 2 })
        local s = enter_review()

        local before = overview_tick()
        assert.is_true(fire(s.view:column_for("new").bufnr, "PR overview"))
        wait_overview(before)
        assert.are.same({ row, 2 }, vim.api.nvim_win_get_cursor(s.overview_win))

        -- q back into the review stashes afresh, so a second hop restores the new spot
        local header = row_containing(buf, "threads:")
        assert.is_truthy(header)
        vim.api.nvim_win_set_cursor(s.overview_win, { header, 0 })
        assert.is_true(fire_lhs(buf, "q"))
        assert.is_true(vim.wait(1000, function()
            return s.view ~= nil and s.view:is_open()
        end))

        before = overview_tick()
        assert.is_true(fire(s.view:column_for("new").bufnr, "PR overview"))
        wait_overview(before)
        assert.are.same({ header, 0 }, vim.api.nvim_win_get_cursor(s.overview_win))

        restore()
    end)

    it("closing the page window pre-review ends the session", function()
        local restore = open_overview(default_responses())
        vim.api.nvim_win_close(pr.current_session().overview_win, true)
        assert.is_true(vim.wait(1000, function()
            return pr.current_session() == nil
        end))
        restore()
    end)

    it("closing the page window with a live review also ends the session", function()
        local restore = open_overview(default_responses())
        local s = enter_review()
        local before = overview_tick()
        assert.is_true(fire(s.view:column_for("new").bufnr, "PR overview"))
        wait_overview(before)

        vim.api.nvim_win_close(s.overview_win, true)
        assert.is_true(vim.wait(1000, function()
            return pr.current_session() == nil
        end))
        restore()
    end)
end)

-- descriptions of the two edit binds on the diff surface (see session.diff_extra_keymaps)
local EDIT_SPLIT = "edit the real file (in review)"
local EDIT_ZOOM = "edit the real file (zoom tab)"

describe("pr edit verbs (df/de)", function()
    local review_tab

    after_each(function()
        -- drop any stray zoom tabs the test left open before tearing the session down
        review_tab = nil
        for _, t in ipairs(vim.api.nvim_list_tabpages()) do
            if t ~= vim.api.nvim_list_tabpages()[1] and vim.api.nvim_tabpage_is_valid(t) then
                pcall(vim.api.nvim_set_current_tabpage, t)
                pcall(vim.cmd, "tabclose")
            end
        end
        if pr.current_session() then
            pr.end_session()
        end
    end)

    it("df opens the worktree file in a split beside the diff, session.view untouched", function()
        local restore = open_overview(default_responses())
        local s = enter_review()
        local tmp = make_worktree_file("a.txt", "a\nB\nc\n")
        s.view.model.root = tmp.root

        local view = s.view
        local diff_buf = view:column_for("new").bufnr
        local tabs_before = #vim.api.nvim_list_tabpages()
        local wins_before = #vim.api.nvim_tabpage_list_wins(0)

        assert.is_true(fire(diff_buf, EDIT_SPLIT))

        -- a split in the same tab, not a new tab
        assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        assert.is_true(#vim.api.nvim_tabpage_list_wins(0) > wins_before)
        -- the edit window holds the real file, distinct from the diff buffer
        local edit_buf = vim.api.nvim_win_get_buf(view.edit_win)
        assert.are_not.equal(diff_buf, edit_buf)
        assert.is_truthy(vim.api.nvim_buf_get_name(edit_buf):match("a%.txt$"))
        -- the session + its view are the same objects, still open
        assert.are.equal(s, pr.current_session())
        assert.are.equal(view, s.view)
        assert.is_true(view:is_open())

        tmp.cleanup()
        restore()
    end)

    it("de zoom-edits in its own tab; closing it returns to the review tab", function()
        local restore = open_overview(default_responses())
        local s = enter_review()
        local tmp = make_worktree_file("a.txt", "a\nB\nc\n")
        s.view.model.root = tmp.root
        review_tab = vim.api.nvim_get_current_tabpage()

        local view = s.view
        assert.is_true(fire(view:column_for("new").bufnr, EDIT_ZOOM))

        local zoom_tab = view.zoom_tab
        assert.is_truthy(zoom_tab)
        assert.is_true(vim.api.nvim_tabpage_is_valid(zoom_tab))
        assert.are.equal(zoom_tab, vim.api.nvim_get_current_tabpage())
        assert.are_not.equal(review_tab, zoom_tab)
        assert.is_truthy(vim.api.nvim_buf_get_name(0):match("a%.txt$"))

        -- :q the zoom tab lands back on the review tab (the return hop is scheduled)
        vim.cmd("tabclose")
        assert.is_true(vim.wait(1000, function()
            return vim.api.nvim_get_current_tabpage() == review_tab
        end))

        tmp.cleanup()
        restore()
    end)

    it("a repeat de while the zoom tab is open refocuses instead of stacking tabs", function()
        local restore = open_overview(default_responses())
        local s = enter_review()
        local tmp = make_worktree_file("a.txt", "a\nB\nc\n")
        s.view.model.root = tmp.root
        review_tab = vim.api.nvim_get_current_tabpage()

        local view = s.view
        local diff_buf = view:column_for("new").bufnr
        assert.is_true(fire(diff_buf, EDIT_ZOOM))
        local zoom_tab = view.zoom_tab
        local tabs_after_first = #vim.api.nvim_list_tabpages()

        -- back on the review, press de again: the same zoom tab is refocused
        vim.api.nvim_set_current_tabpage(review_tab)
        assert.is_true(fire(diff_buf, EDIT_ZOOM))

        assert.are.equal(zoom_tab, view.zoom_tab)
        assert.are.equal(zoom_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(tabs_after_first, #vim.api.nvim_list_tabpages())

        tmp.cleanup()
        restore()
    end)

    it("df on the overview (no open diff) notifies and no-ops", function()
        local restore = open_overview(default_responses())
        local s = pr.current_session()
        assert.is_nil(s.view) -- pre-review page: no diff yet

        local before = #_G.notifs
        pr.edit_split()

        assert.is_true(#_G.notifs > before)
        assert.is_truthy(_G.notifs[#_G.notifs].msg:find("no active pull request diff", 1, true))

        restore()
    end)

    it("df without a local checkout (no session.root) notifies and no-ops", function()
        local restore = open_overview(default_responses())
        local s = enter_review()
        s.root = nil -- simulate a repo with no local checkout

        local before = #_G.notifs
        pr.edit_split()

        assert.is_truthy(_G.notifs[#_G.notifs].msg:find("editing needs a local checkout", 1, true))
        assert.is_nil(s.view.edit_win) -- no edit window opened
        assert.is_true(#_G.notifs > before)

        restore()
    end)
end)

describe("pr overview resilient navigation", function()
    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
    end)

    -- a thread anchored on a path the PR's file list doesn't carry (a comment on a file
    -- outside the diff). the anchor jump can't land it, so entry must fall back to the
    -- panel's own file rather than erroring, and clear the one-shot focus
    local function ghost_responses()
        local responses = default_responses()
        local threads = threads_result()
        threads[1].path = "ghost.txt"
        threads[1].line = 5
        responses.get_threads = { result = threads }
        return responses
    end

    it("<CR> on an out-of-list thread falls back to the panel entry, focus cleared", function()
        local restore = open_overview(ghost_responses())

        local buf = overview_buf()
        local row = row_containing(buf, "commented on ghost.txt:5")
        assert.is_truthy(row)
        vim.api.nvim_win_set_cursor(pr.current_session().overview_win, { row, 0 })
        assert.is_true(fire_lhs(buf, "<CR>"))

        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s ~= nil and s.view ~= nil and s.view:is_open()
        end))
        local s = pr.current_session()
        assert.is_nil(s.pending_focus) -- the failed jump cleared the one-shot
        assert.are.equal("a.txt", s.view.model.path) -- landed on the panel's real file

        restore()
    end)

    it("e on an out-of-list thread falls back without error, focus cleared", function()
        local restore = open_overview(ghost_responses())

        local buf = overview_buf()
        local row = row_containing(buf, "commented on ghost.txt:5")
        assert.is_truthy(row)
        vim.api.nvim_win_set_cursor(pr.current_session().overview_win, { row, 0 })
        assert.is_true(fire_lhs(buf, "e"))

        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s ~= nil and s.view ~= nil and s.view:is_open()
        end))
        local s = pr.current_session()
        assert.is_nil(s.pending_focus)
        assert.are.equal("a.txt", s.view.model.path)

        restore()
    end)
end)

-- the sole floating window (relative ~= ""), or nil
local function float_win()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
            return w
        end
    end
end

describe("pr overview cheatsheet (g?)", function()
    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
    end)

    it("g? floats the keymap help; q dismisses it", function()
        local restore = open_overview(default_responses())

        assert.is_nil(float_win())
        assert.is_true(fire_lhs(overview_buf(), "g?"))

        local float = float_win()
        assert.is_truthy(float)
        local fbuf = vim.api.nvim_win_get_buf(float)
        local text = table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
        assert.is_truthy(text:find("enter review", 1, true))
        assert.is_truthy(text:find("this help", 1, true))

        assert.is_true(fire_lhs(fbuf, "q")) -- the float's own dismiss key
        assert.is_false(vim.api.nvim_win_is_valid(float))

        restore()
    end)
end)
