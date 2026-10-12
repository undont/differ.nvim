-- :Differ pr command-surface routing (slice 7). a fake differ.pr records which verb the
-- dispatch reached so the routing and the tree-aware completion are unit-checked without a
-- nvim runtime. the fake is swapped into package.loaded per test; the with_session block
-- loads the real module under stub deps to check the no-session guard

local calls = {}
local notifs = {}

-- a minimal additive vim: only the pieces command.lua and pr/init.lua touch. set with `or`
-- so a real runtime (if ever present) wins, and capture notify into `notifs`
_G.vim = _G.vim or {}
vim.log = vim.log or {}
vim.log.levels = vim.log.levels or { INFO = 2, WARN = 3, ERROR = 4 }
vim.notify = function(msg, level)
    notifs[#notifs + 1] = { msg = msg, level = level }
end
vim.split = vim.split
    or function(s, sep)
        local out, pos = {}, 1
        while true do
            local a, b = string.find(s, sep, pos)
            if not a then
                out[#out + 1] = string.sub(s, pos)
                break
            end
            out[#out + 1] = string.sub(s, pos, a - 1)
            pos = b + 1
        end
        return out
    end
vim.trim = vim.trim or function(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
vim.tbl_filter = vim.tbl_filter
    or function(f, t)
        local out = {}
        for _, v in ipairs(t) do
            if f(v) then
                out[#out + 1] = v
            end
        end
        return out
    end
vim.tbl_keys = vim.tbl_keys
    or function(t)
        local out = {}
        for k in pairs(t) do
            out[#out + 1] = k
        end
        return out
    end

-- each fake verb records its name + trailing args; rec closes over the `calls` upvalue,
-- which before_each reassigns (Lua upvalues are shared, so the closures see the new table)
local function rec(name)
    return function(...)
        calls[#calls + 1] = { name = name, args = { ... } }
        return nil
    end
end

local FAKE_PR = {
    open = rec("open"),
    view = rec("view"),
    review = rec("review"),
    overview = rec("overview"),
    submit = rec("submit"),
    discard_review = rec("discard_review"),
    resume = rec("resume"),
    checks = rec("checks"),
    merge = rec("merge"),
    set_state = rec("set_state"),
    checkout = rec("checkout"),
    browser = rec("browser"),
    url = rec("url"),
}

-- the last recorded verb name, or nil
local function last()
    return calls[#calls]
end

-- whether `set` (a completion result) contains `value`
local function has(set, value)
    for _, v in ipairs(set) do
        if v == value then
            return true
        end
    end
    return false
end

describe(":Differ pr dispatch", function()
    local cmd

    before_each(function()
        calls = {}
        notifs = {}
        package.loaded["differ.view"] = { current = function() end }
        package.loaded["differ.pr"] = FAKE_PR
        package.loaded["differ.command"] = nil
        cmd = require("differ.command")
    end)

    after_each(function()
        package.loaded["differ.command"] = nil
        package.loaded["differ.pr"] = nil
        package.loaded["differ.view"] = nil
    end)

    it("opens the picker on the overview when given no verb", function()
        cmd.pr(nil)
        assert.are.equal("open", last().name)
        assert.is_nil(last().args[1].number)
        assert.are.equal("overview", last().args[1].land)
    end)

    it("opens a bare number on the overview", function()
        cmd.pr("7")
        assert.are.equal("open", last().name)
        assert.are.equal(7, last().args[1].number)
        assert.are.equal("overview", last().args[1].land)
    end)

    it("routes owner/repo#number to that repo on the overview", function()
        cmd.pr("octo/cat#7")
        local o = last()
        assert.are.equal("open", o.name)
        assert.are.same({ owner = "octo", repo = "cat" }, o.args[1].coords)
        assert.are.equal(7, o.args[1].number)
        assert.are.equal("overview", o.args[1].land)
    end)

    it("view <n> targets that PR; bare view targets the active session", function()
        cmd.pr("view", "9")
        assert.are.equal("view", last().name)
        assert.are.equal(9, last().args[1].number)

        cmd.pr("view", nil)
        assert.are.equal("view", last().name)
        assert.is_nil(last().args[1].number)
    end)

    it("nests submit/discard/resume under `pr review`", function()
        cmd.pr("review", "submit")
        assert.are.equal("submit", last().name)
        cmd.pr("review", "discard")
        assert.are.equal("discard_review", last().name)
        cmd.pr("review", "resume")
        assert.are.equal("resume", last().name)
    end)

    it("treats bare `pr review` and `pr review start` as start on the active session", function()
        cmd.pr("review", nil)
        assert.are.equal("review", last().name)
        assert.is_nil(last().args[1])
        cmd.pr("review", "start")
        assert.are.equal("review", last().name)
        assert.is_nil(last().args[1])
    end)

    it("opens `pr review <n>` on the files with a draft", function()
        cmd.pr("review", "42")
        assert.are.equal("review", last().name)
        assert.are.equal(42, last().args[1].number)
    end)

    it("maps the lifecycle verbs onto set_state, and merge keeps its method", function()
        cmd.pr("ready")
        assert.are.same({ "ready" }, last().args)
        cmd.pr("draft")
        assert.are.same({ "draft" }, last().args)
        cmd.pr("close")
        assert.are.same({ "close" }, last().args)
        cmd.pr("reopen")
        assert.are.same({ "reopen" }, last().args)
        cmd.pr("merge", "rebase")
        assert.are.equal("merge", last().name)
        assert.are.same({ "rebase" }, last().args)
    end)

    it("routes the flat session-context verbs", function()
        cmd.pr("checks")
        assert.are.equal("checks", last().name)
        cmd.pr("checkout")
        assert.are.equal("checkout", last().name)
        cmd.pr("overview")
        assert.are.equal("overview", last().name)
        cmd.pr("browser")
        assert.are.equal("browser", last().name)
        cmd.pr("url")
        assert.are.equal("url", last().name)
    end)

    it("notifies, without throwing, on an unknown verb", function()
        cmd.pr("frobnicate")
        assert.are.equal(0, #calls)
        assert.are.equal(1, #notifs)
        assert.are.equal(vim.log.levels.WARN, notifs[1].level)
    end)

    it("notifies, without throwing, on an unknown `pr review` action", function()
        cmd.pr("review", "frobnicate")
        assert.are.equal(0, #calls)
        assert.are.equal(1, #notifs)
        assert.are.equal(vim.log.levels.WARN, notifs[1].level)
    end)

    it("no longer exposes resolve/reply/delete as ex-commands", function()
        for _, verb in ipairs({ "resolve", "reply", "delete" }) do
            calls, notifs = {}, {}
            cmd.pr(verb)
            assert.are.equal(0, #calls, verb .. " should not route to a pr verb")
            assert.are.equal(1, #notifs, verb .. " should notify unknown")
        end
    end)
end)

describe("M.complete (pr tree)", function()
    local cmd

    before_each(function()
        package.loaded["differ.view"] = { current = function() end }
        package.loaded["differ.pr"] = FAKE_PR
        package.loaded["differ.merge.continue"] = {
            in_progress = function()
                return false
            end,
        }
        package.loaded["differ.command"] = nil
        cmd = require("differ.command")
    end)

    after_each(function()
        package.loaded["differ.command"] = nil
        package.loaded["differ.pr"] = nil
        package.loaded["differ.view"] = nil
        package.loaded["differ.merge.continue"] = nil
    end)

    it("offers the review actions after `pr review `", function()
        assert.are.same(
            { "start", "submit", "discard", "resume" },
            cmd.complete("", "Differ pr review ")
        )
    end)

    it("filters the review actions by the lead", function()
        assert.are.same({ "start", "submit" }, cmd.complete("s", "Differ pr review s"))
    end)

    it("offers the merge methods after `pr merge `", function()
        assert.are.same({ "squash", "merge", "rebase" }, cmd.complete("", "Differ pr merge "))
    end)

    it("drops resolve/reply/delete from the first-level pr verbs", function()
        local pool = cmd.complete("", "Differ pr ")
        assert.is_true(has(pool, "review"))
        assert.is_true(has(pool, "checks"))
        assert.is_false(has(pool, "resolve"))
        assert.is_false(has(pool, "reply"))
        assert.is_false(has(pool, "delete"))
        assert.is_false(has(pool, "submit"))
        assert.is_false(has(pool, "discard"))
        assert.is_false(has(pool, "resume"))
    end)

    it("offers the subcommands (incl. base) at the first token", function()
        local pool = cmd.complete("", "Differ ")
        assert.is_true(has(pool, "pr"))
        assert.is_true(has(pool, "base"))
    end)
end)

describe("pr.with_session", function()
    local real

    setup(function()
        package.loaded["differ.pr"] = nil
        package.loaded["differ.pr.repo"] = package.loaded["differ.pr.repo"] or {}
        package.loaded["differ.pr.client"] = package.loaded["differ.pr.client"] or {}
        package.loaded["differ.pr.viewed"] = package.loaded["differ.pr.viewed"] or {}
        real = require("differ.pr")
    end)

    teardown(function()
        package.loaded["differ.pr"] = nil
        package.loaded["differ.pr.repo"] = nil
        package.loaded["differ.pr.client"] = nil
        package.loaded["differ.pr.viewed"] = nil
    end)

    before_each(function()
        notifs = {}
    end)

    it("notifies and skips fn when there is no active session", function()
        local ran = false
        real.with_session(function()
            ran = true
        end)
        assert.is_false(ran)
        assert.are.equal(1, #notifs)
        assert.are.equal("differ: no active pull request", notifs[1].msg)
    end)
end)
