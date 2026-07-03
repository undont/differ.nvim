-- public entry point: setup() and the top-level API surface

local config = require("differ.config")

local M = {}

---@type differ.Config|nil
M.config = nil

-- register each `command_alias` as an ex-command routing to the `:Differ` dispatcher.
-- a bad name (e.g. not starting uppercase) warns rather than aborting setup()
---@param alias string|string[]|nil
local function register_aliases(alias)
    if not alias then
        return
    end
    local names = type(alias) == "table" and alias or { alias }
    for _, name in ipairs(names) do
        local ok, err = pcall(
            require("differ.command").register,
            name,
            "differ diff viewer (alias for :Differ)"
        )
        if not ok then
            local msg = "differ: could not register command alias "
                .. vim.inspect(name)
                .. ": "
                .. tostring(err)
            vim.notify(msg, vim.log.levels.WARN)
        end
    end
end

-- resolve options and register highlight groups; call once from user config
---@param opts table|nil
function M.setup(opts)
    M.config = config.resolve(opts)
    require("differ.ui.highlights").setup()
    register_aliases(M.config.command_alias)
end

-- return the resolved config, defaulting if setup() was never called
---@return differ.Config
function M.get_config()
    return M.config or config.defaults
end

---@class differ.DiffSpec
---@field old_text string
---@field new_text string
---@field path string|nil
---@field old_rev string|nil
---@field new_rev string|nil
---@field layout differ.Layout|nil
---@field context integer|nil

-- open a View from an already-built DiffModel. the git frontend and panel use
-- this; `opts` overrides the layout/context defaults and carries the hunk-staging
-- capability for worktree-status panels
---@class differ.DiffModelOpts
---@field layout? differ.Layout
---@field context? integer
---@field staging? differ.view.Staging
---@field can_stage? boolean
---@field on_edit_unstage? fun(path: string)
---@field extra_keymaps? differ.panel.ExtraMap[]
---@field on_rerender? fun()
---@field on_cursor? fun()

---@param model differ.DiffModel
---@param opts? differ.DiffModelOpts
---@return differ.View
function M.diff_model(model, opts)
    require("differ.ui.highlights").setup()
    local cfg = M.get_config()
    opts = opts or {}
    return require("differ.view")
        .new(model, {
            layout = opts.layout or cfg.layout,
            context = opts.context or cfg.context,
            wrap = cfg.wrap,
            counter = cfg.diff_counter,
            cursorline_tint = cfg.cursorline_tint,
            deep_diff = cfg.deep_diff,
            keymaps = cfg.keymaps.diff,
            staging = opts.staging,
            can_stage = opts.can_stage,
            on_edit_unstage = opts.on_edit_unstage,
            extra_keymaps = opts.extra_keymaps,
            on_rerender = opts.on_rerender,
            on_cursor = opts.on_cursor,
        })
        :open()
end

-- open a diff view for an old/new text pair. the frontends (local git, PR) build
-- their DiffModel from real sources; this is the shared, source-agnostic entry
---@param spec differ.DiffSpec
---@return differ.View
function M.diff(spec)
    local model = require("differ.model.diff").build({
        path = spec.path or "",
        old_rev = spec.old_rev or "OLD",
        new_rev = spec.new_rev or "NEW",
        old_text = spec.old_text,
        new_text = spec.new_text,
    })
    return M.diff_model(model, { layout = spec.layout, context = spec.context })
end

-- open a local git change set from a rev spec, DiffviewOpen-style: the file
-- panel plus the first file's diff. the entry-point keymaps bind to this, e.g.
-- `require("differ").open("main...")` for the branch-total diff. a string is one
-- rev token; pass a table for multi-arg forms
---@param spec string|string[]|nil
---@return differ.Panel|nil
function M.open(spec)
    return require("differ.git").panel({ rev = spec, open_first = true })
end

