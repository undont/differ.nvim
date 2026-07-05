-- view lifecycle: own one derived buffer per render column, lay them into windows
-- (one for stacked, a scroll-bound pair for split), and hold each column's map.
-- buffers + maps are regenerated atomically on re-render; the gutter rail, the
-- diff highlight layer, and the treesitter syntax pass are refreshed from
-- the map; overlays are extmark-only

local render = require("differ.render")
local paint = require("differ.ui.paint")
local syntax = require("differ.syntax")
local statuscolumn = require("differ.ui.statuscolumn")
local nav = require("differ.nav")
local bind = require("differ.util.keymap").bind

local ns = vim.api.nvim_create_namespace("differ")
local staged_ns = vim.api.nvim_create_namespace("differ.staging")
local cursor_ns = vim.api.nvim_create_namespace("differ.cursorline")
-- dimmed deep-diff groups for staged hunks, keyed by rail kind (mirrors ui.paint)
local STAGED_LINE_HL = { old = "differStagedLineDelete", new = "differStagedLineAdd" }
local STAGED_WORD_HL = { old = "differStagedWordDelete", new = "differStagedWordAdd" }
local STATUSCOLUMN_EXPR = '%!v:lua.require("differ.ui.statuscolumn").render()'
local FOLDTEXT_EXPR = 'v:lua.require("differ.ui.foldtext").render()'
local CTRL_D = vim.api.nvim_replace_termcodes("<C-d>", true, false, true)
local CTRL_U = vim.api.nvim_replace_termcodes("<C-u>", true, false, true)

local set_wo = require("differ.util.win").set_local

---@type table<integer, differ.View> -- bufnr -> owning view, for command dispatch
local by_buf = {}

-- place the cursor at (line, col) in the current window, clamping the column to the
-- target line's length so a column past EOL doesn't fail the set and strand us at the
-- top of the file. used by de/df, which carry the diff cursor's column to the real file
---@param line integer
---@param col integer
local function place_cursor(line, col)
    local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, 0, { line, math.min(col, #text) })
    vim.cmd("normal! zz")
end

-- monotonic per-view id, for a stable per-view augroup name (the close guard)
local view_seq = 0
local function next_id()
    view_seq = view_seq + 1
    return view_seq
end

-- the most recently laid-out view: only it owns the diff-window-close teardown. there
-- is one live session at a time, so a superseded view's stale WinClosed (window ids get
-- recycled) must not tear down a newer session
local armed_view = nil

---@class differ.ViewColumn
---@field bufnr integer
---@field winid integer|nil
---@field map differ.LineMap
---@field side differ.ColumnSide

-- the hunk-staging capability the git frontend supplies per source. the
-- view keeps its diff frozen and marks staged hunks in place rather than re-reading
-- git, so it tracks per-hunk state and calls `apply` to patch one hunk: `reverse`
-- false stages, true unstages, `offset` shifts past already-staged hunks before it.
-- `initial` is every hunk's opening state (an unstaged diff opens unstaged, a staged
-- one opens staged). `apply` patches one hunk and returns ok; `refresh` repaints the
-- panel counts and is called once after a single toggle or a whole S/U batch
---@class differ.view.Staging
---@field initial "staged"|"unstaged"
---@field apply fun(model: differ.DiffModel, hunk: differ.Hunk, offset: integer, reverse: boolean): boolean
---@field refresh fun()

---@class differ.View
---@field columns differ.ViewColumn[]
---@field model differ.DiffModel
---@field layout differ.Layout
---@field context integer
---@field wrap boolean  -- soft-wrap long lines in the diff windows
---@field counter boolean  -- hunk-counter winbar on the diff windows
---@field cursorline_tint boolean  -- tint the cursor line by add/delete kind
---@field deep_diff table
---@field keymaps table
---@field can_stage boolean  -- session-level: bind s/u (worktree-status panels)
---@field staging differ.view.Staging|nil  -- per-source capability (nil off-side)
---@field staged_hunks table<integer, boolean>  -- hunk index -> staged, for marking
---@field on_edit_unstage fun(path: string)|nil  -- frontend hook: unstage + re-source for edit-in-review
---@field extra_keymaps differ.panel.ExtraMap[]|nil  -- session-supplied buffer maps (pr unviewed nav)
---@field on_rerender fun()|nil  -- session hook after a re-render, to re-apply overlays (pr threads)
---@field on_cursor fun()|nil  -- session hook on cursor move in a diff window (pr thread cursor-expand)
---@field edit_win integer|nil  -- transient editable real-file window (edit-in-review)
---@field id integer  -- per-view id, for the close-guard augroup name
---@field _suppress_close boolean  -- true while we close a diff window ourselves (relayout/teardown)
---@field _closing boolean  -- re-entrancy guard once a user close has begun
---@field _close_group integer|nil  -- augroup id for the WinClosed close guard
local View = {}
View.__index = View

---@class differ.view.Opts
---@field layout differ.Layout
---@field context integer
---@field wrap? boolean
---@field counter? boolean
---@field cursorline_tint? boolean
---@field deep_diff table
---@field keymaps? table
---@field staging? differ.view.Staging
---@field can_stage? boolean
---@field on_edit_unstage? fun(path: string)
---@field extra_keymaps? differ.panel.ExtraMap[]
---@field on_rerender? fun()
---@field on_cursor? fun()

-- build a view for a model. buffers and data are created here; windows are not
-- touched until :open(), so a View can be constructed headlessly for tests
---@param model differ.DiffModel
---@param opts differ.view.Opts
---@return differ.View
function View.new(model, opts)
    local self = setmetatable({
        columns = {},
        model = model,
        layout = opts.layout,
        context = opts.context,
        wrap = opts.wrap ~= false, -- default on; only an explicit false disables it
        counter = opts.counter ~= false, -- default on; only an explicit false disables it
        cursorline_tint = opts.cursorline_tint ~= false, -- default on; explicit false disables
        deep_diff = opts.deep_diff,
        -- the diff surface's resolved action -> lhs map; default to the shared
        -- defaults so a directly-constructed View still binds (merge keeps partials)
        keymaps = vim.tbl_extend(
            "force",
            require("differ.config").defaults.keymaps,
            opts.keymaps or {}
        ),
        can_stage = opts.can_stage or false,
        staging = opts.staging,
        on_edit_unstage = opts.on_edit_unstage,
        -- session-supplied maps the generic diff surface doesn't own (pr unviewed nav)
        extra_keymaps = opts.extra_keymaps,
        on_rerender = opts.on_rerender,
        on_cursor = opts.on_cursor,
        staged_hunks = {},
        id = next_id(),
        _suppress_close = false,
        _closing = false,
    }, View)
    self:_init_staged()
    self:rerender(opts)
    return self
end

-- seed per-hunk staged state for the current source: a staged diff (HEAD↔index)
-- opens with every hunk staged, an unstaged diff (index↔worktree) with none
function View:_init_staged()
    self.staged_hunks = {}
    if self.staging and self.staging.initial == "staged" then
        for i = 1, #self.model.hunks do
            self.staged_hunks[i] = true
        end
    end
end

