-- a seeded fuzz of s, u and X on contiguous stacked-row selections, over random
-- HEAD / index / worktree triples, through the selection core the ops write from
-- (git/staging/selection.lua). a written op is checked against the index and
-- file the drawn marks say it should leave: the moved lines' texts, every other line
-- still in its order, and each line at its row. needs vim.text.diff, so it runs under nvim

local content = require("differ.git.content")
local stage = require("differ.model.stage")
local text_util = require("differ.util.text")
local selected = require("differ.git.staging.selection")

local M = {}

local ALPHABET = { "a", "b", "c", "d", "e" }

---@param n integer
---@return string
local function token(n)
    if math.random() < 0.15 then
        return "x" .. math.random(n)
    end
    return ALPHABET[math.random(#ALPHABET)]
end

-- `lines` with each line kept, dropped, replaced or followed by a new one
---@param lines string[]
---@param rate number
---@return string[]
local function mutate(lines, rate)
    local out = {}
    for _, line in ipairs(lines) do
        local r = math.random()
        if r < rate / 3 then
            out[#out + 1] = token(#lines)
        elseif r < rate * 2 / 3 then
            out[#out + 1] = line
            out[#out + 1] = token(#lines)
        elseif r >= rate then
            out[#out + 1] = line
        end
    end
    return out
end

---@param lines string[]
---@return string
local function text_of(lines)
    if #lines == 0 then
        return ""
    end
    local text = table.concat(lines, "\n")
    if math.random() < 0.8 then
        text = text .. "\n"
    end
    return text
end

---@class differ.fuzz.Triple
---@field head string
---@field index string
---@field work string

---@param size integer   -- HEAD's lines
---@param staged number  -- the share of HEAD's lines the index edits
---@param edited number  -- the share of the index's lines the worktree edits
---@return differ.fuzz.Triple
function M.triple(size, staged, edited)
    local head = {}
    for i = 1, size do
        head[i] = token(size)
    end
    local index = mutate(head, staged)
    local work = mutate(index, edited)
    return { head = text_of(head), index = text_of(index), work = text_of(work) }
end

---@class differ.fuzz.Row
---@field side "old"|"new"
---@field line integer

-- the union's changed lines in stacked order: each hunk's old lines, then its new
---@param union differ.DiffModel
---@return differ.fuzz.Row[]
function M.rows(union)
    local rows = {}
    for _, h in ipairs(union.hunks) do
        for l = h.old_start, h.old_start + h.old_count - 1 do
            rows[#rows + 1] = { side = "old", line = l }
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            rows[#rows + 1] = { side = "new", line = l }
        end
    end
    return rows
end

---@param rows differ.fuzz.Row[]
---@param first integer
---@param last integer
---@return differ.model.Selection
local function selection_of(rows, first, last)
    local selection = { old = {}, new = {} }
    for i = first, last do
        selection[rows[i].side][rows[i].line] = true
    end
    return selection
end

---@param a string[]
---@param b string[]
---@return integer
local function lcs(a, b)
    local prev = {}
    for j = 0, #b do
        prev[j] = 0
    end
    for i = 1, #a do
        local cur = { [0] = 0 }
        for j = 1, #b do
            if a[i] == b[j] then
                cur[j] = prev[j - 1] + 1
            else
                cur[j] = math.max(prev[j], cur[j - 1])
            end
        end
        prev = cur
    end
    return prev[#b]
end

-- whether `to` is `from` with the `leave` texts taken out and the `enter` texts put in,
-- every other line in the order `from` has it
---@param from string
---@param to string
---@param leave string[]
---@param enter string[]
---@return boolean
function M.moved(from, to, leave, enter)
    local a, b = text_util.ended_lines(from), text_util.ended_lines(to)
    local count = {} ---@type table<string, integer>
    local function add(lines, sign)
        for _, line in ipairs(lines) do
            count[line] = (count[line] or 0) + sign
        end
    end
    add(a, 1)
    add(leave, -1)
    add(enter, 1)
    add(b, -1)
    for _, n in pairs(count) do
        if n ~= 0 then
            return false
        end
    end
    return lcs(a, b) >= #a - #leave
end

---@class differ.fuzz.Moves
---@field index_leave string[]
---@field index_enter string[]
---@field work_leave string[]
---@field work_enter string[]

-- the texts the op moves in or out of the index and the file, from the drawn marks.
-- `take` nil is X
---@param union differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean|nil
---@return differ.fuzz.Moves
local function moves(union, m, selection, take)
    local old_lines = text_util.ended_lines(union.old_text)
    local new_lines = text_util.ended_lines(union.new_text)
    local out = { index_leave = {}, index_enter = {}, work_leave = {}, work_enter = {} }
    local function push(list, line)
        list[#list + 1] = line
    end
    for l in pairs(selection.old) do
        local staged = m.old[l] == true
        if take == nil then
            push(out.work_enter, old_lines[l])
            if staged then
                push(out.index_enter, old_lines[l])
            end
        elseif staged ~= take and take then
            push(out.index_leave, old_lines[l])
        elseif staged ~= take then
            push(out.index_enter, old_lines[l])
        end
    end
    for l in pairs(selection.new) do
        local staged = m.new[l] == true
        if take == nil then
            push(out.work_leave, new_lines[l])
            if staged then
                push(out.index_leave, new_lines[l])
            end
        elseif staged ~= take and take then
            push(out.index_enter, new_lines[l])
        elseif staged ~= take then
            push(out.index_leave, new_lines[l])
        end
    end
    return out
end

---@param h differ.Hunk
---@param selection differ.model.Selection
---@return boolean
local function touches(h, selection)
    for l = h.old_start, h.old_start + h.old_count - 1 do
        if selection.old[l] then
            return true
        end
    end
    for l = h.new_start, h.new_start + h.new_count - 1 do
        if selection.new[l] then
            return true
        end
    end
    return false
end

-- the result check's refusal, by whether a touched hunk has sides of unequal length
-- and a staged line, the shape select_block puts in "old then new" order
---@param union differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@return string
local function moves_others(union, m, selection)
    for _, h in ipairs(union.hunks) do
        if h.old_count ~= h.new_count and touches(h, selection) then
            for l = h.old_start, h.old_start + h.old_count - 1 do
                if m.old[l] then
                    return "moves_others:unequal"
                end
            end
            for l = h.new_start, h.new_start + h.new_count - 1 do
                if m.new[l] then
                    return "moves_others:unequal"
                end
            end
        end
    end
    return "moves_others:other"
end

-- whether `lines` from `at` on interleave `a` and `b`, each in its order
---@param lines string[]
---@param at integer
---@param a string[]
---@param b string[]
---@return boolean
local function interleaves(lines, at, a, b)
    local ok = {} ---@type boolean[][]
    for i = 0, #a do
        ok[i] = {}
        for j = 0, #b do
            local line = lines[at + i + j - 1]
            if i == 0 and j == 0 then
                ok[i][j] = true
            else
                ok[i][j] = (i > 0 and ok[i - 1][j] and a[i] == line)
                    or (j > 0 and ok[i][j - 1] and b[j] == line)
                    or false
            end
        end
    end
    return ok[#a][#b]
end

---@class differ.fuzz.Keep
---@field old fun(l: integer): boolean  -- the text holds union old line `l`
---@field new fun(l: integer): boolean

-- whether `text` reads as the union's rows: every unchanged line where it is, and at
-- each hunk the old and new lines `keep` holds, each side in its order
---@param union differ.DiffModel
---@param text string
---@param keep differ.fuzz.Keep
---@return boolean
function M.placed(union, text, keep)
    local old, new = text_util.ended_lines(union.old_text), text_util.ended_lines(union.new_text)
    local lines = text_util.ended_lines(text)
    local at, next_old = 1, 1
    ---@param to integer  -- the old line after the unchanged run
    ---@return boolean
    local function unchanged(to)
        for l = next_old, to - 1 do
            if lines[at] ~= old[l] then
                return false
            end
            at = at + 1
        end
        return true
    end
    for _, h in ipairs(union.hunks) do
        local first = h.old_start
        if h.old_count == 0 then
            first = first + 1
        end
        if not unchanged(first) then
            return false
        end
        local a, b = {}, {}
        for l = h.old_start, h.old_start + h.old_count - 1 do
            if keep.old(l) then
                a[#a + 1] = old[l]
            end
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            if keep.new(l) then
                b[#b + 1] = new[l]
            end
        end
        if not interleaves(lines, at, a, b) then
            return false
        end
        at, next_old = at + #a + #b, first + h.old_count
    end
    return unchanged(#old + 1) and at == #lines + 1
end

-- what the index holds once the selected lines are staged (`take`) or not, every other
-- line as `m` has it. `take` nil is the index as it is
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean|nil
---@return differ.fuzz.Keep
local function index_keep(m, selection, take)
    ---@param side "old"|"new"
    ---@param l integer
    ---@return boolean
    local function staged(side, l)
        if take ~= nil and selection[side][l] then
            return take
        end
        return m[side][l] == true
    end
    return {
        old = function(l)
            return not staged("old", l)
        end,
        new = function(l)
            return staged("new", l)
        end,
    }
end

-- whether the written index reads as the union's rows with the op's staged state, and
-- for X the file as them with the selection reverted. nil where the index before the op
-- doesn't read as the rows (content no hunk shows), so placement can't be judged
---@param t differ.fuzz.Triple
---@param union differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean
---@param index string
---@param work string|nil  -- X's file text
---@return boolean|nil
local function placed_op(t, union, m, selection, take, index, work)
    if not M.placed(union, t.index, index_keep(m, selection, nil)) then
        return nil
    end
    if not M.placed(union, index, index_keep(m, selection, take)) then
        return false
    end
    if work == nil then
        return true
    end
    return M.placed(union, work, {
        old = function(l)
            return selection.old[l] == true
        end,
        new = function(l)
            return not selection.new[l]
        end,
    })
end

---@class differ.fuzz.Outcome
---@field kind "unchanged"|"refused"|"written"
---@field reason? string  -- refused: why
---@field index? string   -- written: the index text
---@field work? string    -- written by X: the file text
---@field moves? differ.fuzz.Moves
---@field placed? boolean|nil  -- written: placed_op

-- the op's refusal, with the result check's split by moves_others
---@param union differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param refused differ.git.SelectionRefusal
---@return differ.fuzz.Outcome
local function refusal(union, m, selection, refused)
    if refused == "moves_others" then
        return { kind = "refused", reason = moves_others(union, m, selection) }
    end
    return { kind = "refused", reason = refused }
end

-- s (`take` true) or u, through the selection core apply_lines writes from
---@param t differ.fuzz.Triple
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@param selection differ.model.Selection
---@param take boolean
---@return differ.fuzz.Outcome
local function stage_op(t, union, cached, unstaged, selection, take)
    local m = stage.marks_of(union, cached, unstaged)
    local text, _, refused = selected.stage("/", "f", union, cached, unstaged, selection, take)
    if refused then
        return refusal(union, m, selection, refused)
    end
    if not text then
        return { kind = "unchanged" }
    end
    return {
        kind = "written",
        index = text,
        moves = moves(union, m, selection, take),
        placed = placed_op(t, union, m, selection, take, text, nil),
    }
end

-- X, through the selection core revert_texts writes from
---@param t differ.fuzz.Triple
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@param selection differ.model.Selection
---@return differ.fuzz.Outcome
local function revert_op(t, union, cached, unstaged, selection)
    local m = stage.marks_of(union, cached, unstaged)
    local index, reverted, refused = selected.revert("/", "f", union, cached, unstaged, selection)
    if refused then
        return refusal(union, m, selection, refused)
    end
    if not (index and reverted) then
        return { kind = "unchanged" }
    end
    return {
        kind = "written",
        index = index,
        work = reverted.old_text,
        moves = moves(union, m, selection, nil),
        placed = placed_op(t, union, m, selection, false, index, reverted.old_text),
    }
end

---@param t differ.fuzz.Triple
---@param outcome differ.fuzz.Outcome
---@return boolean
local function matches(t, outcome)
    local mv = outcome.moves
    if outcome.placed == false then
        return false
    end
    if not M.moved(t.index, outcome.index, mv.index_leave, mv.index_enter) then
        return false
    end
    return outcome.work == nil or M.moved(t.work, outcome.work, mv.work_leave, mv.work_enter)
end

M.OPS = { "s", "u", "X" }

---@param t differ.fuzz.Triple
---@param op "s"|"u"|"X"
---@param selection differ.model.Selection
---@return differ.fuzz.Outcome
function M.run_op(t, op, selection)
    local union, cached, unstaged = content.union_pairs("/", "f", t.head, t.index, t.work)
    if op == "X" then
        return revert_op(t, union, cached, unstaged, selection)
    end
    return stage_op(t, union, cached, unstaged, selection, op == "s")
end

---@class differ.fuzz.Mismatch
---@field triple differ.fuzz.Triple
---@field op string
---@field rows differ.fuzz.Row[]
---@field outcome differ.fuzz.Outcome

---@class differ.fuzz.Counts
---@field tried integer
---@field unchanged integer
---@field refused table<string, integer>
---@field written integer
---@field unplaced integer  -- written where placement can't be judged
---@field mismatched integer

---@class differ.fuzz.Report
---@field ops table<string, differ.fuzz.Counts>
---@field mismatches differ.fuzz.Mismatch[]  -- the first few

---@class differ.fuzz.Opts
---@field seed integer
---@field count integer       -- triples
---@field size? integer       -- HEAD's lines
---@field staged? number      -- M.triple's rates
---@field edited? number
---@field selections? integer -- the most selections tried per triple
---@field keep? integer       -- mismatches kept in the report

---@param opts differ.fuzz.Opts
---@return differ.fuzz.Report
function M.run(opts)
    local size, most, keep = opts.size or 40, opts.selections or 60, opts.keep or 5
    local report = { ops = {}, mismatches = {} }
    for _, op in ipairs(M.OPS) do
        report.ops[op] =
            { tried = 0, unchanged = 0, refused = {}, written = 0, unplaced = 0, mismatched = 0 }
    end
    math.randomseed(opts.seed)
    for _ = 1, opts.count do
        local t = M.triple(size, opts.staged or 0.1, opts.edited or 0.1)
        local rows = M.rows((content.union_pairs("/", "f", t.head, t.index, t.work)))
        local ranges = {}
        for first = 1, #rows do
            for last = first, #rows do
                ranges[#ranges + 1] = { first, last }
            end
        end
        for _ = 1, math.min(most, #ranges) do
            local range = table.remove(ranges, math.random(#ranges))
            local selection = selection_of(rows, range[1], range[2])
            for _, op in ipairs(M.OPS) do
                local counts = report.ops[op]
                local outcome = M.run_op(t, op, selection)
                counts.tried = counts.tried + 1
                if outcome.kind == "unchanged" then
                    counts.unchanged = counts.unchanged + 1
                elseif outcome.kind == "refused" then
                    counts.refused[outcome.reason] = (counts.refused[outcome.reason] or 0) + 1
                else
                    counts.written = counts.written + 1
                    if outcome.placed == nil then
                        counts.unplaced = counts.unplaced + 1
                    end
                    if not matches(t, outcome) then
                        counts.mismatched = counts.mismatched + 1
                        if #report.mismatches < keep then
                            report.mismatches[#report.mismatches + 1] = {
                                triple = t,
                                op = op,
                                rows = { unpack(rows, range[1], range[2]) },
                                outcome = outcome,
                            }
                        end
                    end
                end
            end
        end
    end
    return report
end

-- a text's lines on one line, `$` on a last line with no newline
---@param text string
---@return string
local function shown(text)
    local lines = text_util.ended_lines(text)
    for i, line in ipairs(lines) do
        if line:sub(-1) == text_util.NO_EOL then
            lines[i] = line:sub(1, -2) .. "$"
        end
    end
    return table.concat(lines, " ")
end

---@param report differ.fuzz.Report
---@return string
function M.format(report)
    local out = {}
    for _, op in ipairs(M.OPS) do
        local c = report.ops[op]
        local refused, reasons = 0, {}
        for reason, n in pairs(c.refused) do
            refused = refused + n
            reasons[#reasons + 1] = ("%s %d"):format(reason, n)
        end
        table.sort(reasons)
        local why = ""
        if #reasons > 0 then
            why = " [" .. table.concat(reasons, ", ") .. "]"
        end
        local line = "%s: tried %d, unchanged %d, refused %d (%.2f%%)%s, "
            .. "written %d (unplaced %d), mismatched %d"
        out[#out + 1] = line:format(
            op,
            c.tried,
            c.unchanged,
            refused,
            100 * refused / math.max(c.tried, 1),
            why,
            c.written,
            c.unplaced,
            c.mismatched
        )
    end
    for _, mm in ipairs(report.mismatches) do
        local rows = {}
        for _, r in ipairs(mm.rows) do
            rows[#rows + 1] = r.side .. " " .. r.line
        end
        out[#out + 1] = ("\nmismatch: %s on %s"):format(mm.op, table.concat(rows, ", "))
        out[#out + 1] = "  head  " .. shown(mm.triple.head)
        out[#out + 1] = "  index " .. shown(mm.triple.index)
        out[#out + 1] = "  work  " .. shown(mm.triple.work)
        out[#out + 1] = "  wrote index " .. shown(mm.outcome.index)
        if mm.outcome.work then
            out[#out + 1] = "  wrote work  " .. shown(mm.outcome.work)
        end
    end
    return table.concat(out, "\n")
end

return M
