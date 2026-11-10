-- the fuzz reports' shared layout: headed sections, aligned grids of counts, a legend,
-- and example files with the rows in question bracketed

local text_util = require("differ.util.text")

local M = {}

local tty = vim.uv.guess_handle(1) == "tty"

---@param s string
---@param code string  -- an SGR colour
---@return string
local function painted(s, code)
    if not tty then
        return s
    end
    return ("\27[%sm%s\27[0m"):format(code, s)
end

---@param ok boolean
---@return string
function M.mark(ok)
    if ok then
        return painted("✓", "32")
    end
    return painted("✗", "31")
end

---@param n integer
---@param of integer
---@return string
function M.share(n, of)
    return ("%.1f%%"):format(100 * n / math.max(of, 1))
end

-- a title, then what it measures on the line under it
---@param out string[]
---@param title string
---@param about? string
function M.heading(out, title, about)
    if #out > 0 then
        out[#out + 1] = ""
    end
    out[#out + 1] = title
    if about then
        out[#out + 1] = "  " .. about
    end
end

---@class differ.fuzz.GridRow
---@field [1] string                   -- label
---@field [2] (integer|string)[]|nil   -- a value per column; nil for a label alone
---@field indent? integer              -- levels under the row it breaks down
---@field zero? boolean                -- every value must be 0
---@field note? string

-- rows of values under `cols`, labels and values aligned. no header row for one column
---@param out string[]
---@param cols string[]
---@param rows differ.fuzz.GridRow[]
function M.grid(out, cols, rows)
    local label_w, widths = 0, {}
    for i, col in ipairs(cols) do
        widths[i] = #cols > 1 and vim.fn.strdisplaywidth(col) or 0
    end
    for _, row in ipairs(rows) do
        label_w = math.max(label_w, 2 * (row.indent or 0) + #row[1])
        for i, v in ipairs(row[2] or {}) do
            widths[i] = math.max(widths[i] or 0, #tostring(v))
        end
    end
    ---@param label string
    ---@param values (integer|string)[]
    ---@return string
    local function line(label, values)
        local s = "  " .. label .. (" "):rep(label_w - #label)
        for i, v in ipairs(values) do
            s = s .. "  " .. (" "):rep(widths[i] - vim.fn.strdisplaywidth(tostring(v))) .. v
        end
        return s
    end
    if #cols > 1 then
        out[#out + 1] = line("", cols)
    end
    for _, row in ipairs(rows) do
        local s = line((" "):rep(2 * (row.indent or 0)) .. row[1], row[2] or {})
        if row.zero then
            local ok = true
            for _, v in ipairs(row[2] or {}) do
                ok = ok and v == 0
            end
            s = s .. "  " .. M.mark(ok) .. " must be 0"
        end
        if row.note then
            s = s .. "  " .. row.note
        end
        out[#out + 1] = (s:gsub("%s+$", ""))
    end
end

-- each term and what it means, aligned
---@param out string[]
---@param terms string[][]  -- { term, meaning }
function M.legend(out, terms)
    local width = 0
    for _, t in ipairs(terms) do
        width = math.max(width, #t[1])
    end
    for _, t in ipairs(terms) do
        out[#out + 1] = ("  %-" .. width .. "s  %s"):format(t[1], t[2])
    end
end

-- a text's lines on one line, `$` on a last line with no newline, and each line in
-- `marked` in brackets
---@param text string
---@param marked? table<integer, true>
---@return string
function M.text(text, marked)
    local lines = text_util.ended_lines(text)
    for i, line in ipairs(lines) do
        if line:sub(-1) == text_util.NO_EOL then
            line = line:sub(1, -2) .. "$"
        end
        if marked and marked[i] then
            line = "[" .. line .. "]"
        end
        lines[i] = line
    end
    return table.concat(lines, " ")
end

-- rows as "HEAD 3-5, worktree 4", runs of one side's lines as ranges
---@param rows differ.fuzz.Row[]
---@return string
function M.rows(rows)
    local runs = {} ---@type { side: string, first: integer, last: integer }[]
    for _, r in ipairs(rows) do
        local run = runs[#runs]
        if run and run.side == r.side and run.last + 1 == r.line then
            run.last = r.line
        else
            runs[#runs + 1] = { side = r.side, first = r.line, last = r.line }
        end
    end
    local named = {}
    for _, run in ipairs(runs) do
        local name = run.side == "old" and "HEAD " or "worktree "
        if run.first == run.last then
            named[#named + 1] = name .. run.first
        else
            named[#named + 1] = ("%s%d-%d"):format(name, run.first, run.last)
        end
    end
    return table.concat(named, ", ")
end

-- an example file: a title, then labelled lines, the HEAD and worktree lines in `rows`
-- bracketed (the union's old side is HEAD, its new side the worktree)
---@param out string[]
---@param title string
---@param t differ.fuzz.Triple
---@param rows differ.fuzz.Row[]
---@param more? string[][]  -- { label, line } after the three texts
function M.case(out, title, t, rows, more)
    local marked = { old = {}, new = {} }
    for _, r in ipairs(rows) do
        marked[r.side][r.line] = true
    end
    out[#out + 1] = ""
    out[#out + 1] = "  " .. title
    local lines = {
        { "HEAD", M.text(t.head, marked.old) },
        { "index", M.text(t.index) },
        { "worktree", M.text(t.work, marked.new) },
    }
    vim.list_extend(lines, more or {})
    for _, l in ipairs(lines) do
        out[#out + 1] = ("    %-9s %s"):format(l[1], l[2])
    end
end

return M
