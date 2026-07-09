-- highlight group definitions for diff lines, word-level spans, threads, and the
-- file panel. structural groups are plain links; the diff line + word backgrounds
-- and the panel's status + count groups carry a semantic palette (green add / yellow
-- modify / blue rename / orange conflict / red delete) derived from the active theme
-- with hex fallbacks, mirroring the user's diffview/octo colours. the line + word
-- backgrounds are a coherent two-tone pair from one colour per side (see
-- diff_bg_groups). all are set with `default = true` so explicit user overrides win,
-- and re-applied on `ColorScheme` so theme switches propagate

local M = {}

-- static links: body diff layers and structural panel chrome
---@diagnostic disable-next-line: undefined-doc-name
---@type table<string, vim.api.keyset.highlight>
local LINKS = {
    -- thread overlay: all thread groups (range background, panel-tinted chrome,
    -- meta, body) ride the palette + theme bg in thread_groups
    -- our own cursor-line overlay: CursorLine is low-priority when it has no
    -- foreground (`:h hl-CursorLine`), so it loses to the diff line backgrounds; we
    -- repaint it as a char-level extmark above them. links to CursorLine to track the theme
    differCursorLine = { link = "CursorLine" },
    -- split's row-padding: a meta/filler row opposite an inserted or deleted block.
    -- a dashed fill marks the side that has no line here, the native-vimdiff look, so
    -- the gap reads as "absent on this side" rather than an empty void. dim like NonText
    differFiller = { link = "NonText" },
    -- neutral fallback for a staged line with no add/delete kind; kinded staged lines
    -- use the dimmed deep-diff groups (differStagedLine{Add,Delete}/Word*) instead
    differStagedLine = { link = "CursorLine" },
    -- file panel chrome
    differPanelHeader = { link = "Title" },
    differPanelRoot = { link = "Directory" },
    differPanelHelp = { link = "Comment" },
    differPanelDir = { link = "Directory" },
    -- dimmed "·parent/" trailer after a basename in the name listing
    differPanelContext = { link = "Comment" },
    -- history panel commit rows: the author column (sha reuses differPanelDir,
    -- the date reuses differPanelHelp, the counts reuse the panel count groups) and
    -- the ref-decoration tag in branch-range mode
    differHistoryAuthor = { link = "Identifier" },
    differHistoryRef = { link = "Special" },
    -- overview page: the title rides the theme Title; the meta/body/verdict/author
    -- groups are palette-derived in overview_groups
    differOverviewTitle = { link = "Title" },
}

-- the first defined fg among `groups`, else `fallback` (a 0xRRGGBB int). lets the
-- palette ride the theme (e.g. green from `Added`/`GitSignsAdd`) yet still render
-- on bare themes that define none of them
---@param groups string[]
---@param fallback integer
---@return integer
local function fg_of(groups, fallback)
    for _, name in ipairs(groups) do
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        if ok and hl and hl.fg then
            return hl.fg
        end
    end
    return fallback
end

-- the first defined bg among `groups`, else `fallback` (a 0xRRGGBB int)
---@param groups string[]
---@param fallback integer
---@return integer
local function bg_of(groups, fallback)
    for _, name in ipairs(groups) do
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        if ok and hl and hl.bg then
            return hl.bg
        end
    end
    return fallback
end

-- mix `top` over `base` by `alpha` (0..1); both 0xRRGGBB ints, arithmetic only so
-- there's no bit-op dependency
---@param top integer
---@param base integer
---@param alpha number
---@return integer
local function blend(top, base, alpha)
    local function chan(shift)
        local t = math.floor(top / shift) % 256
        local b = math.floor(base / shift) % 256
        return math.floor(b + (t - b) * alpha + 0.5) % 256
    end
    return chan(65536) * 65536 + chan(256) * 256 + chan(1)
end

