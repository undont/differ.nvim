-- the merge-tool session: lay the 3-way render into windows — ours / theirs on
-- top (plus base under the diff4 layout), the result spine full-width below — drive
-- conflict navigation (]x/[x), and resolve per conflict (take ours/theirs/both/base/none),
-- splicing the chosen slab into the result and stripping the markers. the result column is
-- the real worktree file: a write auto-stages it once no markers remain, and the session stays
-- on it. ]f/[f save the result, stage it when marker-free, and step to the next/prev conflicted
-- file; the session stays open until :Differ close.
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
local keymap = require("differ.util.keymap")
local tab_util = require("differ.util.tab")
local plural = require("differ.util.text").plural
local merge_files = require("differ.merge.files")
local markers_reformatted = require("differ.git.conflict").reformatted
local bind = keymap.bind

local M = {}

local merge_ns = vim.api.nvim_create_namespace("differ.merge")
local flash_ns = vim.api.nvim_create_namespace("differ.merge.flash")
-- take-base recovers the ancestor from a slab keyed by the conflict's *original* index, so
-- the live -> original mapping has to survive edits, resolves and undo. one extmark per
-- original conflict, spanning its block: it rides edits, `invalidate` retires it when its
-- block is spliced away, and undo restores both text and mark together. its own namespace,
-- since paint_result clears merge_ns on every repaint
local anchor_ns = vim.api.nvim_create_namespace("differ.merge.anchor")
local notice_ns = vim.api.nvim_create_namespace("differ.merge.notice")

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
---@field anchors table<integer, integer> -- anchor extmark id -> original conflict index
---@field base_slabs table<integer, string[]> -- original conflict index -> recovered base slab
---@field total integer                   -- original conflict count (for the winbar N/M)
---@field active_index integer|nil        -- live index of the conflict under the cursor
---@field labels table<string, string>    -- side -> winbar pane label (OURS (HEAD), ...)
---@field no_ancestor boolean             -- add/add: the base pane says so rather than sitting empty
---@field deleted "ours"|"theirs"|nil     -- modify/delete: the side that deleted the file
---@field binary boolean                  -- binary stages: the result is a scratch notice, not the file
---@field layout "default"|"diff4"  -- the chosen layout, reused when stepping to another file
---@field files string[]                -- the conflicted files at session start, in git's order (]f/[f)
---@field file_index integer            -- this file's position in files
---@field left integer                  -- conflicted files still unstaged (for the winbar)
---@field staged boolean                -- this file has been staged this session
---@field removed boolean|nil           -- a modify/delete file deleted this session
---@field head string|nil               -- HEAD at session start; a move means the operation went on
---@field operation string|nil          -- the in-progress operation at session start
---@field watcher differ.git.Watcher|nil -- the git dir watch for changes made outside the session
---@field result_win integer
---@field result_buf integer              -- the real worktree file (editable), or a binary's scratch notice
---@field bufs integer[]                  -- the scratch buffers (deleted on close)
---@field inputs differ.MergeInput[]       -- the input panes (for pane sync on navigation)
---@field win_side table<integer, string> -- window id -> side (for the winbar)
---@field return_tab integer
---@field session_tab integer
---@field keymaps table                   -- resolved merge keymaps (for the g? cheatsheet)
---@field saved_autoformat any            -- the result buffer's prior disable_autoformat, restored on close
---@field saved_markdown_render boolean|nil -- the result buffer's prior render-markdown state, restored on close
---@field saved_diagnostics boolean       -- the result buffer's prior diagnostic enable state, restored on close
---@field autoformat_warned boolean|nil   -- set once a save is seen to have reformatted the markers
---@field diag_aug integer|nil            -- the DiagnosticChanged hook that hushes the result
---@field aug integer|nil                 -- the session augroup on the result buffer
---@field held_keys differ.keymap.Held[] -- the maps bound on the result buffer, with what they replaced

---@type differ.MergeSession|nil
local session = nil

-- the result-buffer conflict chords (<leader>co/ct/cb/ca/cx) are multi-key, so nvim waits
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

-- the recovered base comes from raw stage blobs, so on a CRLF repo every line ends `\r`.
-- the result buffer is the worktree file as nvim loaded it, and nvim strips the CR into
-- fileformat=dos, so splicing a slab carrying its own would have :w write a second one.
-- ours/theirs need no such thing: they are re-parsed from the buffer at resolve time
---@param slab string[]|nil
---@return string[]|nil
local function strip_cr(slab)
    if not slab then
        return slab
    end
    local out = {}
    for i, line in ipairs(slab) do
        out[i] = (line:gsub("\r$", ""))
    end
    return out
end

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- the active session, or nil. exposed so :Differ close can route to it
---@return differ.MergeSession|nil
function M.current()
    return session
end

-- the session to act on, or nil once its result window has gone. every verb reads the
-- cursor from that window, so a session that outlived it can't do anything but raise
-- E5108 from inside a keymap: tear it down instead. the WinClosed/TabClosed hooks
-- normally get there first; this is the net for a teardown they can't see
---@return differ.MergeSession|nil
local function live_session()
    if not session then
        return nil
    end
    if not vim.api.nvim_win_is_valid(session.result_win) then
        M.close()
        return nil
    end
    return session
end

-- the result is the real file, so the user's LSP/linter parses it and reports errors over
-- the conflict markers (invalid source). disabling display alone leaves the diagnostics
-- stored for hover floats and the loc/qf list, so also clear them outright and keep them
-- cleared as the producers re-publish (DiagnosticChanged), until the session closes.
-- returns the augroup id so close can drop the hook
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

-- the original conflict index a live region belongs to, by the surviving anchor sitting on
-- its `<<<<<<<` line. nil when no anchor is there or more than one has collapsed onto it:
-- callers refuse rather than guess, since guessing here writes another conflict's ancestor
-- into the file
---@param result_start integer  -- 1-based line of the region's `<<<<<<<`
---@return integer|nil
local function original_index(result_start)
    local s = assert(session)
    local row = result_start - 1
    local found
    for _, m in
        ipairs(vim.api.nvim_buf_get_extmarks(s.result_buf, anchor_ns, { row, 0 }, {
            row,
            -1,
        }, { details = true }))
    do
        if not m[4].invalid then
            if found then
                return nil -- ambiguous
            end
            found = s.anchors[m[1]]
        end
    end
    return found
end

-- the original index of the conflict at live position `pos`, or nil
---@param pos integer|nil
---@return integer|nil
local function original_at(pos)
    local s = assert(session)
    local region = pos and s.regions[pos]
    return region and original_index(region.result_start) or nil
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
    s.regions = live_regions()
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
        set_local(w, "scrollbind", false)
    end)
    local ok, err = pcall(fn)
    each(function(w)
        if saved[w] ~= nil then
            set_local(w, "scrollbind", saved[w])
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
    sync_inputs(original_at(active))
end

-- jump the result cursor to the next/prev conflict block (wrapping at the ends), repaint
-- the emphasis, and scroll the input panes to the same conflict
---@param dir "next"|"prev"
local function goto_conflict(dir)
    if not live_session() then
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

-- every marker line in the file, in order. mark_base is nil under the default
-- conflictStyle, set under diff3/zdiff3
---@return integer[]
local function marker_lines()
    local lines = {}
    for _, r in ipairs(session.regions) do
        lines[#lines + 1] = r.result_start
        if r.mark_base then
            lines[#lines + 1] = r.mark_base
        end
        lines[#lines + 1] = r.mark_sep
        lines[#lines + 1] = r.result_end
    end
    table.sort(lines)
    return lines
end

-- step the result cursor marker to marker, wrapping at the ends like goto_conflict
---@param dir "next"|"prev"
local function goto_marker(dir)
    if not live_session() then
        return
    end
    local cur = vim.api.nvim_win_get_cursor(session.result_win)[1]
    local lines = marker_lines()
    if #lines == 0 then
        return notify("no conflicts remain")
    end
    local target
    for _, lnum in ipairs(lines) do
        if dir == "next" and lnum > cur then
            target = target or lnum
        elseif dir == "prev" and lnum < cur then
            target = lnum
        end
    end
    if not target then -- wrap
        target = dir == "next" and lines[1] or lines[#lines]
    end
    vim.api.nvim_win_set_cursor(session.result_win, { target, 0 })
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
    local s = live_session()
    if not s then
        return
    end
    if s.deleted then
        return require("differ.merge.deleted").resolve(s, choice)
    end
    if s.binary then
        return require("differ.merge.binary").resolve(s, choice)
    end
    local regions = live_regions()
    if #regions == 0 then
        return notify("no conflicts remain")
    end
    local cur = vim.api.nvim_win_get_cursor(session.result_win)[1]
    local region = region_at(regions, cur)
    if not region then
        return notify("no conflict under the cursor", vim.log.levels.WARN)
    end
    -- the live buffer parse carries no base under the default conflictStyle, so take-base
    -- reads the slab recovered at build time, mapped live index -> original via `order`
    if choice == "base" and not region.base then
        local original = original_index(region.result_start)
        if not original then
            return notify(
                "this conflict's markers were edited; run :Differ mergetool again to use its base",
                vim.log.levels.WARN
            )
        end
        region.base = session.base_slabs[original]
    end
    local slab = require("differ.merge.resolve").slab(region, choice)
    if not slab then
        return notify("no base version in this conflict", vim.log.levels.WARN)
    end
    local anchor = region.result_start
    local slab_count = #slab -- 0 for `none`
    vim.bo[session.result_buf].modifiable = true
    -- replace just the conflict's own lines, not the whole buffer: a whole-buffer set
    -- deletes every line and takes the anchors with it, and the surviving conflicts' marks
    -- are exactly what take-base needs afterwards
    vim.api.nvim_buf_set_lines(
        session.result_buf,
        region.result_start - 1,
        region.result_end,
        false,
        slab
    )
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
    end
end

-- the active conflict's position among the remaining ones
---@return integer
local function active_pos()
    local s = assert(session)
    for i, r in ipairs(s.regions) do
        if r.index == s.active_index then
            return i
        end
    end
    return 1
end

-- the base pane says why it's empty rather than looking broken: add/add has no ancestor at
-- all, and an individual conflict carries no slab when the mapping was too ambiguous to
-- trust. the file-level cause wins, else every conflict would blame itself for it
---@return string
local function base_label()
    local s = assert(session)
    local label = s.labels.base or "BASE"
    if s.no_ancestor then
        return label .. " · no common ancestor"
    end
    if #s.regions > 0 and not s.base_slabs[original_at(active_pos())] then
        return label .. " · none for this conflict"
    end
    return label
end

-- a winbar segment in `hl`, then back to the winbar's own colours
---@param text string
---@param hl string
---@return string
local function tint(text, hl)
    return ("%%#%s#%s%%*"):format(hl, text)
end

-- the result winbar: file progress, then the conflicts left or this file's index state
---@param s differ.MergeSession
---@return string
local function result_winbar(s)
    local file = ("RESULT · file %d/%d"):format(s.file_index, #s.files)
    local remaining = #s.regions
    if s.deleted and not s.staged then
        return ("%s · %s"):format(file, tint("deleted in " .. s.deleted, "differMergeUnstaged"))
    end
    if s.binary and not s.staged then
        return ("%s · binary · %s"):format(file, tint("not staged", "differMergeUnstaged"))
    end
    if remaining == 0 and s.staged then
        local done = tint(s.removed and "deleted" or "staged", "differMergeStaged")
        if s.left == 0 and s.operation then
            local hint = require("differ.merge.continue").hint(s.keymaps)
            return ("%s · %s · all conflicts resolved · %s"):format(file, done, hint)
        end
        if s.left == 0 then
            return ("%s · %s · all conflicts resolved"):format(file, done)
        end
        return ("%s · %s · %s left"):format(file, done, plural(s.left, "file"))
    end
    if remaining == 0 then
        return ("%s · all resolved · %s"):format(file, tint("not staged", "differMergeUnstaged"))
    end
    local n = (s.total - remaining) + active_pos() -- the absolute conflict ordinal
    return ("%s · conflict %d/%d · %d unresolved"):format(file, n, s.total, remaining)
end

-- winbar text for the merge windows: the result shows the conflict counter, an input
-- shows its side label. a `%!` expression reading the window it renders for
---@return string
function M.winbar()
    if not session then
        return ""
    end
    local win = vim.g.statusline_winid
    if win == session.result_win then
        return result_winbar(session)
    end
    local side = session.win_side[win]
    if side == "base" then
        return base_label()
    end
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

-- an empty pane that stands for a deleted or binary file: one dim virtual line, no line
-- numbers. a second call replaces the line
---@param win integer
---@param buf integer
---@param text string
local function show_notice(win, buf, text)
    vim.api.nvim_buf_clear_namespace(buf, notice_ns, 0, -1)
    set_local(win, "number", false)
    set_local(win, "cursorline", false)
    set_local(win, "signcolumn", "no")
    vim.api.nvim_buf_set_extmark(buf, notice_ns, 0, 0, {
        virt_text = { { text, "differFiller" } },
        virt_text_pos = "overlay",
    })
end

-- (re)create the native folds for a window from its fold ranges, left open by default
-- (the structure stays so zM/zc collapse the unchanged regions on demand)
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

-- every window option dress() and apply_folds set, back to its global value. nvim stores
-- a buffer's last window-local options and reapplies them when the buffer is next shown
---@param win integer
local function undress(win)
    vim.api.nvim_win_call(win, function()
        vim.cmd("silent! normal! zE")
        vim.cmd(
            "setlocal number< relativenumber< wrap< foldcolumn< foldenable< foldmethod<"
                .. " foldtext< signcolumn< cursorline< scrollbind< winbar<"
        )
    end)
end

-- the result buffer is the user's real file and outlives the session, so it has to be
-- handed back clean: no session paint, no session keymaps, no session hooks, no
-- session window options
---@param s differ.MergeSession
local function release_result(s)
    if
        vim.api.nvim_win_is_valid(s.result_win)
        and vim.api.nvim_win_get_buf(s.result_win) == s.result_buf
    then
        undress(s.result_win)
    end
    if vim.api.nvim_buf_is_valid(s.result_buf) then
        vim.b[s.result_buf].disable_autoformat = s.saved_autoformat -- give autoformat back
        if s.saved_markdown_render then
            set_markdown_render(s.result_buf, true) -- re-render markdown if it was on
        end
        vim.diagnostic.enable(s.saved_diagnostics, { bufnr = s.result_buf })
        for _, ns in ipairs({ merge_ns, flash_ns, anchor_ns }) do
            vim.api.nvim_buf_clear_namespace(s.result_buf, ns, 0, -1)
        end
        keymap.release(s.result_buf, s.held_keys)
        if s.aug then
            vim.api.nvim_clear_autocmds({ group = s.aug, buffer = s.result_buf })
        end
    end
    -- drop the diagnostics hook; the producers re-lint the now-resolved file on their own
    if s.diag_aug then
        pcall(vim.api.nvim_del_augroup_by_id, s.diag_aug)
        s.diag_aug = nil
    end
end

-- read back what git wrote to the result's file while the session held it. a buffer with
-- unsaved edits gets nvim's changed-on-disk prompt
---@param s differ.MergeSession
local function reload_result(s)
    if vim.api.nvim_buf_is_valid(s.result_buf) then
        vim.cmd.checktime(s.result_buf)
    end
end

-- end the session: drop the tab + buffers and return to the invoking tab
function M.close()
    if not session then
        return
    end
    local s = session
    session = nil
    restore_timeout() -- net in case the tab teardown didn't fire BufLeave on the result buf
    release_result(s)
    reload_result(s)
    if s.aug then
        pcall(vim.api.nvim_del_augroup_by_id, s.aug)
    end
    if s.watcher then
        s.watcher:stop()
    end
    for _, buf in ipairs(s.bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    tab_util.close_session(s.session_tab)
    if vim.api.nvim_tabpage_is_valid(s.return_tab) then
        vim.api.nvim_set_current_tabpage(s.return_tab)
    end
end

-- g?: a floating keymap cheatsheet, mirroring the diff view's. rows read the session's
-- resolved keymaps so a configured lhs shows correctly; an input pane lists only its keys
local function show_help()
    if not session then
        return
    end
    local km = session.keymaps
    local help = require("differ.ui.help")
    local fmt, pair = help.fmt, help.pair
    local rows = { { pair(km.next_conflict, km.prev_conflict), "next / previous conflict" } }
    local deleted = session.deleted
    local in_result = vim.api.nvim_get_current_buf() == session.result_buf and not session.removed
    if in_result and deleted then
        vim.list_extend(rows, {
            { fmt(km.choose_ours), deleted == "ours" and "delete the file" or "keep the file" },
            { fmt(km.choose_theirs), deleted == "theirs" and "delete the file" or "keep the file" },
        })
    elseif in_result and session.binary then
        vim.list_extend(rows, {
            { fmt(km.choose_ours), "take ours" },
            { fmt(km.choose_theirs), "take theirs" },
        })
    elseif in_result then
        vim.list_extend(rows, {
            { pair(km.next_marker, km.prev_marker), "next / previous marker line" },
            { fmt(km.choose_ours), "take ours" },
            { fmt(km.choose_theirs), "take theirs" },
            { fmt(km.choose_base), "take base" },
            { fmt(km.choose_all), "take both (ours then theirs)" },
            { fmt(km.choose_none), "drop the conflict" },
            { ":w", "save and stage" },
        })
    end
    vim.list_extend(rows, {
        { pair(km.next_file, km.prev_file), "next / previous file" },
        { fmt(km.commit), "continue, skip or abort (once resolved)" },
        { ":Differ close", "close the merge tool" },
        { fmt(km.help), "this help" },
    })
    -- dismiss on the configured help key too, not just the hardcoded q/<Esc>
    local dismiss = { "q", "<Esc>" }
    vim.list_extend(dismiss, type(km.help) == "table" and km.help or { km.help })
    help.show(help.lines(rows), { title = " Differ: merge ", dismiss = dismiss })
end

-- the input pane labels, named by the first conflict's markers. a modify/delete or binary
-- file has none: HEAD is ours under every operation, and theirs is named from git's state
---@param model differ.MergeModel
---@return table<string, string>
local function side_labels(model)
    local first = model.regions[1]
    local labels = { ours = "OURS (HEAD)", base = "BASE", theirs = "THEIRS", result = "RESULT" }
    if first then
        labels.ours = ("OURS (%s)"):format(first.label_ours or "HEAD")
        labels.theirs = ("THEIRS (%s)"):format(first.label_theirs or "MERGE_HEAD")
    else
        local theirs = require("differ.git").operation_theirs(model.root)
        if theirs then
            labels.theirs = ("THEIRS (%s)"):format(theirs)
        end
    end
    if model.deleted then
        labels[model.deleted] = labels[model.deleted] .. " · deleted"
    end
    return labels
end

-- git add the marker-free result. the winbar shows it staged; only the file's first stage
-- reports progress, since an auto-save re-stages it on every later edit
local function stage_result()
    local s = assert(session)
    -- a failed add has already notified; the file stays unstaged so a later write retries
    if not require("differ.git").stage(s.root, s.path) then
        return
    end
    if not s.staged then
        merge_files.mark_staged(s)
    end
end

-- BufWritePost on the result: stage once no markers remain. repaint so a hand-edit's
-- regions stay current
local function on_write()
    if not session then
        return
    end
    repaint_result()
    -- a format-on-save that didn't honour disable_autoformat reflows the markers; the
    -- parser loses the region, so guard the stage on the raw buffer, not the count
    if markers_reformatted(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false)) then
        if not session.autoformat_warned then
            session.autoformat_warned = true
            notify(
                "a formatter changed the conflict markers on save; not staged. "
                    .. "your format_on_save ignores vim.b.disable_autoformat",
                vim.log.levels.WARN
            )
        end
        return
    end
    if #session.regions == 0 then
        stage_result()
    end
end

-- save the result and stage it once marker-free, as a write does. false holds the session
-- on this file: the save failed, or the result is marker-free but unstaged, which
-- model.build couldn't reopen
---@return boolean
local function settle_result()
    local s = assert(session)
    -- on_write warns about a reformatting formatter once; a later refusal has to say why
    local warned = s.autoformat_warned
    -- an untouched modify/delete or binary file waits for a take; stepping past isn't one
    if (s.deleted or s.binary) and not s.staged and not vim.bo[s.result_buf].modified then
        return true
    end
    if vim.bo[s.result_buf].modified then
        local ok, err = pcall(vim.api.nvim_buf_call, s.result_buf, function()
            vim.cmd("silent update")
        end)
        if not ok then
            notify(tostring(err), vim.log.levels.ERROR)
            return false
        end
    elseif #s.regions == 0 and not s.staged then
        on_write() -- written but never staged, e.g. after a failed add
    end
    if #s.regions > 0 or s.staged then
        return true
    end
    local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
    if warned and markers_reformatted(lines) then
        notify(
            ("%s isn't staged: a formatter changed its conflict markers"):format(s.path),
            vim.log.levels.WARN
        )
    end
    return false
end

-- the keys an input pane carries; also bound on the scratch buffer a delete leaves behind
---@param buf integer
local function bind_pane(buf)
    local km = assert(session).keymaps
    bind(buf, km.next_conflict, function()
        goto_conflict("next")
    end, "differ: next conflict")
    bind(buf, km.prev_conflict, function()
        goto_conflict("prev")
    end, "differ: previous conflict")
    bind(buf, km.next_file, function()
        merge_files.step("next")
    end, "differ: next conflicted file")
    bind(buf, km.prev_file, function()
        merge_files.step("prev")
    end, "differ: previous conflicted file")
    bind(buf, km.help, show_help, "differ: keymap help")
end

-- lay out the render in a fresh session tab and wire navigation
---@param root string
---@param relpath string
---@param model differ.MergeModel
---@param layout "default"|"diff4"
---@param files string[]
local function lay_out(root, relpath, model, layout, files)
    local git = require("differ.git")
    if session then -- re-open over a live session
        M.close()
    end
    -- the four slabs are told apart by colour alone, so the groups have to exist even
    -- when the user never called setup()
    require("differ.ui.highlights").ensure()
    local result = require("differ.render.merge").render(model, { layout = layout })

    local return_tab, session_tab = tab_util.open_session()
    vim.cmd("silent! only")

    -- result spans the bottom; inputs share the top row left-to-right
    local top = vim.api.nvim_get_current_win()
    vim.cmd("botright split")
    local result_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(top)

    local abs = root .. "/" .. relpath
    local bufs, result_buf = {}, nil -- bufs: the scratch buffers (deleted on close)
    local result_col -- the result render column (for its fold ranges)
    local inputs = {} -- { side, win, regions, folds }
    local input_wins = {}
    for i, col in ipairs(result.columns) do
        if i == result.result_index and model.binary then
            -- never the real file: a write from nvim can change a binary's bytes
            result_buf = make_buffer("result", relpath, {})
            -- acwrite, so a :w reaches the session's BufWriteCmd rather than failing on the buftype
            vim.bo[result_buf].buftype = "acwrite"
            vim.bo[result_buf].modified = false -- or stepping off would save it
            bufs[#bufs + 1] = result_buf
            vim.api.nvim_win_set_buf(result_win, result_buf)
            result_col = col
        elseif i == result.result_index then
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
    for _, inp in ipairs(inputs) do
        local buf = vim.api.nvim_win_get_buf(inp.win)
        if inp.side == model.deleted then
            show_notice(inp.win, buf, "deleted in " .. inp.side)
        elseif model.binary and model.binary[inp.side] then
            show_notice(
                inp.win,
                buf,
                require("differ.merge.binary").describe(model.binary[inp.side])
            )
        end
    end
    dress(result_win)
    if model.binary then
        show_notice(result_win, result_buf, "binary file: take ours or theirs")
    end

    -- nav + take-this resolution live on the result buffer (the working surface), from
    -- the configurable merge keymaps; falls back to the flat defaults when setup
    -- wasn't called, like the diff view does
    local cfg = require("differ").get_config()
    local km = (cfg.keymaps.merge or require("differ.config").defaults.keymaps) --[[@as differ.KeymapSet]]

    local held = {} -- the maps bound below, so close hands back exactly these
    local file_index
    for i, f in ipairs(files) do
        if f == relpath then
            file_index = i
        end
    end
    session = {
        root = root,
        path = relpath,
        regions = model.regions,
        anchors = {},
        base_slabs = {},
        total = #model.regions,
        active_index = nil,
        labels = side_labels(model),
        no_ancestor = model.no_ancestor or false,
        deleted = model.deleted,
        binary = model.binary ~= nil,
        layout = layout,
        files = files,
        file_index = assert(file_index, "merge: " .. relpath .. " is not in the file list"),
        left = #git.conflicted(root),
        staged = false,
        head = git.head_sha(root),
        operation = git.operation(root),
        result_win = result_win,
        result_buf = result_buf,
        bufs = bufs,
        inputs = inputs,
        win_side = win_side,
        return_tab = return_tab,
        session_tab = session_tab,
        keymaps = km, -- for the g? cheatsheet
        held_keys = held,
        diag_aug = suppress_diagnostics(result_buf), -- the markers aren't valid source
        saved_markdown_render = quiet_markdown_render(result_buf), -- don't conceal the markers
        saved_diagnostics = vim.diagnostic.is_enabled({ bufnr = result_buf }),
    }
    -- one anchor per original conflict, spanning its block so a splice retires it
    for _, r in ipairs(model.regions) do
        local id = vim.api.nvim_buf_set_extmark(result_buf, anchor_ns, r.result_start - 1, 0, {
            end_row = r.result_end - 1,
            invalidate = true,
        })
        session.anchors[id] = r.index
    end
    -- recovered base slabs by original conflict index: the default conflictStyle leaves no
    -- base in the live result parse, so take-base looks the slab up here (nil where the
    -- re-merge couldn't recover one, which take-base reports as no base version)
    for _, r in ipairs(model.regions) do
        session.base_slabs[r.index] = strip_cr(r.base)
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
    -- the reset alone leaves a renderer registered after the hook with a stale cache: the
    -- nested empty DiagnosticChanged reaches it before the outer one
    vim.diagnostic.enable(false, { bufnr = result_buf })
    local function rb(action, fn, desc)
        vim.list_extend(held, keymap.hold(result_buf, km[action], fn, desc))
    end
    rb("next_conflict", function()
        goto_conflict("next")
    end, "differ: next conflict")
    rb("prev_conflict", function()
        goto_conflict("prev")
    end, "differ: previous conflict")
    rb("next_marker", function()
        goto_marker("next")
    end, "differ: next conflict marker")
    rb("prev_marker", function()
        goto_marker("prev")
    end, "differ: previous conflict marker")
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
    rb("next_file", function()
        merge_files.step("next")
    end, "differ: next conflicted file")
    rb("prev_file", function()
        merge_files.step("prev")
    end, "differ: previous conflicted file")
    rb("commit", function()
        require("differ.merge.continue").pick_resolved()
    end, "differ: continue, skip or abort the operation")
    rb("help", show_help, "differ: keymap help")
    -- the input panes are scratch buffers deleted on close, so these need no unbind
    for _, buf in ipairs(bufs) do
        bind_pane(buf)
    end
    -- no close key here: the result buffer is the real file and stays editable, so q is
    -- left to native macro recording. `:Differ close` ends the session

    local aug = vim.api.nvim_create_augroup("differ.merge." .. result_buf, { clear = true })
    session.aug = aug
    -- a stage, lazygit or a --continue run outside the session changes the index or HEAD
    local git_dir = git.git_dir(root)
    if git_dir then
        local this = session
        session.watcher = require("differ.git.watch").new({
            git_dir = git_dir,
            on_change = function()
                merge_files.on_git_change(this)
            end,
        })
    end
    vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = result_buf,
        group = aug,
        callback = on_write,
    })
    if model.binary then
        vim.api.nvim_create_autocmd("BufWriteCmd", {
            buffer = result_buf,
            group = aug,
            callback = function()
                notify(("%s is binary: nothing to write"):format(relpath))
            end,
        })
    end
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
        callback = function()
            if session then -- never touch the global option outside a live session
                bump_timeout()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = result_buf,
        group = aug,
        callback = restore_timeout,
    })
    -- the session dies with its window: :tabclose on the merge tab, or a :q on the result
    -- window, would otherwise leave a live session aimed at a dead window. deferred because
    -- the tab is still collapsing when the event fires, and close moves tabs itself; tied to
    -- this exact session so a close (or a new session) before the tick cancels it
    local function teardown()
        local this = session
        if not this then
            return
        end
        vim.schedule(function()
            if session == this then
                M.close()
            end
        end)
    end
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(result_win),
        group = aug,
        callback = teardown,
    })
    -- TabClosed reports shifting tab numbers, not handles, so the callback checks the
    -- session tab's validity rather than trying to match the one that closed
    vim.api.nvim_create_autocmd("TabClosed", {
        group = aug,
        callback = function()
            if not vim.api.nvim_tabpage_is_valid(session_tab) then
                teardown()
            end
        end,
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

-- before :Differ continue runs git: save and stage the open result. false when the save
-- failed or a marker-free result stays unstaged
---@return boolean
function M.settle()
    if not session then
        return true
    end
    return settle_result()
end

-- once differ's own continue, skip or abort ends: open the first conflict it stopped on,
-- else close the session when the operation is over, else keep it with git's new HEAD
---@param root string
function M.after_operation(root)
    local git = require("differ.git")
    local s = session
    local operation = git.operation(root)
    if s then
        s.head, s.operation = git.head_sha(root), operation
        reload_result(s)
    end
    if not operation then
        return M.close()
    end
    local conflicted = git.conflicted(root)
    if #conflicted == 0 then
        return
    end
    local relpath, model = merge_files.first_openable(root, conflicted)
    if relpath then
        local layout = s and s.layout or require("differ").get_config().merge.layout
        return lay_out(root, relpath, assert(model), layout or "default", conflicted)
    end
    merge_files.report_unopenable(conflicted)
    M.close()
end

-- resolve root + the target relpath, then build + open. with no path the current file is
-- used when it's conflicted, else the sole conflicted file, else a picker over them. an
-- explicit opts.layout wins over the configured merge.layout
---@param opts { path?: string, layout?: "default"|"diff4" }|nil
function M.open(opts)
    opts = opts or {}
    local git = require("differ.git")

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

    local merge_cfg = require("differ").get_config().merge or {}
    local layout = opts.layout or merge_cfg.layout or "default"

    local function go(relpath)
        local model = require("differ.merge.model").build(root, relpath, nil)
        if not model then
            return merge_files.report_unopenable({ relpath })
        end
        lay_out(root, relpath, model, layout, conflicted)
    end

    if opts.path and opts.path ~= "" then
        local full = vim.fn.fnamemodify(opts.path, ":p")
        -- the directory only: git lists a conflicted symlink by its own path, not its target
        local abs = vim.fn.resolve(vim.fn.fnamemodify(full, ":h"))
            .. "/"
            .. vim.fn.fnamemodify(full, ":t")
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

-- for merge/files.lua and merge/deleted.lua
M._live_session, M._lay_out, M._bind_pane = live_session, lay_out, bind_pane
M._make_buffer, M._release_result = make_buffer, release_result
M._dress, M._show_notice = dress, show_notice

return M
