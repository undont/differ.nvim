-- pure line-pairing scorer for the word-level pass, no nvim API
-- lines with no partner above threshold stay unpaired (whole-line highlight)

local tokenize = require("differ.worddiff.tokenize")

---@class differ.LinePair
---@field old integer|nil -- index into the hunk's old_lines (nil = pure addition)
---@field new integer|nil -- index into the hunk's new_lines (nil = pure deletion)
---@field score number    -- similarity in [0,1]; 0 for unpaired

local M = {}

-- non-whitespace word tokens of a line, in order
---@param s string
---@return string[]
local function word_tokens(s)
    local out = {}
    for _, t in ipairs(tokenize.word(s)) do
        if t.text:match("%S") then
            out[#out + 1] = t.text
        end
    end
    return out
end

-- longest common subsequence length over two token lists (order-aware), O(la*lb)
-- with a rolling row so the table stays one-dimensional
---@param a string[]
---@param b string[]
---@return integer
local function lcs_len(a, b)
    local la, lb = #a, #b
    if la == 0 or lb == 0 then
        return 0
    end
    local prev = {}
    for j = 0, lb do
        prev[j] = 0
    end
    for i = 1, la do
        local diag = 0 -- prev[j-1] before it's overwritten
        for j = 1, lb do
            local up = prev[j]
            if a[i] == b[j] then
                prev[j] = diag + 1
            elseif prev[j - 1] > up then
                prev[j] = prev[j - 1]
            else
                prev[j] = up
            end
            diag = up
        end
    end
    return prev[lb]
end

-- the same score over already-tokenised lines, so a caller comparing every old line
-- against every new one tokenises each line once instead of once per comparison
---@param ta string[]
---@param tb string[]
---@return number
local function score(ta, tb)
    local total = #ta + #tb
    if total == 0 then
        return 0.0
    end
    return (2 * lcs_len(ta, tb)) / total
end

-- order-aware token similarity in [0,1]: 2·LCS/(|a|+|b|) over word tokens (a
-- sequence Sørensen–Dice). order matters, so lines that merely share scattered
-- words (a rewritten comment, a different field with a similar comment) score below
-- the token-set metric and fall back to a clean whole-line highlight
---@param a string
---@param b string
---@return number
function M.similarity(a, b)
    if a == b then
        return 1.0
    end
    return score(word_tokens(a), word_tokens(b))
end

-- pair old/new lines for the word-level pass: a maximum-similarity monotonic
-- (non-crossing) alignment over partners scoring at or above `threshold`, so an old
-- line can't reach past its neighbours to a more token-similar but out-of-order line.
-- lines with no in-order partner stay unpaired (whole-line highlight)
---@param old_lines string[]
---@param new_lines string[]
---@param threshold number
---@return differ.LinePair[]
function M.pair(old_lines, new_lines, threshold)
    local m, n = #old_lines, #new_lines
    -- tokenise once per line, not once per comparison: the matrix below is m*n cells
    -- and tokenising inside it dominated the whole pass
    local old_toks, new_toks = {}, {}
    for i = 1, m do
        old_toks[i] = word_tokens(old_lines[i])
    end
    for j = 1, n do
        new_toks[j] = word_tokens(new_lines[j])
    end
    local sim = {}
    for i = 1, m do
        sim[i] = {}
        local old_line, ta = old_lines[i], old_toks[i]
        for j = 1, n do
            -- identical text short-circuits to 1.0, as in M.similarity
            sim[i][j] = old_line == new_lines[j] and 1.0 or score(ta, new_toks[j])
        end
    end

    -- dp[i][j] = best total similarity aligning old[1..i] with new[1..j]; a match is
    -- only an option when it clears the threshold
    local dp = {}
    for i = 0, m do
        dp[i] = {}
        dp[i][0] = 0
    end
    for j = 0, n do
        dp[0][j] = 0
    end
    for i = 1, m do
        for j = 1, n do
            local best = dp[i - 1][j]
            if dp[i][j - 1] > best then
                best = dp[i][j - 1]
            end
            if sim[i][j] >= threshold then
                local matched = dp[i - 1][j - 1] + sim[i][j]
                if matched > best then
                    best = matched
                end
            end
            dp[i][j] = best
        end
    end

    -- backtrack, preferring an unpaired line over a tied match so an old line takes
    -- its earliest equal-scoring partner (the "first partner on a tie" rule)
    local mate, scores = {}, {}
    local i, j = m, n
    while i > 0 and j > 0 do
        if dp[i][j] == dp[i - 1][j] then
            i = i - 1
        elseif dp[i][j] == dp[i][j - 1] then
            j = j - 1
        else
            mate[i], scores[i] = j, sim[i][j]
            i, j = i - 1, j - 1
        end
    end

    -- emit old lines in order (paired or pure deletion), then leftover insertions
    local pairs_out, used_new = {}, {}
    for oi = 1, m do
        local ni = mate[oi]
        if ni then
            used_new[ni] = true
        end
        pairs_out[#pairs_out + 1] = { old = oi, new = ni, score = ni and scores[oi] or 0 }
    end
    for ni = 1, n do
        if not used_new[ni] then
            pairs_out[#pairs_out + 1] = { old = nil, new = ni, score = 0 }
        end
    end
    return pairs_out
end

return M
