-- the merge-tool session: lay the 3-way render into windows — ours / theirs on
-- top (plus base under the diff3_mixed layout), the result spine full-width below — drive
-- conflict navigation (]x/[x), and resolve per conflict (take ours/theirs/both/base/none),
-- splicing the chosen slab into the result and stripping the markers. the result column is
-- the real worktree file: :w writes it and auto-stages once no markers remain, then advances
-- to the next conflicted file; when none remain the session reports done and closes. the user
-- can :Differ close any time to stop after the current file.
--
-- each input column is a read-only scratch buffer of a whole stage file, so windows use
-- native `number` + native syntax; conflict regions are extmark-only in the differ.merge
-- namespace (no buffer/text touch on the inputs).
--
-- the UX-polish slice makes the result readable without hiding anything: it's the file the
-- user hand-edits, so the raw conflict markers stay as real text. each conflict region is
-- coloured per side (marker lines included), the conflict under the cursor is emphasised, a
-- winbar counts the conflicts, the input panes recentre on the active conflict, unchanged
-- regions are foldable, and a take-this briefly flashes the lines it produced

local set_local = require("differ.util.win").set_local
local bind = require("differ.util.keymap").bind

local M = {}

local merge_ns = vim.api.nvim_create_namespace("differ.merge")
local flash_ns = vim.api.nvim_create_namespace("differ.merge.flash")

local FOLDTEXT_EXPR = 'v:lua.require("differ.ui.foldtext").render()'

---@type table<string, { normal: string, active: string }> -- result section side -> hl pair
local SECTION_HL = {
    ours = { normal = "differMergeOurs", active = "differMergeOursActive" },
    base = { normal = "differMergeBase", active = "differMergeBaseActive" },
    theirs = { normal = "differMergeTheirs", active = "differMergeTheirsActive" },
}

---@type table<string, { body: string, sign: string }> -- input side -> body hl + sign hl
local INPUT_HL = {
    ours = { body = "differMergeOursStrong", sign = "differMergeSignOurs" },
    base = { body = "differMergeBaseStrong", sign = "differMergeSignBase" },
    theirs = { body = "differMergeTheirsStrong", sign = "differMergeSignTheirs" },
}

---@class differ.MergeInput
---@field side "ours"|"base"|"theirs"
---@field win integer
---@field regions differ.merge.ColumnRegion[]  -- the side's located slabs, original indices

---@class differ.MergeSession
---@field root string
---@field path string
---@field regions differ.merge.Region[]   -- re-derived from the live result buffer
---@field order integer[]                 -- live region position -> original conflict index
---@field total integer                   -- original conflict count (for the winbar N/M)
---@field active_index integer|nil        -- live index of the conflict under the cursor
---@field labels table<string, string>    -- side -> winbar pane label (OURS (HEAD), ...)
---@field layout "default"|"diff3_mixed"  -- the chosen layout, reused when advancing to the next file
---@field result_win integer
---@field result_buf integer              -- the real worktree file (editable)
---@field bufs integer[]                  -- the scratch input buffers (deleted on close)
---@field inputs differ.MergeInput[]       -- the input panes (for pane sync on navigation)
---@field win_side table<integer, string> -- window id -> side (for the winbar)
---@field return_tab integer
---@field session_tab integer
---@field keymaps table                   -- resolved merge keymaps (for the g? cheatsheet)
---@field saved_autoformat any            -- the result buffer's prior disable_autoformat, restored on close
---@field saved_markdown_render boolean|nil -- the result buffer's prior render-markdown state, restored on close
---@field autoformat_warned boolean|nil   -- set once a save is seen to have reformatted the markers
---@field diag_aug integer|nil            -- the DiagnosticChanged hook that hushes the result

---@type differ.MergeSession|nil
local session = nil

-- the result-buffer conflict chords (<leader>co/ct/cb/ca, dx) are multi-key, so nvim waits
-- timeoutlen for the completing key. a short global timeoutlen (which-key setups often run
-- 200ms) drops them unless typed fast, so widen the window to a generous floor while the
-- cursor sits in the result buffer and restore the user's value on leave/close. timeoutlen
-- is global-only (no buffer scope), hence a save/restore rather than set_local; the nil
-- guard keeps it re-entrant and never lowers an already-larger setting
local saved_timeoutlen = nil

