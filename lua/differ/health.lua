-- :checkhealth differ. one section per requirement that can fail at runtime

local health = vim.health

local M = {}

-- added to the client's restart budget: giving up before it does reports a timeout
-- instead of the crash. covers the process starts the retries pay for
local PING_MARGIN_MS = 2000

local function check_nvim()
    health.start("neovim")
    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("nvim " .. tostring(vim.version()))
    else
        health.error(
            ("nvim %s is below the 0.12 floor"):format(vim.version()),
            { "differ needs vim.text.diff, which 0.12 introduced" }
        )
    end
    if vim.o.termguicolors then
        health.ok("'termguicolors' is on")
    else
        health.warn(
            "'termguicolors' is off; the diff, merge and thread highlights render uncoloured",
            {
                "add `vim.o.termguicolors = true` to your config",
            }
        )
    end
end

-- a boolean git config key, or nil when it isn't set. `--type=bool` collapses the
-- spellings git accepts (`0`, `no`, `off`); it refuses `copies`, which is rename
-- detection plus copy detection and so reads as on
---@param key string
---@return boolean|nil
local function git_bool(key)
    local res = vim.system({ "git", "config", "--get", "--type=bool", key }, { text = true }):wait()
    if res.code == 0 then
        return vim.trim(res.stdout or "") == "true"
    end
    if res.code == 1 then
        return nil -- not set
    end
    return true
end

-- git pairs renames off two keys, and `status.renames` defaults to `diff.renames`, so
-- the two only disagree when it was set on its own. the file panel lists through `git
-- status` and a rev-pair diff through `git diff`, so that split shows one change set
-- two ways, with different file counts
local function check_renames()
    local status_renames = git_bool("status.renames")
    if status_renames == nil then
        return
    end
    local diff_renames = git_bool("diff.renames")
    if diff_renames == nil then
        diff_renames = true -- git's own default
    end
    if status_renames == diff_renames then
        return
    end
    local panel, pair = "an add and a delete", "a rename"
    if status_renames then
        panel, pair = pair, panel
    end
    health.warn(
        ("status.renames is `%s` but diff.renames is `%s`"):format(status_renames, diff_renames),
        {
            ("the file panel lists a rename as %s, a rev-pair diff as %s"):format(panel, pair),
            "set diff.renames to cover both, or unset status.renames",
        }
    )
end

local function check_git()
    health.start("git")
    if vim.fn.executable("git") ~= 1 then
        return health.error("git is not on PATH", {
            "every local diff, log and merge surface shells out to git",
        })
    end
    local res = vim.system({ "git", "--version" }, { text = true }):wait()
    if res.code ~= 0 then
        return health.error("git is on PATH but `git --version` failed: " .. (res.stderr or ""))
    end
    health.ok(vim.trim(res.stdout or "git found"))
    check_renames()
end

local function check_config()
    health.start("configuration")
    local differ = require("differ")
    if differ.config == nil then
        health.info("setup() has not been called; the built-in defaults are in use")
    end
    -- the raw opts: after the merge an unknown key looks like a deliberate one
    local diags = require("differ.config").validate(differ.user_opts)
    if #diags == 0 then
        return health.ok("no problems found in the options passed to setup()")
    end
    for _, diag in ipairs(diags) do
        health.warn(diag)
    end
end

-- whatever the sidecar has said, dead or alive. a crash-restart leaves no other trace,
-- and neither does a recovered panic: dispatch logs the stack and keeps the process up,
-- so the caller gets a bare "internal error" and this is where the stack surfaces
local function check_sidecar_output(sidecar)
    local exit = sidecar.last_exit()
    if exit then
        health.warn(
            sidecar.with_tail(
                ("the sidecar exited unexpectedly this session (code %d), last words:"):format(
                    exit.code
                ),
                exit.stderr
            )
        )
    end
    local lines = sidecar.stderr_lines()
    if #lines > 0 then
        health.info(sidecar.with_tail("the running sidecar has logged:", lines))
    end
end

-- returns the hello result so the auth section needs no second ping
---@return differ.sidecar.Hello|nil
local function check_sidecar(sidecar)
    health.start("sidecar")
    local level = vim.env.DIFFER_LOG_LEVEL
    if level and level ~= "" then
        health.info("DIFFER_LOG_LEVEL=" .. level)
    end

    local bin = sidecar.binary_path()
    if not bin then
        health.warn("no differ-sidecar binary found; PR review is unavailable", {
            "run `make go-build` in the plugin directory",
            "or point `sidecar_bin` at an existing one",
        })
        return nil
    end
    health.info("binary: " .. bin)

    local timeout = sidecar.restart_budget_ms() + PING_MARGIN_MS
    local done, gerr = false, nil
    ---@type differ.sidecar.Hello|nil
    local ginfo
    -- vim.wait delivers the client's own failure notification inside this call, and an
    -- error-level notify aborts :checkhealth
    local notify = vim.notify
    vim.notify = function() end
    local pinged = pcall(function()
        sidecar.ping(function(err, info)
            gerr, ginfo, done = err, info, true
        end)
        return vim.wait(timeout, function()
            return done
        end)
    end)
    vim.notify = notify

    if not pinged or not done then
        health.error(("no answer to a hello within %dms"):format(timeout))
        check_sidecar_output(sidecar)
        return nil
    end
    if gerr then
        -- no check_sidecar_output: a death on the way up already folded its stderr in
        -- here, and a handshake that failed any other way left no exit to report
        health.error(gerr.message or gerr.code)
        return nil
    end

    health.ok(
        ("handshake ok: protocol %d, binary %s"):format(ginfo.protocol or 0, ginfo.binary or "?")
    )
    check_sidecar_output(sidecar)
    return ginfo
end

---@param hello differ.sidecar.Hello|nil
local function check_auth(hello)
    health.start("github auth")
    if not hello then
        return health.info("not checked: the sidecar did not answer")
    end
    -- absent is not "ok": a sidecar predating the field simply says nothing
    if not hello.auth or hello.auth == "" then
        return health.warn("this sidecar does not report auth state", {
            "rebuild it with `make go-build` to see it here",
        })
    end
    if hello.auth == "ok" then
        return health.ok("a github token is available")
    end
    local advice = { "PR review is unavailable until this is resolved" }
    if hello.auth == "gh_missing" then
        advice = { "install the gh CLI, or set GH_TOKEN / GITHUB_TOKEN" }
    elseif hello.auth == "auth" then
        advice = { "run `gh auth login`" }
    end
    health.warn(hello.auth_message or ("github auth: " .. hello.auth), advice)
end

function M.check()
    local sidecar = require("differ.sidecar")
    check_nvim()
    check_git()
    check_config()
    check_auth(check_sidecar(sidecar))
end

return M
