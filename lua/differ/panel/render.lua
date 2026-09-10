-- panel rendering (pure): flatten section "blocks" of tree rows into buffer lines
-- plus per-line metadata. byte-column offsets for the status letter and names are
-- computed here so the runtime highlighter (panel/init.lua) and navigation read
-- authoritative positions rather than re-deriving them. no nvim API

local text = require("differ.util.text")

local M = {}

local INDENT = " "
local FOLD_OPEN, FOLD_CLOSED = "▾", "▸"

---@class differ.panel.LineMeta
---@field kind "root"|"help"|"blank"|"header"|"dir"|"file"|"foothead"|"footrev"
---@field entry differ.FileEntry|nil
---@field path string|nil
---@field dir_path string|nil      -- dir rows: full repo-relative dir path (prefix re-attached)
---@field section integer|nil      -- dir rows: 1-based block/section index, for dir-level staging
---@field status string|nil
---@field collapsed boolean|nil
---@field title string|nil        -- header rows: the section title
---@field depth integer|nil       -- tree depth (dir + file rows), for parent lookup
---@field file_index integer|nil  -- 1-based position among all files (fold-independent); stamped by the panel
---@field status_col integer|nil  -- byte col of the status letter (file rows)
---@field name_col integer|nil    -- byte col where the name starts
---@field icon_col integer|nil    -- byte range of the devicon glyph (when shown)
---@field icon_end integer|nil
---@field icon_hl string|nil      -- devicon highlight group
---@field context_col integer|nil -- byte range of the dimmed "·parent/" trailer (name listing)
---@field context_end integer|nil
---@field viewed_col integer|nil  -- byte range of the PR viewed-checkbox glyph (PR sections only)
---@field viewed_end integer|nil
---@field prefix_col integer|nil  -- header rows: byte col where the dimmed common-prefix subtitle begins
---@field prefix_end integer|nil

---@class differ.panel.Block
---@field title string|nil               -- section header, nil = no header row
---@field prefix string|nil              -- common dir stripped in tree mode, shown as a subtitle
---@field count integer|nil              -- file count for the header; defaults to the visible file rows
---@field rows differ.panel.Row[]

---@param rows differ.panel.Row[]
---@return integer
local function count_files(rows)
    local n = 0
    for _, r in ipairs(rows) do
        if r.kind == "file" then
            n = n + 1
        end
    end
    return n
end

---@class differ.panel.Header
---@field path string|nil   -- repo/worktree path shown on the top line
---@field help string|nil   -- keymap hint (rendered as "Help: <help>")