local function bump_timeout()
    if saved_timeoutlen == nil then
        saved_timeoutlen = vim.o.timeoutlen
        vim.o.timeoutlen = math.max(saved_timeoutlen, 1000)
    end
end

local function restore_timeout()
    if saved_timeoutlen ~= nil then
        vim.o.timeoutlen = saved_timeoutlen
        saved_timeoutlen = nil
    end
end

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- a clean conflict marker sits at column 0; a format-on-save that ignores the buffer's
-- disable_autoformat opt-out reflows the whole region and indents the markers with it. the
-- parser then can't see the region (it matches at column 0), so it would read as resolved
-- and stage a file that still has markers. an indented <<<<<<< / >>>>>>> run is the tell;
-- `<`/`>` only, since a stray indented ======= can be decorative
---@param lines string[]
---@return boolean
local function markers_reformatted(lines)
    for _, line in ipairs(lines) do
        local ch = line:match("^%s+([<>])")
        if ch then
            local run = line:match("^%s+(%" .. ch .. "+)")
            if run and #run >= 7 then
                return true
            end
        end
    end
    return false
end

-- the active session, or nil. exposed so :Differ close can route to it
---@return differ.MergeSession|nil
function M.current()
    return session
end

-- the result is the real file, so the user's LSP/linter parses it and reports errors over
-- the conflict markers (invalid source). just toggling display (enable/disable) leaves the
-- diagnostics stored, so they still leak through hover floats and the loc/qf list — clear
-- them outright and keep them cleared as the producers re-publish (DiagnosticChanged),
-- until the session closes. returns the augroup id so close can drop the hook
---@param buf integer
---@return integer|nil augroup
local function suppress_diagnostics(buf)
    if not vim.diagnostic then
        return nil
    end
    local clearing = false
    local function clear()
        -- guard re-entry (reset itself fires DiagnosticChanged) and skip when already empty
        if clearing or #vim.diagnostic.get(buf) == 0 then
            return
        end
        clearing = true
        vim.diagnostic.reset(nil, buf) -- all namespaces for this buffer
        clearing = false
    end
    clear()
    local aug = vim.api.nvim_create_augroup("differ.merge.diag." .. buf, { clear = true })
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
        group = aug,
        buffer = buf,
        callback = clear,
    })
    return aug
end

-- toggle render-markdown.nvim for one buffer; its buf_enable/buf_disable act on the current
-- buffer, so run them in the buffer's context. guarded so a missing plugin is a no-op
---@param buf integer
---@param on boolean
local function set_markdown_render(buf, on)
    local ok, rm = pcall(require, "render-markdown")
    if ok then
        pcall(vim.api.nvim_buf_call, buf, function()
            local fn = on and rm.buf_enable or rm.buf_disable
            fn()
        end)
    end
end

-- the result is a real `.md` file when the conflict is in markdown, and an in-buffer
-- renderer (render-markdown.nvim) treats it as prose: it conceals the `>>>>>>>`/`<<<<<<<`
-- runs as nested block-quotes and overlays a quote glyph, hiding the very markers the user
-- resolves here. read the buffer's current render state (so close can restore it), then
-- disable rendering for the session. guarded: a no-op when the plugin isn't loaded (e.g. a
-- non-markdown result) or absent
---@param buf integer
---@return boolean|nil prior  -- the buffer's render-markdown enabled state before disabling
local function quiet_markdown_render(buf)
    -- only markdown results are at risk; gating here also avoids a lazy `require` loading the
    -- plugin for an unrelated result filetype
    if vim.bo[buf].filetype ~= "markdown" then
        return nil
    end
    local prior
    local ok_state, state = pcall(require, "render-markdown.state")
    if ok_state then
        local ok_cfg, cfg = pcall(state.get, buf)
        if ok_cfg and cfg then
            prior = cfg.enabled
        end
    end
    set_markdown_render(buf, false)
    return prior
end

-- a scratch buffer for one column: the side's content, named + filetyped so native
-- syntax highlights it (these are whole, valid source files, unlike the diff buffers),
-- locked read-only for this slice
---@param side string
---@param path string
---@param lines string[]
---@return integer bufnr
local function make_buffer(side, path, lines)
    local buf = vim.api.nvim_create_buf(false, true)
    local name = ("differ://merge/%s/%s"):format(side, path)
    if not pcall(vim.api.nvim_buf_set_name, buf, name) then
        pcall(vim.api.nvim_buf_set_name, buf, name .. "#" .. buf)
    end
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ""
    return buf
