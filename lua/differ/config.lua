-- plugin options: defaults, user merge, and validation

---@class differ.Config.Panel
---@field position "bottom"|"top"|"left"|"right"
---@field height integer  -- used for top/bottom
---@field width integer   -- used for left/right
---@field listing "tree"|"name"
---@field progress boolean  -- file-position meter in the panel winbar

---@class differ.Config.History
---@field position "bottom"|"top"|"left"|"right"
---@field height integer  -- used for top/bottom
---@field width integer   -- used for left/right

---@class differ.Config.Merge
---@field layout "default"|"diff4"

-- a resolved per-surface keymap table: action -> lhs (a string, a multi-lhs list,
-- or false to disable). the shape `resolve_keymaps` produces per surface
---@alias differ.KeymapSet table<string, string|string[]|false>

---@class differ.Config
---@field layout differ.Layout
---@field context number  -- math.huge = whole file, no folds
---@field wrap boolean
---@field diff_counter boolean
---@field cursorline_tint boolean
---@field deep_diff { enabled: boolean, granularity: "word"|"char", similarity_threshold: number }
---@field comments { inline: boolean, collapsed: boolean }
---@field panel differ.Config.Panel
---@field history differ.Config.History
---@field merge differ.Config.Merge
---@field keymaps table<string, string|string[]|false|table>
---@field relative_dates boolean
---@field base string|nil
---@field sidecar_bin string|nil
---@field command_alias string|string[]|nil

local M = {}

-- the surfaces that bind buffer-local maps; each takes the shared defaults plus its
-- own `keymaps.<surface>` override subtable
local SURFACES = { "diff", "panel", "history", "merge" }
local SURFACE_SET = { diff = true, panel = true, history = true, merge = true }

-- the closed value sets the options below draw from. named once and shared, so a
-- set used by two options (position) has one definition; `M.closed` maps each
-- option to its set
local POSITION = { "bottom", "top", "left", "right" }
local LISTING = { "tree", "name" }
local LAYOUT = { "stacked", "split" }
local PANES = { "default", "diff4" }
local GRAIN = { "word", "char" }

