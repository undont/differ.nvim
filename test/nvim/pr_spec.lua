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