end

-- paint a full-line background over an inclusive 1-based range (extmark-only, invariant 2).
-- clamps to the buffer: a hand-edit can leave a cached region pointing past the new EOF for
-- the moment between the edit and the re-parse, and an out-of-range extmark would throw
---@param buf integer
---@param first integer
---@param last integer
---@param hl string
local function paint_lines(buf, first, last, hl)
    local count = vim.api.nvim_buf_line_count(buf)
    for row = math.max(first - 1, 0), math.min(last - 1, count - 1) do
        vim.api.nvim_buf_set_extmark(buf, merge_ns, row, 0, {
            end_row = row + 1,
            end_col = 0,
            hl_group = hl,
            hl_eol = true,
            priority = 100,
        })
    end
end

-- paint an input pane's located slabs: a strong side tint plus a ▌ gutter sign, so the
-- conflicting lines pop out of the otherwise full, unhighlighted stage file
---@param buf integer
---@param side "ours"|"base"|"theirs"
---@param regions differ.merge.ColumnRegion[]
local function paint_input(buf, side, regions)
    local hl = INPUT_HL[side]
    for _, r in ipairs(regions) do
        for row = r.first - 1, r.last - 1 do
            vim.api.nvim_buf_set_extmark(buf, merge_ns, row, 0, {
                end_row = row + 1,
                end_col = 0,
                hl_group = hl.body,
                hl_eol = true,
                priority = 100,
                sign_text = "▌",
                sign_hl_group = hl.sign,
            })
        end
    end
end

-- paint each conflict region in the result, coloured per side with the marker lines drawn
-- in their section's colour (the markers stay visible: this is the file the user edits).
-- ours runs <<<<<<< .. the base/sep marker, base runs ||||||| .. the sep, theirs runs
-- ======= .. >>>>>>> (so the closing marker reads as theirs). the block under the cursor
-- paints at full strength. driven by the live parse on the session, so a hand-edit or a
-- splice both recompute from one source
---@param active integer|nil  -- the live index of the conflict under the cursor
local function paint_result(active)
    local s = assert(session)
    vim.api.nvim_buf_clear_namespace(s.result_buf, merge_ns, 0, -1)
    for _, r in ipairs(s.regions) do
        local on = r.index == active
        local function fill(side, first, last)
            local pair = SECTION_HL[side]
            paint_lines(s.result_buf, first, last, on and pair.active or pair.normal)
        end
        fill("ours", r.result_start, (r.mark_base or r.mark_sep) - 1)
        if r.mark_base then
            fill("base", r.mark_base, r.mark_sep - 1)
        end
        fill("theirs", r.mark_sep, r.result_end)
    end
end

-- briefly highlight the lines a take-this produced, cleared after ~250ms on its own
-- namespace so the flash never lingers under the section colours
---@param buf integer
---@param first integer  -- 1-based
---@param count integer
local function flash(buf, first, count)
    if count <= 0 then
        return
    end
    for row = first - 1, first - 1 + count - 1 do
        vim.api.nvim_buf_set_extmark(buf, flash_ns, row, 0, {
            end_row = row + 1,
            end_col = 0,
            hl_group = "differMergeFlash",
            hl_eol = true,
            priority = 250,
        })
    end
    vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
        end
    end, 250)
end

-- the conflict regions of the live result buffer (re-parsed each call, so hand edits and
-- keymap splices stay consistent), plus the buffer's current lines
---@return differ.merge.Region[], string[]
local function live_regions()
    local s = assert(session)
    local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
    return require("differ.git.conflict").parse(lines), lines
end

-- the live index of the conflict under the result cursor, else nil
---@return integer|nil
local function active_index()
    local s = assert(session)
    if not vim.api.nvim_win_is_valid(s.result_win) then
        return nil
    end
    local cur = vim.api.nvim_win_get_cursor(s.result_win)[1]
    for _, r in ipairs(s.regions) do
        if cur >= r.result_start and cur <= r.result_end then
            return r.index
        end
    end
    return nil
end