-- build the panel buffer lines and a parallel metadata list (one per line). an
-- optional header (repo path + `Help: g?` + blank) prefixes the sections,
-- and an optional `footer` rev appends a "Showing changes for:" block.
-- `icon_for(path)` (supplied by the runtime layer, nvim-web-devicons, so this
-- stays pure) returns a `(glyph, hl_group)` pair painted before each filename.
-- the +/- counts aren't in the line text: the runtime layer pins them to the
-- right of the content column as a virtual-text extmark, so `width` (when given)
-- only reserves room for them and truncates the filename to fit the rest
---@param blocks differ.panel.Block[]
---@param header differ.panel.Header|nil
---@param icon_for nil|fun(path: string): string|nil, string|nil
---@param footer string|nil  -- rev spec shown under "Showing changes for:"
---@param width integer|nil  -- panel window width; nil skips truncation (headless)
---@return { lines: string[], meta: differ.panel.LineMeta[] }
function M.lines(blocks, header, icon_for, footer, width)
    local lines, meta = {}, {}
    if header then
        if header.path then
            lines[#lines + 1] = header.path
            meta[#meta + 1] = { kind = "root" }
        end
        if header.help then
            lines[#lines + 1] = "Help: " .. header.help
            meta[#meta + 1] = { kind = "help" }
        end
        lines[#lines + 1] = ""
        meta[#meta + 1] = { kind = "blank" }
    end
    for bi, block in ipairs(blocks) do
        if block.title or block.prefix then
            -- count is the section's true file total (fold-independent); fall back
            -- to the visible file rows when the caller doesn't supply it (tests)
            local n = block.count or count_files(block.rows)
            local head = block.title and ("%s (%d)"):format(block.title, n) or ""
            local m = { kind = "header", section = bi, title = block.title }
            if block.prefix then
                local sep = head ~= "" and " · " or ""
                m.prefix_col = #head -- byte col where the dimmed " · prefix" begins
                head = head .. sep .. block.prefix
                m.prefix_end = #head
            end
            lines[#lines + 1] = head
            meta[#meta + 1] = m
        end
        for _, row in ipairs(block.rows) do
            local indent = INDENT:rep(row.depth)
            if row.kind == "dir" then
                local prefix = indent .. (row.collapsed and FOLD_CLOSED or FOLD_OPEN) .. " "
                lines[#lines + 1] = prefix .. row.name .. "/"
                meta[#meta + 1] = {
                    kind = "dir",
                    path = row.path,
                    -- full repo-relative dir path: the tree strips a deep common
                    -- prefix from `row.path` for display, so re-attach it (block.prefix)
                    -- to match against entry paths for dir-level staging
                    dir_path = (block.prefix or "") .. row.path,
                    section = bi,
                    collapsed = row.collapsed,
                    depth = row.depth,
                    name_col = #prefix,
                }
            else
                local e = row.entry
                -- viewed-checkbox column, PR sections only: gated on the
                -- entry carrying a `viewed` boolean, so local entries (viewed == nil)
                -- leave the column off and the local panel is untouched
                local checkbox = ""
                if e.viewed ~= nil then
                    checkbox = (e.viewed and "[x]" or "[ ]") .. " "
                end
                local prefix = indent .. checkbox .. e.status .. " "
                local m = {
                    kind = "file",
                    entry = e,
                    path = row.path,
                    status = e.status,
                    depth = row.depth,
                    status_col = #indent + #checkbox,
                }
                if checkbox ~= "" then
                    m.viewed_col = #indent
                    m.viewed_end = #indent + #checkbox - 1 -- the glyph, less the trailing space
                end
                if icon_for then
                    local glyph, hl = icon_for(e.path)
                    if glyph and glyph ~= "" then
                        m.icon_col = #prefix
                        m.icon_end = #prefix + #glyph
                        m.icon_hl = hl
                        prefix = prefix .. glyph .. " "
                    end
                end
                m.name_col = #prefix
                -- reserve room at the content column for the pinned +/- counts so
                -- text doesn't slide under them; the counts are a virt_text extmark
                -- (pinned by win_col), painted by the runtime layer, not line text
                local reserve = 0
                if e.additions and (e.additions > 0 or e.deletions > 0) then
                    reserve = #("+" .. e.additions) + #("-" .. e.deletions) + 2
                end
                local name, trailer = row.name, ""
                if row.context then
                    -- name listing: "name  ·parent/" with the counts pinned right.
                    -- keep BOTH visible when the column is tight by truncating the
                    -- name first (the primary token), then the parent only if a
                    -- floored name still won't fit (else a long parent clips off the
                    -- right edge and silently vanishes)
                    local ctx = "·" .. row.context
                    if width then
                        local name_min = 6
                        local budget = width - #prefix - reserve - 2 -- name + ctx, less the gap
                        if #name + #ctx > budget then
                            local ctx_max = math.max(budget - name_min, 3)
                            if #ctx > ctx_max then
                                ctx = text.truncate_end(ctx, ctx_max)
                            end
                            name = text.truncate_end(name, math.max(budget - #ctx, 1))
                        end
                    end
                    trailer = "  " .. ctx
                elseif width then
                    local avail = width - #prefix - reserve
                    if avail >= 1 then
                        name = text.truncate_end(name, avail)
                    end
                end
                local line = prefix .. name
                if trailer ~= "" then
                    m.context_col = #line + 2 -- byte col of the "·"
                    m.context_end = #line + #trailer
                end
                line = line .. trailer
                lines[#lines + 1] = line
                meta[#meta + 1] = m
            end
        end
    end
    if footer then
        lines[#lines + 1] = ""
        meta[#meta + 1] = { kind = "blank" }
        lines[#lines + 1] = "Showing changes for:"
        meta[#meta + 1] = { kind = "foothead" }
        lines[#lines + 1] = footer
        meta[#meta + 1] = { kind = "footrev" }
    end
    return { lines = lines, meta = meta }
end

return M