-- semantic status palette, resolved against the current theme. GitSigns groups
-- come first because that's where themes (and the user's diffview config) keep the
-- vivid git colours; `Added`/`Changed`/`Removed` are often duller or unset. order
-- and fallbacks mirror the user's diff-highlights.lua so the panel matches diffview
---@return table<string, integer>
local function palette()
    return {
        green = fg_of({ "GitSignsAdd", "Added", "diffAdded", "String" }, 0xa6e3a1),
        yellow = fg_of({ "GitSignsChange", "Changed", "diffChanged", "WarningMsg" }, 0xf9e2af),
        red = fg_of({ "GitSignsDelete", "Removed", "diffRemoved", "ErrorMsg" }, 0xf38ba8),
        blue = fg_of({ "Function", "Directory" }, 0x89b4fa),
        orange = fg_of({ "Number", "Constant" }, 0xfab387),
        grey = fg_of({ "Comment", "NonText" }, 0x6c7086),
    }
end

-- map the panel's status/count groups onto the palette (status letters,
-- "Status presentation", and the right-aligned +N -M counts)
---@param p table<string, integer>
---@diagnostic disable-next-line: undefined-doc-name
---@return table<string, vim.api.keyset.highlight>
local function status_groups(p)
    return {
        differPanelAdd = { fg = p.green },
        differPanelModify = { fg = p.yellow },
        differPanelDelete = { fg = p.red },
        differPanelRename = { fg = p.blue },
        differPanelUnmerged = { fg = p.orange },
        differPanelUntracked = { fg = p.green },
        differPanelCountAdd = { fg = p.green },
        differPanelCountDelete = { fg = p.red },
        -- the staged-hunk gutter glyph: green for "in the index"
        differStagedSign = { fg = p.green },
    }
end

-- thread overlay groups: every chunk sits on a faint panel tint so the comment
-- block reads as a non-code overlay (the jetbrains look), not more code. the chrome
-- (spine + header/footer rules + author) is state-coloured: open active (blue),
-- resolved receded (grey), pending draft (orange); meta is dim; body keeps the normal
-- fg. all share the one panel bg blended off Normal
---@param p table<string, integer>
---@diagnostic disable-next-line: undefined-doc-name
---@return table<string, vim.api.keyset.highlight>
local function thread_groups(p)
    local base = bg_of({ "Normal" }, 0x14161b)
    local panel = blend(p.blue, base, 0.12) -- subtle blue-tinted panel
    return {
        differThread = { fg = p.blue, bg = panel },
        differThreadResolved = { fg = p.grey, bg = panel },
        differThreadResolvedTag = { fg = p.green, bg = panel }, -- the footer "✓ resolved" tag
        differThreadPending = { fg = p.orange, bg = panel },
        differThreadMeta = { fg = p.grey, bg = panel },
        differThreadBody = { bg = panel }, -- fg unset -> Normal, readable on the tint
        -- the diff winbar's pending-review badge: a bold warning yellow so the draft
        -- state stands out (no bg; it rides the winbar, not the panel tint)
        differReviewDraft = { fg = p.yellow, bold = true },
        -- the lines a range comment covers: the same blue family as the panel, a touch
        -- stronger so it reads over the diff bg, but far gentler than the old Visual link
        differThreadRange = { bg = blend(p.blue, base, 0.2) },
    }
end

-- overview page groups: the meta chrome is dim, the body keeps Normal, and the
-- verdict + author groups ride the palette (approved green, requested-changes orange,
-- author blue) so a review verdict reads at a glance. the title links Title in LINKS
---@param p table<string, integer>
---@diagnostic disable-next-line: undefined-doc-name
---@return table<string, vim.api.keyset.highlight>
local function overview_groups(p)
    return {
        differOverviewMeta = { fg = p.grey },
        differOverviewBody = {}, -- fg unset -> Normal
        differOverviewApproved = { fg = p.green },
        differOverviewChanges = { fg = p.orange },
        differOverviewAuthor = { fg = p.blue },
    }
end