-- re-parse the result buffer and repaint its per-side colour + emphasis, caching the
-- regions on the session for navigation. keeps the order map aligned: a structured splice
-- maintains it itself (so this no-ops), but an arbitrary hand-edit + write rebuilds it to
-- the identity so the pane sync stays consistent (degrading to live-index = original-index)
local function repaint_result()
    local s = assert(session)
    local regions = live_regions()
    s.regions = regions
    if not s.order or #s.order ~= #regions then
        s.order = {}
        for i = 1, #regions do
            s.order[i] = i
        end
    end
    s.active_index = active_index()
    paint_result(s.active_index)
end

-- run fn with scrollbind off on every merge window, then restore it. the panes are
-- scroll-bound so manual scrolling tracks across columns, but a programmatic cursor move +
-- zz would otherwise feed back through the bind (an input pane's zz dragging the result
-- cursor off the conflict, stalling ]x), so centring happens with the bind lifted
---@param fn fun()
local function without_scrollbind(fn)
    local s = assert(session)
    local saved = {}
    local function each(f)
        for _, inp in ipairs(s.inputs) do
            if vim.api.nvim_win_is_valid(inp.win) then
                f(inp.win)
            end
        end
        if vim.api.nvim_win_is_valid(s.result_win) then
            f(s.result_win)
        end
    end
    each(function(w)
        saved[w] = vim.wo[w].scrollbind
        vim.wo[w].scrollbind = false
    end)
    local ok, err = pcall(fn)
    each(function(w)
        if saved[w] ~= nil then
            vim.wo[w].scrollbind = saved[w]
        end
    end)
    if not ok then
        error(err)
    end
end

-- centre each input window on the active conflict's slab (matched by original index), so
-- all panes show one conflict together. a slab that wasn't located simply doesn't scroll
---@param index integer|nil  -- original conflict index (nil when none is active)
local function sync_inputs(index)
    if not (session and index) then
        return
    end
    without_scrollbind(function()
        for _, inp in ipairs(session.inputs) do
            if vim.api.nvim_win_is_valid(inp.win) then
                for _, r in ipairs(inp.regions) do
                    if r.index == index then
                        vim.api.nvim_win_set_cursor(inp.win, { r.first, 0 })
                        vim.api.nvim_win_call(inp.win, function()
                            vim.cmd("normal! zz")
                        end)
                        break
                    end
                end
            end
        end
    end)
end

-- when the active conflict changes, repaint the emphasis and recentre the input panes on
-- it, so moving the result cursor (by scroll or motion, not just ]x/[x) keeps ours/theirs
-- aligned. no-ops while the cursor stays in one block, so the painter doesn't run per key
local function on_cursor_moved()
    if not session then
        return
    end
    local active = active_index()
    if active == session.active_index then
        return
    end
    session.active_index = active
    paint_result(active)
    sync_inputs(active and session.order[active])
end

-- jump the result cursor to the next/prev conflict block (wrapping at the ends), repaint
-- the emphasis, and scroll the input panes to the same conflict
---@param dir "next"|"prev"
local function goto_conflict(dir)
    if not (session and vim.api.nvim_win_is_valid(session.result_win)) then
        return
    end
    local cur = vim.api.nvim_win_get_cursor(session.result_win)[1]
    local target
    for _, r in ipairs(session.regions) do
        if dir == "next" and r.result_start > cur then
            target = target or r
        elseif dir == "prev" and r.result_start < cur then
            target = r -- keep the last one below the cursor
        end
    end
    if #session.regions == 0 then
        return notify("no conflicts remain")
    end
    if not target then -- wrap
        target = dir == "next" and session.regions[1] or session.regions[#session.regions]
    end
    vim.api.nvim_win_set_cursor(session.result_win, { target.result_start, 0 })
    vim.api.nvim_win_call(session.result_win, function()
        vim.cmd("normal! zz")
    end)
    on_cursor_moved()
end

-- the conflict at the cursor, else the first one at or below it (so a take-this from just
-- above a block still resolves it)
---@param regions differ.merge.Region[]
---@param lnum integer
---@return differ.merge.Region|nil
local function region_at(regions, lnum)
    for _, r in ipairs(regions) do
        if lnum >= r.result_start and lnum <= r.result_end then
            return r
        end
    end
    for _, r in ipairs(regions) do
        if r.result_start >= lnum then
            return r
        end
    end
    return nil
end

-- resolve the conflict under the cursor by splicing in the chosen slab, then re-derive +
-- repaint, flash the produced lines, and advance to the next remaining conflict
---@param choice "ours"|"theirs"|"both"|"base"|"none"
local function resolve_choice(choice)
    if not session then
        return
    end
    local regions, lines = live_regions()
    if #regions == 0 then
        return notify("no conflicts remain")
    end
    local cur = vim.api.nvim_win_get_cursor(session.result_win)[1]
    local region = region_at(regions, cur)
    if not region then
        return notify("no conflict under the cursor")
    end
    local new_lines, delta = require("differ.merge.resolve").splice(lines, region, choice)
    if not new_lines then
        return notify("no base version in this conflict", vim.log.levels.WARN)
    end
    local anchor = region.result_start
    local block_len = region.result_end - region.result_start + 1
    local slab_count = delta + block_len -- the chosen slab's line count (0 for `none`)
    vim.bo[session.result_buf].modifiable = true
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, new_lines)
    table.remove(session.order, region.index) -- drop the resolved conflict's mapping
    repaint_result()
    flash(session.result_buf, anchor, slab_count)
    -- land on the next remaining conflict at or after where this one was
    local target
    for _, r in ipairs(session.regions) do
        if r.result_start >= anchor then
            target = target or r
        end
    end
    if target then
        vim.api.nvim_win_set_cursor(session.result_win, { target.result_start, 0 })
        on_cursor_moved()
    elseif #session.regions == 0 then
        notify("all conflicts resolved — :w to save and stage")
    end