---@type differ.Config
M.defaults = {
    layout = "stacked",
    context = math.huge, -- whole file, no folds
    wrap = true, -- soft-wrap long lines in the diff view
    diff_counter = true, -- "hunk K/N" counter in the diff window's winbar
    -- tint the diff cursor line by the line's change kind (a stronger add/delete
    -- shade) so the add/remove colour survives under the cursor; false falls back to
    -- a plain neutral cursor line
    cursorline_tint = true,
    deep_diff = {
        enabled = true,
        granularity = "word",
        similarity_threshold = 0.5,
    },
    comments = {
        inline = true,
        collapsed = false,
    },
    -- the file panel's default placement and size; `:Differ panel` opts (and the
    -- runtime Panel.current() setters) still override these per-session
    panel = {
        position = "right",
        height = 9, -- top/bottom
        width = 35, -- left/right
        listing = "tree",
        progress = true, -- "file K/N" position meter in the panel winbar
    },
    -- the log/history sidebar's default placement and size. a commit row is wide
    -- (sha · date · author · subject), so it defaults to the bottom strip where the
    -- whole row fits on one line; left/right are supported but render two lines per
    -- commit. `:Differ panel <pos>` repositions a live one
    history = {
        position = "bottom",
        height = 10, -- top/bottom
        width = 40, -- left/right
    },
    -- the merge tool's pane layout: `default` is ours | theirs over the result,
    -- `diff4` adds the base column (base/ours/theirs over the result). base-pane
    -- visibility is a stable preference, so there's no per-invocation argument
    merge = {
        layout = "default",
    },
    -- buffer-local maps, one flat table of action -> lhs shared across the diff,
    -- panel and history surfaces (each binds the actions it implements). a value is
    -- a string, a list of strings (multiple binds), or false to disable. override
    -- globally here, or scope to one surface via a `diff`/`panel`/`history` subtable
    keymaps = {
        next_hunk = "]c", -- diff, panel, history
        prev_hunk = "[c",
        next_file = "]f", -- diff; panel/history step the selection
        prev_file = "[f",
        first_file = "gg", -- panel/history: jump to the first/last file or commit
        last_file = "G",
        next_section = "]]", -- panel: next/prev section (Staged/Unstaged); history: commit
        prev_section = "[[",
        toggle_viewed = "<Tab>", -- pr panel: flip the github viewed checkbox
        next_unviewed = "]u", -- pr panel + diff: jump to the next/prev unviewed file
        prev_unviewed = "[u",
        next_thread = "]t", -- pr diff: jump to the next/prev review-thread anchor
        prev_thread = "[t",
        overview = "go", -- pr diff + panel: back to the PR overview home (shadows native go, goto-byte)
        -- both buffer-local to the read-only pr diff, so the g-family shadowing is
        -- deliberate and inert: gc = native comment op (no source to toggle), gr =
        -- native lsp prefix (no lsp on a synthetic diff buffer)
        toggle_thread = "gc", -- pr diff: collapse/expand the thread under the cursor
        resolve_thread = "gr", -- pr diff: resolve/unresolve the thread under the cursor
        -- pr diff commenting. ga shadows native ga (:ascii, negligible); gp shadows
        -- native gp (paste, inert on the read-only diff)
        comment = "ga", -- comment on the line (normal) or the selection (visual)
        reply = "gp", -- reply to the thread under the cursor
        delete_comment = "gx", -- delete the latest comment of the thread under the cursor
        -- pr review lifecycle, on the pr diff + panel, so a review can be finished
        -- without leaving the files. capitalised to keep the lowercase g-family for
        -- thread/comment actions; each one's own prompt (verdict picker, confirm) is
        -- the guard, not the key. resume isn't here: entering the review already
        -- adopts any pending draft, so `:Differ pr review resume` covers the cold start
        review_submit = "gS", -- pr: submit the pending review
        review_discard = "gD", -- pr: discard the pending review and its drafts
        scroll_down = "f", -- all three (shadows native f/b; set false to restore)
        scroll_up = "b",
        select = { "<CR>", "o" }, -- panel, history
        details = "K", -- history: float the full commit message (subject + body)
        help = "g?", -- panel, history
        toggle_listing = "i", -- panel: toggle tree / name
        close_node = "c", -- panel: collapse the dir under the cursor; history: the commit
        close_all = "C", -- panel/history: collapse every dir / commit
        open_all = "O", -- panel/history: expand every dir / commit
        stage = "s", -- diff (hunk-level), panel (file-level)
        unstage = "u",
        stage_all = "S",
        unstage_all = "U",
        more_context = "d=", -- diff
        less_context = "d-",
        edit_file = "df", -- diff: edit-in-review; pr diff: worktree split beside the pinned diff
        goto_file = "de", -- diff: open the real file and end the session; pr diff: zoom-edit in a tab instead
        discard = "X", -- panel
        refresh = "R",
        toggle_fold = "za", -- history (range mode)
        -- session-level verbs, joining the d-family the diff verbs already use. the
        -- diff/panel/history buffers are read-only scratch, so the shadowed deletes are
        -- inert; q stays free for native macro recording on every surface
        close = "dc", -- diff/panel/history: end the session (merge, pr or local)
        toggle_panel = "dd", -- diff/panel: hide/show the file panel sidebar
        toggle_layout = "dl", -- diff: flip stacked / split
        -- merge tool, bound on the result buffer. nav + take-this resolution,
        -- the result buffer is the real worktree
        -- file and stays editable, so the whole choose family sits behind <leader>
        -- rather than shadowing live operators
        next_conflict = "]x", -- merge: jump to the next/prev conflict
        prev_conflict = "[x",
        choose_ours = "<leader>co", -- merge: take ours / theirs / base for the conflict
        choose_theirs = "<leader>ct",
        choose_base = "<leader>cb",
        choose_all = "<leader>ca", -- take both (ours then theirs)
        choose_none = "<leader>cx", -- drop the conflict region
    },
    -- show dates as relative ("3 days ago") instead of YYYY-MM-DD wherever the
    -- plugin renders one (the history panel today, more surfaces later)
    relative_dates = false,
    -- base branch for the `base` shortcut (`:Differ base`, `:Differ log base`).
    -- nil auto-detects: origin/HEAD (the remote trunk), else local main/master
    base = nil,
    sidecar_bin = nil,
    -- extra ex-command name(s) routing to the same dispatcher as `:Differ`, e.g.
    -- "D" gives `:D HEAD~1`, `:D log`. nil registers none. names must start with an
    -- uppercase letter (a vim user-command rule); registered by setup()
    command_alias = nil,
}

-- option path -> the set it must fall in. a value outside its set merges cleanly
-- and then silently does nothing, which is what makes these worth checking by name
---@type table<string, string[]>
M.closed = {
    ["layout"] = LAYOUT,
    ["panel.position"] = POSITION,
    ["panel.listing"] = LISTING,
    ["history.position"] = POSITION,
    ["merge.layout"] = PANES,
    ["deep_diff.granularity"] = GRAIN,
}

-- options that default to nil, so the defaults table carries no key for them and
-- the unknown-key walk can't see them. keep in step with the nil entries above
local NILABLE = { base = true, sidecar_bin = true, command_alias = true }

local function show(value)
    if type(value) == "string" then
        return '"' .. value .. '"'
    end
    return tostring(value)
end

local function check_enum(path, value, diags)
    local allowed = M.closed[path]
    if not allowed or value == nil then
        return
    end
    for _, ok in ipairs(allowed) do
        if value == ok then
            return
        end
    end
    local quoted = {}
    for i, ok in ipairs(allowed) do
        quoted[i] = '"' .. ok .. '"'
    end
    diags[#diags + 1] = ("%s must be one of %s (got %s)"):format(
        path,
        table.concat(quoted, ", "),
        show(value)
    )
end

