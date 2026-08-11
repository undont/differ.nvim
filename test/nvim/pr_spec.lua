-- runs under headless nvim: exercises the pr session frontend against a stubbed
-- sidecar. every pr/*.lua module only ever reaches the outside world through
-- differ.sidecar.request (see pr/client.lua), so stubbing that one seam is enough to
-- drive a real session (get_pr -> open_session -> panel + diff) without a Go subprocess

require("differ").setup({})

local sidecar = require("differ.sidecar")
local pr = require("differ.pr")

-- replace differ.sidecar.request for the duration of a test, dispatching by method
-- name to a canned `{result, err}` per method (missing method -> empty result), and
-- scheduling the callback like the real client does. returns a restore() to undo it
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
        mergeable = true,
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

-- fire a buffer-local keymap by its description, so a test doesn't depend on <leader>
-- (same pattern as mergetool_spec.lua)
local function fire(buf, desc)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.desc == desc and m.callback then
            m.callback()
            return true
        end
    end
    return false
end

-- fire a buffer-local keymap by its lhs (the checks float sets no desc on <CR>/o)
local function fire_lhs(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == lhs and m.callback then
            m.callback()
            return true
        end
    end
    return false
end

describe("pr session notifies", function()
    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
    end)

    -- get_pr fetches the whole file list, so a big PR answers slower than a small one
    -- asked for after it. the open the user made last is the one they meant
    it("lands on the PR opened last even when its response arrives first", function()
        local pending = {} -- get_pr callbacks, released by hand
        local real = sidecar.request
        sidecar.request = function(method, params, cb)
            if method == "get_pr" then
                pending[params.number] = function()
                    cb(nil, get_pr_result({ title = "pr " .. params.number }))
                end
                return
            end
            vim.schedule(function()
                cb(nil, method == "get_file_versions" and { base = {}, head = {} } or {})
            end)
        end

        pr.show({ owner = "acme", repo = "widget", number = 10 })
        pr.show({ owner = "acme", repo = "widget", number = 20 })
        assert.is_truthy(pending[10] and pending[20])

        pending[20]() -- the one the user asked for last answers first
        pending[10]() -- the superseded, slower one lands after

        assert.is_true(vim.wait(1000, function()
            return pr.current_session() ~= nil
        end))
        assert.are.equal(20, pr.current_session().pr.number)

        sidecar.request = real
    end)

    -- the neighbour prefetch is speculative and outlives the session that issued it, so
    -- its callback has to prove the session is still the live one before writing the memo
    it("a prefetch landing after a PR switch stays out of the new session's memo", function()
        -- disjoint file sets, so b.txt can only reach PR 8's memo by contamination
        local function files_for(number)
            local names = number == 7 and { "a.txt", "b.txt" } or { "c.txt", "d.txt" }
            local out = {}
            for _, path in ipairs(names) do
                out[#out + 1] = { path = path, status = "modified", additions = 1, deletions = 1 }
            end
            return out
        end
        local held -- b.txt's blob, released by hand after the switch
        local real = sidecar.request
        sidecar.request = function(method, params, cb)
            if method == "get_file_versions" and params.path == "b.txt" and not held then
                held = function()
                    cb(nil, { base = { content = "stale\n" }, head = { content = "STALE\n" } })
                end
                return
            end
            vim.schedule(function()
                if method == "get_pr" then
                    return cb(nil, get_pr_result({ files = files_for(params.number) }))
                elseif method == "get_file_versions" then
                    return cb(nil, { base = { content = "a\n" }, head = { content = "A\n" } })
                end
                cb(nil, {})
            end)
        end

        pr.show(PR)
        assert.is_true(vim.wait(1000, function()
            return held ~= nil -- the first session issued the neighbour prefetch
        end))
        local first = pr.current_session()

        pr.show({ owner = "acme", repo = "widget", number = 8 })
        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s ~= nil and s ~= first
        end))
        local second = pr.current_session()

        held() -- the superseded session's blob finally lands
        assert.is_nil(second.versions["b.txt"])

        sidecar.request = real
    end)

    it("warns when opening a check with no url from the checks float", function()
        local restore = stub_sidecar({
            get_pr = { result = get_pr_result() },
            get_file_versions = {
                result = { base = { content = "a\n" }, head = { content = "b\n" } },
            },
            get_checks = {
                result = {
                    rollup = "FAILURE",
                    checks = { { name = "build", status = "COMPLETED", conclusion = "FAILURE" } },
                },
            },
        })

        pr.show(PR)
        assert.is_true(vim.wait(1000, function()
            return pr.current_session() ~= nil
        end))

        pr.checks()
        assert.is_true(vim.wait(1000, function()
            return vim.api.nvim_win_get_config(0).relative ~= ""
        end))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        _G.notifs = {}
        assert.is_true(fire_lhs(vim.api.nvim_get_current_buf(), "o"))
        assert.are.equal("differ: this check has no url", _G.notifs[#_G.notifs].msg)
        assert.are.equal(vim.log.levels.WARN, _G.notifs[#_G.notifs].level)

        restore()
    end)

    it("notifies 'no thread on this line' toggling a thread off a plain diff line", function()
        local restore = stub_sidecar({
            get_pr = { result = get_pr_result() },
            get_file_versions = {
                result = { base = { content = "a\nb\nc\n" }, head = { content = "a\nB\nc\n" } },
            },
            get_threads = { result = {} },
        })

        pr.show(PR)
        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s and s.view and s.view:is_open()
        end))
        assert.is_true(vim.wait(1000, function()
            return pr.current_session().threads ~= nil
        end))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        _G.notifs = {}
        assert.is_true(fire(vim.api.nvim_get_current_buf(), "toggle thread"))
        assert.are.equal("differ: no thread on this line", _G.notifs[#_G.notifs].msg)

        restore()
    end)

    it("notifies 'no thread on this line' resolving off a plain diff line", function()
        local restore = stub_sidecar({
            get_pr = { result = get_pr_result() },
            get_file_versions = {
                result = { base = { content = "a\nb\nc\n" }, head = { content = "a\nB\nc\n" } },
            },
            get_threads = { result = {} },
        })

        pr.show(PR)
        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s and s.view and s.view:is_open()
        end))
        assert.is_true(vim.wait(1000, function()
            return pr.current_session().threads ~= nil
        end))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        _G.notifs = {}
        assert.is_true(fire(vim.api.nvim_get_current_buf(), "resolve thread"))
        assert.are.equal("differ: no thread on this line", _G.notifs[#_G.notifs].msg)

        restore()
    end)
end)

describe("pr review lifecycle keymaps", function()
    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
    end)

    it("binds submit / discard on both the diff and the panel", function()
        local restore = stub_sidecar({
            get_pr = { result = get_pr_result() },
            get_file_versions = {
                result = { base = { content = "a\n" }, head = { content = "b\n" } },
            },
            get_threads = { result = {} },
        })

        pr.show(PR)
        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s and s.view and s.view:is_open() and s.panel
        end))

        local s = pr.current_session()
        for _, buf in ipairs({ s.view.columns[1].bufnr, s.panel.bufnr }) do
            local km = {}
            for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
                km[m.lhs] = m.desc
            end
            assert.is_truthy(km["gS"]:find("submit the review", 1, true))
            assert.is_truthy(km["gD"]:find("discard the review", 1, true))
            assert.is_nil(km["gR"]) -- entering the review already adopts a pending draft
        end

        restore()
    end)
end)

describe("pr session root", function()
    local function git(cwd, ...)
        local args = { "git", "-c", "user.email=t@t", "-c", "user.name=t" }
        vim.list_extend(args, { ... })
        local res = vim.system(args, { cwd = cwd, text = true }):wait()
        assert(res.code == 0, "git failed: " .. table.concat({ ... }, " "))
        return res.stdout
    end

    -- a repo whose remotes are `urls` keyed by remote name
    ---@param urls table<string, string>
    local function repo_with_remotes(urls)
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git(root, "init", "-q")
        for name, url in pairs(urls) do
            git(root, "remote", "add", name, url)
        end
        return root
    end

    local repo = require("differ.pr.repo")

    it("matches a clone of the pr's repo, whichever remote carries it", function()
        local root = repo_with_remotes({
            origin = "git@github.com:me/widget.git",
            upstream = "https://github.com/acme/widget",
        })
        -- a fork checkout is a legitimate local clone of either side, so both match
        -- even though resolve() would only ever return upstream
        assert.is_true(repo.has_remote(root, { owner = "acme", repo = "widget" }))
        assert.is_true(repo.has_remote(root, { owner = "me", repo = "widget" }))
        assert.is_false(repo.has_remote(root, { owner = "acme", repo = "other" }))
        assert.is_false(repo.has_remote(root, { owner = "other", repo = "widget" }))
    end)

    it("ignores non-github and unparsable remotes", function()
        local root = repo_with_remotes({
            origin = "https://gitlab.com/acme/widget.git",
            weird = "not a url",
        })
        assert.is_false(repo.has_remote(root, { owner = "acme", repo = "widget" }))
    end)

    -- session.root drives the edit verbs (which open root/path as "the real file") and
    -- :Differ pr checkout (which fetches into it), so an unrelated cwd must not set it
    local function show_from(cwd)
        vim.cmd.cd(vim.fn.fnameescape(cwd)) -- global: after_each puts it back
        local restore = stub_sidecar({
            get_pr = { result = get_pr_result() },
            get_file_versions = {
                result = { base = { content = "a\n" }, head = { content = "b\n" } },
            },
            get_threads = { result = {} },
        })
        pr.show(PR)
        assert.is_true(vim.wait(1000, function()
            local s = pr.current_session()
            return s and s.view and s.view:is_open()
        end))
        local s = pr.current_session()
        restore()
        return s
    end

    -- the spec files resolve `require` against a relative package.path, so a leaked cwd
    -- breaks every suite loaded after this one
    local saved_cwd
    before_each(function()
        saved_cwd = vim.fn.getcwd()
    end)
    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
        vim.cmd.cd(vim.fn.fnameescape(saved_cwd))
    end)

    it("takes the cwd's repo when it is a clone of the pr's repo", function()
        local root = repo_with_remotes({ origin = "git@github.com:acme/widget.git" })
        assert.are.equal(vim.fn.resolve(root), vim.fn.resolve(show_from(root).root))
    end)

    it("leaves root nil in an unrelated repo, rather than adopting its files", function()
        local root = repo_with_remotes({ origin = "git@github.com:acme/mine.git" })
        assert.is_nil(show_from(root).root)
    end)

    it(
        "refuses :Differ pr checkout without a local clone, rather than fetching into the cwd",
        function()
            -- origin is a local bare repo, so a fetch that shouldn't happen fails here
            -- rather than reaching github: the refusal is what's under test, not the fetch
            local bare = vim.fn.tempname()
            vim.fn.mkdir(bare, "p")
            git(bare, "init", "-q", "--bare")
            local root = repo_with_remotes({ origin = bare })
            local s = show_from(root)
            assert.is_nil(s.root)

            _G.notifs = {}
            pr.checkout()
            assert.is_truthy(
                _G.notifs[#_G.notifs].msg:find(
                    "checkout needs a local clone of acme/widget",
                    1,
                    true
                )
            )
            -- the unrelated repo is untouched: no branch created, no FETCH_HEAD
            assert.are.equal("", vim.trim(git(root, "branch", "--list", "feature")))
        end
    )
end)

-- gx deletes a thread's newest comment, which on a long thread is not in the capped
-- list the overlay renders from
describe("pr comment delete targets the newest comment", function()
    after_each(function()
        if pr.current_session() then
            pr.end_session()
        end
    end)

    ---@param n integer  -- comments in the (capped) render list
    ---@param newest table|nil  -- the thread's actual last comment
    ---@return table  -- get_threads result
    local function thread_of(n, newest)
        local comments = {}
        for i = 1, n do
            comments[i] = {
                id = 1000 + i,
                node_id = "gid" .. i,
                author = "reviewer",
                body = "comment " .. i,
                created_at = string.format("2026-01-01T00:%02d:00Z", i % 60),
            }
        end
        return {
            {
                id = 1001,
                thread_id = "th_1",
                path = "a.txt",
                side = "RIGHT",
                line = 2,
                resolved = false,
                is_pending = false,
                comments_truncated = newest ~= nil and newest.node_id ~= "gid" .. n,
                newest_comment = newest,
                comments = comments,
            },
        }
    end

    -- boot a session on a.txt with the given thread, put the cursor on its anchor row and
    -- fire gx; returns the delete_comment params the sidecar saw, or nil
    ---@param threads table
    ---@return table|nil
    local function gx_on(threads)
        local seen = {}
        local real = sidecar.request
        sidecar.request = function(method, params, cb)
            if method == "delete_comment" then
                seen[#seen + 1] = params
            end
            local canned = {
                get_pr = get_pr_result(),
                get_file_versions = {
                    base = { content = "a\nb\nc\n" },
                    head = { content = "a\nB\nc\n" },
                },
                get_threads = threads,
                get_timeline = { comments = {}, reviews = {} },
                get_checks = { rollup = "SUCCESS", checks = {} },
            }
            vim.schedule(function()
                cb(nil, canned[method] or {})
            end)
        end
        local real_confirm = vim.fn.confirm
        local prompts = {}
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.confirm = function(msg)
            prompts[#prompts + 1] = msg
            return 1 -- Yes
        end

        pr.show(PR)
        assert.is_true(vim.wait(2000, function()
            local s = pr.current_session()
            return s and s.view and s.view:is_open() and s.threads ~= nil
        end))
        local s = pr.current_session()
        assert.is_true(vim.wait(2000, function()
            return #(s.thread_anchors or {}) > 0
        end))
        local a = s.thread_anchors[1]
        vim.api.nvim_set_current_win(vim.fn.win_findbuf(a.bufnr)[1])
        vim.api.nvim_win_set_cursor(0, { a.row, 0 })

        _G.notifs = {}
        assert.is_true(fire(a.bufnr, "delete comment"))
        vim.wait(300, function()
            return #seen > 0
        end)

        vim.fn.confirm = real_confirm
        sidecar.request = real
        return seen[1], prompts[1]
    end

    -- the render list stops at the cap, so its tail is whichever comment the cap reached;
    -- deleting that destroys one the user never pointed at
    it("deletes past the cap rather than the last comment it can see", function()
        local sent, prompt = gx_on(thread_of(100, { node_id = "gid101", body = "the newest one" }))
        assert.is_truthy(sent)
        assert.are.equal("gid101", sent.comment_id)
        assert.is_truthy(prompt:find("the newest one", 1, true))
    end)

    it("deletes the last comment of a thread that fits under the cap", function()
        local sent = gx_on(thread_of(3, { node_id = "gid3", body = "comment 3" }))
        assert.is_truthy(sent)
        assert.are.equal("gid3", sent.comment_id)
    end)

    it("refuses when the thread carries no newest comment", function()
        local sent = gx_on(thread_of(3, nil))
        assert.is_nil(sent)
        assert.is_truthy(_G.notifs[#_G.notifs].msg:find("can't be deleted", 1, true))
    end)
end)