-- a stable, file-shaped buffer name so the statusline/winbar shows the file path
-- instead of `[Scratch]`. the `differ://` scheme keeps it distinct from the
-- real file (a bare relative name would resolve to the same absolute path and
-- collide) and marks it non-editable; the path stays last so `:t` is the basename.
-- the default stacked view is just `differ://<path>`; a split's two columns get an
-- old/new segment to stay distinct
---@param model differ.DiffModel
---@param side differ.ColumnSide
---@return string
local function buf_name(model, side)
    if side == "unified" then
        return "differ://" .. model.path
    end
    return ("differ://%s/%s"):format(side, model.path)
end

-- name `bufnr` for `side`, falling back to a bufnr-suffixed name if that exact
-- name is somehow already taken (E95), e.g. a second concurrent view
---@param bufnr integer
---@param model differ.DiffModel
---@param side differ.ColumnSide
local function name_buffer(bufnr, model, side)
    local name = buf_name(model, side)
    if not pcall(vim.api.nvim_buf_set_name, bufnr, name) then
        pcall(vim.api.nvim_buf_set_name, bufnr, name .. "#" .. bufnr)
    end
end

-- a private filetype rather than the source one: the buffer holds interleaved
-- old+new lines that aren't valid source and differ paints its own syntax (the
-- syntax module reads the language off the path, not this option), so a native
-- highlighter would only mangle it. a source `FileType <lang>` would also attach
-- lsp, lint and semantic-token churn to a throwaway differ:// buffer, which is what
-- breaks which-key's trigger windows on .cs/roslyn diffs. the source filetype is
-- stashed in a buffer var for a lualine component that wants the language label
local DIFF_FILETYPE = "differdiff"
---@param bufnr integer
---@param path string
local function set_filetype(bufnr, path)
    vim.b[bufnr].differ_filetype = vim.filetype.match({ filename = path }) or ""
    if vim.bo[bufnr].filetype ~= DIFF_FILETYPE then
        vim.bo[bufnr].filetype = DIFF_FILETYPE
    end
    pcall(vim.treesitter.stop, bufnr)
    vim.bo[bufnr].syntax = "OFF"
end

-- gitsigns never attaches to our synthetic buffers, so a lualine that reads its
-- status dict shows no branch/diffstat. populate those vars ourselves from the
-- model: counts come from the hunks, the branch from model.head (frontend-set)
---@param bufnr integer
---@param model differ.DiffModel
local function set_git_status(bufnr, model)
    local added, changed, removed = 0, 0, 0
    for _, h in ipairs(model.hunks) do
        local common = math.min(h.old_count, h.new_count)
        changed = changed + common
        added = added + (h.new_count - common)
        removed = removed + (h.old_count - common)
    end
    vim.b[bufnr].gitsigns_status_dict =
        { added = added, changed = changed, removed = removed, head = model.head }
    vim.b[bufnr].gitsigns_head = model.head
end

-- the map for a side, or the unified map. consumers (]c, staging, comment
-- anchoring) read this rather than branching on layout themselves
---@param side differ.ColumnSide
---@return differ.LineMap|nil
function View:map_for(side)
    for _, col in ipairs(self.columns) do
        if col.side == side or col.side == "unified" then
            return col.map
        end
    end
    return nil
end

-- the column (bufnr + map) backing a side, for consumers that set extmarks on the
-- right buffer (the thread overlay). a stacked view's single "unified" column backs
-- both sides; a split returns the matching old/new column
---@param side differ.ColumnSide
---@return { bufnr: integer, map: differ.LineMap, side: differ.ColumnSide }|nil
function View:column_for(side)
    for _, col in ipairs(self.columns) do
        if col.side == side or col.side == "unified" then
            return col
        end
    end
    return nil
end

-- re-render the active model and atomically replace each column's content, map,
-- gutter rail, and highlight layer. window layout is unchanged; if a re-render
-- changes the column count (a layout toggle), call :open() to relayout
---@param opts { layout: differ.Layout, context: integer, deep_diff: table }
function View:rerender(opts)
    self.layout = opts.layout
    self.context = opts.context
    self.deep_diff = opts.deep_diff
    local result = render.render(self.model, opts)

    for i, col in ipairs(result.columns) do
        local existing = self.columns[i]
        local bufnr = existing and existing.bufnr or vim.api.nvim_create_buf(false, true)
        name_buffer(bufnr, self.model, col.side)
        set_filetype(bufnr, self.model.path)
        set_git_status(bufnr, self.model)
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, col.lines)
        vim.bo[bufnr].modifiable = false
        paint.apply(bufnr, ns, col)
        syntax.apply(bufnr, col, self.model)
        statuscolumn.set(bufnr, statuscolumn.format(col))
        self.columns[i] = {
            bufnr = bufnr,
            winid = existing and existing.winid or nil,
            map = col.map,
            side = col.side,
            folds = col.folds,
        }
        by_buf[bufnr] = self
    end
    -- shrinking column count (split -> stacked): drop the surplus buffers/windows
    for i = #result.columns + 1, #self.columns do
        self:_discard(self.columns[i])
        self.columns[i] = nil
    end
    self:_paint_staged() -- overlay marks for staged hunks (no-op off a staging view)
    self:_paint_cursorline() -- our cursor-line overlay (no-op until windows exist)
    if self.on_rerender then
        self.on_rerender() -- re-apply session overlays (the pr thread overlay) onto the fresh buffers
    end
    -- folds are a window concern, not buffer content: the callers that change the
    -- ranges or the windows reapply them (set_context/set_source in place, _relayout
    -- on open / layout toggle), so rerender doesn't, avoiding a double-apply
end

-- overlay the staged-hunk marks: a dimmed deep diff over every line of a staged hunk
-- plus the gutter glyph. repaints the line in the quieter staged add/delete shade and
-- its word spans in the staged word shade, above the live diff bg + word spans, so a
-- staged hunk reads as set-aside yet still shows what changed. repainted on every
-- render and on each toggle; buffer content is untouched (the diff stays frozen).
-- a no-op off a staging view, which leaves the gutter at its normal width
function View:_paint_staged()
    if not self.can_stage then
        return
    end
    for _, col in ipairs(self.columns) do
        vim.api.nvim_buf_clear_namespace(col.bufnr, staged_ns, 0, -1)
        local staged_lines = {}
        for i, line in ipairs(col.map.lines) do
            if line.hunk and self.staged_hunks[line.hunk] then
                local row = i - 1
                -- char-level fill with hl_eol, not line_hl_group: a line_hl_group covers
                -- the text but loses the past-EOL tail to the diff bg's own hl_eol (it
                -- can't be raised above it), leaking the vivid colour into the tail. as a
                -- char fill it spans the whole row and, above the live add/delete bg AND
                -- word spans, recolours the line in the quieter staged shade
                vim.api.nvim_buf_set_extmark(col.bufnr, staged_ns, row, 0, {
                    end_row = i,
                    end_col = 0,
                    hl_group = STAGED_LINE_HL[line.kind] or "differStagedLine",
                    hl_eol = true,
                    priority = 210, -- above the live add/delete bg (100) and word spans (200)
                })
                -- the changed words a notch above the staged line so the deep diff still reads
                local word_hl = STAGED_WORD_HL[line.kind]
                if word_hl and line.spans then
                    for _, span in ipairs(line.spans) do
                        vim.api.nvim_buf_set_extmark(col.bufnr, staged_ns, row, span.col_start, {
                            end_col = span.col_end,
                            hl_group = word_hl,
                            priority = 215,
                        })
                    end
                end
                staged_lines[i] = true
            end
        end
        statuscolumn.set_staged(col.bufnr, staged_lines)
    end