end

-- winbar text for the merge windows: the result shows the conflict counter, an input
-- shows its static side label. a `%!` expression reading the window it renders for
---@return string
function M.winbar()
    if not session then
        return ""
    end
    local win = vim.g.statusline_winid
    if win == session.result_win then
        local remaining = #session.regions
        if remaining == 0 then
            return "RESULT · all resolved"
        end
        local total = session.total
        local pos = 1 -- the active conflict's position among the remaining
        for i, r in ipairs(session.regions) do
            if r.index == session.active_index then
                pos = i
                break
            end
        end
        local n = (total - remaining) + pos -- the absolute conflict ordinal
        return ("RESULT · conflict %d/%d · %d unresolved"):format(n, total, remaining)
    end
    local side = session.win_side[win]
    return side and (session.labels[side] or side:upper()) or ""
end

-- common window dressing: real line numbers, no wrap chrome, cursorline, folds enabled but
-- left open (latent, like every other view); a `%!` winbar labels the pane. scroll-bound so
-- manual scrolling tracks loosely across columns (the files diverge, the result is the
-- spine); programmatic centring lifts the bind first (see without_scrollbind)
---@param win integer
local function dress(win)
    set_local(win, "number", true)
    set_local(win, "relativenumber", false)
    set_local(win, "wrap", false)
    set_local(win, "foldcolumn", "0")
    set_local(win, "foldenable", true)
    set_local(win, "signcolumn", "no")
    set_local(win, "cursorline", true)
    set_local(win, "scrollbind", true)
    set_local(win, "winbar", '%!v:lua.require("differ.merge").winbar()')
end

-- (re)create the native folds for a window from its fold ranges, left open by default
-- (the structure stays so zM/zc collapse the unchanged regions on demand), mirroring
-- view.lua:_apply_folds
---@param win integer
---@param folds differ.FoldRange[]|nil
local function apply_folds(win, folds)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    set_local(win, "foldmethod", "manual")
    set_local(win, "foldtext", FOLDTEXT_EXPR)
    set_local(win, "foldenable", true)
    vim.api.nvim_win_call(win, function()
        vim.cmd("silent! normal! zE") -- drop existing folds before rebuilding
        for _, f in ipairs(folds or {}) do
            if f.last > f.first then
                vim.cmd(("silent! %d,%dfold"):format(f.first, f.last))
            end
        end
        vim.cmd("silent! normal! zR") -- open by default; the structure stays for zc/za
    end)
end