-- merge-tool region backgrounds: one quiet tint per side so each conflict slab
-- reads as that version (ours green, theirs blue, base muted) and the result's
-- unresolved block stands out in the conflict orange. same blend recipe as the diff
-- line backgrounds, bg-only so native syntax shows through. the UX-polish slice
-- adds: active vs inactive intensities (the block under the cursor at full strength, the
-- rest faint), the ▌ input-slab sign, a stronger input body tint, and the resolved flash
---@param p table<string, integer>
---@diagnostic disable-next-line: undefined-doc-name
---@return table<string, vim.api.keyset.highlight>
local function merge_groups(p)
    local base = bg_of({ "Normal" }, 0x14161b)
    local w, active, strong = 0.16, 0.28, 0.24
    return {
        differMergeOurs = { bg = blend(p.green, base, w) },
        differMergeTheirs = { bg = blend(p.blue, base, w) },
        differMergeBase = { bg = blend(p.grey, base, w) },
        differMergeConflict = { bg = blend(p.orange, base, w) },
        -- the conflict under the cursor: stronger per-side tint, colour at full strength
        differMergeOursActive = { bg = blend(p.green, base, active) },
        differMergeTheirsActive = { bg = blend(p.blue, base, active) },
        differMergeBaseActive = { bg = blend(p.grey, base, active) },
        differMergeMarker = { fg = p.grey },
        -- the ▌ input-slab gutter sign, fg per side
        differMergeSignOurs = { fg = p.green },
        differMergeSignBase = { fg = p.grey },
        differMergeSignTheirs = { fg = p.blue },
        -- stronger input-pane slab body so the conflicting lines pop out of the full file
        differMergeOursStrong = { bg = blend(p.green, base, strong) },
        differMergeBaseStrong = { bg = blend(p.grey, base, strong) },
        differMergeTheirsStrong = { bg = blend(p.blue, base, strong) },
        -- transient flash on the lines a take-this produced
        differMergeFlash = { bg = blend(p.yellow, base, 0.30) },
    }
end

-- coherent two-tone diff backgrounds: a quiet line tint and a richer same-hue word
-- patch, both blended from one vivid colour per side (the add/delete fg) over the
-- editor bg. deriving line and patch from the same source keeps the hue identical
-- and steps only saturation/lightness, so the changed words read as a deeper block
-- of the line they sit on (the claude-style look) instead of a clashing overlay.
-- the vivid fg is a mid-tone, so the same alpha lightens on dark themes and darkens
-- on light ones, no per-theme branching. word spans are bg-only (no fg/bold) so the
-- syntax foreground shows through. these replace the old DiffAdd/DiffDelete links
---@param p table<string, integer>
---@diagnostic disable-next-line: undefined-doc-name
---@return table<string, vim.api.keyset.highlight>
local function diff_bg_groups(p)
    local base = bg_of({ "Normal" }, 0x14161b)
    local line, cursor, word = 0.22, 0.36, 0.52 -- blend weights toward the vivid colour; tune to taste
    -- staged hunks keep the same-hue deep diff but quieter, so they read as set-aside
    -- yet still show what changed; well under the live weights so staged reads distinctly
    -- dimmer; line/word stay paired so the word patch still pops
    local staged_line, staged_word = 0.12, 0.34
    return {
        differLineAdd = { bg = blend(p.green, base, line) },
        differLineDelete = { bg = blend(p.red, base, line) },
        -- the cursor line over an add/delete line: the same hue, well clear of the line
        -- tint so it reads as the current line over text (not just past EOL) yet still as
        -- added/removed; word spans stay a notch above so they show through
        differCursorLineAdd = { bg = blend(p.green, base, cursor) },
        differCursorLineDelete = { bg = blend(p.red, base, cursor) },
        differWordAdd = { bg = blend(p.green, base, word) },
        differWordDelete = { bg = blend(p.red, base, word) },
        -- dimmed deep diff for staged hunks (same hue, quieter than the live tints)
        differStagedLineAdd = { bg = blend(p.green, base, staged_line) },
        differStagedLineDelete = { bg = blend(p.red, base, staged_line) },
        differStagedWordAdd = { bg = blend(p.green, base, staged_word) },
        differStagedWordDelete = { bg = blend(p.red, base, staged_word) },
    }
end

-- (re)define all default highlight groups. `default = true` keeps user overrides
-- authoritative; the ColorScheme autocmd (registered once by setup) re-resolves the
-- palette so it tracks theme changes
local function apply()
    local p = palette()
    local groups = vim.tbl_extend(
        "error",
        {},
        LINKS,
        status_groups(p),
        diff_bg_groups(p),
        merge_groups(p),
        thread_groups(p),
        overview_groups(p)
    )
    for name, val in pairs(groups) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", { default = true }, val))
    end
end

local registered = false

function M.setup()
    apply()
    if not registered then
        registered = true
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = vim.api.nvim_create_augroup("differ.highlights", { clear = true }),
            callback = apply,
        })
    end
end

return M