end

-- repaint our own cursor line above the diff backgrounds, since a no-foreground
-- CursorLine is low-priority and gets buried by them. mirrors the diff line bg
-- (a char-level fill with hl_eol so it spans the whole row past EOL) but at a higher
-- priority so it wins; bg-only, so syntax foreground and word spans still show
-- through. with cursorline_tint on, the fill takes the row's add/delete shade so the
-- change kind reads under the cursor instead of a neutral wash. cleared from every
-- column and painted only in the focused one (the cursor lives in one column), so the
-- off-side column shows none. driven by CursorMoved / WinEnter and after each render
function View:_paint_cursorline()
    for _, col in ipairs(self.columns) do
        if col.bufnr and vim.api.nvim_buf_is_valid(col.bufnr) then
            vim.api.nvim_buf_clear_namespace(col.bufnr, cursor_ns, 0, -1)
        end
    end
    local col = self:_focused_column()
    local win = col and col.winid
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    local line = col.map.lines[row + 1]
    -- tint the cursor line by the row's change kind so the add/remove colour survives
    -- under the cursor (a neutral overlay would bury it); plain neutral when off
    local hl = "differCursorLine"
    if self.cursorline_tint then
        local kind = line and line.kind
        if kind == "new" then
            hl = "differCursorLineAdd"
        elseif kind == "old" then
            hl = "differCursorLineDelete"
        end
    end
    -- a staged line is recoloured above the live word spans (210/215); lift the cursor
    -- tint over that so the focused line still lights up in its kind. on a normal line
    -- stay under the word spans (200) so changed words show through under the cursor
    local staged = self.can_stage and line and line.hunk and self.staged_hunks[line.hunk]
    vim.api.nvim_buf_set_extmark(col.bufnr, cursor_ns, row, 0, {
        end_row = row + 1,
        end_col = 0,
        hl_group = hl,
        hl_eol = true, -- fill past EOL so the whole row is covered, like the diff bg
        priority = staged and 220 or 160,
    })
end

-- the net line-count delta of the staged hunks before `idx`: the frozen view's
-- line numbers are from open time, but git applies against the live index, where
-- each already-staged earlier hunk has shifted positions by its added/removed lines
---@param idx integer
---@return integer
function View:_stage_offset(idx)
    local off = 0
    for j = 1, idx - 1 do
        if self.staged_hunks[j] then
            local h = self.model.hunks[j]
            off = off + (h.new_count - h.old_count)
        end
    end
    return off
end