-- open (or toggle) the file panel over a local git change set. `opts` are
-- runtime, not setup config: `rev` (rev spec, string or args), `position`
-- ("bottom"|"top"|"left"|"right"), `listing` ("tree"|"name"), `height`, `width`.
-- the live panel is reachable via `require("differ.panel").current()` for runtime
-- tweaks, e.g. `:current():set_position("left")` / `:toggle_listing()`
---@param opts table|nil
---@return differ.Panel|nil
function M.panel(opts)
    -- always show a file: the diff window is the session anchor, so a panel
    -- never opens without one
    return require("differ.git").panel(vim.tbl_extend("keep", { open_first = true }, opts or {}))
end

-- open single-file history (the `dh` keymap): a commit-list panel over the
-- file's `git log`, driving the diff view per commit. `opts.path` defaults to the
-- current buffer; `require("differ").file_history()` on the file you're editing
---@param opts table|nil
---@return differ.History|nil
function M.file_history(opts)
    return require("differ.git").history(opts or {})
end

-- open branch-range history (the `dp` keymap): a commit-list panel over a
-- rev-range (`opts.range`, e.g. "origin/HEAD...HEAD"); commits expand to their files
-- and selecting/stepping a file drives the diff view
---@param opts table|nil
---@return differ.History|nil
function M.range_history(opts)
    return require("differ.git").range_history(opts or {})
end

-- open the PR frontend: pick a PR (or jump to `opts.number`) and drive the
-- reused file panel + diff view from the sidecar's blobs. `opts` are runtime:
-- `number`, `filter` ("open"/"mine"/"review_requested"), `coords` ({owner, repo}
-- override for forks). `require("differ").pr_open({ number = 42 })`
---@param opts table|nil
function M.pr_open(opts)
    require("differ.pr").open(opts or {})
end

-- close the local session, the file panel and the diff view it drives (the `dc`
-- keymap binds to this). mirrors `:DiffviewClose`
function M.close()
    require("differ.git").close()
end

-- the diff view to act on: the one under the cursor, or, when focused in the file
-- panel, the view the panel drives (its origin window's buffer). lets the diff
-- commands (gofile, hunk nav) work from either the diff window or the panel
---@return differ.View|nil
function M.active_view()
    local View = require("differ.view")
    local view = View.current()
    if view then
        return view
    end
    local panel = require("differ.panel").current()
    local history = require("differ.history").current()
    local origin = (panel and panel.origin_win) or (history and history.origin_win)
    if origin and vim.api.nvim_win_is_valid(origin) then
        return View.for_buf(vim.api.nvim_win_get_buf(origin))
    end
    return nil
end

-- jump-to-file (the `de` keymap): from the diff under the cursor, close the
-- session and open the real file on disk at the mapped line. works from the panel
-- too (acts on the driven view); a no-op with a notice when no diff is active
function M.jump_to_file()
    local view = M.active_view()
    if not view then
        return vim.notify("differ: no diff view here", vim.log.levels.WARN)
    end
    view:jump_to_file()
end

-- edit-in-review (the `df` keymap): open the real worktree file in a transient
-- editable window at the mapped line, keeping the session; `:w` re-sources the diff.
-- works from the panel too (acts on the driven view); a no-op with a notice when no
-- diff is active
function M.edit_file()
    local view = M.active_view()
    if not view then
        return vim.notify("differ: no diff view here", vim.log.levels.WARN)
    end
    view:edit_file()
end

-- ]c / [c from the panel: move the driven diff view to the next/previous hunk
-- (in the diff window already bound buffer-locally). a no-op with a notice when no
-- diff is active
---@param direction "next"|"prev"
---@param opts? { fallback?: fun(direction: "next"|"prev"): boolean|nil }
function M.goto_hunk(direction, opts)
    local view = M.active_view()
    if not view then
        return vim.notify("differ: no diff view here", vim.log.levels.WARN)
    end
    view:goto_hunk(direction, opts)
end

return M
