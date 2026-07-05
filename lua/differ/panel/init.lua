-- file panel: the persistent sidebar listing a change set. source-agnostic
-- by design: it renders FileEntry sections, owns fold/listing state and the
-- window, and calls `on_select(entry)` when a file is chosen. the local frontend
-- feeds it git changes (phase 2); the PR frontend reuses it verbatim (phase 4),
-- only swapping the model source. it owns *which file*; the View owns *how it
-- renders*, so selecting a file re-sources the existing View (separation of
-- concerns). pure tree/line logic lives in panel/tree.lua + panel/render.lua

local tree = require("differ.panel.tree")
local render = require("differ.panel.render")
local set_wo = require("differ.util.win").set_local
local bind = require("differ.util.keymap").bind

local ns = vim.api.nvim_create_namespace("differ.panel")
local CTRL_D = vim.api.nvim_replace_termcodes("<C-d>", true, false, true)
local CTRL_U = vim.api.nvim_replace_termcodes("<C-u>", true, false, true)

---@type differ.Panel|nil -- the live panel, for runtime API (Panel.current())
local current = nil

-- a `(glyph, hl)` provider backed by nvim-web-devicons, or nil when it's absent
-- (icons degrade away cleanly). resolved once per panel
---@return nil|fun(path: string): string|nil, string|nil
local function devicon_provider()
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if not ok then
        return nil
    end
    return function(path)
        local name = path:match("[^/]+$") or path
        local ext = name:match("%.([^.]+)$")
        return devicons.get_icon(name, ext, { default = true })
    end
end

---@type table<string, string>
local STATUS_HL = {
    A = "differPanelAdd",
    M = "differPanelModify",
    D = "differPanelDelete",
    R = "differPanelRename",
    C = "differPanelRename",
    U = "differPanelUnmerged",
    ["?"] = "differPanelUntracked",
}

---@class differ.panel.Section
---@field title string|nil
---@field entries differ.FileEntry[]