-- (re)create the native folds for each column's window from its fold ranges, left
-- open by default (the structure stays so zc/za collapse them on demand), unless
-- `closed` says otherwise. `closed[i]` (per column, keyed by the fold's `gap`
-- boundary index, not position in the list) re-closes the fold the user had
-- manually closed before a context change shifted the ranges; omit it to open
-- everything (a file switch or the initial open, where the previous fold state
-- doesn't carry over). matching by `gap` rather than list position survives a
-- neighbouring gap disappearing from the list entirely at the new context (not
-- just becoming a non-real single-line range): a gap's boundary index is fixed
-- by which hunks flank it, regardless of whether *that* gap folds at either
-- context. reapplied only where the ranges or windows change: a context change
-- (d= / d-), a file switch, a layout toggle, and open; never on scroll or redraw.
-- with context = full the renderer returns no ranges.
---@param closed? table<integer, boolean>[]  -- per-column, keyed by fold.gap: "was this one closed"
function View:_apply_folds(closed)
    for ci, col in ipairs(self.columns) do
        local win = col.winid
        local was_closed = closed and closed[ci]
        if win and vim.api.nvim_win_is_valid(win) then
            set_wo(win, "foldmethod", "manual")
            set_wo(win, "foldtext", FOLDTEXT_EXPR)
            set_wo(win, "foldenable", true)
            vim.api.nvim_win_call(win, function()
                vim.cmd("silent! normal! zE") -- drop existing folds before rebuilding
                for _, f in ipairs(col.folds or {}) do
                    if f.last > f.first then
                        vim.cmd(("silent! %d,%dfold"):format(f.first, f.last)) -- :fold starts closed
                        if not (was_closed and f.gap ~= nil and was_closed[f.gap]) then
                            vim.cmd(("silent! %dfoldopen"):format(f.first))
                        end
                    end
                end
            end)
        end
    end
end

-- the view owning the current buffer, if any. commands dispatch through this
---@return differ.View|nil
function View.current()
    return by_buf[vim.api.nvim_get_current_buf()]
end

-- the view owning `bufnr`, if any. lets the panel reach the diff view it drives
-- (via its origin window's buffer) so panel-side keys act on that view
---@param bufnr integer
---@return differ.View|nil
function View.for_buf(bufnr)
    return by_buf[bufnr]
end

-- whether the view's primary window is still alive (panel uses this to decide
-- between re-sourcing in place and opening fresh)
---@return boolean
function View:is_open()
    local col = self.columns[1]
    return col ~= nil and col.winid ~= nil and vim.api.nvim_win_is_valid(col.winid)
end

-- swap the diffed file in place: same windows/layout/context, new model. the
-- panel calls this when a different file is selected so the View is re-sourced,
-- not recreated (separation of concerns). column count is layout-determined,
-- so it never changes here, no relayout. `staging` rides along because the stage
-- direction is per-file (a staged entry unstages, an unstaged one stages).
-- `opts.focus_line` is a new-side file line to snap to (a re-source of the same
-- file underneath the user); without it the cursor lands on the first unstaged hunk
---@param model differ.DiffModel
---@param staging differ.view.Staging|nil
---@param opts? { focus_line?: integer }
function View:set_source(model, staging, opts)
    -- a switch to a different file leaves any edit window stale; drop it. a same-file
    -- re-source (the watcher after a `:w`) keeps it so editing continues uninterrupted
    if self.edit_win and self.model.path ~= model.path then
        self:_release_edit_window()
    end
    self.model = model
    self.staging = staging
    self:_init_staged() -- a new file: reseed staged state from the fresh git read
    self:rerender({ layout = self.layout, context = self.context, deep_diff = self.deep_diff })
    self:_apply_folds() -- new file's ranges; windows unchanged so refold in place
    if opts and opts.focus_line then
        self:focus_new_line(opts.focus_line, true) -- hold the precise line across a refresh
    else
        self:_focus_first_hunk() -- land on the first unstaged hunk of the new file
    end
end

-- swap the layout for this view (a pure re-render behind the map contract).
-- column count changes (1 <-> 2), so re-lay the windows after
---@param layout differ.Layout
function View:set_layout(layout)
    if layout == self.layout then
        return
    end
    self:rerender({ layout = layout, context = self.context, deep_diff = self.deep_diff })
    self:_relayout()
end

-- flip stacked <-> split
function View:toggle_layout()
    self:set_layout(self.layout == "stacked" and "split" or "stacked")
end

-- set the per-view context line count (math.huge = whole file). same column
-- count, so no relayout, content/map/gutter/highlights refresh in place
---@param n integer
function View:set_context(n)
    -- snapshot which folds are closed before rerender replaces col.folds with the
    -- ranges at the new context, so a manually-closed fold (zc/zm) survives the
    -- boundary shift instead of reopening under the user. keyed by fold.gap, not
    -- list position, so a neighbouring gap vanishing at the new context can't
    -- shift a later fold's key out from under it (see _apply_folds)
    local closed = {}
    for ci, col in ipairs(self.columns) do
        closed[ci] = {}
        local win = col.winid
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_call(win, function()
                for _, f in ipairs(col.folds or {}) do
                    if f.last > f.first and f.gap ~= nil then
                        closed[ci][f.gap] = vim.fn.foldclosed(f.first) ~= -1
                    end
                end
            end)
        end
    end
    self:rerender({ layout = self.layout, context = n, deep_diff = self.deep_diff })
    self:_apply_folds(closed) -- ranges shifted with the context; windows unchanged
end

-- widen/narrow context by `delta`. no-op while whole-file (can't decrement ∞)
---@param delta integer
function View:adjust_context(delta)
    if self.context == math.huge then
        return
    end
    self:set_context(math.max(0, self.context + delta))
end

-- goto_hunk's fallback for the diff window's own ]c/[c: past the last/first hunk,
-- defer to a live history session's own fallback (steps within the current commit
-- in range mode; a no-op everywhere else, leaving the plain stop-and-notify boundary)
---@param direction "next"|"prev"
---@param view differ.View
---@return boolean moved
local function history_hunk_fallback(direction, view)
    local history = require("differ.history").current()
    return history ~= nil and history:goto_hunk_fallback(direction, view)
end

-- per-window appearance + buffer-local motions. our own dual-rail gutter replaces
-- the native gutter; ]c / [c jump between hunks via the active column's map
---@param winid integer
---@param bufnr integer
function View:_setup_window(winid, bufnr)
    vim.api.nvim_win_set_buf(winid, bufnr)
    set_wo(winid, "number", false)
    set_wo(winid, "relativenumber", false)
    set_wo(winid, "signcolumn", "no")
    set_wo(winid, "foldcolumn", "0")
    set_wo(winid, "list", false) -- no listchars markers; we own rendering
    set_wo(winid, "wrap", self.wrap)
    set_wo(winid, "spell", false) -- syntax is OFF here, so spell would check every word, not just comments
    if self.counter then
        -- a `%!` expression so the hunk count tracks the cursor on every redraw
        set_wo(winid, "winbar", '%!v:lua.require("differ.ui.winbar").diff()')
    end
    set_wo(winid, "scrollbind", false) -- cleared default; split re-enables it in :open
    set_wo(winid, "statuscolumn", STATUSCOLUMN_EXPR)
    -- own the cursor line: a no-fg CursorLine is low-priority and lost under the diff
    -- backgrounds, so repaint it as an extmark on cursor move / window focus
    local group = vim.api.nvim_create_augroup("differ.cursorline." .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "BufEnter" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            self:_paint_cursorline()
            if self.on_cursor then
                self.on_cursor() -- session cursor hook (the pr thread cursor-expand)
            end
        end,
    })
    local km = self.keymaps
    bind(bufnr, km.next_hunk, function()
        self:goto_hunk("next", {
            fallback = function(direction)
                return history_hunk_fallback(direction, self)
            end,
        })
    end, "differ: next hunk")
    bind(bufnr, km.prev_hunk, function()
        self:goto_hunk("prev", {
            fallback = function(direction)
                return history_hunk_fallback(direction, self)
            end,
        })
    end, "differ: previous hunk")
    bind(bufnr, km.more_context, function()
        self:adjust_context(1)
    end, "differ: more context")
    bind(bufnr, km.less_context, function()
        self:adjust_context(-1)
    end, "differ: less context")
    -- go-to-file: leave the session and open the real file. available wherever
    -- the source is file-backed (jump_to_file notifies if not)
    bind(bufnr, km.goto_file, function()
        self:jump_to_file()
    end, "differ: go to the real file")
    -- edit-in-review: only on an uncommitted diff (worktree or staged), where
    -- the file on disk is editable. rev-pair / history / PR diffs aren't
    if self:_editable_source() then
        bind(bufnr, km.edit_file, function()
            self:edit_file()
        end, "differ: edit the real file")
    end
    -- next/prev file drive the file panel's (or history's) selection in lockstep,
    -- keeping focus here in the diff window (no-op when neither is open)
    bind(bufnr, km.next_file, function()
        self:step_file("next")
    end, "differ: next file")
    bind(bufnr, km.prev_file, function()
        self:step_file("prev")
    end, "differ: previous file")
    -- scroll defaults to f/b, which shadow native find-char / back-word (set false)
    bind(bufnr, km.scroll_down, function()
        self:quarter_scroll("down")
    end, "differ: scroll down a quarter page")
    bind(bufnr, km.scroll_up, function()
        self:quarter_scroll("up")
    end, "differ: scroll up a quarter page")
    bind(bufnr, km.help, function()
        self:show_help()
    end, "differ: keymap help")
    -- stage / unstage the hunk under the cursor, hunk-level here vs file-level
    -- in the panel. bound for the whole worktree-status session; the per-file
    -- direction is checked at call time (the buffer is read-only, so shadowing native
    -- substitute / undo is harmless)
    if self.can_stage then
        bind(bufnr, km.stage, function()
            self:stage_hunk()
        end, "differ: stage hunk")
        bind(bufnr, km.unstage, function()
            self:unstage_hunk()
        end, "differ: unstage hunk")
        bind(bufnr, km.stage_all, function()
            self:stage_all()
        end, "differ: stage all hunks")
        bind(bufnr, km.unstage_all, function()
            self:unstage_all()
        end, "differ: unstage all hunks")
    end
    for _, m in ipairs(self.extra_keymaps or {}) do
        bind(bufnr, m.spec, m.fn, m.desc, m.mode)
    end
end