-- one level down into a known table option: unknown sub-keys and their enums.
-- every nested default is non-nil, so absence from the default is a real typo
local function check_section(key, value, diags)
    local default = M.defaults[key]
    if type(default) ~= "table" then
        return
    end
    if type(value) ~= "table" then
        diags[#diags + 1] = ("%s must be a table (got %s)"):format(key, type(value))
        return
    end
    for sub, sub_value in pairs(value) do
        local path = key .. "." .. sub
        if default[sub] == nil then
            diags[#diags + 1] = ('unknown option "%s"'):format(path)
        else
            check_enum(path, sub_value, diags)
        end
    end
end

-- keymaps is flat action -> lhs plus the per-surface subtables, so it doesn't
-- follow the nested-table shape the other sections do
local function check_keymaps(value, diags)
    if type(value) ~= "table" then
        diags[#diags + 1] = ("keymaps must be a table (got %s)"):format(type(value))
        return
    end
    for action, lhs in pairs(value) do
        if SURFACE_SET[action] then
            if type(lhs) ~= "table" then
                diags[#diags + 1] = ("keymaps.%s must be a table of actions (got %s)"):format(
                    action,
                    type(lhs)
                )
            else
                for sub in pairs(lhs) do
                    if M.defaults.keymaps[sub] == nil then
                        diags[#diags + 1] = ('unknown keymap action "keymaps.%s.%s"'):format(
                            action,
                            sub
                        )
                    end
                end
            end
        elseif M.defaults.keymaps[action] == nil then
            diags[#diags + 1] = ('unknown keymap action "keymaps.%s"'):format(action)
        end
    end
end

-- check user opts against the defaults: unknown keys at the top level and one level
-- into each known table, plus the closed value sets. warnings only, and side-effect
-- free so setup() and :checkhealth can both render the same list. pure (no vim), like
-- resolve_keymaps, so it stays in the busted suite
---@param user table|nil
---@return string[]
function M.validate(user)
    if user == nil then
        return {}
    end
    if type(user) ~= "table" then
        return { ("setup() expects a table of options (got %s)"):format(type(user)) }
    end
    local diags = {}
    for key, value in pairs(user) do
        if key == "keymaps" then
            check_keymaps(value, diags)
        elseif M.defaults[key] == nil and not NILABLE[key] then
            diags[#diags + 1] = ('unknown option "%s"'):format(key)
        else
            check_enum(key, value, diags)
            check_section(key, value, diags)
        end
    end
    table.sort(diags) -- pairs order is arbitrary; a stable list keeps the notice readable
    return diags
end

-- resolve the keymaps config into per-surface action tables. the shared (top-level)
-- defaults take any top-level user override, then each surface layers its own
-- `keymaps.<surface>` subtable on top. merges are shallow per action so a user list
-- or `false` replaces the default wholesale (tbl_deep_extend would index-merge lists)
-- pure (no vim) so it stays unit-testable under busted, like the other parsers
---@param user_km table|nil
---@return table<string, table<string, string|string[]|false>>
function M.resolve_keymaps(user_km)
    user_km = user_km or {}
    local shared = {}
    for action, lhs in pairs(M.defaults.keymaps) do
        shared[action] = lhs
    end
    for action, lhs in pairs(user_km) do
        if not SURFACE_SET[action] then
            shared[action] = lhs -- top-level override reaches every surface
        end
    end
    local out = {}
    for _, surface in ipairs(SURFACES) do
        local resolved = {}
        for action, lhs in pairs(shared) do
            resolved[action] = lhs
        end
        local override = user_km[surface]
        if type(override) == "table" then
            for action, lhs in pairs(override) do
                resolved[action] = lhs -- per-surface override wins
            end
        end
        out[surface] = resolved
    end
    return out
end

-- resolve a dotted `M.closed` path against `t`: the table holding the final key, and
-- that key. a path with no dot is top level, so `t` holds it directly
---@param t table
---@param path string
---@return table|nil holder, string key
function M.locate(t, path)
    local section, key = path:match("^(.-)%.(.+)$")
    if not section then
        return t, path
    end
    return type(t[section]) == "table" and t[section] or nil, key
end

-- put any out-of-set value back to its default. a value no branch matches is worse
-- than the default: `panel.position = "middle"` opened the bottom split (the else
-- arm) while rendering as a sidebar (the top/bottom test), so nothing downstream
-- agreed on what it meant
local function clamp_closed(cfg)
    for path, allowed in pairs(M.closed) do
        local holder, key = M.locate(cfg, path)
        if holder and not vim.tbl_contains(allowed, holder[key]) then
            holder[key] = (M.locate(M.defaults, path))[key]
        end
    end
end

-- merge user opts over defaults and return the resolved config. keymaps are resolved
-- into per-surface tables separately (a plain deep-extend would index-merge the
-- multi-lhs lists)
---@param user table|nil
---@return differ.Config
function M.resolve(user)
    user = user or {}
    local cfg = vim.tbl_deep_extend("force", M.defaults, user)
    cfg.keymaps = M.resolve_keymaps(user.keymaps)
    clamp_closed(cfg)
    return cfg
end

return M