-- file-level staging hooks (slice C); supplied by the local frontend for the
-- working-tree source, nil otherwise (rev-pair lists aren't stageable)
---@class differ.panel.Actions
---@field stage fun(entry: differ.FileEntry)
---@field unstage fun(entry: differ.FileEntry)
---@field stage_all fun()
---@field unstage_all fun()
---@field discard fun(entry: differ.FileEntry)
---@field reload fun(): differ.panel.Section[] -- recompute sections after an op

---@class differ.Panel
---@field bufnr integer
---@field winid integer|nil
---@field origin_win integer|nil
---@field return_tab integer|nil
---@field progress boolean  -- file-position meter in the panel winbar
---@field sections differ.panel.Section[]
---@field listing "tree"|"name"
---@field collapsed table<string, table<string, boolean>>  -- section key -> dir path -> folded
---@field on_select fun(entry: differ.FileEntry)
---@field on_close fun()|nil
---@field on_external_change fun()|nil
---@field root string|nil
---@field footer string|nil
---@field actions differ.panel.Actions|nil
---@field keymaps table<string, string|string[]|false>
-- session-supplied buffer maps (e.g. pr viewed nav) the generic panel doesn't own
---@field extra_keymaps differ.panel.ExtraMap[]|nil
-- fired after a ]f/[f step, for an optional session hook (the pr forward-auto-mark)
---@field on_step fun(direction: "next"|"prev", left: differ.FileEntry|nil, new: differ.FileEntry)|nil
---@field icon_for nil|fun(path: string): string|nil, string|nil
---@field position string
---@field height integer
---@field width integer
---@field content_width integer|nil  -- column the list + pinned counts occupy; capped under window width for top/bottom
---@field lines string[]
---@field meta differ.panel.LineMeta[]
---@field file_total integer|nil  -- total files in the change set (fold-independent)
---@field add_total integer|nil  -- total additions across the change set (diff --stat, on the help line)
---@field del_total integer|nil  -- total deletions across the change set
---@field augroup integer|nil  -- autocmd group for the external-change refresh
---@field win_augroup integer|nil  -- autocmd group for the resize re-fit
---@field selected_row integer|nil  -- meta row of the last opened file; drives ]f/[f
---  and the show() cursor while the sidebar is hidden (no window to read from)
local Panel = {}
Panel.__index = Panel

---@class differ.panel.Opts
---@field sections differ.panel.Section[]
---@field on_select fun(entry: differ.FileEntry)
---@field on_close? fun()  -- runs on :close (e.g. tear down the driven view)
---@field on_external_change? fun() -- re-source list + diff after an outside git change
---@field root? string  -- repo/worktree path shown in the panel header
---@field footer? string -- rev spec shown under "Showing changes for:"
---@field actions? differ.panel.Actions -- file-level staging hooks (slice C)
---@field keymaps? table<string, string|string[]|false> -- resolved panel action -> lhs
---@field extra_keymaps? differ.panel.ExtraMap[] -- session maps (pr viewed nav)
---@field on_step? fun(direction: "next"|"prev", left: differ.FileEntry|nil, new: differ.FileEntry)

---@class differ.panel.ExtraMap
---@field spec string|string[]|false  -- resolved lhs (a keymaps value)
---@field fn fun()
---@field desc string
---@field mode? string|string[] -- keymap mode (default normal; pr range-comment uses "x")
---@field icons? boolean -- filetype devicons (default true when available)
---@field listing? "tree"|"name"
---@field position? "bottom"|"top"|"left"|"right"
---@field height? integer
---@field width? integer
---@field progress? boolean -- file-position meter in the panel winbar (default on)

-- build a panel (buffer only; the window is created on :open, so it's headless-
-- constructible for tests)
---@param opts differ.panel.Opts
---@return differ.Panel
function Panel.new(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    -- "hide", not "wipe": set_position closes + reopens the window, and the panel
    -- owns the buffer's lifecycle explicitly via :close()
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "differpanel"
    vim.bo[bufnr].modifiable = false
    -- name it so the statusline shows "differ://panel" rather than "[Scratch]"
    -- (#bufnr fallback guards the rare case the bare name is already taken)
    if not pcall(vim.api.nvim_buf_set_name, bufnr, "differ://panel") then
        pcall(vim.api.nvim_buf_set_name, bufnr, "differ://panel#" .. bufnr)
    end
    return setmetatable({
        bufnr = bufnr,
        sections = opts.sections,
        on_select = opts.on_select,
        on_close = opts.on_close,
        on_external_change = opts.on_external_change,
        root = opts.root,
        footer = opts.footer,
        actions = opts.actions,
        extra_keymaps = opts.extra_keymaps,
        on_step = opts.on_step,
        keymaps = vim.tbl_extend(
            "force",
            require("differ.config").defaults.keymaps,
            opts.keymaps or {}
        ),
        icon_for = opts.icons ~= false and devicon_provider() or nil,
        listing = opts.listing or "tree",
        position = opts.position or "bottom",
        height = opts.height or 7,
        width = opts.width or 35,
        progress = opts.progress ~= false, -- default on; only an explicit false disables it
        collapsed = {},
        lines = {},
        meta = {},
    }, Panel)
end

-- 1-based line of the first file row, or 1 if there are none
---@return integer
function Panel:_first_file_line()
    for i, m in ipairs(self.meta) do
        if m.kind == "file" then
            return i
        end
    end
    return 1
end

-- move the cursor to the first visitable file row, skipping pure renames (which diff
-- to a blank view) but landing on untracked files (zero numstat counts, yet real
-- content). falls back to the first file when every entry is a blank rename. shares
-- the edge-jump logic so the initial open and [[/]] agree on what's visitable
function Panel:focus_first_changed()
    local row = self:_edge_file_row("first")
    if row then
        pcall(vim.api.nvim_win_set_cursor, self.winid, { row, 0 })
    end
end

-- move the cursor to `path`'s file row if it's currently rendered, returning whether
-- it was found; lets :Differ open on the current file rather than the first
---@param path string -- repo-relative
---@return boolean
function Panel:focus_file(path)
    for i, m in ipairs(self.meta) do
        if m.kind == "file" and m.entry.path == path then
            if self:is_open() then
                pcall(vim.api.nvim_win_set_cursor, self.winid, { i, 0 })
            end
            return true
        end
    end
    return false
end

-- a stable per-section fold namespace: the title (unique, and survives the index
-- shuffle when an empty section drops on refresh) or the index when untitled
---@param i integer
---@return string
function Panel:_section_key(i)
    local sec = self.sections[i]
    return (sec and sec.title) or ("#" .. i)
end

-- build a section's tree the way render does: in tree mode, strip the shared dir
-- prefix when it's 2+ levels deep (that's where indentation hurts, and a single
-- shared dir is worth keeping as a foldable row), shown once as a header subtitle.
-- returns the root and that stripped prefix ("" when none). fold-all ops reuse this
-- so their collapse keys match the dir.path values tree.rows reads
---@param sec differ.panel.Section
---@return differ.panel.Node root, string strip
function Panel:_section_root(sec)
    local strip = ""
    if self.listing == "tree" then
        local common = tree.common_dir(sec.entries)
        local _, levels = common:gsub("/", "")
        if levels >= 2 then
            strip = common
        end
    end
    return tree.build(sec.entries, strip), strip
end

-- re-flatten the sections (honouring listing + fold state) and repaint the
-- buffer. cursor line is preserved across re-renders (clamped)
function Panel:render()
    local blocks = {}
    -- absolute file numbering across the whole change set, in display order and
    -- independent of which dirs are folded, so the section counts + winbar meter
    -- stay accurate when collapsed (entry -> 1-based index)
    local abs_of, total = {}, 0
    -- diff --stat totals, summed over every file (fold-independent, like the count)
    local add_total, del_total = 0, 0
    for bi, sec in ipairs(self.sections) do
        local root, strip = self:_section_root(sec)
        for _, row in ipairs(tree.rows(root, "tree", {})) do -- fully expanded
            if row.kind == "file" then
                total = total + 1
                abs_of[row.entry] = total
                add_total = add_total + (row.entry.additions or 0)
                del_total = del_total + (row.entry.deletions or 0)
            end
        end
        blocks[#blocks + 1] = {
            title = sec.title,
            prefix = strip ~= "" and strip or nil,
            count = #sec.entries,
            -- fold state is namespaced per section: the same dir path can list under
            -- two sections at once (e.g. an untracked src/ and an unstaged src/), so a
            -- shared key would collapse both rows from one toggle
            rows = tree.rows(root, self.listing, self.collapsed[self:_section_key(bi)]),
        }
    end
    self.file_total = total
    -- diff --stat totals, painted on the help line (the file count already sits in the
    -- winbar meter, so the totals show the +A -B the count doesn't repeat)
    self.add_total, self.del_total = add_total, del_total
    local header = self.root and { path = self.root, help = "g?" } or nil
    -- live window width, falling back to the configured width when the window
    -- isn't open yet (headless construction / tests)
    local live = self:is_open() and vim.api.nvim_win_get_width(self.winid) or self.width
    -- a top/bottom panel spans the full editor width, so the window's right edge
    -- is far from the file list. rather than cap the content column at the fixed
    -- configured width (which truncates names that would otherwise fit), fit it to
    -- the content: render untruncated, measure the longest name plus its pinned
    -- counts, and anchor the column just past it. floor at the configured width so
    -- a short list keeps a stable column; cap at the live width so an overflowing
    -- list still truncates at the editor edge
    local horizontal = self.position == "top" or self.position == "bottom"
    local out, width
    if horizontal then
        out = render.lines(blocks, header, self.icon_for, self.footer, nil)
        local needed = 0
        for i, m in ipairs(out.meta) do
            if m.kind == "file" then
                local e = m.entry
                local reserve = (e.additions and (e.additions > 0 or e.deletions > 0))
                        and #("+" .. e.additions) + #("-" .. e.deletions) + 2
                    or 0
                needed = math.max(needed, #out.lines[i] + reserve)
            end
        end
        width = math.min(live, math.max(needed, self.width))
        -- the untruncated render stands unless the content overflows the window, in
        -- which case re-render truncated to the live edge
        if width < needed then
            out = render.lines(blocks, header, self.icon_for, self.footer, width)
        end
    else
        width = live
        out = render.lines(blocks, header, self.icon_for, self.footer, width)
    end
    self.content_width = width
    self.lines, self.meta = out.lines, out.meta
    for _, m in ipairs(self.meta) do
        if m.kind == "file" then
            m.file_index = abs_of[m.entry]
        end
    end

    vim.bo[self.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, out.lines)
    vim.bo[self.bufnr].modifiable = false
    self:_highlight()
end

-- paint section/dir/status highlights from the line metadata
function Panel:_highlight()
    vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
    for i, m in ipairs(self.meta) do
        local row = i - 1
        local eol = #self.lines[i]
        if m.kind == "root" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                0,
                { end_col = eol, hl_group = "differPanelRoot" }
            )
        elseif m.kind == "help" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                0,
                { end_col = eol, hl_group = "differPanelHelp" }
            )
            -- the diff --stat totals ride the (otherwise sparse) help line, pinned to
            -- the same content column as the per-file counts so they stack directly
            -- above them as a column total. virt_text, not line text, so it can't be
            -- clipped the way a winbar segment is on a narrow panel
            if (self.add_total or 0) > 0 or (self.del_total or 0) > 0 then
                local label = "--stat"
                local add = ("+%d"):format(self.add_total)
                local del = ("-%d"):format(self.del_total)
                local reserve = #label + 1 + #add + #del + 2
                vim.api.nvim_buf_set_extmark(self.bufnr, ns, row, 0, {
                    virt_text = {
                        { label, "differPanelContext" },
                        { " ", "Normal" },
                        { add, "differPanelCountAdd" },
                        { " ", "Normal" },
                        { del, "differPanelCountDelete" },
                        { " ", "Normal" },
                    },
                    virt_text_win_col = math.max((self.content_width or 0) - reserve, 0),
                })
            end
        elseif m.kind == "header" or m.kind == "foothead" then
            local title_end = m.prefix_col or eol
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                0,
                { end_col = title_end, hl_group = "differPanelHeader" }
            )
            if m.prefix_col then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.prefix_col,
                    { end_col = m.prefix_end, hl_group = "differPanelContext" }
                )
            end
        elseif m.kind == "footrev" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                0,
                { end_col = eol, hl_group = "differPanelHelp" }
            )
        elseif m.kind == "dir" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                m.name_col,
                { end_col = eol, hl_group = "differPanelDir" }
            )
        elseif m.kind == "file" then
            local hl = STATUS_HL[m.status]
            if hl then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.status_col,
                    { end_col = m.status_col + #m.status, hl_group = hl }
                )
            end
            if m.icon_col and m.icon_hl then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.icon_col,
                    { end_col = m.icon_end, hl_group = m.icon_hl }
                )
            end
            if m.context_col then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.context_col,
                    { end_col = m.context_end, hl_group = "differPanelContext" }
                )
            end
            -- dim a viewed PR file's checkbox so reviewed files recede
            if m.viewed_col and m.entry and m.entry.viewed then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.viewed_col,
                    { end_col = m.viewed_end, hl_group = "differPanelContext" }
                )
            end
            local e = m.entry
            if e and (e.additions > 0 or e.deletions > 0) then
                -- pin the diffstat to the content column as virtual text, so it sits
                -- next to the tree regardless of panel orientation (the line text
                -- holds no counts; render.lines reserves the room and truncates the
                -- name to the same width). win_col, not right_align: a top/bottom
                -- panel's right edge is the full editor width, far from the list
                local add = ("+%d"):format(e.additions)
                local del = ("-%d"):format(e.deletions)
                local reserve = #add + #del + 2
                vim.api.nvim_buf_set_extmark(self.bufnr, ns, row, 0, {
                    virt_text = {
                        { add, "differPanelCountAdd" },
                        { " ", "Normal" },
                        { del, "differPanelCountDelete" },
                        { " ", "Normal" },
                    },
                    virt_text_win_col = math.max((self.content_width or 0) - reserve, 0),
                })
            end
        end
    end
