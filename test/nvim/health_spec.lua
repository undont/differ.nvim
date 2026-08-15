-- runs under headless nvim: drives the real check() with vim.health stubbed, so the
-- assertions are on what each section reports rather than on rendered buffer text
local health = require("differ.health")

-- capture: { { kind = "ok"|"warn"|..., section = "sidecar", msg = "..." } }, plus a
-- count of any vim.notify that escaped check(). the suite's own notify stub means an
-- error-level one can't raise here the way it does inside a real :checkhealth, so the
-- assertion has to be that none is emitted at all
local notified = 0

local function capture()
    local real_health, real_notify = vim.health, vim.notify
    local calls, section = {}, nil
    local function record(kind)
        return function(msg)
            calls[#calls + 1] = { kind = kind, section = section, msg = msg }
        end
    end
    vim.health = {
        start = function(name)
            section = name
        end,
        ok = record("ok"),
        info = record("info"),
        warn = record("warn"),
        error = record("error"),
    }
    notified = 0
    vim.notify = function()
        notified = notified + 1
    end
    -- health.lua caches vim.health at require time, so reload it against the stub
    package.loaded["differ.health"] = nil
    local ok, err = pcall(function()
        require("differ.health").check()
    end)
    vim.health, vim.notify = real_health, real_notify
    package.loaded["differ.health"] = health
    assert.is_true(ok, "check() raised: " .. tostring(err))
    return calls
end

local function find(calls, section, pattern)
    for _, c in ipairs(calls) do
        if c.section == section and tostring(c.msg):find(pattern, 1, true) then
            return c
        end
    end
    return nil
end

local function section_kinds(calls, section)
    local kinds = {}
    for _, c in ipairs(calls) do
        if c.section == section then
            kinds[c.kind] = true
        end
    end
    return kinds
end

describe("differ.health", function()
    local saved_config, saved_opts

    local function fake_sidecar(lines)
        local path = vim.fn.tempname()
        vim.fn.writefile(vim.list_extend({ "#!/bin/sh" }, lines), path)
        vim.fn.setfperm(path, "rwxr-xr-x")
        return path
    end

    before_each(function()
        local differ = require("differ")
        saved_config, saved_opts = differ.config, differ.user_opts
    end)

    after_each(function()
        require("differ.sidecar").stop()
        local differ = require("differ")
        differ.config, differ.user_opts = saved_config, saved_opts
        vim.wait(100)
    end)

    it("reports every section against the real binary", function()
        require("differ").setup({})
        local calls = capture()

        for _, section in ipairs({ "neovim", "git", "configuration", "sidecar", "github auth" }) do
            assert.is_true(#vim.tbl_filter(function(c)
                return c.section == section
            end, calls) > 0, "no output for section: " .. section)
        end
        assert.is_truthy(find(calls, "neovim", "nvim "))
        assert.is_truthy(find(calls, "git", "git version"))
        assert.is_truthy(find(calls, "sidecar", "handshake ok: protocol 1"))
        -- the real binary reports its auth state, whatever this machine's state is
        assert.is_nil(find(calls, "github auth", "does not report auth state"))
    end)

    it("surfaces config warnings in the configuration section", function()
        require("differ").setup({ pannel = {}, panel = { position = "middle" } })
        local calls = capture()

        -- error, not warn: a key that can never do what it says is wrong for everyone,
        -- unlike a missing gh CLI, which is only wrong if you review PRs
        assert.are.equal("error", find(calls, "configuration", 'unknown option "pannel"').kind)
        assert.are.equal(
            "error",
            find(calls, "configuration", "panel.position must be one of").kind
        )
    end)

    it("reports a sidecar that dies without abandoning the report", function()
        require("differ").setup({
            sidecar_bin = fake_sidecar({ "echo 'boom: cannot start' >&2", "exit 3" }),
        })
        local calls = capture()

        local err = find(calls, "sidecar", "sidecar exited (code 3)")
        assert.is_truthy(err)
        assert.are.equal("error", err.kind)
        assert.is_truthy(err.msg:find("boom: cannot start", 1, true)) -- its own last words
        -- the sections after the failure still ran
        assert.is_truthy(find(calls, "github auth", "the sidecar did not answer"))
        -- the client notifies at error level on a failed handshake, which inside a real
        -- :checkhealth raises out of the command and abandons everything after it
        assert.are.equal(0, notified, "check() let a notification escape")
    end)

    it("warns rather than failing when no binary is resolvable", function()
        require("differ").setup({ sidecar_bin = "/nonexistent/differ-sidecar-xyz" })
        local calls = capture()

        -- an unresolvable path still resolves to itself; the spawn is what fails
        assert.is_true(section_kinds(calls, "sidecar").error)
        assert.is_truthy(find(calls, "github auth", "the sidecar did not answer"))
    end)
end)
