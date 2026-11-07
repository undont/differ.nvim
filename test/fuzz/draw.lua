-- a seeded fuzz of the union view's drawn marks where the index doesn't cut cleanly into
-- blocks. each index is HEAD with a random staged state per union row, built straight
-- from the union hunks, so the true marks are known. a wrong draw is ambiguous where the
-- drawn marks also place the index at cost 0, else a reading bug. needs vim.text.diff

local apply = require("differ.model.apply")
local content = require("differ.git.content")
local fuzz = require("test.fuzz.stage")
local layout = require("test.fuzz.layout")
local marks = require("differ.model.marks")
local stage = require("differ.model.stage")
local text_util = require("differ.util.text")

local M = {}

---@class differ.fuzz.Truth
---@field index string
---@field marks differ.model.Marks
---@field hidden_in? integer  -- the hunk whose block holds a line no row shows

-- `a` and `b` merged at random, each in its order
---@param a string[]
---@param b string[]
---@return string[]
local function merge(a, b)
    local out, i, j = {}, 1, 1
    while i <= #a or j <= #b do
        if j > #b or (i <= #a and math.random() < 0.5) then
            out[#out + 1] = a[i]
            i = i + 1
        else
            out[#out + 1] = b[j]
            j = j + 1
        end
    end
    return out
end

-- a line no row of `h` shows: a new word, or a copy of one of its rows or of the
-- unchanged line either side, as a line staged then undone in the worktree leaves
---@param h differ.Hunk  -- ended
---@param head string[]  -- ended lines
---@return string
local function stray(h, head)
    local first = h.old_count > 0 and h.old_start or h.old_start + 1
    local near = {}
    for _, lines in ipairs({
        { head[first - 1] },
        { head[first + h.old_count] },
        h.old_lines,
        h.new_lines,
    }) do
        for _, line in ipairs(lines) do
            if line:sub(-1) ~= text_util.NO_EOL then
                near[#near + 1] = line
            end
        end
    end
    if #near == 0 or math.random() < 0.5 then
        return "h" .. math.random(1000)
    end
    return near[math.random(#near)]
end

-- an index with a random staged state per row of `ended`'s hunks, and with `head`
-- given, one line no row shows in a random hunk's block. nil where a line with no
-- newline lands before another, which no index text can hold
---@param ended differ.DiffModel
---@param head? string[]  -- ended lines
---@return differ.fuzz.Truth|nil
local function truth_of(ended, head)
    local m = { old = {}, new = {} }
    local blocks = {}
    for i, h in ipairs(ended.hunks) do
        local kept, held = {}, {}
        for k, line in ipairs(h.old_lines) do
            local staged = math.random() < 0.5
            m.old[h.old_start + k - 1] = staged
            if not staged then
                kept[#kept + 1] = line
            end
        end
        for k, line in ipairs(h.new_lines) do
            local staged = math.random() < 0.5
            m.new[h.new_start + k - 1] = staged
            if staged then
                held[#held + 1] = line
            end
        end
        blocks[i] = merge(kept, held)
    end
    local hidden_in = nil
    if head and #ended.hunks > 0 then
        hidden_in = math.random(#ended.hunks)
        local block = blocks[hidden_in]
        table.insert(block, math.random(#block + 1), stray(ended.hunks[hidden_in], head))
    end
    local joined = {}
    for _, block in ipairs(blocks) do
        for _, line in ipairs(block) do
            joined[#joined + 1] = line
        end
    end
    for i, line in ipairs(joined) do
        if line:sub(-1) == text_util.NO_EOL and i < #joined then
            return nil
        end
    end
    return { index = apply.join(ended, blocks), marks = m, hidden_in = hidden_in }
end

---@class differ.fuzz.Possible
---@field old table<integer, table<boolean, true>>  -- old lnum -> the marks some cost 0 reading gives it
---@field new table<integer, table<boolean, true>>

---@param set table<integer, true>
---@param p integer
local function add(set, p)
    set[p] = true
end

-- every mark each row takes in some reading of `index` that holds every unchanged line
-- in place and every index line on a row: one forward and one backward pass over
-- (old rows passed, new rows passed, next index line) per hunk
---@param hunks differ.Hunk[]  -- ended
---@param head string[]        -- ended lines
---@param index string[]       -- ended lines
---@return differ.fuzz.Possible
function M.possible(hunks, head, index)
    local segs, next_old = {}, 1
    for _, h in ipairs(hunks) do
        local first = h.old_count > 0 and h.old_start or h.old_start + 1
        for l = next_old, first - 1 do
            segs[#segs + 1] = { line = head[l] }
        end
        segs[#segs + 1] = { hunk = h }
        next_old = first + h.old_count
    end
    for l = next_old, #head do
        segs[#segs + 1] = { line = head[l] }
    end

    local entry, forward = { [1] = true }, {}
    for k, seg in ipairs(segs) do
        local out = {}
        if seg.line then
            for p in pairs(entry) do
                if index[p] == seg.line then
                    add(out, p + 1)
                end
            end
        else
            local h, fw = seg.hunk, {}
            for i = 0, h.old_count do
                fw[i] = {}
                for j = 0, h.new_count do
                    fw[i][j] = {}
                end
            end
            fw[0][0] = entry
            for i = 0, h.old_count do
                for j = 0, h.new_count do
                    for p in pairs(fw[i][j]) do
                        if i < h.old_count then
                            add(fw[i + 1][j], p)
                            if index[p] == h.old_lines[i + 1] then
                                add(fw[i + 1][j], p + 1)
                            end
                        end
                        if j < h.new_count then
                            add(fw[i][j + 1], p)
                            if index[p] == h.new_lines[j + 1] then
                                add(fw[i][j + 1], p + 1)
                            end
                        end
                    end
                end
            end
            forward[k] = fw
            out = fw[h.old_count][h.new_count]
        end
        entry = out
    end

    local possible = { old = {}, new = {} }
    local exit = { [#index + 1] = true }
    for k = #segs, 1, -1 do
        local seg, out = segs[k], {}
        if seg.line then
            for p in pairs(exit) do
                if index[p - 1] == seg.line then
                    add(out, p - 1)
                end
            end
        else
            local h, fw, bw = seg.hunk, forward[k], {}
            for i = h.old_count, 0, -1 do
                bw[i] = {}
                for j = h.new_count, 0, -1 do
                    local here = {}
                    if i == h.old_count and j == h.new_count then
                        here = exit
                    end
                    if i < h.old_count then
                        local l = h.old_start + i
                        possible.old[l] = possible.old[l] or {}
                        for p in pairs(bw[i + 1][j]) do
                            add(here, p)
                            if fw[i][j][p] then
                                possible.old[l][true] = true
                            end
                            if index[p - 1] == h.old_lines[i + 1] then
                                add(here, p - 1)
                                if fw[i][j][p - 1] then
                                    possible.old[l][false] = true
                                end
                            end
                        end
                    end
                    if j < h.new_count then
                        local l = h.new_start + j
                        possible.new[l] = possible.new[l] or {}
                        for p in pairs(bw[i][j + 1]) do
                            add(here, p)
                            if fw[i][j][p] then
                                possible.new[l][false] = true
                            end
                            if index[p - 1] == h.new_lines[j + 1] then
                                add(here, p - 1)
                                if fw[i][j][p - 1] then
                                    possible.new[l][true] = true
                                end
                            end
                        end
                    end
                    bw[i][j] = here
                end
            end
            out = bw[0][0]
        end
        exit = out
    end
    return possible
end

---@class differ.fuzz.WrongRow: differ.fuzz.Row
---@field staged boolean  -- as drawn

---@class differ.fuzz.DrawCase
---@field what string
---@field triple differ.fuzz.Triple
---@field rows differ.fuzz.WrongRow[]

---@class differ.fuzz.DrawReport
---@field triples integer
---@field skipped integer    -- no index text holds the chosen marks
---@field clean integer      -- the index cuts into blocks: drawn from them
---@field unclean integer
---@field unread integer     -- unclean and too big to read
---@field wrong integer      -- unclean draws marking some row wrongly
---@field ambiguous integer  -- wrong, and the drawn marks place the index at cost 0
---@field copies integer     -- ambiguous, marking another copy of the same lines
---@field hidden integer     -- wrong, and the reading hides some index line
---@field unplaced integer   -- wrong, nothing hidden, and the drawn marks don't place it
---@field doubtful integer   -- unclean draws where some row takes either mark at cost 0
---@field doubtful_right integer
---@field rows integer       -- changed rows in unclean draws
---@field doubtful_rows integer
---@field wrong_rows integer
---@field wrong_sure_rows integer  -- wrong rows only one mark fits: a reading bug
---@field cases differ.fuzz.DrawCase[]
---@field kept table<string, integer>  -- case kind -> seen

---@param m differ.model.Marks
---@return differ.fuzz.Keep
local function keep_of(m)
    return {
        old = function(l)
            return not m.old[l]
        end,
        new = function(l)
            return m.new[l] == true
        end,
    }
end

-- whether `a` and `b` stage the same texts on each side of each hunk, differing only
-- in which copy of a repeated line they mark
---@param hunks differ.Hunk[]  -- ended
---@param a differ.model.Marks
---@param b differ.model.Marks
---@return boolean
local function copies_only(hunks, a, b)
    for _, h in ipairs(hunks) do
        for _, side in ipairs({ "old", "new" }) do
            local count = {} ---@type table<string, integer>
            for k, line in ipairs(h[side .. "_lines"]) do
                local l = h[side .. "_start"] + k - 1
                local n = (a[side][l] == true and 1 or 0) - (b[side][l] == true and 1 or 0)
                count[line] = (count[line] or 0) + n
            end
            for _, n in pairs(count) do
                if n ~= 0 then
                    return false
                end
            end
        end
    end
    return true
end

-- the first `keep` cases of each kind
---@param report differ.fuzz.DrawReport|differ.fuzz.HiddenReport
---@param keep integer
---@param what string
---@param t differ.fuzz.Triple
---@param rows differ.fuzz.WrongRow[]
---@param kind? string  -- what the count is kept by, `what` by default
local function keep_case(report, keep, what, t, rows, kind)
    kind = kind or what
    report.kept[kind] = (report.kept[kind] or 0) + 1
    if report.kept[kind] > keep then
        return
    end
    table.sort(rows, function(a, b)
        if a.side ~= b.side then
            return a.side == "old"
        end
        return a.line < b.line
    end)
    report.cases[#report.cases + 1] = { what = what, triple = t, rows = rows }
end

-- scores one HEAD / worktree pair with a random truth into `report`
---@param report differ.fuzz.DrawReport
---@param head string
---@param work string
---@param keep integer  -- cases kept
function M.score(report, head, work, keep)
    report.triples = report.triples + 1
    local union = content.union_pairs("/", "f", head, head, work)
    local ended = apply.ended(union)
    local truth = truth_of(ended)
    if not truth then
        report.skipped = report.skipped + 1
        return
    end
    assert(fuzz.placed(union, truth.index, keep_of(truth.marks)), "truth doesn't place its index")
    local _, cached, unstaged = content.union_pairs("/", "f", head, truth.index, work)
    local blocks = stage.index_blocks(union, truth.index)
    if blocks then
        local held, hidden_in = marks.of_blocks(ended.hunks, blocks)
        if held and #hidden_in == 0 then
            report.clean = report.clean + 1
            return
        end
    end
    report.unclean = report.unclean + 1
    local drawn, hidden, _, unread = stage.marks_of(union, cached, unstaged)
    if unread then
        report.unread = report.unread + 1
    end
    local possible = M.possible(
        ended.hunks,
        text_util.ended_lines(union.old_text),
        text_util.ended_lines(truth.index)
    )
    local wrong_rows, doubtful = {}, false
    for _, side in ipairs({ "old", "new" }) do
        for l, can in pairs(possible[side]) do
            report.rows = report.rows + 1
            if can[true] and can[false] then
                doubtful = true
                report.doubtful_rows = report.doubtful_rows + 1
            end
            local want, got = truth.marks[side][l] == true, drawn[side][l] == true
            if want ~= got then
                report.wrong_rows = report.wrong_rows + 1
                if not (can[true] and can[false]) then
                    report.wrong_sure_rows = report.wrong_sure_rows + 1
                end
                wrong_rows[#wrong_rows + 1] = { side = side, line = l, staged = got }
            end
        end
    end
    if doubtful then
        report.doubtful = report.doubtful + 1
    end
    if #wrong_rows == 0 then
        if doubtful then
            report.doubtful_right = report.doubtful_right + 1
        end
        return
    end
    report.wrong = report.wrong + 1
    local what = "ambiguous"
    if hidden then
        what = "hidden"
    elseif not fuzz.placed(union, truth.index, keep_of(drawn)) then
        what = "unplaced"
    end
    report[what] = report[what] + 1
    if what == "ambiguous" and copies_only(ended.hunks, truth.marks, drawn) then
        report.copies = report.copies + 1
        what = "another copy"
    end
    keep_case(report, keep, what, { head = head, index = truth.index, work = work }, wrong_rows)
end

---@return differ.fuzz.DrawReport
function M.report()
    local report = { cases = {}, kept = {} }
    for _, k in ipairs({
        "triples",
        "skipped",
        "clean",
        "unclean",
        "unread",
        "wrong",
        "ambiguous",
        "copies",
        "hidden",
        "unplaced",
        "doubtful",
        "doubtful_right",
        "rows",
        "doubtful_rows",
        "wrong_rows",
        "wrong_sure_rows",
    }) do
        report[k] = 0
    end
    return report
end

---@class differ.fuzz.HiddenReport
---@field triples integer
---@field skipped integer    -- no index text holds the chosen marks
---@field read_away integer  -- drawn with nothing hidden: some reading places every line
---@field named integer      -- drawn hidden, the true hunk among those drawn `!`
---@field elsewhere integer  -- drawn hidden, the true hunk not among them
---@field wrong_bare integer  -- draws marking a row wrongly outside every `!` hunk
---@field wrong_bare_away integer  -- of those, read_away ones
---@field wrong_bare_tie integer   -- of those, hidden at the true reading's cost
---@field wrong_bare_dearer integer  -- of those, hidden at more than the true reading's cost
---@field rows integer
---@field wrong_rows integer
---@field wrong_bare_rows integer
---@field cases differ.fuzz.DrawCase[]
---@field kept table<string, integer>

---@return differ.fuzz.HiddenReport
function M.hidden_report()
    local report = { cases = {}, kept = {} }
    for _, k in ipairs({
        "triples",
        "skipped",
        "read_away",
        "named",
        "elsewhere",
        "wrong_bare",
        "wrong_bare_away",
        "wrong_bare_tie",
        "wrong_bare_dearer",
        "rows",
        "wrong_rows",
        "wrong_bare_rows",
    }) do
        report[k] = 0
    end
    return report
end

-- scores one HEAD / worktree pair whose truth holds a line no row shows into `report`
---@param report differ.fuzz.HiddenReport
---@param head string
---@param work string
---@param keep integer  -- cases kept
function M.score_hidden(report, head, work, keep)
    report.triples = report.triples + 1
    local union = content.union_pairs("/", "f", head, head, work)
    local ended = apply.ended(union)
    local truth = truth_of(ended, text_util.ended_lines(union.old_text))
    if not truth or not truth.hidden_in then
        report.skipped = report.skipped + 1
        return
    end
    local _, cached, unstaged = content.union_pairs("/", "f", head, truth.index, work)
    local drawn, hidden, hidden_in = stage.marks_of(union, cached, unstaged)
    local flagged = {} ---@type table<integer, true>
    for _, i in ipairs(hidden_in) do
        flagged[i] = true
    end
    if not hidden then
        report.read_away = report.read_away + 1
    elseif flagged[truth.hidden_in] then
        report.named = report.named + 1
    else
        report.elsewhere = report.elsewhere + 1
    end
    local bare = {}
    for i, h in ipairs(ended.hunks) do
        for _, side in ipairs({ "old", "new" }) do
            for k = 1, h[side .. "_count"] do
                local l = h[side .. "_start"] + k - 1
                report.rows = report.rows + 1
                if (truth.marks[side][l] == true) ~= (drawn[side][l] == true) then
                    report.wrong_rows = report.wrong_rows + 1
                    if not flagged[i] then
                        report.wrong_bare_rows = report.wrong_bare_rows + 1
                        bare[#bare + 1] = { side = side, line = l, staged = drawn[side][l] == true }
                    end
                end
            end
        end
    end
    if #bare == 0 then
        return
    end
    report.wrong_bare = report.wrong_bare + 1
    local what = "read away"
    if not hidden then
        report.wrong_bare_away = report.wrong_bare_away + 1
    elseif stage.reading(union, truth.index).cost <= 1 then
        report.wrong_bare_tie = report.wrong_bare_tie + 1
        what = "! on another hunk, equal cost"
    else
        report.wrong_bare_dearer = report.wrong_bare_dearer + 1
        what = "reading bug"
    end
    local t = { head = head, index = truth.index, work = work }
    keep_case(
        report,
        keep,
        ("%s, stray line in hunk %d"):format(what, truth.hidden_in),
        t,
        bare,
        what
    )
end

---@param opts differ.fuzz.Opts
---@return differ.fuzz.DrawReport plain, differ.fuzz.HiddenReport hidden
function M.run(opts)
    local report, hidden = M.report(), M.hidden_report()
    for _, pass in ipairs({ { report, M.score }, { hidden, M.score_hidden } }) do
        math.randomseed(opts.seed)
        for _ = 1, opts.count do
            local t = fuzz.triple(
                opts.size or 40,
                opts.staged or 0.1,
                opts.edited or 0.1,
                opts.alphabet or 5
            )
            pass[2](pass[1], t.head, t.work, opts.keep or 5)
        end
    end
    return report, hidden
end

---@param n integer
---@param total integer
---@return string
local function of(n, total)
    return ("%d of %d (%s)"):format(n, total, layout.share(n, total))
end

---@param out string[]
---@param cases differ.fuzz.DrawCase[]
local function list_cases(out, cases)
    for _, c in ipairs(cases) do
        local staged, unstaged = {}, {}
        for _, r in ipairs(c.rows) do
            local list = r.staged and staged or unstaged
            list[#list + 1] = r
        end
        local drawn = {}
        if #staged > 0 then
            drawn[#drawn + 1] = "staged " .. layout.rows(staged)
        end
        if #unstaged > 0 then
            drawn[#drawn + 1] = "unstaged " .. layout.rows(unstaged)
        end
        layout.case(out, c.what, c.triple, c.rows, { { "drawn", table.concat(drawn, "; ") } })
    end
end

---@param p differ.fuzz.DrawReport
---@param h differ.fuzz.HiddenReport
---@return integer
function M.bugs(p, h)
    return p.hidden + p.unplaced + p.wrong_sure_rows + h.wrong_bare_dearer
end

---@param p differ.fuzz.DrawReport
---@param h differ.fuzz.HiddenReport
---@param out string[]
local function summary(p, h, out)
    layout.heading(
        out,
        ("wrong draws        %s guessed files"):format(of(p.wrong, p.unclean)),
        "the index doesn't cut into blocks, so the view reads each row's state; truth known"
    )
    layout.grid(out, { "" }, {
        { "another copy", { p.copies }, note = "same staged lines, marked on another copy" },
        { "other tie", { p.ambiguous - p.copies }, note = "another reading at the same cost" },
        { "reading bug", { p.hidden + p.unplaced }, zero = true },
    })
    local drawn = h.triples - h.skipped
    layout.heading(
        out,
        ("stray line         %s files with a wrong row and no !"):format(of(h.wrong_bare, drawn)),
        "the index also holds one line no row shows, in a known hunk"
    )
    layout.grid(out, { "" }, {
        { "read away", { h.wrong_bare_away }, note = "a reading with no stray explains the index" },
        { "! on another hunk", { h.wrong_bare_tie }, note = "at the same cost as the truth" },
        { "reading bug", { h.wrong_bare_dearer }, zero = true },
    })
end

---@param p differ.fuzz.DrawReport
---@param h differ.fuzz.HiddenReport
---@param out string[]
local function detail(p, h, out)
    layout.heading(out, "draws, every row from the union", "one count per file")
    layout.grid(out, { "" }, {
        { "files", { p.triples } },
        { "no index holds the chosen states", { p.skipped }, indent = 1 },
        { "cut into blocks", { p.clean }, indent = 1 },
        { "guessed", { p.unclean }, indent = 1 },
        { "too big to read", { p.unread }, indent = 2 },
        { "drawn wrong", { p.wrong }, indent = 2 },
        { "another reading at cost 0", { p.ambiguous }, indent = 3 },
        { "another copy", { p.copies }, indent = 4 },
        { "a line hidden", { p.hidden }, indent = 3, zero = true },
        { "the drawn states don't place it", { p.unplaced }, indent = 3, zero = true },
        { "doubtful", { p.doubtful }, indent = 2 },
        { "drawn right", { p.doubtful_right }, indent = 3 },
        { "rows in guessed files", { p.rows } },
        { "doubtful", { p.doubtful_rows, layout.share(p.doubtful_rows, p.rows) }, indent = 1 },
        { "drawn wrong", { p.wrong_rows, layout.share(p.wrong_rows, p.rows) }, indent = 1 },
        { "only one state fits", { p.wrong_sure_rows }, indent = 2, zero = true },
    })
    local drawn = h.triples - h.skipped
    layout.heading(out, "draws with a stray line", "one count per file")
    layout.grid(out, { "" }, {
        { "files", { h.triples } },
        { "no index holds the chosen states", { h.skipped }, indent = 1 },
        { "! on the stray's hunk", { h.named, layout.share(h.named, drawn) }, indent = 1 },
        { "! on another hunk only", { h.elsewhere, layout.share(h.elsewhere, drawn) }, indent = 1 },
        { "read away", { h.read_away, layout.share(h.read_away, drawn) }, indent = 1 },
        { "a wrong row and no ! on it", { h.wrong_bare }, indent = 1 },
        { "read away", { h.wrong_bare_away }, indent = 2 },
        { "at the truth's cost", { h.wrong_bare_tie }, indent = 2 },
        { "dearer than the truth", { h.wrong_bare_dearer }, indent = 2, zero = true },
        { "rows", { h.rows } },
        { "drawn wrong", { h.wrong_rows }, indent = 1 },
        { "no ! on it", { h.wrong_bare_rows }, indent = 2 },
    })
    if #p.cases + #h.cases > 0 then
        layout.heading(out, "example wrong draws", "the wrong rows bracketed")
        list_cases(out, p.cases)
        list_cases(out, h.cases)
    end
    layout.heading(out, "legend")
    layout.legend(out, {
        { "guessed", "the index doesn't cut cleanly into per-hunk blocks, so marks.reading" },
        { "", "places it; these are the draws in question" },
        { "doubtful", "some row takes either state in a reading of the same cost" },
        { "another copy", "the drawn and true states stage the same lines on each side of each" },
        { "", "hunk, differing only in which copy of a repeated line" },
        { "stray line", "an index line no row shows, as a line staged then undone leaves" },
        { "read away", "a reading with no hidden line explains the index: nothing can see it" },
        { "!", "a hunk drawn hidden: the index holds something there no row shows" },
    })
end

---@param p differ.fuzz.DrawReport
---@param h differ.fuzz.HiddenReport
---@param show_detail? boolean
---@return string
function M.format(p, h, show_detail)
    local out = {}
    summary(p, h, out)
    if show_detail then
        detail(p, h, out)
    end
    return table.concat(out, "\n")
end

return M