-- end the session: drop the tab + buffers and return to the invoking tab
function M.close()
    if not session then
        return
    end
    local s = session
    session = nil
    restore_timeout() -- net in case the tab teardown didn't fire BufLeave on the result buf
    if vim.api.nvim_buf_is_valid(s.result_buf) then
        vim.b[s.result_buf].disable_autoformat = s.saved_autoformat -- give autoformat back
        if s.saved_markdown_render then
            set_markdown_render(s.result_buf, true) -- re-render markdown if it was on
        end
    end
    -- drop the diagnostics hook; the producers re-lint the now-resolved file on their own
    if s.diag_aug then
        pcall(vim.api.nvim_del_augroup_by_id, s.diag_aug)
    end
    for _, buf in ipairs(s.bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    if vim.api.nvim_tabpage_is_valid(s.session_tab) then
        if #vim.api.nvim_list_tabpages() == 1 then
            vim.cmd("tabnew")
        end
        pcall(function()
            vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(s.session_tab))
        end)
    end
    if vim.api.nvim_tabpage_is_valid(s.return_tab) then
        vim.api.nvim_set_current_tabpage(s.return_tab)
    end
end

-- g?: a floating keymap cheatsheet for the merge result buffer, mirroring the diff
-- view's. rows read the session's resolved keymaps so a configured lhs shows correctly
local function show_help()
    if not session then
        return
    end
    local km = session.keymaps
    local function fmt(spec)
        return type(spec) == "table" and table.concat(spec, " / ") or tostring(spec)
    end
    local function pair(a, b)
        return fmt(a) .. " / " .. fmt(b)
    end
    local rows = {
        { pair(km.next_conflict, km.prev_conflict), "next / previous conflict" },
        { fmt(km.choose_ours), "take ours" },
        { fmt(km.choose_theirs), "take theirs" },
        { fmt(km.choose_base), "take base" },
        { fmt(km.choose_all), "take both (ours then theirs)" },
        { fmt(km.choose_none), "drop the conflict" },
        { ":w", "write the file (auto-stages once resolved)" },
        { "q", "close the merge tool" },
        { fmt(km.help), "this help" },
    }
    local keyw = 0
    for _, r in ipairs(rows) do
        keyw = math.max(keyw, #r[1])
    end
    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = (" %-" .. keyw .. "s   %s"):format(r[1], r[2])
    end
    -- dismiss on the configured help key too, not just the hardcoded q/<Esc>
    local dismiss = { "q", "<Esc>" }
    vim.list_extend(dismiss, type(km.help) == "table" and km.help or { km.help })
    require("differ.ui.help").show(lines, { title = " Differ: merge ", dismiss = dismiss })
end

---@type fun(root: string, relpath: string, model: differ.MergeModel, layout: "default"|"diff3_mixed")
local lay_out

-- once a file resolves + stages, open the next conflicted file (git's order, the staged file
-- already dropped off), reusing the session layout. when none remain, report done and close,
-- returning to the invoking tab. a next file that fails to build leaves the resolved view up
-- rather than looping. no commit hint: the merge may be a rebase/cherry-pick/etc., so naming
-- one command would be wrong as often as right
---@param root string
---@param layout "default"|"diff3_mixed"
local function advance(root, layout)
    local remaining = require("differ.git").conflicted(root)
    if #remaining == 0 then
        notify("all conflicts resolved and staged")
        return M.close()
    end
    local relpath = remaining[1]
    local model, err = require("differ.merge.model").build(root, relpath, nil)
    if not model then
        return notify(err or ("could not open " .. relpath), vim.log.levels.WARN)
    end
    lay_out(root, relpath, model, layout)
end

-- lay out the render in a fresh session tab and wire navigation
---@param root string
---@param relpath string
---@param model differ.MergeModel
---@param layout "default"|"diff3_mixed"
function lay_out(root, relpath, model, layout)
    if session then -- re-open over a live session
        M.close()
    end
    local result = require("differ.render.merge").render(model, { layout = layout })

    local return_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tab split")
    local session_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("silent! only")

    -- result spans the bottom; inputs share the top row left-to-right
    local top = vim.api.nvim_get_current_win()
    vim.cmd("botright split")
    local result_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(top)

    local abs = root .. "/" .. relpath
    local bufs, result_buf = {}, nil -- bufs: the scratch input buffers (deleted on close)
    local result_col -- the result render column (for its fold ranges)
    local inputs = {} -- { side, win, regions, folds }
    local input_wins = {}
    for i, col in ipairs(result.columns) do
        if i == result.result_index then
            -- the result is the REAL worktree file: editable, native syntax/undo/LSP, and
            -- :w writes it for real (BufWritePost stages it once it's marker-free)
            vim.api.nvim_win_call(result_win, function()
                vim.cmd.edit(vim.fn.fnameescape(abs))
            end)
            result_buf = vim.api.nvim_win_get_buf(result_win)
            result_col = col
        else
            local buf = make_buffer(col.side, relpath, col.lines)
            bufs[#bufs + 1] = buf
            local win
            if #input_wins == 0 then
                win = top
            else
                vim.api.nvim_set_current_win(input_wins[#input_wins])
                vim.cmd("rightbelow vsplit")
                win = vim.api.nvim_get_current_win()
            end
            input_wins[#input_wins + 1] = win
            vim.api.nvim_win_set_buf(win, buf)
            inputs[#inputs + 1] =
                { side = col.side, win = win, regions = col.regions, folds = col.folds }
        end
    end

    -- the render layer always yields a result column; assert so the buf type narrows
    -- (and a broken render fails loudly here rather than nil-derefing later)
    assert(result_buf, "merge: render produced no result column")

    local win_side = { [result_win] = "result" }
    for _, win in ipairs(input_wins) do
        dress(win)
        set_local(win, "signcolumn", "yes:1") -- room for the ▌ slab sign
    end
    dress(result_win)

    -- nav + take-this resolution live on the result buffer (the working surface), from
    -- the configurable merge keymaps; falls back to the flat defaults when setup
    -- wasn't called, like the diff view does
    local cfg = require("differ").get_config()
    local km = cfg.keymaps.merge or require("differ.config").defaults.keymaps

    local first = model.regions[1]
    session = {
        root = root,
        path = relpath,
        regions = model.regions,
        order = {},
        total = #model.regions,
        active_index = nil,
        labels = {
            ours = ("OURS (%s)"):format((first and first.label_ours) or "HEAD"),
            base = "BASE",
            theirs = ("THEIRS (%s)"):format((first and first.label_theirs) or "MERGE_HEAD"),
            result = "RESULT",
        },
        layout = layout,
        result_win = result_win,
        result_buf = result_buf,
        bufs = bufs,
        inputs = inputs,
        win_side = win_side,
        return_tab = return_tab,
        session_tab = session_tab,
        keymaps = km, -- for the g? cheatsheet
        diag_aug = suppress_diagnostics(result_buf), -- the markers aren't valid source
        saved_markdown_render = quiet_markdown_render(result_buf), -- don't conceal the markers
    }
    for i = 1, #model.regions do
        session.order[i] = i
    end

    -- paint the panes + lay down the (latent) folds
    for _, inp in ipairs(inputs) do
        win_side[inp.win] = inp.side
        paint_input(vim.api.nvim_win_get_buf(inp.win), inp.side, inp.regions)
        apply_folds(inp.win, inp.folds)
    end
    apply_folds(result_win, result_col and result_col.folds)
    paint_result(nil)

    -- the result is the real file, so a format-on-save would run on :w and choke on (or
    -- mangle) the conflict markers. set conform's buffer-local opt-out for the session,
    -- restored on close; honoured by any format_on_save gate that checks the flag
    session.saved_autoformat = vim.b[result_buf].disable_autoformat
    vim.b[result_buf].disable_autoformat = true
    local function rb(action, fn, desc)
        bind(result_buf, km[action], fn, desc)
    end
    rb("next_conflict", function()
        goto_conflict("next")
    end, "differ: next conflict")
    rb("prev_conflict", function()
        goto_conflict("prev")
    end, "differ: previous conflict")
    rb("choose_ours", function()
        resolve_choice("ours")
    end, "differ: take ours")
    rb("choose_theirs", function()
        resolve_choice("theirs")
    end, "differ: take theirs")
    rb("choose_base", function()
        resolve_choice("base")
    end, "differ: take base")
    rb("choose_all", function()
        resolve_choice("both")
    end, "differ: take both")
    rb("choose_none", function()
        resolve_choice("none")
    end, "differ: drop the conflict")
    rb("help", show_help, "differ: keymap help")
    -- q closes the tool (conventional, no config action)
    vim.keymap.set(
        "n",
        "q",
        M.close,
        { buffer = result_buf, silent = true, desc = "differ: close" }
    )

    local aug = vim.api.nvim_create_augroup("differ.merge." .. result_buf, { clear = true })
    -- :w writes the real file; once no markers remain it auto-stages (git add = resolve),
    -- otherwise it just reports what's left. repaint so a hand-edit's regions stay current
    vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = result_buf,
        group = aug,
        callback = function()
            if not session then
                return
            end
            repaint_result()
            -- a format-on-save that didn't honour disable_autoformat reflows the markers; the
            -- parser loses the region, so guard the stage on the raw buffer, not the count
            local reformatted =
                markers_reformatted(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false))
            if reformatted then
                if not session.autoformat_warned then
                    session.autoformat_warned = true
                    notify(
                        "conflict markers were reformatted on save and the file was NOT staged. "
                            .. "your format_on_save isn't honouring vim.b.disable_autoformat, "
                            .. "which differ sets on this buffer",
                        vim.log.levels.WARN
                    )
                end
            elseif #session.regions == 0 then
                require("differ.git").stage(session.root, session.path)
                notify(session.path .. " resolved and staged")
                -- advance to the next conflicted file (or finish + close) once the write
                -- settles; re-opening the session from inside this BufWritePost isn't safe.
                -- root/layout are this session's lay_out upvalues. tie the deferred advance to
                -- this exact session so a close (or a new session) before the tick cancels it
                local this = session
                vim.schedule(function()
                    if session == this then
                        advance(root, layout)
                    end
                end)
            else
                notify(("%d conflict(s) still unresolved — not staged"):format(#session.regions))
            end
        end,
    })
    -- keep the active-conflict emphasis tracking the cursor
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = result_buf,
        group = aug,
        callback = on_cursor_moved,
    })
    -- widen the mapping timeout while focused in the result buffer so the multi-key
    -- conflict chords land at any pace, not just under a short global timeoutlen
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = result_buf,
        group = aug,
        callback = bump_timeout,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = result_buf,
        group = aug,
        callback = restore_timeout,
    })
    -- a hand-edit shifts the marker lines: re-parse + repaint so the regions, colour, and
    -- nav stay aligned to the live buffer (not just on splice/:w). InsertLeave covers a run
    -- of insert-mode edits that TextChanged doesn't fire per-keystroke for
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
        buffer = result_buf,
        group = aug,
        callback = function()
            if session then
                repaint_result()
            end
        end,
    })

    -- land in the result on the first conflict; on_cursor_moved centres the inputs on it
    vim.api.nvim_set_current_win(result_win)
    if #model.regions > 0 then
        vim.api.nvim_win_set_cursor(result_win, { model.regions[1].result_start, 0 })
    end
    vim.cmd("normal! zz")
    on_cursor_moved()
