-- a seeded fuzz of s, u and X on contiguous stacked-row selections, over random
-- HEAD / index / worktree triples, through the selection core the ops write from
-- (git/staging/selection.lua). a written op is checked against the index and
-- file the drawn marks say it should leave: the moved lines' texts, every other line
-- still in its order, and each line at its row. needs vim.text.diff, so it runs under nvim

local content = require("differ.git.content")
local stage = require("differ.model.stage")
local text_util = require("differ.util.text")
local selected = require("differ.git.staging.selection")
local layout = require("test.fuzz.layout")

local M = {}

---@param n integer
---@param alphabet integer  -- the shared words a line is drawn from
---@return string
local function token(n, alphabet)
    if math.random() < 0.15 then
        return "x" .. math.random(n)
    end
    local i = math.random(alphabet)
    if i <= 26 then
        return string.char(96 + i)
    end
    return "w" .. i
end

-- `lines` with each line kept, dropped, replaced or followed by a new one
---@param lines string[]
---@param rate number
---@param alphabet integer
---@return string[]
local function mutate(lines, rate, alphabet)
    local out = {}
    for _, line in ipairs(lines) do
        local r = math.random()
        if r < rate / 3 then
            out[#out + 1] = token(#lines, alphabet)
        elseif r < rate * 2 / 3 then
            out[#out + 1] = line
            out[#out + 1] = token(#lines, alphabet)
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
---@param alphabet integer
---@return differ.fuzz.Triple
function M.triple(size, staged, edited, alphabet)
    local head = {}
    for i = 1, size do
        head[i] = token(size, alphabet)
    end
    local index = mutate(head, staged, alphabet)
    local work = mutate(index, edited, alphabet)
    return { head = text_of(head), index = text_of(index), work = text_of(work) }
end

---@class differ.fuzz.Row
---@field side "old"|"new"
---@field line integer

-- HEAD<->worktree's changed lines in stacked order: each hunk's old lines, then its new
---@param head_work differ.DiffModel
---@return differ.fuzz.Row[]
function M.rows(head_work)
    local rows = {}
    for _, h in ipairs(head_work.hunks) do
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
---@param head_work differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean|nil
---@return differ.fuzz.Moves
local function moves(head_work, m, selection, take)
    local old_lines = text_util.ended_lines(head_work.old_text)
    local new_lines = text_util.ended_lines(head_work.new_text)
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
---@param head_work differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@return string
local function moves_others(head_work, m, selection)
    for _, h in ipairs(head_work.hunks) do
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
---@field old fun(l: integer): boolean  -- the text holds HEAD<->worktree old line `l`
---@field new fun(l: integer): boolean

-- whether `text` reads as HEAD<->worktree's rows: every unchanged line where it is, and at
-- each hunk the old and new lines `keep` holds, each side in its order
---@param head_work differ.DiffModel
---@param text string
---@param keep differ.fuzz.Keep
---@return boolean
function M.placed(head_work, text, keep)
    local old, new =
        text_util.ended_lines(head_work.old_text), text_util.ended_lines(head_work.new_text)
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
    for _, h in ipairs(head_work.hunks) do
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

-- whether the written index reads as HEAD<->worktree's rows with the op's staged state, and
-- for X the file as them with the selection reverted. nil where the index before the op
-- doesn't read as the rows (content no hunk shows), so placement can't be judged
---@param t differ.fuzz.Triple
---@param head_work differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean
---@param index string
---@param work string|nil  -- X's file text
---@return boolean|nil
local function placed_op(t, head_work, m, selection, take, index, work)
    if not M.placed(head_work, t.index, index_keep(m, selection, nil)) then
        return nil
    end
    if not M.placed(head_work, index, index_keep(m, selection, take)) then
        return false
    end
    if work == nil then
        return true
    end
    return M.placed(head_work, work, {
        old = function(l)
            return selection.old[l] == true
        end,
        new = function(l)
            return not selection.new[l]
        end,
    })
end

-- the text s (`take`), u or X moves the index towards, where a reading places the
-- index: nil where it cuts into blocks with nothing hidden
---@param head_work differ.DiffModel
---@param index string
---@param take boolean
---@return string|nil
local function towards_of(head_work, index, take)
    local blocks, ended = stage.index_blocks(head_work, index)
    if blocks then
        local held, hidden_in = require("differ.model.marks").of_blocks(ended.hunks, blocks)
        if held and #hidden_in == 0 then
            return nil
        end
    end
    if take then
        return head_work.new_text
    end
    return head_work.old_text
end

---@class differ.fuzz.Outcome
---@field kind "unchanged"|"refused"|"written"
---@field reason? string  -- refused: why
---@field index? string   -- written: the index text
---@field work? string    -- written by X: the file text
---@field moves? differ.fuzz.Moves
---@field placed? boolean|nil  -- written: placed_op
---@field towards? string     -- written where a reading places the index: the text it moves towards

-- the op's refusal, with the result check's split by moves_others
---@param head_work differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param refused differ.git.SelectionRefusal
---@return differ.fuzz.Outcome
local function refusal(head_work, m, selection, refused)
    if refused == "moves_others" then
        return { kind = "refused", reason = moves_others(head_work, m, selection) }
    end
    return { kind = "refused", reason = refused }
end

-- s (`take` true) or u writing `index`, or X writing `index` and the file `work`
---@param t differ.fuzz.Triple
---@param head_work differ.DiffModel
---@param m differ.model.Marks
---@param selection differ.model.Selection
---@param take boolean
---@param index string
---@param work string|nil
---@return differ.fuzz.Outcome
local function written(t, head_work, m, selection, take, index, work)
    local moved_take = take ---@type boolean|nil
    if work then
        moved_take = nil
    end
    return {
        kind = "written",
        index = index,
        work = work,
        moves = moves(head_work, m, selection, moved_take),
        placed = placed_op(t, head_work, m, selection, take, index, work),
        towards = towards_of(head_work, t.index, take),
    }
end

-- s (`take` true) or u, through the selection core apply_lines writes from
---@param t differ.fuzz.Triple
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@param selection differ.model.Selection
---@param take boolean
---@return differ.fuzz.Outcome
local function stage_op(t, head_work, head_index, index_work, selection, take)
    local m = stage.marks_of(head_work, head_index, index_work)
    local text, _, refused =
        selected.stage("/", "f", head_work, head_index, index_work, selection, take)
    if refused then
        return refusal(head_work, m, selection, refused)
    end
    if not text then
        return { kind = "unchanged" }
    end
    return written(t, head_work, m, selection, take, text, nil)
end

-- X, through the selection core revert_texts writes from
---@param t differ.fuzz.Triple
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@param selection differ.model.Selection
---@return differ.fuzz.Outcome
local function revert_op(t, head_work, head_index, index_work, selection)
    local m = stage.marks_of(head_work, head_index, index_work)
    local index, reverted, refused =
        selected.revert("/", "f", head_work, head_index, index_work, selection)
    if refused then
        return refusal(head_work, m, selection, refused)
    end
    if not (index and reverted) then
        return { kind = "unchanged" }
    end
    return written(t, head_work, m, selection, false, index, reverted.old_text)
end

-- whether `to` lies on a shortest edit path from `from` to `towards`: an oracle that
-- reads no marks
---@param towards string
---@param from string
---@param to string
---@return boolean
function M.straight(towards, from, to)
    local edits = require("differ.git.staging.write").edits
    local function distance(a, b)
        local dropped, added = edits(a, b)
        return dropped + added
    end
    return distance(towards, to) + distance(to, from) == distance(towards, from)
end

---@param line string  -- an ended line
---@return string
local function bare(line)
    if line:sub(-1) == text_util.NO_EOL then
        return line:sub(1, -2)
    end
    return line
end

---@param text string
---@param line string  -- bare
---@return integer
local function copies(text, line)
    local n = 0
    for _, l in ipairs(text_util.ended_lines(text)) do
        if bare(l) == line then
            n = n + 1
        end
    end
    return n
end

-- the line HEAD and the worktree both end on with different endings, where every side
-- holds it once: a line and its newline change. nil for any other triple
---@param t differ.fuzz.Triple
---@return string|nil
local function ending_line(t)
    local head, work = text_util.ended_lines(t.head), text_util.ended_lines(t.work)
    local h, w = head[#head], work[#work]
    if not h or not w or h == w or bare(h) ~= bare(w) then
        return nil
    end
    local line = bare(h)
    for _, text in ipairs({ t.head, t.index, t.work }) do
        if copies(text, line) ~= 1 then
            return nil
        end
    end
    return line
end

-- whether a write keeps a line and its newline change as one line: every text it
-- writes holds that line once. an oracle that reads no diff and no marks
---@param t differ.fuzz.Triple
---@param outcome differ.fuzz.Outcome  -- a written one
---@return boolean
function M.ending_kept(t, outcome)
    local line = ending_line(t)
    if not line then
        return true
    end
    if copies(outcome.index, line) ~= 1 then
        return false
    end
    return outcome.work == nil or copies(outcome.work, line) == 1
end

---@param text string
---@return table<string, integer>
local function line_counts(text)
    local n = {}
    for _, line in ipairs(text_util.ended_lines(text)) do
        n[bare(line)] = (n[bare(line)] or 0) + 1
    end
    return n
end

-- whether every line's count in `to` stays where `from` has it or within `towards`'s,
-- less at most its `below` rows and plus at most its `above` rows
---@param towards string
---@param from string
---@param to string
---@param below table<string, integer>
---@param above table<string, integer>
---@return boolean
local function within(towards, from, to, below, above)
    local target, was, got = line_counts(towards), line_counts(from), line_counts(to)
    for _, side in ipairs({ target, was, got }) do
        for line in pairs(side) do
            local n, aim, o = got[line] or 0, target[line] or 0, was[line] or 0
            local low, high =
                math.min(o, aim - (below[line] or 0)), math.max(o, aim + (above[line] or 0))
            if n < low or n > high then
                return false
            end
        end
    end
    return true
end

-- whether a write leaves each line's count where it was, or where the side the op takes
-- has it off by at most the HEAD<->worktree rows of that line the selection leaves out: the
-- index towards the worktree for s, HEAD for u and X, and X's file towards HEAD. an
-- oracle that reads no diff of the written text and no marks
---@param t differ.fuzz.Triple
---@param op "s"|"u"|"X"
---@param selection differ.model.Selection
---@param outcome differ.fuzz.Outcome  -- a written one
---@return boolean
function M.counts_kept(t, op, selection, outcome)
    local head_work = content.three_diffs("/", "f", t.head, t.index, t.work)
    local sides = {
        old = text_util.ended_lines(head_work.old_text),
        new = text_util.ended_lines(head_work.new_text),
    }
    local out = { old = {}, new = {} }
    for _, r in ipairs(M.rows(head_work)) do
        if not selection[r.side][r.line] then
            local line = bare(sides[r.side][r.line])
            out[r.side][line] = (out[r.side][line] or 0) + 1
        end
    end
    if op == "s" then
        if not within(t.work, t.index, outcome.index, out.new, out.old) then
            return false
        end
    elseif not within(t.head, t.index, outcome.index, out.old, out.new) then
        return false
    end
    return outcome.work == nil or within(t.head, t.work, outcome.work, out.old, out.new)
end

---@param t differ.fuzz.Triple
---@param outcome differ.fuzz.Outcome  -- a written one
---@return boolean
function M.matches(t, outcome)
    local mv = outcome.moves
    if outcome.placed == false then
        return false
    end
    if outcome.towards and not M.straight(outcome.towards, t.index, outcome.index) then
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
    local head_work, head_index, index_work = content.three_diffs("/", "f", t.head, t.index, t.work)
    if op == "X" then
        return revert_op(t, head_work, head_index, index_work, selection)
    end
    return stage_op(t, head_work, head_index, index_work, selection, op == "s")
end

-- the write the result check refused, as the op builds it before reading it back
---@param t differ.fuzz.Triple
---@param op "s"|"u"|"X"
---@param selection differ.model.Selection
---@return differ.fuzz.Outcome|nil
local function unchecked(t, op, selection)
    local head_work, head_index, index_work = content.three_diffs("/", "f", t.head, t.index, t.work)
    local m = stage.marks_of(head_work, head_index, index_work)
    local text = stage.select_index(head_work, head_index, selection, op == "s")
    if op ~= "X" then
        if not text then
            return nil
        end
        return written(t, head_work, m, selection, op == "s", text, nil)
    end
    local origins = stage.index_origins(head_work, head_index)
    local reverted = stage.select_worktree(head_work, selection, origins)
    if not reverted then
        return nil
    end
    return written(
        t,
        head_work,
        m,
        selection,
        false,
        text or head_index.new_text,
        reverted.old_text
    )
end

-- why a result-check refusal the oracles call correct was refused: "unplaced" where
-- the index before holds content no hunk shows, "hidden_after" where only the
-- read-back does, else "other". nil for any other refusal, or a write the oracles fault
---@param t differ.fuzz.Triple
---@param op "s"|"u"|"X"
---@param selection differ.model.Selection
---@param outcome differ.fuzz.Outcome  -- a refused one
---@return string|nil
function M.refused_correct(t, op, selection, outcome)
    if not (outcome.reason == "unshown" or outcome.reason:match("^moves_others")) then
        return nil
    end
    local would = unchecked(t, op, selection)
    if not would then
        return nil
    end
    if not (M.matches(t, would) and M.ending_kept(t, would)) then
        return nil
    end
    if not M.counts_kept(t, op, selection, would) then
        return nil
    end
    if would.placed == nil then
        return "unplaced"
    end
    local work = would.work or t.work
    local _, hidden = stage.marks_of(content.three_diffs("/", "f", t.head, would.index, work))
    if hidden then
        return "hidden_after"
    end
    return "other"
end

-- whether a HEAD<->index hunk changes one of `h`'s old lines or the line either side
---@param head_index differ.DiffModel
---@param h differ.Hunk
---@return boolean
local function staged_beside(head_index, h)
    local first, last = h.old_start - 1, h.old_start + h.old_count
    if h.old_count == 0 then
        first, last = h.old_start, h.old_start + 1
    end
    for _, c in ipairs(head_index.hunks) do
        local c_first, c_last = c.old_start, c.old_start + c.old_count - 1
        if c.old_count == 0 then
            c_first, c_last = c.old_start, c.old_start + 1
        end
        if c_first <= last and c_last >= first then
            return true
        end
    end
    return false
end

-- s (`take`) or u on `hunk` as the hunk op runs it: next_index, then the result check
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@param hunk differ.Hunk
---@param take boolean
---@return differ.fuzz.Outcome
local function hunk_op(head_work, head_index, index_work, hunk, take)
    local text, reaches = stage.next_index(head_work, head_index, index_work, hunk, take)
    if reaches then
        return { kind = "refused", reason = "reaches" }
    end
    if not text then
        return { kind = "unchanged" }
    end
    local selection = stage.hunk_selection(hunk)
    local after, refused =
        selected.checked("/", "f", head_work, head_index, index_work, selection, take, text)
    if not after then
        return { kind = "refused", reason = refused }
    end
    return {
        kind = "written",
        index = text,
        towards = towards_of(head_work, head_index.new_text, take),
    }
end

-- visual s (`take`) or u over every line of `hunk`
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@param hunk differ.Hunk
---@param take boolean
---@return differ.fuzz.Outcome
local function visual_op(head_work, head_index, index_work, hunk, take)
    local selection = stage.hunk_selection(hunk)
    local text, _, refused =
        selected.stage("/", "f", head_work, head_index, index_work, selection, take)
    if refused then
        return { kind = "refused", reason = refused }
    end
    if not text or text == head_index.new_text then
        return { kind = "unchanged" }
    end
    return { kind = "written", index = text }
end

-- how visual s or u over a whole hunk compares with the hunk op on it
---@param visual differ.fuzz.Outcome
---@param by_hunk differ.fuzz.Outcome
---@param beside boolean  -- staged_beside
---@return string
local function agreement(visual, by_hunk, beside)
    if visual.kind == "refused" and by_hunk.kind == "refused" then
        return "both refuse"
    end
    if visual.kind == "refused" and visual.reason == "between" and beside then
        return "visual refuses: between, staged beside"
    end
    if visual.kind == "refused" then
        return "visual refuses: " .. visual.reason
    end
    if by_hunk.kind == "refused" then
        return "hunk refuses: " .. by_hunk.reason
    end
    if visual.kind == by_hunk.kind and visual.index == by_hunk.index then
        return "agree"
    end
    return "mismatch"
end

M.HUNK_OPS = { "s", "u" }

---@class differ.fuzz.HunkMismatch
---@field triple differ.fuzz.Triple
---@field op string
---@field hunk integer
---@field visual differ.fuzz.Outcome
---@field by_hunk differ.fuzz.Outcome

---@class differ.fuzz.Mismatch
---@field triple differ.fuzz.Triple
---@field op string
---@field rows differ.fuzz.Row[]
---@field outcome differ.fuzz.Outcome

---@class differ.fuzz.Counts
---@field tried integer
---@field unchanged integer
---@field refused table<string, integer>
---@field refused_correct table<string, integer>  -- refused_correct's reason -> count
---@field written integer
---@field unplaced integer  -- written where placement can't be judged
---@field mismatched integer
---@field ending_split integer  -- written with a line and its newline change apart

---@class differ.fuzz.Report
---@field ops table<string, differ.fuzz.Counts>
---@field mismatches differ.fuzz.Mismatch[]  -- the first few
---@field ending_splits differ.fuzz.Mismatch[]  -- the first few
---@field hunks table<string, table<string, integer>>  -- op -> agreement -> count
---@field hunk_mismatches differ.fuzz.HunkMismatch[]  -- the first few

---@class differ.fuzz.Opts
---@field seed integer
---@field count integer       -- triples
---@field size? integer       -- HEAD's lines
---@field staged? number      -- M.triple's rates
---@field edited? number
---@field alphabet? integer   -- shared words, 5 by default
---@field selections? integer -- the most selections tried per triple
---@field keep? integer       -- mismatches kept in the report

-- each seeded triple and the selections tried on it, the same for a seed and opts.
-- `whole` sees each triple once, before its selections
---@param opts differ.fuzz.Opts
---@param each fun(t: differ.fuzz.Triple, rows: differ.fuzz.Row[], selection: differ.model.Selection)
---@param whole? fun(t: differ.fuzz.Triple)
function M.cases(opts, each, whole)
    local size, most = opts.size or 40, opts.selections or 60
    math.randomseed(opts.seed)
    for _ = 1, opts.count do
        local t = M.triple(size, opts.staged or 0.1, opts.edited or 0.1, opts.alphabet or 5)
        if whole then
            whole(t)
        end
        local rows = M.rows((content.three_diffs("/", "f", t.head, t.index, t.work)))
        local ranges = {}
        for first = 1, #rows do
            for last = first, #rows do
                ranges[#ranges + 1] = { first, last }
            end
        end
        for _ = 1, math.min(most, #ranges) do
            local range = table.remove(ranges, math.random(#ranges))
            each(t, { unpack(rows, range[1], range[2]) }, selection_of(rows, range[1], range[2]))
        end
    end
end

---@param opts differ.fuzz.Opts
---@return differ.fuzz.Report
function M.run(opts)
    local keep = opts.keep or 5
    local report = {
        ops = {},
        mismatches = {},
        ending_splits = {},
        count_bads = {},
        hunks = {},
        hunk_mismatches = {},
    }
    for _, op in ipairs(M.OPS) do
        report.ops[op] = {
            tried = 0,
            unchanged = 0,
            refused = {},
            refused_correct = {},
            written = 0,
            unplaced = 0,
            mismatched = 0,
            ending_split = 0,
            count_bad = 0,
        }
    end
    for _, op in ipairs(M.HUNK_OPS) do
        report.hunks[op] = { mismatch = 0, off_path = 0, count_bad = 0 }
    end
    ---@param t differ.fuzz.Triple
    local function whole(t)
        local head_work, head_index, index_work =
            content.three_diffs("/", "f", t.head, t.index, t.work)
        for i, h in ipairs(head_work.hunks) do
            for _, op in ipairs(M.HUNK_OPS) do
                local visual = visual_op(head_work, head_index, index_work, h, op == "s")
                local by_hunk = hunk_op(head_work, head_index, index_work, h, op == "s")
                local what = agreement(visual, by_hunk, staged_beside(head_index, h))
                local counts = report.hunks[op]
                counts[what] = (counts[what] or 0) + 1
                if
                    by_hunk.towards
                    and not M.straight(by_hunk.towards, head_index.new_text, by_hunk.index)
                then
                    counts.off_path = counts.off_path + 1
                end
                if
                    by_hunk.kind == "written"
                    and not M.counts_kept(t, op, stage.hunk_selection(h), by_hunk)
                then
                    counts.count_bad = counts.count_bad + 1
                end
                if what == "mismatch" and #report.hunk_mismatches < keep then
                    report.hunk_mismatches[#report.hunk_mismatches + 1] =
                        { triple = t, op = op, hunk = i, visual = visual, by_hunk = by_hunk }
                end
            end
        end
    end
    M.cases(opts, function(t, rows, selection)
        for _, op in ipairs(M.OPS) do
            local counts = report.ops[op]
            local outcome = M.run_op(t, op, selection)
            counts.tried = counts.tried + 1
            if outcome.kind == "unchanged" then
                counts.unchanged = counts.unchanged + 1
            elseif outcome.kind == "refused" then
                counts.refused[outcome.reason] = (counts.refused[outcome.reason] or 0) + 1
                local why = M.refused_correct(t, op, selection, outcome)
                if why then
                    counts.refused_correct[why] = (counts.refused_correct[why] or 0) + 1
                end
            else
                counts.written = counts.written + 1
                if outcome.placed == nil then
                    counts.unplaced = counts.unplaced + 1
                end
                local case = { triple = t, op = op, rows = rows, outcome = outcome }
                if not M.matches(t, outcome) then
                    counts.mismatched = counts.mismatched + 1
                    if #report.mismatches < keep then
                        report.mismatches[#report.mismatches + 1] = case
                    end
                end
                if not M.ending_kept(t, outcome) then
                    counts.ending_split = counts.ending_split + 1
                    if #report.ending_splits < keep then
                        report.ending_splits[#report.ending_splits + 1] = case
                    end
                end
                if not M.counts_kept(t, op, selection, outcome) then
                    counts.count_bad = counts.count_bad + 1
                    if #report.count_bads < keep then
                        report.count_bads[#report.count_bads + 1] = case
                    end
                end
            end
        end
    end, whole)
    return report
end

-- what each oracle that must read 0 faults
local COUNT_BAD = "a line's count is neither where it was nor where the op takes it"
local WRONG = {
    { "mismatched", "mismatched", "the write isn't what the drawn marks say it should be" },
    { "ending_split", "ending split", "a line and its newline change written apart" },
    { "count_bad", "count bad", COUNT_BAD },
}
local HUNK_WRONG = {
    { "mismatch", "mismatch", "visual over the whole hunk wrote other text than the hunk op" },
    { "off_path", "off path", "the hunk op's write isn't on the way to the side it takes" },
    { "count_bad", "count bad", COUNT_BAD },
}

---@class differ.fuzz.Wrong
---@field who string  -- the op, or "hunk s"/"hunk u"
---@field what string
---@field n integer
---@field meaning string

-- every oracle that faulted a write
---@param report differ.fuzz.Report
---@return differ.fuzz.Wrong[]
function M.wrong(report)
    local found = {}
    for _, op in ipairs(M.OPS) do
        for _, w in ipairs(WRONG) do
            local n = report.ops[op][w[1]]
            if n > 0 then
                found[#found + 1] = { who = op, what = w[2], n = n, meaning = w[3] }
            end
        end
    end
    for _, op in ipairs(M.HUNK_OPS) do
        for _, w in ipairs(HUNK_WRONG) do
            local n = report.hunks[op][w[1]] or 0
            if n > 0 then
                found[#found + 1] = { who = "hunk " .. op, what = w[2], n = n, meaning = w[3] }
            end
        end
    end
    return found
end

---@param counts table<string, integer>[]
---@return string[]  -- every key, the most common first
local function kinds(counts)
    local total = {}
    for _, c in ipairs(counts) do
        for k, n in pairs(c) do
            total[k] = (total[k] or 0) + n
        end
    end
    local keys = vim.tbl_keys(total)
    table.sort(keys, function(a, b)
        if total[a] ~= total[b] then
            return total[a] > total[b]
        end
        return a < b
    end)
    return keys
end

---@param counts table<string, integer>
---@return integer
local function sum(counts)
    local n = 0
    for _, v in pairs(counts) do
        n = n + v
    end
    return n
end

-- the whole-hunk comparisons each hunk op made, one per hunk
---@param counts table<string, integer>
---@return integer
local function hunks_tried(counts)
    return sum(counts) - counts.off_path - counts.count_bad
end

---@param o differ.fuzz.Outcome
---@return string
local function said(o)
    if o.kind == "written" then
        return layout.text(o.index)
    end
    return o.reason or o.kind
end

---@param r differ.fuzz.Report
---@param out string[]
local function examples(r, out)
    local groups = {
        { "mismatched", r.mismatches },
        { "ending split", r.ending_splits },
        { "count bad", r.count_bads },
    }
    for _, g in ipairs(groups) do
        for i, c in ipairs(g[2]) do
            local more = { { "new index", layout.text(c.outcome.index) } }
            if c.outcome.work then
                more[#more + 1] = { "new file", layout.text(c.outcome.work) }
            end
            local title = ("%s %s, example %d of %d, on %s"):format(
                c.op,
                g[1],
                i,
                #g[2],
                layout.rows(c.rows)
            )
            layout.case(out, title, c.triple, c.rows, more)
        end
    end
    for i, c in ipairs(r.hunk_mismatches) do
        local title = ("whole hunk %s mismatch, example %d of %d, on hunk %d"):format(
            c.op,
            i,
            #r.hunk_mismatches,
            c.hunk
        )
        layout.case(out, title, c.triple, {}, {
            { "visual", said(c.visual) },
            { "hunk op", said(c.by_hunk) },
        })
    end
end

---@param r differ.fuzz.Report
---@param out string[]
local function summary(r, out)
    local found = M.wrong(r)
    local tried = r.ops[M.OPS[1]].tried
    local checked = ("s, u and X on %d selections each, whole-hunk s and u on %d hunks each"):format(
        tried,
        hunks_tried(r.hunks[M.HUNK_OPS[1]])
    )
    if #found == 0 then
        layout.heading(out, "wrong writes       none " .. layout.mark(true), checked)
    else
        local rows, total = {}, 0
        for _, w in ipairs(found) do
            total = total + w.n
            rows[#rows + 1] = { ("%s %s"):format(w.who, w.what), { w.n }, note = w.meaning }
        end
        layout.heading(out, ("wrong writes       %d %s"):format(total, layout.mark(false)), checked)
        layout.grid(out, { "" }, rows)
        examples(r, out)
    end
    layout.heading(out, "needless refusals", "the op refused, but the write it blocked was right")
    local rows = {}
    for _, op in ipairs(M.OPS) do
        local n = sum(r.ops[op].refused_correct)
        rows[#rows + 1] = { op, { n, layout.share(n, r.ops[op].tried) }, note = "of tries" }
    end
    layout.grid(out, { "" }, rows)
end

---@param r differ.fuzz.Report
---@param out string[]
local function detail(r, out)
    local ops = {}
    for i, op in ipairs(M.OPS) do
        ops[i] = r.ops[op]
    end
    ---@param f fun(c: differ.fuzz.Counts): integer|string
    ---@return (integer|string)[]
    local function per_op(f)
        local values = {}
        for i, c in ipairs(ops) do
            values[i] = f(c)
        end
        return values
    end
    layout.heading(out, "what each op did", "one count per selection tried")
    layout.grid(out, M.OPS, {
        { "tried", per_op(function(c)
            return c.tried
        end) },
        { "written", per_op(function(c)
            return c.written
        end) },
        {
            "placement not judged",
            per_op(function(c)
                return c.unplaced
            end),
            indent = 1,
        },
        { "left the index alone", per_op(function(c)
            return c.unchanged
        end) },
        { "refused", per_op(function(c)
            return sum(c.refused)
        end) },
        {
            "share of tried",
            per_op(function(c)
                return layout.share(sum(c.refused), c.tried)
            end),
            indent = 1,
        },
    })

    local refused, correct = {}, {}
    for i, c in ipairs(ops) do
        refused[i], correct[i] = c.refused, c.refused_correct
    end
    ---@param counts table<string, integer>[]
    ---@return differ.fuzz.GridRow[]
    local function by_kind(counts)
        local rows = {}
        for _, k in ipairs(kinds(counts)) do
            local values = {}
            for i, c in ipairs(counts) do
                values[i] = c[k] or 0
            end
            rows[#rows + 1] = { k, values }
        end
        return rows
    end
    layout.heading(out, "refusals by kind", "why each op refused, most common first")
    layout.grid(out, M.OPS, by_kind(refused))
    layout.heading(
        out,
        "needless refusals by kind",
        "why the blocked write was still checked as right"
    )
    layout.grid(out, M.OPS, by_kind(correct))

    local hunks = {}
    for i, op in ipairs(M.HUNK_OPS) do
        hunks[i] = r.hunks[op]
    end
    ---@param key string
    ---@return integer[]
    local function per_hunk_op(key)
        local values = {}
        for i, c in ipairs(hunks) do
            values[i] = c[key] or 0
        end
        return values
    end
    local rows = {
        { "hunks", per_hunk_op("") },
        { "agree", per_hunk_op("agree") },
        { "both refuse", per_hunk_op("both refuse") },
    }
    for i, c in ipairs(hunks) do
        rows[1][2][i] = hunks_tried(c)
    end
    for _, side in ipairs({ "visual", "hunk" }) do
        local prefix = side .. " refuses: "
        local keys = {}
        for _, k in ipairs(kinds(hunks)) do
            if vim.startswith(k, prefix) then
                keys[#keys + 1] = k
            end
        end
        if #keys > 0 then
            rows[#rows + 1] =
                { side == "visual" and "only visual refuses" or "only the hunk op refuses" }
            for _, k in ipairs(keys) do
                rows[#rows + 1] = { k:sub(#prefix + 1), per_hunk_op(k), indent = 1 }
            end
        end
    end
    layout.heading(
        out,
        "whole hunk vs hunk op",
        "visual s/u over every row of a hunk, against the hunk op on it"
    )
    layout.grid(out, M.HUNK_OPS, rows)

    layout.heading(out, "legend")
    layout.legend(out, {
        { "selection", "a run of rows in the diff view (HEAD vs worktree), as visual mode picks" },
        { "placement not judged", "the index before holds a line no row shows, so where each" },
        { "", "line lands isn't checked; the other checks still run" },
        { "hidden", "a selected hunk holds an index line neither side has (drawn !)" },
        { "split_ending", "the op would move a line apart from its newline change" },
        { "ending, ending_after", "the op would leave a line with no newline above others" },
        { "unshown", "the index holds a line again where no row shows it" },
        { "moves_others", "the write would change rows outside the selection; :unequal where" },
        { "", "a touched hunk has sides of unequal length and a staged row" },
        { "between", "a file too big to read, or a selection the drawn marks can't take" },
        { "reaches", "the hunk op's write reaches past the hunk" },
        { "unplaced", "needless, where the index before holds a line no row shows" },
        { "hidden_after", "needless, where only the written index holds such a line" },
        { "x12, w30", "a line whose text is that word; files share a few words on purpose" },
        { "$", "the last line has no newline" },
        { "[a]", "a row the example is about" },
    })
end

---@param r differ.fuzz.Report
---@param show_detail? boolean
---@return string
function M.format(r, show_detail)
    local out = {}
    summary(r, out)
    if show_detail then
        detail(r, out)
    end
    return table.concat(out, "\n")
end

return M
