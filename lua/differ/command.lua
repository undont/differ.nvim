-- :Differ subcommand router. phase 1 wires the runtime view controls;
-- diff/pr/log/mergetool subcommands arrive with their frontends (phases 2+)

local View = require("differ.view")

local M = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- :Differ layout [stacked|split], no arg flips the current view's layout
---@param arg string|nil
function M.layout(arg)
    local view = View.current()
    if not view then
        return notify("no diff view here", vim.log.levels.WARN)
    end
    if arg == nil or arg == "" then
        view:toggle_layout()
    elseif arg == "stacked" or arg == "split" then
        view:set_layout(arg)
    else
        notify("layout: expected 'stacked' or 'split'", vim.log.levels.ERROR)
    end
end

-- :Differ context <n|full|+|->, sets/adjusts the per-view context lines
---@param arg string|nil
function M.context(arg)
    local view = View.current()
    if not view then
        return notify("no diff view here", vim.log.levels.WARN)
    end
    if arg == "full" then
        view:set_context(math.huge)
    elseif arg == "+" then
        view:adjust_context(1)
    elseif arg == "-" then
        view:adjust_context(-1)
    else
        local n = tonumber(arg)
        if not n then
            return notify("context: expected a number, 'full', '+' or '-'", vim.log.levels.ERROR)
        end
        view:set_context(math.max(0, math.floor(n)))
    end
end

---@type table<string, true>
local PANEL_POSITIONS = { left = true, right = true, top = true, bottom = true }