end

-- resolve root + the target relpath, then build + open. with no path the current file is
-- used when it's conflicted, else the sole conflicted file, else a picker over them
---@param opts { path?: string, layout?: "default"|"diff3_mixed" }|nil
function M.open(opts)
    opts = opts or {}
    local git = require("differ.git")
    local layout = opts.layout or "default"

    local file = vim.api.nvim_buf_get_name(0)
    local anchor = (file ~= "" and vim.fn.filereadable(file) == 1) and file or vim.fn.getcwd()
    local root = git.root(anchor)
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end

    local conflicted = git.conflicted(root)
    if #conflicted == 0 then
        return notify("no conflicted files to resolve")
    end

    local function go(relpath)
        local model, err = require("differ.merge.model").build(root, relpath, nil)
        if not model then
            return notify(err or "could not open the merge tool", vim.log.levels.WARN)
        end
        lay_out(root, relpath, model, layout)
    end

    if opts.path and opts.path ~= "" then
        local abs = vim.fn.fnamemodify(opts.path, ":p")
        local rel = (abs:sub(1, #root + 1) == root .. "/") and abs:sub(#root + 2) or opts.path
        if not vim.tbl_contains(conflicted, rel) then
            return notify(("%s is not conflicted"):format(opts.path), vim.log.levels.WARN)
        end
        return go(rel)
    end

    -- no explicit path: prefer the current file when it's one of the conflicted
    local rel
    if file ~= "" then
        local resolved = vim.fn.resolve(file)
        if resolved:sub(1, #root + 1) == root .. "/" then
            rel = resolved:sub(#root + 2)
        end
    end
    if rel and vim.tbl_contains(conflicted, rel) then
        return go(rel)
    end
    if #conflicted == 1 then
        return go(conflicted[1])
    end
    vim.ui.select(conflicted, { prompt = "Resolve conflict in:" }, function(choice)
        if choice then
            go(choice)
        end
    end)
end

return M