end

-- replace the file-list model and repaint (used on refresh / source change)
---@param sections differ.panel.Section[]
function Panel:set_sections(sections)
    self.sections = sections
    self:render()
end

-- the line of the dir row for `path` in `section`, or nil when it isn't rendered
---@param section integer
---@param path string
---@return integer|nil
function Panel:_dir_line(section, path)
    for i, m in ipairs(self.meta) do
        if m.kind == "dir" and m.section == section and m.path == path then
            return i
        end
    end
    return nil
end

-- toggle the fold state of a section's directory and repaint, anchoring the cursor
-- to the toggled dir row (its line number shifts when folds above it change height)
---@param section integer
---@param path string
function Panel:toggle_fold(section, path)
    local key = self:_section_key(section)
    local sub = self.collapsed[key]
    if not sub then
        sub = {}
        self.collapsed[key] = sub
    end
    sub[path] = not sub[path]
    local lnum = self.winid and vim.api.nvim_win_get_cursor(self.winid)[1] or 1
    self:render()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        local row = self:_dir_line(section, path) or math.min(lnum, math.max(#self.lines, 1))
        vim.api.nvim_win_set_cursor(self.winid, { row, 0 })
    end
end

-- the line of the nearest dir row above `lnum` with a shallower depth: the parent
-- directory of the row at `lnum`, or nil if it's already top-level
---@param lnum integer
---@return integer|nil
function Panel:_parent_dir_line(lnum)
    local m = self.meta[lnum]
    if not m or not m.depth then
        return nil
    end
    for i = lnum - 1, 1, -1 do
        local p = self.meta[i]
        if p and p.kind == "dir" and (p.depth or 0) < m.depth then
            return i
        end
    end
    return nil
end

-- c: close the directory under the cursor. on an open dir, collapse it; on a file
-- or an already-closed dir, collapse its parent and move there (tree-nav idiom)
function Panel:close_node()
    if not self:is_open() then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
    local m = self.meta[lnum]
    if not m then
        return
    end
    if m.kind == "dir" then
        local folded = (self.collapsed[self:_section_key(m.section)] or {})[m.path]
        if not folded then
            self:toggle_fold(m.section, m.path)
            return
        end
    end
    local parent = self:_parent_dir_line(lnum)
    if parent then
        local pm = self.meta[parent]
        vim.api.nvim_win_set_cursor(self.winid, { parent, 0 })
        self:toggle_fold(pm.section, pm.path)
    end
end

-- set every directory's fold state and repaint, keeping the cursor put. C / O bind
-- collapse-all / expand-all to this
---@param collapsed boolean
function Panel:set_all_folds(collapsed)
    if collapsed then
        for bi, sec in ipairs(self.sections) do
            local sub = {}
            for _, path in ipairs(tree.dir_paths((self:_section_root(sec)))) do
                sub[path] = true
            end
            self.collapsed[self:_section_key(bi)] = sub
        end
    else
        self.collapsed = {}
    end
    local lnum = self.winid and vim.api.nvim_win_get_cursor(self.winid)[1] or 1
    self:render()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_win_set_cursor(self.winid, { math.min(lnum, math.max(#self.lines, 1)), 0 })
    end
end

-- the main content window the panel drives (where diffs and the overview page open),
-- carving a fresh split off the panel if none survives. exposed for the pr overview
---@return integer
function Panel:content_win()
    return self:_ensure_origin()
end

-- a non-panel window to open diffs in: the origin window if still valid, else any
-- other window, else a fresh split carved off the panel
---@return integer
function Panel:_ensure_origin()
    if
        self.origin_win
        and self.origin_win ~= self.winid
        and vim.api.nvim_win_is_valid(self.origin_win)
    then
        return self.origin_win
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= self.winid then
            self.origin_win = w
            return w
        end
    end
    vim.api.nvim_set_current_win(self.winid)
    vim.cmd("aboveleft split")
    self.origin_win = vim.api.nvim_get_current_win()
    return self.origin_win
end

-- open `entry`'s diff in the main window. by default focus returns to the panel so
-- file browsing keeps flowing; `keep_focus` leaves it in the diff window (used when
-- stepping files from inside the diff via `]f`/`[f`)
---@param entry differ.FileEntry
---@param keep_focus boolean|nil
function Panel:_open(entry, keep_focus)
    vim.api.nvim_set_current_win(self:_ensure_origin())
    self.on_select(entry)
    if not keep_focus and self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_set_current_win(self.winid)
    end
end

-- <CR>/o: open a file, or toggle a directory's fold. `keep_focus` leaves the cursor
-- in the diff window (used by the open-and-show entry so :Differ lands you in the diff)
---@param keep_focus boolean|nil
function Panel:select(keep_focus)
    local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
    local m = self.meta[lnum]
    if not m then
        return
    end
    if m.kind == "dir" then
        self:toggle_fold(m.section, m.path)
    elseif m.kind == "file" then
        self.selected_row = lnum
        self:_open(m.entry, keep_focus)
    end
end

-- every FileEntry under a directory row, scoped to that row's own section (the same
-- dir path can list under Staged and Unstaged at once, so a section-blind path match
-- would stage the wrong side). collapsed dirs work too: this reads the section's
-- entries, not the rendered rows
---@param m differ.panel.LineMeta -- a dir row's meta
---@return differ.FileEntry[]
function Panel:_dir_entries(m)
    local sec = self.sections[m.section]
    if not sec then
        return {}
    end
    local prefix = m.dir_path .. "/"
    local out = {}
    for _, e in ipairs(sec.entries) do
        if e.path:sub(1, #prefix) == prefix then
            out[#out + 1] = e
        end
    end
    return out
end

-- the entries a stage/unstage/discard acts on from the cursor row: the single file
-- under the cursor, every file beneath a directory row, or every file in a section
-- when the cursor is on its header (the only target for a section whose shared deep
-- prefix is stripped to a subtitle, leaving no dir row). also returns a label for the
-- discard confirm. empty when the cursor isn't on a file, dir, or header row
---@return differ.FileEntry[] entries, string|nil label
function Panel:_op_targets()
    local m = self.winid and self.meta[vim.api.nvim_win_get_cursor(self.winid)[1]]
    if not m then
        return {}, nil
    end
    if m.kind == "file" then
        return { m.entry }, m.entry.path
    end
    if m.kind == "dir" then
        return self:_dir_entries(m), m.dir_path .. "/"
    end
    if m.kind == "header" then
        local sec = self.sections[m.section]
        return sec and vim.list_slice(sec.entries) or {}, m.title or "section"
    end
    return {}, nil
end

-- re-read the model (after a stage op or on focus) and repaint, keeping the cursor
-- line (clamped). no-op without staging actions (rev-pair panels aren't reloadable)
function Panel:refresh()
    if not self.actions or not self:is_open() then
        return
    end
    local lnum = self.winid and vim.api.nvim_win_get_cursor(self.winid)[1] or 1
    self:set_sections(self.actions.reload())
    self:_restore_cursor(lnum)
end

-- s/u/S/U: stage or unstage the cursor's target (a file, or every file under a
-- directory row) or all, then refresh
---@param op "stage"|"unstage"|"stage_all"|"unstage_all"
function Panel:stage_op(op)
    if not self.actions then
        return
    end
    if op == "stage_all" or op == "unstage_all" then
        self.actions[op]()
    else
        local entries = self:_op_targets()
        if #entries == 0 then
            return
        end
        for _, e in ipairs(entries) do
            self.actions[op](e)
        end
    end
    self:refresh()
end

-- X: discard the cursor's target after a confirm (destructive), then refresh. on a
-- directory row, discards every file beneath it
function Panel:discard()
    if not self.actions then
        return
    end
    local entries, label = self:_op_targets()
    if #entries == 0 then
        return
    end
    local what = #entries == 1 and entries[1].path or ("%s (%d files)"):format(label, #entries)
    local choice = vim.fn.confirm(("Discard changes to %s?"):format(what), "&Yes\n&No", 2)
    if choice == 1 then
        for _, e in ipairs(entries) do
            self.actions.discard(e)
        end
        self:refresh()
    end
end

-- the next/prev file row from `lnum`. wraps past the ends by default so ]f / [f
-- stepping is cyclic (you often open mid-list); `wrap == false` bounds it instead,
-- returning nil at the first/last file so the staging review flow stops at the ends.
-- nil too when there are no file rows at all. the second return reports whether
-- reaching it actually crossed an end, so goto_file can notify on a wrap
---@param lnum integer
---@param direction "next"|"prev"
---@param wrap? boolean  -- default true; false stops at the list ends
---@return integer|nil row, boolean wrapped
function Panel:_file_row(lnum, direction, wrap)
    local n = #self.meta
    if n == 0 then
        return nil, false
    end
    local step = direction == "prev" and -1 or 1
    local i = lnum + step
    while i >= 1 and i <= n do
        if self.meta[i] and self.meta[i].kind == "file" then
            return i, false
        end
        i = i + step
    end
    if wrap == false then
        return nil, false
    end
    for k = 1, n do
        local j = ((lnum - 1 + step * k) % n) + 1
        local m = self.meta[j]
        if m and m.kind == "file" then
            return j, true
        end
    end
    return nil, false
end

-- ]f / [f: move to the next/prev file row and open it (lockstep file stepping).
-- wraps at the ends by default (notifying, since it's otherwise not obvious you
-- cycled back rather than simply moved); `wrap == false` (the staging review flow)
-- stops at them instead. `keep_focus` is threaded to `_open` so in-view stepping
-- stays in the diff window. returns whether a file was actually opened (false at a
-- no-wrap list end)
---@param direction "next"|"prev"
---@param keep_focus boolean|nil
---@param wrap? boolean  -- default true; false stops at the list ends
---@return boolean moved
function Panel:goto_file(direction, keep_focus, wrap)
    -- step from the live cursor when the sidebar is visible, else from the last
    -- opened row so ]f/[f keeps working with the panel hidden
    local from = self:is_open() and vim.api.nvim_win_get_cursor(self.winid)[1]
        or self.selected_row
        or self:_first_file_line()
    local i, wrapped = self:_file_row(from, direction, wrap)
    if not i then
        return false
    end
    -- the file being left, for an optional session step hook (the pr forward-auto-mark)
    local left = self.meta[from] and self.meta[from].kind == "file" and self.meta[from].entry or nil
    self.selected_row = i
    if self:is_open() then
        vim.api.nvim_win_set_cursor(self.winid, { i, 0 })
    end
    self:_open(self.meta[i].entry, keep_focus)
    if self.on_step then
        self.on_step(direction, left, self.meta[i].entry)
    end
    if wrapped then
        vim.notify(
            direction == "next" and "differ: wrapped to the first file"
                or "differ: wrapped to the last file",
            vim.log.levels.INFO
        )
    end
    return true
end

-- a pure rename/copy (status R/C with no added/deleted lines) diffs to nothing, so
-- landing on it shows a blank view. untracked/added files report zero numstat counts
-- too (git doesn't diff them) but render their whole content, so they're not blank
---@param e differ.FileEntry
---@return boolean
local function is_blank_rename(e)
    return (e.status == "R" or e.status == "C") and (e.additions or 0) + (e.deletions or 0) == 0
end

-- the first/last visitable file row, skipping pure renames (blank diffs) and falling
-- back to the absolute first/last file row when every entry is a blank rename. the
-- edge jumps skip those the way the initial open does (focus_first_changed)
---@param edge "first"|"last"
---@return integer|nil
function Panel:_edge_file_row(edge)
    local fallback, visitable
    local from = edge == "first" and 0 or #self.meta + 1
    local direction = edge == "first" and "next" or "prev"
    local i = self:_file_row(from, direction, false)
    while i do
        fallback = fallback or i
        if not is_blank_rename(self.meta[i].entry) then
            visitable = i
            break
        end
        i = self:_file_row(i, direction, false)
    end
    return visitable or fallback
end

-- move the cursor to the first unstaged file row, skipping the Staged section so
-- :Differ lands on the first thing left to review, falling back to the first
-- visitable file when everything is staged. mirrors the per-file _first_review_line,
-- which already prefers an unstaged hunk. pure renames are skipped as in
-- focus_first_changed; for sources without staging (rev-pair, pr) entries carry no
-- staged flag, so this degenerates to the first file
function Panel:focus_first_unstaged()
    local i = self:_file_row(0, "next", false)
    while i do
        local e = self.meta[i].entry
        if not e.staged and not is_blank_rename(e) then
            pcall(vim.api.nvim_win_set_cursor, self.winid, { i, 0 })
            return
        end
        i = self:_file_row(i, "next", false)
    end
    self:focus_first_changed()
end

-- gg / G: move the cursor to the first/last visitable file row without opening it,
-- skipping pure renames (blank diffs). plain list navigation; <CR>/o opens the row
-- under the cursor
---@param edge "first"|"last"
function Panel:cursor_to_edge(edge)
    if not self:is_open() then
        return
    end
    local row = self:_edge_file_row(edge)
    if not row then
        return
    end
    vim.api.nvim_win_set_cursor(self.winid, { row, 0 })
end

-- the meta rows of the section headers, in order. titled blocks (Staged/Unstaged/
-- Untracked) render a header; an untitled single-section panel (rev-pair/history)
-- has none, so section nav is inert there
---@return integer[]
function Panel:_header_rows()
    local rows = {}
    for i, m in ipairs(self.meta) do
        if m.kind == "header" then
            rows[#rows + 1] = i
        end
    end
    return rows
end

-- the first visitable file row inside the section beginning at `header_row` (down to
-- the next header or the list end), skipping pure renames; falls back to the section's
-- first file row, or nil when the section has no visible file rows (all folded away)
---@param header_row integer
---@return integer|nil
function Panel:_section_first_file(header_row)
    local stop = #self.meta
    for i = header_row + 1, #self.meta do
        if self.meta[i].kind == "header" then
            stop = i - 1
            break
        end
    end
    local fallback
    for i = header_row + 1, stop do
        local m = self.meta[i]
        if m.kind == "file" then
            fallback = fallback or i
            if not is_blank_rename(m.entry) then
                return i
            end
        end
    end
    return fallback
end

-- ]] / [[: jump to the next/prev section and open its first (visitable) file. with a
-- section fully folded away its header still gets the cursor, so the motion never
-- stalls. inert in single-section panels. `keep_focus` is threaded to `_open`
---@param direction "next"|"prev"
---@param keep_focus boolean|nil
function Panel:goto_section(direction, keep_focus)
    local headers = self:_header_rows()
    if #headers < 2 then
        return
    end
    local from = self:is_open() and vim.api.nvim_win_get_cursor(self.winid)[1]
        or self.selected_row
        or 1
    -- the index of the section the cursor sits in: the last header at or above it
    local ci = 0
    for k, h in ipairs(headers) do
        if h <= from then
            ci = k
        else
            break
        end
    end
    -- explicit branch, not `cond and a or b`: at the last section headers[ci+1] is nil,
    -- which the and/or form would silently fold into the prev-section branch
    local target
    if direction == "next" then
        target = headers[ci + 1]
    else
        target = headers[ci - 1]
    end
    if not target then
        return
    end
    local file = self:_section_first_file(target)
    if file then
        self.selected_row = file
        if self:is_open() then
            vim.api.nvim_win_set_cursor(self.winid, { file, 0 })
        end
        self:_open(self.meta[file].entry, keep_focus)
    elseif self:is_open() then
        vim.api.nvim_win_set_cursor(self.winid, { target, 0 })
    end
end

-- the file selection's entry: the live cursor row when the sidebar is open, else the
-- last opened row (so it works with the panel hidden). nil if neither is a file row
---@return differ.FileEntry|nil
function Panel:current_entry()
    local row = self:is_open() and vim.api.nvim_win_get_cursor(self.winid)[1] or self.selected_row
    local m = row and self.meta[row]
    return m and m.kind == "file" and m.entry or nil
end

-- jump the selection straight to `path`'s row and open it (arbitrary jump, vs
-- goto_file's single step). drives `]u`/`[u` unviewed nav. returns whether it landed
---@param path string -- repo-relative
---@param keep_focus boolean|nil
---@return boolean
function Panel:goto_path(path, keep_focus)
    for i, m in ipairs(self.meta) do
        if m.kind == "file" and m.entry.path == path then
            self.selected_row = i
            if self:is_open() then
                vim.api.nvim_win_set_cursor(self.winid, { i, 0 })
            end
            self:_open(m.entry, keep_focus)
            return true
        end
    end
    return false
end

-- repaint after a session mutates an entry in place (e.g. a viewed flip), holding the
-- cursor line. lighter than refresh (no model reload) and works without staging actions
function Panel:repaint()
    if not self:is_open() then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
    self:render()
    self:_restore_cursor(lnum)
end

-- scroll the *diff view* a quarter page (the origin window, where the file renders),
-- not the panel list, mirroring diffview's file-panel scroll (default f / b)
---@param direction "down"|"up"
function Panel:scroll(direction)
    local win = self.origin_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local n = math.max(1, math.floor(vim.api.nvim_win_get_height(win) / 4))
    vim.api.nvim_win_call(win, function()
        vim.cmd("normal! " .. n .. (direction == "down" and CTRL_D or CTRL_U))
    end)
end

-- g?: a floating keymap cheatsheet, dismissed with <Esc> / g?
function Panel:show_help()
    local lines = {
        " <CR> / o   open file / toggle fold",
        " c          close node / parent",
        " C / O      close / open all nodes",
        " ]f / [f    next / previous file",
        " gg / G     first / last file",
        " ]] / [[    next / previous section",
        " ]c / [c    next / previous hunk",
        " f / b      scroll diff down / up",
        " i          toggle listing (tree / name)",
        " de         go to the real file",
    }
    if self.actions then
        vim.list_extend(lines, {
            " s / u      stage / unstage file",
            " S / U      stage / unstage all",
            " X          discard file (confirm)",
            " df         edit the real file (in review)",
            " R          refresh",
        })
    end
    vim.list_extend(lines, { " g?         this help" })
    require("differ.ui.help").show(lines, { title = " Differ: panel " })
end

-- window appearance + buffer-local keymaps
function Panel:_setup_window()
    local win = self.winid
    -- window-local only: a plain vim.wo[win] write also sets the global default
    -- (omits scope), leaking the panel's chrome onto every other window
    set_wo(win, "number", false)
    set_wo(win, "relativenumber", false)
    set_wo(win, "signcolumn", "no")
    set_wo(win, "foldcolumn", "0")
    set_wo(win, "wrap", false)
    set_wo(win, "cursorline", true)
    if self.progress then
        -- a `%!` expression so the file-position meter tracks the cursor on each redraw
        set_wo(win, "winbar", '%!v:lua.require("differ.ui.winbar").panel()')
    end
    if self.position == "left" or self.position == "right" then
        set_wo(win, "winfixwidth", true)
    else
        set_wo(win, "winfixheight", true)
    end

    -- re-render on resize so the name truncation re-fits the new width (clear=true
    -- so re-opening / repositioning doesn't stack duplicate autocmds)
    self.win_augroup =
        vim.api.nvim_create_augroup("differ.panel.win." .. self.bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
        group = self.win_augroup,
        desc = "differ: re-fit the panel name truncation on resize",
        callback = function()
            if not self:is_open() then
                return
            end
            local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
            self:render()
            self:_restore_cursor(lnum)
        end,
    })

    -- navigate-away guard: a picker / :edit that swaps another buffer into the panel
    -- window ends the session (the panel is the session anchor's sidebar, not a place
    -- to open files), carrying the navigation out to the launch tab. only a survived
    -- window holding a foreign buffer counts; a plain close (hide / reposition / :q)
    -- leaves no window, so it's ignored
    vim.api.nvim_create_autocmd("BufWinLeave", {
        group = self.win_augroup,
        buffer = self.bufnr,
        desc = "differ: end the session when the panel window is navigated away",
        callback = function()
            local pwin = self.winid
            vim.schedule(function()
                if not (pwin and vim.api.nvim_win_is_valid(pwin)) then
                    return
                end
                local newbuf = vim.api.nvim_win_get_buf(pwin)
                if newbuf ~= self.bufnr and vim.api.nvim_buf_is_valid(newbuf) then
                    require("differ.git").navigate_away(newbuf)
                end
            end)
        end,
    })

    local km = self.keymaps
    local function map(spec, fn, desc)
        bind(self.bufnr, spec, fn, "differ panel: " .. desc)
    end
    -- de / df: file-targeted diff verbs (go-to-file, edit-in-review). open the row
    -- under the cursor first so they act on it, not the last-shown diff, then defer to
    -- the shared entry points, which act on the driven view and self-guard by source
    local function diff_file_verb(run)
        local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
        local m = self.meta[lnum]
        if not (m and m.kind == "file") then
            return vim.notify("differ: put the cursor on a file", vim.log.levels.WARN)
        end
        if lnum ~= self.selected_row then
            self:select()
        end
        run()
    end
    map(km.select, function()
        self:select()
    end, "open / toggle fold")
    map(km.next_file, function()
        self:goto_file("next")
    end, "next file")
    map(km.prev_file, function()
        self:goto_file("prev")
    end, "previous file")
    map(km.first_file, function()
        self:cursor_to_edge("first")
    end, "first file")
    map(km.last_file, function()
        self:cursor_to_edge("last")
    end, "last file")
    map(km.next_section, function()
        self:goto_section("next")
    end, "next section")
    map(km.prev_section, function()
        self:goto_section("prev")
    end, "previous section")
    -- next/prev hunk drive the diff view's hunk nav from the panel (bound buffer-
    -- locally in the diff window too), so hunk stepping works from either side
    map(km.next_hunk, function()
        require("differ").goto_hunk("next")
    end, "next hunk")
    map(km.prev_hunk, function()
        require("differ").goto_hunk("prev")
    end, "previous hunk")
    map(km.goto_file, function()
        diff_file_verb(function()
            require("differ").jump_to_file()
        end)
    end, "go to the real file")
    map(km.help, function()
        self:show_help()
    end, "help")
    map(km.toggle_listing, function()
        self:toggle_listing()
    end, "toggle listing (tree / name)")
    map(km.close_node, function()
        self:close_node()
    end, "close node / parent")
    map(km.close_all, function()
        self:set_all_folds(true)
    end, "close all nodes")
    map(km.open_all, function()
        self:set_all_folds(false)
    end, "open all nodes")
    map(km.scroll_down, function()
        self:scroll("down")
    end, "scroll down a quarter page")
    map(km.scroll_up, function()
        self:scroll("up")
    end, "scroll up a quarter page")
    if self.actions then
        map(km.stage, function()
            self:stage_op("stage")
        end, "stage file")
        map(km.unstage, function()
            self:stage_op("unstage")
        end, "unstage file")
        map(km.stage_all, function()
            self:stage_op("stage_all")
        end, "stage all")
        map(km.unstage_all, function()
            self:stage_op("unstage_all")
        end, "unstage all")
        map(km.discard, function()
            self:discard()
        end, "discard file")
        map(km.refresh, function()
            self:refresh()
        end, "refresh")
        map(km.edit_file, function()
            diff_file_verb(function()
                require("differ").edit_file()
            end)
        end, "edit the real file")
    end
    -- session-supplied maps the generic panel doesn't own (e.g. the pr viewed nav)
    for _, m in ipairs(self.extra_keymaps or {}) do
        map(m.spec, m.fn, m.desc)
    end
end

-- create the split in the configured position, bind the buffer, set window opts
function Panel:_open_window()
    if self.position == "top" then
        vim.cmd(("topleft %dsplit"):format(self.height))
    elseif self.position == "left" then
        vim.cmd(("topleft %dvsplit"):format(self.width))
    elseif self.position == "right" then
        vim.cmd(("botright %dvsplit"):format(self.width))
    else -- bottom (default)
        vim.cmd(("botright %dsplit"):format(self.height))
    end
    self.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winid, self.bufnr)
    self:_setup_window()
end

-- close the panel window but keep the buffer + state (for re-positioning)
function Panel:_close_window()
    if self:is_open() then
        pcall(vim.api.nvim_win_close, self.winid, true)
    end
    self.winid = nil
end

-- open the panel in its position and focus it
---@return differ.Panel
function Panel:open()
    self.origin_win = vim.api.nvim_get_current_win()
    self:_open_window()
    self:render()
    vim.api.nvim_win_set_cursor(self.winid, { self:_first_file_line(), 0 })
    self:_watch_external_changes()
    current = self
    return self
end

-- refresh when git state may have changed outside differ, without a manual R.
-- FocusGained: back from another app / tmux pane. ShellCmdPost: an in-nvim `:!git`.
-- TermClose / TermLeave: a terminal UI like lazygit run in a float, which never
-- drops nvim's own OS focus so FocusGained doesn't fire. the refresh is scheduled so
-- it runs once the terminal window has finished tearing down. only worktree-status
-- panels reload; rev-pair lists don't track the worktree. FocusGained needs
-- `focus-events on` under tmux
function Panel:_watch_external_changes()
    if not self.actions then
        return
    end
    self.augroup = vim.api.nvim_create_augroup("differ.panel." .. self.bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost", "TermClose", "TermLeave" }, {
        group = self.augroup,
        desc = "differ: refresh the panel when git state changed externally",
        callback = function()
            vim.schedule(function()
                if not self:is_open() then
                    return
                end
                -- on_external_change re-sources the diff too; refresh() is the list-only
                -- fallback for a panel without the hook
                if self.on_external_change then
                    self.on_external_change()
                else
                    self:refresh()
                end
            end)
        end,
    })
end

---@return boolean
function Panel:is_open()
    return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

-- restore the cursor line after a re-render/reposition (clamped to the content)
---@param lnum integer
function Panel:_restore_cursor(lnum)
    if self:is_open() then
        pcall(
            vim.api.nvim_win_set_cursor,
            self.winid,
            { math.min(lnum, math.max(#self.lines, 1)), 0 }
        )
    end
end

-- runtime API (per-view control, not setup config) ----------------

-- switch the listing mode live (tree / name)
---@param listing "tree"|"name"
function Panel:set_listing(listing)
    self.listing = listing
    if self:is_open() then
        local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
        self:render()
        self:_restore_cursor(lnum)
    end
end

-- toggle the listing mode: tree <-> name
function Panel:toggle_listing()
    self:set_listing(self.listing == "tree" and "name" or "tree")
end

-- move the panel to a new position live, preserving the buffer, fold state, and
-- the main (origin) window
---@param position "bottom"|"top"|"left"|"right"
function Panel:set_position(position)
    self.position = position
    if not self:is_open() then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
    local origin = self.origin_win
    self:_close_window()
    if origin and vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
    end
    self:_open_window()
    self.origin_win = origin
    self:render()
    self:_restore_cursor(lnum)
end

-- hide the sidebar window but keep the buffer, folds, selection, and the diff view
-- it drives alive (the session tab survives), so show() can bring it back
function Panel:hide()
    self:_close_window()
end

-- restore a hidden sidebar: reopen its window from the kept buffer + state, landing
-- the cursor on the selected file. focusing origin_win first also switches back to
-- the session tab; mirrors set_position's reopen so origin_win survives
function Panel:show()
    if self:is_open() or not vim.api.nvim_buf_is_valid(self.bufnr) then
        return self
    end
    local origin = self.origin_win
    if origin and vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
    end
    self:_open_window()
    self.origin_win = origin
    self:render()
    self:_restore_cursor(self.selected_row or self:_first_file_line())
    return self
end

-- hide / show the sidebar in place; the session (tab + diff view) survives either
-- way. :Differ close ends the session
function Panel:toggle()
    if self:is_open() then
        self:hide()
    else
        self:show()
    end
end

-- close the panel window and wipe its buffer. `on_close` (if set) tears down the
-- diff view the panel drives, so closing the panel ends the whole differ session
function Panel:close()
    self:_close_window()
    if self.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
        self.augroup = nil
    end
    if self.win_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, self.win_augroup)
        self.win_augroup = nil
    end
    if vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
    if current == self then
        current = nil
    end
    if self.on_close then
        self.on_close()
    end
end

-- the live panel, if one is open: the entry point for the runtime API
---@return differ.Panel|nil
function Panel.current()
    return current
end

return Panel
