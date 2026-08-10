-- syntax highlight pass: treesitter highlights for the diffed code,
-- gitHub/JetBrains-style, but never by parsing the derived buffer (that jumble of
-- interleaved old/new, meta separators and filler would mis-parse). instead parse
-- the *real* old_text/new_text, collect captures in source coords, and project
-- them onto the buffer through the line map's from_old/from_new (derived
-- behaviour). extmark-only, in its own namespace, so it refreshes independently of
-- the diff layer and never touches buffer text or the map (invariant 2)

local project = require("differ.syntax.project")

local M = {}

local ns = vim.api.nvim_create_namespace("differ.syntax")

-- layering: syntax foreground sits *under* the diff line background (paint
-- uses 100) and word-level spans (200), so the diff state always reads on top.
-- an injected layer sits one above its host, capped short of the diff layer, so
-- embedded code wins where the host also captures the region it was lifted from
local PRIORITY = 90
local MAX_DEPTH_BUMP = 9

-- ceiling for parsing injections. the primary tree is still parsed above it, so a
-- generated file keeps its tag/keyword level highlighting without paying for
-- injection discovery over the whole tree
local INJECTION_MAX_BYTES = 512 * 1024

-- resolve a treesitter language for `path`, or nil when there's no filetype, no
-- mapped language, or the parser isn't installed, in which case the pass is
-- skipped and the view stays plain (diff highlights still apply)
---@param path string
---@return string|nil
local function resolve_lang(path)
    if not path or path == "" then
        return nil
    end
    local ft = vim.filetype.match({ filename = path })
    if not ft then
        return nil
    end
    local lang = vim.treesitter.language.get_lang(ft)
    if not lang then
        return nil
    end
    if not pcall(vim.treesitter.language.add, lang) then
        return nil
    end
    return lang
end

-- treesitter handles are typed `any`: there's no nvim type library on the
-- typecheck path, so naming TSTree/TSNode/Query would only be an undefined alias
---@class differ.SyntaxLayer
---@field tree any         -- TSTree
---@field lang string
---@field query any        -- vim.treesitter.Query
---@field priority integer

-- flatten a language tree into paint layers, host before its injections so
-- embedded code is applied over the region the host lifted it from. one injected
-- language holds one layer per region, not one per language, so a file with three
-- `<script>` blocks yields three trees under a single child
---@param parser any
---@return differ.SyntaxLayer[]
local function layers(parser)
    local out = {}
    local function walk(ltree, depth)
        local lang = ltree:lang()
        local query = vim.treesitter.query.get(lang, "highlights")
        if query then
            for _, tree in pairs(ltree:trees()) do
                out[#out + 1] = {
                    tree = tree,
                    lang = lang,
                    query = query,
                    priority = PRIORITY + math.min(depth, MAX_DEPTH_BUMP),
                }
            end
        end
        for _, child in pairs(ltree:children()) do
            walk(child, depth + 1)
        end
    end
    walk(parser, 0)
    return out
end