-- :Differ panel [left|right|top|bottom|revspec], open the file panel over a
-- change set and show the first file's diff (the diff window is the session anchor,
-- so there's never a panel without one). on a live session a bare `:Differ panel`
-- toggles the sidebar's visibility in place (bare `:Differ` just opens); `:Differ
-- close` ends the session. a position word repositions a live panel
-- or history sidebar, reveals a hidden sidebar there, or opens one at that edge when no
-- session exists (height/width carry over from config); any other arg is a rev spec
---@param arg string|nil
function M.panel(arg)
    if arg and PANEL_POSITIONS[arg] then
        -- a live history (`:Differ log`) session has no file panel; reposition its
        -- sidebar in place rather than spawning a second, overlapping session
        local history = require("differ.history").current()
        if history then
            return history:set_position(arg)
        end
        local panel = require("differ.panel").current()
        if panel then
            panel:set_position(arg) -- records position; repositions live if shown
            if not panel:is_open() then
                panel:show() -- hidden sidebar: reveal it at the new position
            end
            return
        end
        return require("differ.git").panel({ position = arg, open_first = true })
    end
    -- a bare `:Differ panel` (no position word) over a live history session has
    -- nothing to toggle (the history sidebar has no hide/show); say so rather than
    -- opening a second worktree-diff session on top of it
    if not (arg and arg ~= "") and require("differ.history").current() then
        return notify(
            "history sidebar can't be toggled; use :Differ panel left|right to move it, "
                .. "or :Differ close to end it"
        )
    end
    require("differ.git").panel({
        rev = (arg ~= "" and arg) or nil,
        open_first = true,
        toggle = true, -- `:Differ panel` is the explicit hide/show gesture
    })
end

local pr = function()
    return require("differ.pr")
end

-- the opener + session-context verb handlers, each taking the trailing arg (may be nil).
-- openers (list/view/review <n>) forward an optional number and establish/switch the
-- session; every other verb ignores args and acts on the one active session via the verb's
-- own pr.with_session gate. cursor-context gestures (resolve/reply/delete) are not here:
-- they're keymaps (gr/gp/gx), not ex-commands
---@type table<string, fun(arg: string|nil)>
local PR_VERBS = {
    list = function(arg)
        pr().open({ filter = arg or "open" })
    end,
    -- view enters the diff read-only on PR n, else the active session
    view = function(arg)
        pr().view({ number = arg and tonumber(arg) or nil })
    end,
    review = function(arg)
        M.pr_review(arg)
    end,
    -- refocus the overview home (the PR landing page) from within the file diff
    overview = function()
        pr().overview()
    end,
    -- the read-only CI checks view
    checks = function()
        pr().checks()
    end,
    -- lifecycle: merge takes an optional method; ready/draft/close/reopen map to a
    -- set_pr_state value; checkout/browser/url stay client-side
    merge = function(arg)
        pr().merge(arg)
    end,
    checkout = function()
        pr().checkout()
    end,
    ready = function()
        pr().set_state("ready")
    end,
    draft = function()
        pr().set_state("draft")
    end,
    close = function()
        pr().set_state("close")
    end,
    reopen = function()
        pr().set_state("reopen")
    end,
    browser = function()
        pr().browser()
    end,
    url = function()
        pr().url()
    end,
}

-- the nested `review` group: a number opens that PR + starts the draft; a keyword is
-- a draft action on the active session; empty / `start` starts (or resumes) the draft.
-- number and keyword never collide, so there's no precedence to remember
---@param arg string|nil
function M.pr_review(arg)
    local P = pr()
    if arg == nil or arg == "" or arg == "start" then
        return P.review() -- start/resume on the active session
    elseif tonumber(arg) then
        return P.review({ number = tonumber(arg) }) -- open PR n + start
    elseif arg == "submit" then
        return P.submit()
    elseif arg == "discard" then
        return P.discard_review()
    elseif arg == "resume" then
        return P.resume()
    end
    notify("unknown `pr review` action: " .. arg, vim.log.levels.WARN)
end

-- :Differ pr [<n>|owner/repo#n|<verb> [arg]]. bare / a number / owner/repo#number
-- open the PR and land on the overview (the PR home); a recognised verb dispatches via
-- PR_VERBS. session-context verbs act on the one active session (pr.with_session)
---@param verb string|nil
---@param arg string|nil
function M.pr(verb, arg)
    local P = pr()
    if verb == nil or verb == "" or tonumber(verb) then
        return P.open({ number = verb and tonumber(verb) or nil, land = "overview" })
    end
    -- explicit override: owner/repo#number targets a specific repo (forks)
    local owner, repo, num = verb:match("^([^/]+)/([^#]+)#(%d+)$")
    if owner then
        return P.open({
            coords = { owner = owner, repo = repo },
            number = tonumber(num),
            land = "overview",
        })
    end
    local h = PR_VERBS[verb]
    if h then
        return h(arg)
    end
    notify("unknown `pr` subcommand: " .. verb, vim.log.levels.WARN)
end

-- :Differ close: end the active session. a merge-tool session ends through its own
-- teardown; a live PR session (the pre-review overview page, which has no panel for
-- git.close to catch, or the review proper) likewise; otherwise close the local git diff
function M.close()
    local mg = require("differ.merge")
    if mg.current() then
        return mg.close()
    end
    local P = pr()
    if P.current_session() then
        return P.end_session()
    end
    require("differ.git").close()
end

-- :Differ mergetool [path]: 3-way conflict resolution. no arg targets the current
-- file (else the sole conflicted file, else a picker). the pane layout follows the
-- configured merge.layout (`default` or `diff4`); there's no ad-hoc layout argument,
-- so the sole arg is always a path
---@param arg string|nil
function M.mergetool(arg)
    require("differ.merge").open({ path = (arg ~= "" and arg) or nil })
end

-- :Differ log [arg]: file history. no arg or an arg naming a readable file →
-- single-file history (that file, else the current buffer); `base` is the trunk
-- shortcut → branch-range history of `<base>...HEAD`; any other arg is a rev-range.
-- bare `:Differ log` with no real file in the buffer falls back to full HEAD history
---@param arg string|nil
function M.log(arg)
    if arg == "base" then
        local base = require("differ.git").resolve_base()
        if not base then
            return
        end
        return require("differ.git").range_history({ range = base .. "...HEAD" })
    end
    if arg and arg ~= "" and vim.fn.filereadable(vim.fn.fnamemodify(arg, ":p")) == 0 then
        return require("differ.git").range_history({ range = arg })
    end
    -- bare `:Differ log` with no real file in the buffer (dashboard/unnamed/home
    -- screen) falls back to the full HEAD history rather than warning
    if not arg or arg == "" then
        local file = vim.api.nvim_buf_get_name(0)
        if file == "" or vim.fn.filereadable(file) == 0 then
            return require("differ.git").range_history({ range = "HEAD" })
        end
    end
    require("differ.git").history({ path = (arg ~= "" and arg) or nil })
end

-- :Differ gofile: jump from the diff to the real file at the cursor's mapped line
function M.gofile()
    require("differ").jump_to_file()
end

-- :Differ edit: edit-in-review — open the real worktree file in a transient
-- editable window at the cursor's mapped line, keeping the diff session live
function M.edit()
    require("differ").edit_file()
end

-- :Differ sidecar [stop]: smoke-check the Go sidecar (start + hello round trip,
-- report the binary version), or stop the supervised process
---@param arg string|nil
function M.sidecar(arg)
    local sidecar = require("differ.sidecar")
    if arg == "stop" then
        sidecar.stop()
        return notify("sidecar stopped")
    end
    sidecar.ping(function(err, info)
        if err then
            -- a spawn/handshake failure already carries the binary's own stderr; a
            -- protocol-level one doesn't, so fall back to whatever it last said
            local msg = "sidecar: " .. (err.message or err.code)
            local exit = sidecar.last_exit()
            if not msg:find("\n", 1, true) and exit then
                msg = sidecar.with_tail(msg, exit.stderr)
            end
            return notify(msg, vim.log.levels.ERROR)
        end
        notify(
            ("sidecar ok — binary %s, protocol %d"):format(info.binary or "?", info.protocol or 0)
        )
    end)
end

-- :Differ cache clear: flush the sidecar's in-process caches
---@param arg string|nil
function M.cache(arg)
    if arg ~= "clear" then
        return notify("cache: expected 'clear'", vim.log.levels.ERROR)
    end
    require("differ.sidecar").request("cache_clear", nil, function(err)
        if err then
            return notify("cache clear: " .. (err.message or err.code), vim.log.levels.ERROR)
        end
        notify("sidecar cache cleared")
    end)
end

---@type table<string, fun(arg: string|nil)>
local SUB = {
    layout = M.layout,
    context = M.context,
    panel = M.panel,
    pr = M.pr,
    close = M.close,
    gofile = M.gofile,
    edit = M.edit,
    log = M.log,
    mergetool = M.mergetool,
    sidecar = M.sidecar,
    cache = M.cache,
}

-- the conflicted files in the tree the current buffer (or cwd) sits in, with its root
---@return string|nil root, string[] paths
local function conflicts()
    local git = require("differ.git")
    local file = vim.api.nvim_buf_get_name(0)
    local anchor = (file ~= "" and vim.fn.filereadable(file) == 1) and file or vim.fn.getcwd()
    local root = git.root(anchor)
    if not root then
        return nil, {}
    end
    return root, git.conflicted(root)
end

-- whether `:Differ <fargs>` resolves to an uncommitted pairing (HEAD/index vs worktree)
---@param fargs string[]
---@return boolean
local function current_state(fargs)
    local rev = require("differ.git.rev")
    local source = rev.source(fargs)
    return rev.editable(source.old.label, source.new.label)
end

-- route `:Differ ...`. a recognised subcommand (layout/context/panel) takes its
-- arg; `base` is the trunk shortcut → the whole branch vs base (`<base>...`, incl.
-- uncommitted); anything else, including no args, is a local-diff rev spec,
-- so `:Differ`, `:Differ main...`, `:Differ a..b` open the file panel over that
-- change set and show the first file's diff (DiffviewOpen-style). the exception: a
-- worktree-backed source mid-conflict opens the merge tool instead
---@param fargs string[]
function M.dispatch(fargs)
    local handler = fargs[1] and SUB[fargs[1]]
    if handler then
        return handler(fargs[2], fargs[3])
    end
    -- mid-conflict the uncommitted sources go to the merge tool, which picks its own
    -- target (current/sole/picker); everything else opens with a hint. above the `base`
    -- branch so `base` is hinted too, matching the `<base>...` it expands to
    local root, conflicted = conflicts()
    local reroute = root ~= nil and #conflicted > 0 and current_state(fargs)
    if root then
        require("differ.git").notify_conflicts(root, conflicted, reroute)
    end
    if reroute then
        return require("differ.merge").open({})
    end
    if fargs[1] == "base" then
        local base = require("differ.git").resolve_base()
        if not base then
            return
        end
        return require("differ.git").panel({
            rev = base .. "...",
            open_first = true,
            supersede = true,
        })
    end
    -- `:Differ <rev>` is idempotent: re-running it over a live session opens the new diff
    -- and closes the previous one (supersede). a bare `:Differ` over a live session just
    -- (re)opens the sidebar — it never toggles it shut (`:Differ panel` is the toggle)
    require("differ.git").panel({ rev = fargs, open_first = true, supersede = true })
end

---@type table<string, string[]>
local VALUES = {
    layout = { "stacked", "split" },
    context = { "full", "+", "-" },
    panel = { "left", "right", "top", "bottom" },
    -- first-level pr verbs. cursor-context gestures (resolve/reply/delete) are
    -- keymaps, not ex-commands; the review-draft actions nest under `review` (PR_SUB)
    pr = {
        "list",
        "view",
        "overview",
        "review",
        "checks",
        "merge",
        "checkout",
        "ready",
        "draft",
        "close",
        "reopen",
        "browser",
        "url",
    },
    sidecar = { "stop" },
    cache = { "clear" },
    log = { "base" },
}

-- second-level completion under `pr <group>`: the review-draft actions, and the
-- merge method as a freebie of the same table. a numeric `pr review <n>` simply matches
-- nothing here, which is correct
---@type table<string, string[]>
local PR_SUB = {
    list = { "open", "mine", "review_requested" },
    review = { "start", "submit", "discard", "resume" },
    merge = { "squash", "merge", "rebase" },
}

-- completion: subcommands at token 2, that subcommand's value set at token 3, and a
-- `pr` group's nested actions at token 4 (e.g. `:Differ pr review <action>`). the token
-- being completed is the last part when arglead is non-empty, else the next one
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
    local parts = vim.split(vim.trim(cmdline), "%s+")
    -- parts[1] == "Differ"; the index of the token under completion
    local idx = arglead ~= "" and #parts or (#parts + 1)
    local pool
    if idx <= 2 then
        pool = vim.tbl_keys(SUB)
        pool[#pool + 1] = "base" -- the trunk diff shortcut isn't a SUB handler
    elseif idx == 3 then
        pool = VALUES[parts[2]] or {}
    elseif parts[2] == "pr" then
        pool = PR_SUB[parts[3]] or {}
    else
        pool = {}
    end
    return vim.tbl_filter(function(c)
        return c:find(arglead, 1, true) == 1
    end, pool)
end

-- register an ex-command routing to dispatch/complete. used for `:Differ` and any
-- config-supplied aliases (`command_alias`); completion is name-agnostic since it
-- keys off token position, not the command word
---@param name string
---@param desc string
function M.register(name, desc)
    vim.api.nvim_create_user_command(name, function(opts)
        M.dispatch(opts.fargs)
    end, {
        nargs = "*",
        desc = desc,
        complete = function(arglead, cmdline)
            return M.complete(arglead, cmdline)
        end,
    })
end

return M
