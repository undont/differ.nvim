-- fragment diff: paired lines -> changed byte-col spans, pure lua, no nvim API.
-- a pure LCS over token streams (not vim.diff) so spans stay testable
-- under plain busted. the LCS grid is O(n*m), which a minified line's token count
-- makes untenable, so the common leading/trailing runs are matched directly and only
-- the middle reaches the grid

local tokenize = require("differ.worddiff.tokenize")
local pair = require("differ.worddiff.pair")

local M = {}

-- the trimmed middle still grids at na*nb, and the dp table is that many slots, so a
-- line long enough to survive the trim is a memory problem before it is a time one
-- (9e6 cells costs ~95MB). past this the middle is left unmarked and reads as one
-- changed span, which is what a line with thousands of differing tokens is anyway
local MAX_MIDDLE_CELLS = 4e6

---@class differ.PairSpans
---@field old differ.SubSpan[]
---@field new differ.SubSpan[]

-- mark which tokens are common to both streams via LCS backtrack. the tokens shared
-- at the head and tail are matched up front and kept out of the grid: an edit sits
-- somewhere inside a line, so trimming both ends leaves only the edited middle to
-- solve. a common prefix (and suffix) is always matchable in some optimal LCS, so the
-- result stays a longest one; where several are equally long this anchors the matches
-- at the line's edges, which is where the unchanged text is
---@param a differ.Token[]
---@param b differ.Token[]
---@return boolean[] keep_a, boolean[] keep_b
local function common_tokens(a, b)
    local n, m = #a, #b
    local keep_a, keep_b = {}, {}

    local head = 0
    while head < n and head < m and a[head + 1].text == b[head + 1].text do
        head = head + 1
        keep_a[head], keep_b[head] = true, true
    end
    local tail = 0
    while tail < n - head and tail < m - head and a[n - tail].text == b[m - tail].text do
        keep_a[n - tail], keep_b[m - tail] = true, true
        tail = tail + 1
    end

    -- the untrimmed middles, indexed off `head`: a[head + i] and b[head + j]
    local na, nb = n - head - tail, m - head - tail
    if na * nb > MAX_MIDDLE_CELLS then
        return keep_a, keep_b -- head/tail stand; the middle merges into one span
    end
    -- dp[i][j] = LCS length of the middles from i and j on
    local dp = {}
    for i = 0, na do
        dp[i] = {}
        dp[i][nb] = 0
    end
    for j = 0, nb do
        dp[na][j] = 0
    end
    for i = na - 1, 0, -1 do
        for j = nb - 1, 0, -1 do
            if a[head + i + 1].text == b[head + j + 1].text then
                dp[i][j] = dp[i + 1][j + 1] + 1
            else
                dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
            end
        end
    end

    local i, j = 0, 0
    while i < na and j < nb do
        if a[head + i + 1].text == b[head + j + 1].text then
            keep_a[head + i + 1] = true
            keep_b[head + j + 1] = true
            i, j = i + 1, j + 1
        elseif dp[i + 1][j] >= dp[i][j + 1] then
            i = i + 1
        else
            j = j + 1
        end
    end
    return keep_a, keep_b
end

-- merge runs of non-common tokens into byte-col spans
---@param tokens differ.Token[]
---@param keep boolean[]
---@return differ.SubSpan[]
local function spans_from(tokens, keep)
    local out = {}
    local i = 1
    local n = #tokens
    while i <= n do
        if not keep[i] then
            local col_start = tokens[i].col_start
            local col_end = tokens[i].col_end
            local has_content = tokens[i].text:match("%S") ~= nil
            local j = i + 1
            while j <= n and not keep[j] do
                col_end = tokens[j].col_end
                has_content = has_content or tokens[j].text:match("%S") ~= nil
                j = j + 1
            end
            -- a purely-whitespace run is alignment churn (e.g. gofmt re-padding a
            -- struct), not a real edit; pairing already ignores whitespace, so drop
            -- it here too rather than lighting up the gap on unchanged lines
            if has_content then
                out[#out + 1] = { col_start = col_start, col_end = col_end }
            end
            i = j
        else
            i = i + 1
        end
    end
    return out
end

-- emit word-level spans for a single old/new line pair
---@param old_line string
---@param new_line string
---@param mode "word"|"char"
---@return differ.PairSpans
function M.emit(old_line, new_line, mode)
    if old_line == new_line then
        return { old = {}, new = {} }
    end
    local old_toks = tokenize.tokenize(old_line, mode)
    local new_toks = tokenize.tokenize(new_line, mode)
    local keep_old, keep_new = common_tokens(old_toks, new_toks)
    return {
        old = spans_from(old_toks, keep_old),
        new = spans_from(new_toks, keep_new),
    }
end

-- pair a hunk's lines and emit per-line spans for the matched pairs.
-- returns sparse arrays keyed by intra-hunk line index (1-based); unpaired
-- lines have no entry and degrade to whole-line highlighting
---@param hunk differ.Hunk
---@param threshold number
---@param mode "word"|"char"
---@return table<integer, differ.SubSpan[]> old_spans, table<integer, differ.SubSpan[]> new_spans
function M.for_hunk(hunk, threshold, mode)
    local pairs_ = pair.pair(hunk.old_lines, hunk.new_lines, threshold)
    local old_spans, new_spans = {}, {}
    for _, p in ipairs(pairs_) do
        if p.old and p.new then
            local s = M.emit(hunk.old_lines[p.old], hunk.new_lines[p.new], mode)
            old_spans[p.old] = s.old
            new_spans[p.new] = s.new
        end
    end
    return old_spans, new_spans
end

return M