-- one capture becomes one entry per line it covers: head to EOL, full middle
-- lines, tail to ecol (an empty tail is skipped)
---@param out differ.SyntaxCapture[]
---@param node any
---@param hl string
---@param lines string[]
---@param priority integer
local function push_capture(out, node, hl, lines, priority)
    local srow, scol, erow, ecol = node:range()
    local function push(row, col_start, col_end)
        out[#out + 1] = {
            row = row,
            col_start = col_start,
            col_end = col_end,
            hl = hl,
            priority = priority,
        }
    end
    if srow == erow then
        push(srow, scol, ecol)
        return
    end
    push(srow, scol, #(lines[srow + 1] or ""))
    for r = srow + 1, erow - 1 do
        push(r, 0, #(lines[r + 1] or ""))
    end
    if ecol > 0 then
        push(erow, 0, ecol)
    end
end

-- captures named `_…` are internal to the query; spell/nospell carry spell
-- metadata rather than a highlight group, which is what the core highlighter
-- reads them as
---@param name string
---@return boolean
local function is_paintable(name)
    return not vim.startswith(name, "_") and name ~= "spell" and name ~= "nospell"
end

-- parse `text` and collect highlight captures in source coordinates, injected
-- languages included. mirrors the core highlighter: the hl group is
-- `@<capture>.<lang>` of the tree the capture came from, so embedded typescript
-- in an astro file reads as typescript. injected ranges come back in the outer
-- string's coordinates, so no translation is needed here or in project
---@param text string
---@param lang string
---@return differ.SyntaxCapture[]
local function captures_for(text, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not parser then
        return {}
    end
    if not pcall(parser.parse, parser, #text <= INJECTION_MAX_BYTES) then
        return {}
    end

    local lines = vim.split(text, "\n", { plain = true })
    local out = {}
    for _, layer in ipairs(layers(parser)) do
        for id, node in layer.query:iter_captures(layer.tree:root(), text, 0, -1) do
            local name = layer.query.captures[id]
            if is_paintable(name) then
                push_capture(out, node, "@" .. name .. "." .. layer.lang, lines, layer.priority)
            end
        end
    end
    return out
end

-- a model's old_text/new_text are fixed once built, so a rerender (a layout or
-- context toggle) reprojects rather than reparsing both sides. weak keys: an
-- entry falls away with the model it was parsed from
---@type table<differ.DiffModel, table<string, differ.SyntaxCapture[]>>
local cache = setmetatable({}, { __mode = "k" })

---@param model differ.DiffModel
---@param lang string
---@param side "old"|"new"
---@return differ.SyntaxCapture[]
local function side_captures(model, lang, side)
    local entry = cache[model]
    if not entry then
        entry = {}
        cache[model] = entry
    end
    if not entry[side] then
        entry[side] = captures_for(side == "old" and model.old_text or model.new_text, lang)
    end
    return entry[side]
end

-- apply the syntax pass to one column's buffer: parse the real source(s) the
-- column draws from (old, new, or both for a unified/stacked column), project the
-- captures through the map, and paint them as extmarks. no-op when the language
-- has no parser. idempotent, clears its namespace first, so it doubles as a
-- refresh after a re-render
---@param bufnr integer
---@param column differ.Column
---@param model differ.DiffModel
function M.apply(bufnr, column, model)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local lang = resolve_lang(model.path)
    if not lang then
        return
    end

    local marks = {}
    if column.side == "old" or column.side == "unified" then
        vim.list_extend(
            marks,
            project.project(side_captures(model, lang, "old"), column.map.from_old)
        )
    end
    if column.side == "new" or column.side == "unified" then
        vim.list_extend(
            marks,
            project.project(side_captures(model, lang, "new"), column.map.from_new)
        )
    end

    for _, m in ipairs(marks) do
        -- end_col is byte-identical to the source line (same content), but guard
        -- against any treesitter range quirk rather than abort the whole pass
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, m.row, m.col_start, {
            end_col = m.col_end,
            hl_group = m.hl,
            priority = m.priority,
        })
    end
end

-- apply the syntax pass to detached code snippets (the overview's diff hunks): parse
-- each snippet's marker-stripped source as one text and paint the captures onto its
-- recorded buffer rows, shifted right by col_offset (the spine + marker prefix). same
-- derived-buffer rule as apply: never parse the page itself. clears the namespace once,
-- so one call per repaint covers every snippet; a path with no parser is skipped and
-- its hunk stays plain. a snippet is a fragment, so an injection whose opening
-- delimiter was cut away simply doesn't fire and that line stays plain
---@param bufnr integer
---@param snippets { path: string, col_offset: integer, lines: { row: integer, text: string }[] }[]|nil
function M.apply_snippets(bufnr, snippets)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, s in ipairs(snippets or {}) do
        local lang = #s.lines > 0 and resolve_lang(s.path) or nil
        if lang then
            local texts = {}
            for i, l in ipairs(s.lines) do
                texts[i] = l.text
            end
            for _, c in ipairs(captures_for(table.concat(texts, "\n"), lang)) do
                local target = s.lines[c.row + 1]
                if target then
                    pcall(
                        vim.api.nvim_buf_set_extmark,
                        bufnr,
                        ns,
                        target.row,
                        c.col_start + s.col_offset,
                        {
                            end_col = c.col_end + s.col_offset,
                            hl_group = c.hl,
                            priority = c.priority,
                        }
                    )
                end
            end
        end
    end
end

return M