-- step the file panel's selection (and re-source this view) without leaving the diff
-- window, the in-view counterpart to the panel's own ]f / [f. `wrap` defaults on (for
-- ]f / [f); the staging review flow passes false so s/S/u/U stop at the list ends.
-- returns whether a file/commit was actually opened (false at a no-wrap list end),
-- which the hunk-nav and review callers use to notify at the change-set boundary
---@param direction "next"|"prev"
---@param wrap? boolean
---@return boolean moved
function View:step_file(direction, wrap)
    local panel = require("differ.panel").current()
    if panel and panel:is_open() then
        return panel:goto_file(direction, true, wrap) -- keep focus in the diff window
    end
    -- file history: one file, so ]f / [f step commits instead
    local history = require("differ.history").current()
    if history and history:is_open() then
        return history:step(direction, true)
    end
    -- sidebar hidden but the panel session is live: step from internal selection so
    -- ]f / [f still walk files with no panel window to read the cursor from
    if panel then
        return panel:goto_file(direction, true, wrap)
    end
    return false
end

-- scroll a quarter of the window height, cursor following (count-prefixed <C-d>/
-- <C-u>, which clamp at the buffer ends)
---@param direction "down"|"up"
function View:quarter_scroll(direction)
    local n = math.max(1, math.floor(vim.api.nvim_win_get_height(0) / 4))
    vim.api.nvim_feedkeys(n .. (direction == "down" and CTRL_D or CTRL_U), "nx", false)
end

-- g?: a floating keymap cheatsheet for the diff window, mirroring the panel's.
-- rows come from the live keymaps (so a configured lhs shows correctly) and list
-- only the keys actually bound for this source: staging, edit-in-review, and the
-- session's extra maps (the pr unviewed nav and thread/comment verbs)
function View:show_help()
    local km = self.keymaps
    local function fmt(spec)
        return type(spec) == "table" and table.concat(spec, " / ") or tostring(spec)
    end
    local function pair(a, b)
        return fmt(a) .. " / " .. fmt(b)
    end
    local rows = {
        { pair(km.next_hunk, km.prev_hunk), "next / previous hunk" },
        { pair(km.next_file, km.prev_file), "next / previous file" },
        { pair(km.scroll_down, km.scroll_up), "scroll down / up" },
        { pair(km.more_context, km.less_context), "more / less context" },
        { fmt(km.goto_file), "go to the real file" },
    }
    if self:_editable_source() then
        rows[#rows + 1] = { fmt(km.edit_file), "edit the real file (in review)" }
    end
    if self.can_stage then
        rows[#rows + 1] = { pair(km.stage, km.unstage), "stage / unstage hunk" }
        rows[#rows + 1] = { pair(km.stage_all, km.unstage_all), "stage / unstage all" }
    end
    for _, m in ipairs(self.extra_keymaps or {}) do
        rows[#rows + 1] = { fmt(m.spec), m.desc }
    end
    rows[#rows + 1] = { fmt(km.help), "this help" }

    local keyw = 0
    for _, r in ipairs(rows) do
        keyw = math.max(keyw, #r[1])
    end
    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = (" %-" .. keyw .. "s   %s"):format(r[1], r[2])
    end
    -- dismiss on the configured help key too, not just the hardcoded g?
    local dismiss = { "q", "<Esc>" }
    vim.list_extend(dismiss, type(km.help) == "table" and km.help or { km.help })
    require("differ.ui.help").show(lines, { title = " Differ: diff ", dismiss = dismiss })
end

-- the column whose window is currently focused, defaulting to the first. split
-- can focus either pane, so motions/jumps read this rather than assuming column 1
---@return differ.ViewColumn
function View:_focused_column()
    local win = vim.api.nvim_get_current_win()
    for _, c in ipairs(self.columns) do
        if c.winid == win then
            return c
        end
    end
    return self.columns[1]
end

local function run_hunk_fallback(direction, opts)
    return opts and opts.fallback and opts.fallback(direction)
end

-- move the cursor to the next/prev hunk in the focused column. at a change-set
-- boundary it flows into the adjacent file (no wrap); a log/history session is the
-- exception: hunk nav stays within the current commit's diff (commits step via ]f/[f),
-- so it stops at the first/last hunk rather than crossing into the next commit
---@param direction "next"|"prev"
---@param opts? { fallback?: fun(direction: "next"|"prev"): boolean|nil }
function View:goto_hunk(direction, opts)
    local col = self:_focused_column()
    local win = col.winid or vim.api.nvim_get_current_win()
    local lnum = vim.api.nvim_win_get_cursor(col.winid or win)[1]
    -- explicit branch, not `a and next() or prev()`: next_hunk returns nil at the
    -- last hunk, which the and/or idiom would wrongly fall through to prev_hunk
    local target
    if direction == "next" then
        target = nav.next_hunk(col.map, lnum)
    else
        target = nav.prev_hunk(col.map, lnum)
    end
    if target then
        return vim.api.nvim_win_set_cursor(col.winid or win, { target, 0 })
    end
    -- at a boundary. in a log/history session the change set is a single commit, so
    -- don't flow into the adjacent commit (that's ]f/[f); just stop with a notice
    local history = require("differ.history").current()
    local in_history = history ~= nil and history:is_open()
    if direction == "next" then
        -- past the last hunk: flow into the next file (no wrap), or notify at the last one
        if in_history or not self:step_file("next", false) then
            if not run_hunk_fallback(direction, opts) then
                vim.notify("differ: no next hunk", vim.log.levels.INFO)
            end
        end
    elseif not in_history and self:step_file("prev", false) then
        self:_focus_last_hunk() -- landed on the previous file: continue the backward flow
    else
        if not run_hunk_fallback(direction, opts) then
            vim.notify("differ: no previous hunk", vim.log.levels.INFO)
        end
    end
end

-- the buffer line to land on when a file opens: the start of the first
-- unstaged hunk, the natural place to begin reviewing, falling back to the first
-- hunk when everything is already staged, or nil for a file with no hunks
---@param col differ.ViewColumn
---@return integer|nil
function View:_first_review_line(col)
    local first_hunk
    for i, line in ipairs(col.map.lines) do
        if line.hunk then
            first_hunk = first_hunk or i
            if not self.staged_hunks[line.hunk] then
                return i
            end
        end
    end
    return first_hunk
end

-- move the primary window's cursor to the first unstaged hunk (or first hunk). run
-- on open and on every file switch so ]f / [f and selecting a file drop you on the
-- first thing to review rather than wherever the cursor happened to be
function View:_focus_first_hunk()
    local col = self.columns[1]
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return
    end
    local lnum = self:_first_review_line(col)
    if lnum then
        pcall(vim.api.nvim_win_set_cursor, col.winid, { lnum, 0 })
    end
end

-- the new-side file line the cursor currently sits on, for holding position across
-- an in-place re-source (an external refresh of the same file). read from the new-
-- side column (the unified column in stacked, the right column in split) so it pairs
-- with focus_new_line; nil when there's no live new side
---@return integer|nil
function View:cursor_new_line()
    -- while editing, the live position is in the edit window (the real worktree file,
    -- which is the new side), so use its line directly; the diff window's own cursor is
    -- stale there. this makes a post-`:w` re-source focus the line just edited
    if self.edit_win and vim.api.nvim_win_is_valid(self.edit_win) then
        return vim.api.nvim_win_get_cursor(self.edit_win)[1]
    end
    local col = self.columns[#self.columns]
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return nil
    end
    local lnum = vim.api.nvim_win_get_cursor(col.winid)[1]
    return nav.file_line(col.map, lnum)
end

-- position the new side near `new_lnum` (where the cursor was, or the line just
-- edited) across an in-place re-source. with `exact` (open-on-origin, or a re-source
-- holding the precise line), when that line maps to a rendered *changed* line, land on
-- it and centre it so an edit deep in a hunk shows the edit, not the hunk's top. a
-- cursor parked on an unchanged/context line (e.g. opening from the top of the file)
-- falls back to the nearest hunk's start, landing on the change you were by, not on the
-- leading context (this is what open-on-origin wants)
---@param new_lnum integer
---@param exact? boolean
function View:focus_new_line(new_lnum, exact)
    local col = self.columns[#self.columns] -- the new side: the unified col, or right in split
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return
    end
    -- the line maps straight to a rendered changed line (the line just edited, or the
    -- origin line :Differ was run from); hold it exactly rather than snapping to the hunk
    local at = col.map.from_new[new_lnum]
    if exact and at and col.map.lines[at] and col.map.lines[at].hunk then
        pcall(vim.api.nvim_win_set_cursor, col.winid, { at, 0 })
        pcall(vim.api.nvim_win_call, col.winid, function()
            vim.cmd("normal! zz")
        end)
        return
    end
    local hunks = self.model.hunks
    if #hunks == 0 then
        return
    end
    local best, best_dist = 1, nil
    for idx, h in ipairs(hunks) do
        local lo, hi = h.new_start, h.new_start + math.max(h.new_count, 1) - 1
        local dist = 0
        if new_lnum < lo then
            dist = lo - new_lnum
        elseif new_lnum > hi then
            dist = new_lnum - hi
        end
        if not best_dist or dist < best_dist then
            best, best_dist = idx, dist
        end
    end
    for i, line in ipairs(col.map.lines) do
        if line.hunk == best then
            pcall(vim.api.nvim_win_set_cursor, col.winid, { i, 0 })
            return
        end
    end
end

-- the buffer line of the last hunk's start, where the backward review flow lands
-- when stepping into a previous file (so u keeps moving backward through it)
---@param col differ.ViewColumn
---@return integer|nil
function View:_last_hunk_line(col)
    local last = #self.model.hunks
    if last == 0 then
        return nil
    end
    for i, line in ipairs(col.map.lines) do
        if line.hunk == last then
            return i
        end
    end
    return nil
end

-- move the primary window's cursor to the last hunk (backward file-step landing)
function View:_focus_last_hunk()
    local col = self.columns[1]
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return
    end
    local lnum = self:_last_hunk_line(col)
    if lnum then
        pcall(vim.api.nvim_win_set_cursor, col.winid, { lnum, 0 })
    end
end

-- the index of the hunk the cursor sits in, via the focused column's map
-- (staging). nil on a context / meta / unchanged line that belongs to no hunk
---@return integer|nil
function View:_hunk_index_under_cursor()
    local col = self:_focused_column()
    local win = col.winid or vim.api.nvim_get_current_win()
    local line = col.map.lines[vim.api.nvim_win_get_cursor(win)[1]]
    return line and line.hunk or nil
end

-- patch hunk `idx` to `want_staged` in the index from the frozen hunk model (never
-- buffer text), shifted past the hunks staged before it, and mark it. no panel
-- refresh / repaint, so callers can batch. returns whether it changed
---@param idx integer
---@param want_staged boolean
---@return boolean
function View:_apply_hunk(idx, want_staged)
    if (self.staged_hunks[idx] or false) == want_staged then
        return false
    end
    local offset = self:_stage_offset(idx)
    -- reverse unstages: we patch away a change currently in the index
    if self.staging.apply(self.model, self.model.hunks[idx], offset, not want_staged) then
        self.staged_hunks[idx] = want_staged
        return true
    end
    return false
end

-- s: stage the hunk under the cursor, or advance if there's nothing to stage here.
-- the review flow: the first s on a hunk stages it (staying put so the mark
-- is visible), a second s (now staged) moves to the next hunk, and at the last hunk
-- it steps to the next file, which opens on its first unstaged hunk. so repeated s
-- walks the whole change set, accepting hunk by hunk
function View:stage_hunk()
    if not (self.can_stage and self.staging) then
        return vim.notify("differ: hunk staging isn't available here", vim.log.levels.WARN)
    end
    local idx = self:_hunk_index_under_cursor()
    if idx and not (self.staged_hunks[idx] or false) then
        self:_toggle_hunk(true)
    else
        self:_advance_review()
    end
end

-- move to the next hunk; at the last hunk, step to the next file (the second-tap of
-- s, and the seam that makes the review flow continuous across files)
function View:_advance_review()
    local col = self:_focused_column()
    local win = col.winid or vim.api.nvim_get_current_win()
    local target = nav.next_hunk(col.map, vim.api.nvim_win_get_cursor(win)[1])
    if target then
        vim.api.nvim_win_set_cursor(win, { target, 0 })
    elseif not self:step_file("next", false) then -- review flow: stop at the last file, don't wrap
        vim.notify("differ: no more hunks to stage", vim.log.levels.INFO)
    end
end

-- u: the mirror of s. unstage the staged hunk under the cursor, or retreat: a
-- second u moves to the previous hunk, and at the first hunk it steps to the
-- previous file landing on its last hunk, so repeated u walks the change set
-- backward, undoing hunk by hunk
function View:unstage_hunk()
    if not (self.can_stage and self.staging) then
        return vim.notify("differ: hunk staging isn't available here", vim.log.levels.WARN)
    end
    local idx = self:_hunk_index_under_cursor()
    if idx and (self.staged_hunks[idx] or false) then
        self:_toggle_hunk(false)
    else
        self:_retreat_review()
    end
end

-- move to the previous hunk; at the first hunk, step to the previous file and land
-- on its last hunk (the backward seam, mirroring _advance_review's forward one)
function View:_retreat_review()
    local col = self:_focused_column()
    local win = col.winid or vim.api.nvim_get_current_win()
    local target = nav.prev_hunk(col.map, vim.api.nvim_win_get_cursor(win)[1])
    if target then
        vim.api.nvim_win_set_cursor(win, { target, 0 })
    elseif self:step_file("prev", false) then -- review flow: stop at the first file, don't wrap
        self:_focus_last_hunk() -- only when a previous file actually opened
    else
        vim.notify("differ: no more hunks to unstage", vim.log.levels.INFO)
    end
end

-- toggle the staged state of the hunk under the cursor, marking it in place
-- rather than re-reading: the diff stays put and the opposite key (u after s) keeps
-- working on it
---@param want_staged boolean
function View:_toggle_hunk(want_staged)
    if not (self.can_stage and self.staging) then
        return vim.notify("differ: hunk staging isn't available here", vim.log.levels.WARN)
    end
    local idx = self:_hunk_index_under_cursor()
    if not idx then
        return vim.notify("differ: no hunk under the cursor", vim.log.levels.WARN)
    end
    if (self.staged_hunks[idx] or false) == want_staged then
        return vim.notify(
            "differ: hunk already " .. (want_staged and "staged" or "unstaged"),
            vim.log.levels.INFO
        )
    end
    if self:_apply_hunk(idx, want_staged) then
        self.staging.refresh()
        self:_paint_staged()
        self:_paint_cursorline() -- re-lift the cursor tint above the fresh staged fill
    end
end

-- S: stage every hunk in the file, or, when they're all staged already (nothing left
-- to do), step to the next file, the file-level echo of s advancing past the last hunk
function View:stage_all()
    if not self:_toggle_all(true) and self.can_stage and self.staging then
        if not self:step_file("next", false) then -- stop at the last file, don't wrap
            vim.notify("differ: no more files to stage", vim.log.levels.INFO)
        end
    end
end

-- U: unstage every hunk, or, when none are staged (nothing to do), step back a file
-- landing on its last hunk, the file-level echo of u retreating past the first hunk
function View:unstage_all()
    if not self:_toggle_all(false) and self.can_stage and self.staging then
        if self:step_file("prev", false) then -- stop at the first file, don't wrap
            self:_focus_last_hunk() -- only when a previous file actually opened
        else
            vim.notify("differ: no more files to unstage", vim.log.levels.INFO)
        end
    end
end

-- stage / unstage every hunk. forward order keeps the running offset correct
-- as the index shifts under each apply; the panel refreshes once after the batch.
-- returns whether anything changed (false when already wholly in the target state),
-- so S/U can fall through to file stepping
---@param want_staged boolean
---@return boolean changed
function View:_toggle_all(want_staged)
    if not (self.can_stage and self.staging) then
        vim.notify("differ: hunk staging isn't available here", vim.log.levels.WARN)
        return false
    end
    local changed = false
    for i = 1, #self.model.hunks do
        if self:_apply_hunk(i, want_staged) then
            changed = true
        end
    end
    if changed then
        self.staging.refresh()
        self:_paint_staged()
        self:_paint_cursorline() -- re-lift the cursor tint above the fresh staged fill
    end
    return changed
end

-- jump-to-file (the `de` verb): leave the diff and open the real file on disk
-- at the line under the cursor, mapped to its new-side line. the session lives
-- in its own tabpage, so this ends it (dropping that tab) and opens the real
-- file back in the tab :Differ was invoked from, where you'll keep working
function View:jump_to_file()
    local root = self.model.root
    if not root then
        vim.notify("differ: jump-to-file needs a file-backed source", vim.log.levels.WARN)
        return
    end
    local abs = root .. "/" .. self.model.path
    if vim.fn.filereadable(abs) == 0 then
        -- e.g. a pure deletion: the new side has no file on disk to open
        vim.notify(("differ: %s is not on disk"):format(self.model.path), vim.log.levels.WARN)
        return
    end

    local col = self:_focused_column()
    local win = (col.winid and vim.api.nvim_win_is_valid(col.winid)) and col.winid
        or vim.api.nvim_get_current_win()
    local target, tcol = self:_file_pos(col, win)

    -- end the session: closing the panel/history tabcloses the differ tab (via its
    -- on_close). then hop back to the invoking tab and open the real file there, so
    -- the diff tab doesn't linger. the owner carries the tab to return to
    local owner = require("differ.panel").current() or require("differ.history").current()
    local return_tab = owner and owner.return_tab
    if owner then
        owner:close()
    else
        self:close()
    end
    if return_tab and vim.api.nvim_tabpage_is_valid(return_tab) then
        vim.api.nvim_set_current_tabpage(return_tab)
    end
    -- if abs is already loaded (e.g. edited but left unsaved after a prior
    -- jump-to-file), switch to that buffer instead of :edit, which would force a
    -- disk reload and refuse with E37 over the unsaved changes
    local bufnr = vim.fn.bufnr(abs)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_win_set_buf(0, bufnr)
    else
        vim.cmd.edit(vim.fn.fnameescape(abs))
    end
    if target then
        place_cursor(target, tcol)
    end
end

-- the real-file (new-side) position for de/df: the cursor line's mapped `new` line
-- plus its column, but the column is carried only when the cursor's own line
-- maps 1:1 to a new-side line. a deleted/meta line redirects to a different line where
-- the column is meaningless, so it lands at column 0 there
---@param col differ.ViewColumn
---@param win integer
---@return integer|nil line, integer col
function View:_file_pos(col, win)
    local crow, ccol = unpack(vim.api.nvim_win_get_cursor(win))
    local target = nav.file_line(col.map, crow)
    local here = col.map.lines[crow]
    local tcol = (target and here and here.new == target) and ccol or 0
    return target, tcol
end

-- whether edit-in-review applies: the diff is the working tree (or index) against its
-- immediate committed/staged base, so every shown hunk is an uncommitted change and the
-- file on disk is the editable target. the daily staging sources qualify (HEAD↔worktree,
-- INDEX↔worktree, HEAD↔index); a `<rev>↔worktree` open (`:Differ HEAD~1`, `main...`)
-- does not, since it folds in committed history you can't edit in place, and committed
-- sources (rev↔rev, history, PR) never do
---@return boolean
function View:_editable_source()
    local old, new = self.model.old_rev, self.model.new_rev
    if new == "WORKTREE" then
        return old == "HEAD" or old == "INDEX"
    end
    return new == "INDEX" and old == "HEAD"
end

-- edit-in-review: pop the real working-tree file into a transient editable
-- window at the cursor's mapped new-side line, keeping the session. unlike
-- jump_to_file this never tears down the diff: you edit, `:w`, and the worktree
-- watcher re-sources the diff in place (cursor held near its hunk). the projection
-- buffer and line map are untouched (invariant 2); you edit the real file's own
-- buffer, so LSP / treesitter / undo all work natively. a staged diff (index↔ side)
-- can't be edited in place (you can't edit the index), so the file is unstaged first:
-- the staged change returns to the worktree and the watcher re-sources to the now-
-- unstaged diff, where the edit shows. git-correct; re-stage (s) when done
function View:edit_file()
    if not self:_editable_source() then
        return vim.notify(
            "differ: editing applies to uncommitted (worktree/staged) changes only",
            vim.log.levels.WARN
        )
    end
    local root = self.model.root
    if not root then
        return vim.notify("differ: editing needs a file-backed source", vim.log.levels.WARN)
    end
    local abs = root .. "/" .. self.model.path
    if vim.fn.filereadable(abs) == 0 then
        -- e.g. a pure deletion: no new-side file on disk to edit
        return vim.notify(
            ("differ: %s is not on disk"):format(self.model.path),
            vim.log.levels.WARN
        )
    end

    local col = self:_focused_column()
    local win = (col.winid and vim.api.nvim_win_is_valid(col.winid)) and col.winid
        or vim.api.nvim_get_current_win()
    local target, tcol = self:_file_pos(col, win)

    -- staged diff: unstage the file and re-source to its unstaged index↔worktree view
    -- so the edit lands on a diff that reflects it. driven explicitly (the watcher's
    -- re-source is suppressed by the staging signature); falls back to an in-place
    -- unstage if no frontend hook is wired
    if self.model.new_rev == "INDEX" then
        if self.on_edit_unstage then
            self.on_edit_unstage(self.model.path)
        elseif self.can_stage and self.staging then
            self:_toggle_all(false)
        end
    end

    self:_open_edit_window(abs, target, tcol, col.winid)
end

-- open (or reuse) the edit window and load `abs` at `target`. split off the diff
-- window so the diff stays visible and live-updates beside the edit; a WinClosed
-- hook keeps `edit_win` in sync when the user closes it natively (`:q`)
---@param abs string
---@param target integer|nil
---@param tcol integer  -- the new-side column carried from the diff cursor
---@param anchor_win integer|nil  -- a diff window to split from
function View:_open_edit_window(abs, target, tcol, anchor_win)
    if self.edit_win and vim.api.nvim_win_is_valid(self.edit_win) then
        vim.api.nvim_set_current_win(self.edit_win)
    else
        -- split from the diff window, not the panel (`:Differ edit` runs with the
        -- panel focused), so the new window lands beside the diff
        if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
            vim.api.nvim_set_current_win(anchor_win)
        end
        vim.cmd("rightbelow split")
        local win = vim.api.nvim_get_current_win()
        self.edit_win = win
        vim.api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(win),
            once = true,
            callback = function()
                if self.edit_win == win then
                    self.edit_win = nil
                end
            end,
        })
    end
    vim.cmd.edit(vim.fn.fnameescape(abs))
    if target then
        place_cursor(target, tcol)
    end
    -- bind g? on the real-file buffer too, so the cheatsheet is reachable from the
    -- edit window (shadows native g?/rot13, inert in this review flow)
    bind(vim.api.nvim_get_current_buf(), self.keymaps.help, function()
        self:show_help()
    end, "differ: keymap help")
end

-- drop the edit window without losing work: a window holding unsaved edits is left
-- open (it's a normal file window, harmless to keep), otherwise it's closed. either
-- way `edit_win` is cleared. called on a file switch (stale window) and on teardown
function View:_release_edit_window()
    local win = self.edit_win
    self.edit_win = nil
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].modified then
        return -- keep the user's unsaved real-file window
    end
    pcall(vim.api.nvim_win_close, win, false)
end

-- the diff buffer is the session anchor: when it leaves its window the whole session
-- ends, so there's never a live state without the diff on screen. guarding the buffer
-- (BufWinLeave) not the window catches both `:q` and a swap-in-place (a picker / :edit
-- loading another file into the diff window). re-armed after every relayout since the
-- buffers are recreated
function View:_arm_close_guard()
    armed_view = self -- this view now owns the close-teardown; supersede any prior one
    self._close_group =
        vim.api.nvim_create_augroup("differ.viewclose." .. self.id, { clear = true })
    for _, col in ipairs(self.columns) do
        if col.bufnr and vim.api.nvim_buf_is_valid(col.bufnr) then
            vim.api.nvim_create_autocmd("BufWinLeave", {
                group = self._close_group,
                buffer = col.bufnr,
                callback = function()
                    self:_on_diff_lost()
                end,
            })
        end
    end
end

-- the diff buffer left its window (closed, or swapped out by a picker / :edit). ignore
-- our own programmatic closes (layout toggle, teardown) and re-entrancy; otherwise tear
-- down the whole session via its owner (panel / history), or just this view when it's a
-- bare diff. deferred because window changes (closing the panel, the session tab) aren't
-- allowed inside BufWinLeave, which also fires *before* the buffer leaves, so the
-- still-displayed re-check has to wait for the schedule
function View:_on_diff_lost()
    -- only the current session's view tears down (a recycled buffer can fire a stale
    -- view's guard); ignore our own programmatic closes and re-entrancy
    if self ~= armed_view or self._suppress_close or self._closing then
        return
    end
    self._closing = true
    vim.schedule(function()
        -- re-check at run time: a newer session may have armed, or this view may have
        -- been torn down another way, between the leave and this deferred callback
        if self ~= armed_view or #self.columns == 0 then
            return
        end
        -- BufWinLeave fires before the buffer leaves, so an aborted switch (e.g. :edit
        -- of an unreadable file) can leave the diff fully on screen: only skip when
        -- every column is still shown. any column gone (a swap-in-place, a split-pane
        -- :q) means the diff is broken, so tear the session down
        local all_shown = true
        local repurposed -- a buffer the user navigated to in a surviving diff window
        for _, col in ipairs(self.columns) do
            if not (col.bufnr and #vim.fn.win_findbuf(col.bufnr) > 0) then
                all_shown = false
                if col.winid and vim.api.nvim_win_is_valid(col.winid) then
                    local newbuf = vim.api.nvim_win_get_buf(col.winid)
                    if newbuf ~= col.bufnr then
                        repurposed = newbuf -- a picker / :edit loaded this in place
                    end
                end
            end
        end
        if all_shown then
            self._closing = false
            return
        end
        -- end the session, carrying any swapped-in buffer out to the launch tab
        require("differ.git").navigate_away(repurposed, self)
    end)
end

-- lay the columns into windows. the first column anchors on its existing window
-- (or the current one on first open); extra columns reuse their window or vsplit
-- a fresh one; >1 column scroll-binds. single authority for open + layout toggle
function View:_relayout()
    local anchor = self.columns[1].winid
    if not (anchor and vim.api.nvim_win_is_valid(anchor)) then
        anchor = vim.api.nvim_get_current_win()
        self.columns[1].winid = anchor
    end
    self:_setup_window(anchor, self.columns[1].bufnr)
    vim.api.nvim_set_current_win(anchor)

    for i = 2, #self.columns do
        local col = self.columns[i]
        if not (col.winid and vim.api.nvim_win_is_valid(col.winid)) then
            vim.cmd("rightbelow vsplit")
            col.winid = vim.api.nvim_get_current_win()
        end
        self:_setup_window(col.winid, col.bufnr)
    end

    if #self.columns > 1 then
        for _, col in ipairs(self.columns) do
            set_wo(col.winid, "scrollbind", true)
        end
        vim.api.nvim_set_current_win(self.columns[1].winid)
        vim.cmd("syncbind")
    end
    self:_apply_folds() -- windows now exist; collapse the unchanged regions
    self:_paint_cursorline() -- windows now exist; show the cursor line over the bg
    self:_arm_close_guard() -- re-arm now the winids are current
end

-- open the view: stacked takes the current window, split adds a scroll-bound pane
---@return differ.View
function View:open()
    self:_relayout()
    self:_focus_first_hunk() -- land on the first hunk; the tinted cursor line shows its kind
    self:_paint_cursorline()
    return self
end

-- tear down a single column's window (if any) and buffer. `keep_win` spares that
-- window from closing (jump-to-file repurposes it for the real file), still
-- dropping the now-hidden synthetic buffer
---@param col differ.ViewColumn|nil
---@param keep_win integer|nil
function View:_discard(col, keep_win)
    if not col then
        return
    end
    by_buf[col.bufnr] = nil
    statuscolumn.clear(col.bufnr)
    -- only close a window we still own: if the user swapped another buffer into it
    -- (a picker / :edit), it's theirs now, so leave it (and the navigation) alone
    if
        col.winid
        and col.winid ~= keep_win
        and vim.api.nvim_win_is_valid(col.winid)
        and vim.api.nvim_win_get_buf(col.winid) == col.bufnr
    then
        -- our own close: don't let the close guard mistake it for a user close
        self._suppress_close = true
        pcall(vim.api.nvim_win_close, col.winid, true)
        self._suppress_close = false
    end
    if vim.api.nvim_buf_is_valid(col.bufnr) then
        vim.api.nvim_buf_delete(col.bufnr, { force = true })
    end
end

-- close all windows and delete all buffers owned by the view. `keep_win` leaves
-- one window open (jump-to-file, which has already loaded the real file into it)
---@param keep_win integer|nil
function View:close(keep_win)
    self._closing = true -- block the WinClosed guard for the duration of teardown
    if armed_view == self then
        armed_view = nil
    end
    if self._close_group then
        pcall(vim.api.nvim_del_augroup_by_id, self._close_group)
        self._close_group = nil
    end
    self:_release_edit_window() -- drop any edit-in-review window (keeps it if unsaved)
    for _, col in ipairs(self.columns) do
        self:_discard(col, keep_win)
    end
    self.columns = {}
end

return View
