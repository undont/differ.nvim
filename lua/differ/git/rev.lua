-- git source resolution: pure mapping from :Differ args to a (old, new) pair of
-- side refs, the `git diff` args that list that pairing's changed files, and a
-- parser for `--name-status -z` output. no nvim or subprocess here (exec lives
-- in git/init.lua) so this stays unit-testable under plain busted

local M = {}

---@class differ.git.Ref
---@field kind "worktree"|"index"|"rev"|"merge_base"
---@field rev string|nil    -- kind == "rev"
---@field base string|nil   -- kind == "merge_base": one side of the merge-base
---@field head string|nil   -- kind == "merge_base": the other side
---@field label string      -- display name (becomes old_rev/new_rev on the model)

---@class differ.git.Source
---@field old differ.git.Ref
---@field new differ.git.Ref

local WORKTREE = { kind = "worktree", label = "WORKTREE" }

---@param rev string
---@return differ.git.Ref
local function rev_ref(rev)
    return { kind = "rev", rev = rev, label = rev }
end

-- an unresolved merge-base ref; git/init.lua resolves it to a concrete rev
---@param base string
---@param head string
---@param label string
---@return differ.git.Ref
local function merge_base_ref(base, head, label)
    return { kind = "merge_base", base = base, head = head, label = label }
end

-- resolve :Differ args into a source pairing. mirrors git/diffview rev
-- syntax so existing muscle memory carries over. these forms cover the whole
-- daily loop (uncommitted / branch-total / range / since-rev); staged-only has no
-- entry (staged/unstaged is a file-panel concern, not a diff-open flag):
--   (none)              -> HEAD vs worktree              (all uncommitted changes)
--   <a>..<b>            -> <a> vs <b>                     (plain two-dot range)
--   <a>...<b>           -> merge-base(a,b) vs <b>         (three-dot; since they diverged)
--   <a>...              -> merge-base(a,HEAD) vs worktree (branch total, incl. uncommitted)
--   <a> <b>             -> <a> vs <b>
--   <rev>               -> <rev> vs worktree             (changes since <rev>, incl. uncommitted)
---@param args string[]|nil
---@return differ.git.Source
function M.source(args)
    args = args or {}
    local first = args[1]
    if first == nil or first == "" then
        return { old = rev_ref("HEAD"), new = WORKTREE }
    end
    -- three-dot before two-dot (it's a superset). empty RHS is the branch-total
    -- convenience: merge-base vs the working tree, so uncommitted work is included
    local ta, tb = first:match("^(.-)%.%.%.(.*)$")
    if ta and ta ~= "" then
        if tb == "" then
            return { old = merge_base_ref(ta, "HEAD", ta .. "..."), new = WORKTREE }
        end
        return { old = merge_base_ref(ta, tb, ta .. "..." .. tb), new = rev_ref(tb) }
    end
    local a, b = first:match("^(.-)%.%.(.+)$")
    if a and a ~= "" and b then
        return { old = rev_ref(a), new = rev_ref(b) }
    end
    if args[2] and args[2] ~= "" then
        return { old = rev_ref(first), new = rev_ref(args[2]) }
    end
    return { old = rev_ref(first), new = WORKTREE }
end

-- the arguments to append after `git diff --name-status -z` to list this source's
-- changed files. expects a *resolved* source (merge_base already turned into a
-- rev by git/init.lua), so old is always a rev:
--   rev vs worktree -> `git diff <rev>`   (uncommitted diff against rev)
--   rev vs rev      -> `git diff <a> <b>`
---@param source differ.git.Source
---@return string[]
function M.diff_args(source)
    local o, n = source.old, source.new
    if n.kind == "worktree" then
        return { o.rev }
    end
    return { o.rev, n.rev }
end

-- split a NUL-delimited byte string into fields. pure (avoids vim.split's vim dep)
-- and trailing-NUL tolerant, matching git's `-z` framing
---@param s string
---@return string[]
local function nul_split(s)
    local out, start = {}, 1
    while start <= #s do
        local z = s:find("\0", start, true)
        if not z then
            out[#out + 1] = s:sub(start)
            break
        end
        out[#out + 1] = s:sub(start, z - 1)
        start = z + 1
    end
    return out
end

---@class differ.git.ChangedFile
---@field status string                -- single-letter: A/M/D/R/C/T...
---@field path string
---@field previous_path string|nil     -- source path on rename/copy

-- parse `git diff --name-status -z [...]` output. rename/copy records carry the
-- similarity-suffixed status (e.g. "R100") followed by old then new path
---@param out string
---@return differ.git.ChangedFile[]
function M.parse_name_status(out)
    local toks = nul_split(out)
    local files, i = {}, 1
    while i <= #toks do
        local status = toks[i]
        i = i + 1
        if status == "" then
            break -- trailing empty field from the final NUL
        end
        local code = status:sub(1, 1)
        if code == "R" or code == "C" then
            local prev, path = toks[i], toks[i + 1]
            i = i + 2
            files[#files + 1] = { status = code, path = path, previous_path = prev }
        else
            files[#files + 1] = { status = code, path = toks[i] }
            i = i + 1
        end
    end
    return files
end

---@class differ.git.StatusEntry
---@field x string                  -- index/staged status letter (" " if clean)
---@field y string                  -- worktree/unstaged status letter (" " if clean)
---@field path string
---@field previous_path string|nil  -- source path on rename/copy

-- parse `git status --porcelain=v1 -z -uall` (slice B). each record is
-- `XY<sp><path>`; X is the staged (HEAD↔index) state, Y the unstaged
-- (index↔worktree) state. rename/copy records (X or Y = R/C) carry the original
-- path in the *next* NUL field, which we attach as previous_path
---@param out string
---@return differ.git.StatusEntry[]
function M.parse_status(out)
    local toks = nul_split(out)
    local entries, i = {}, 1
    while i <= #toks do
        local rec = toks[i]
        i = i + 1
        if rec == "" then
            break -- trailing empty field from the final NUL
        end
        local x, y, path = rec:sub(1, 1), rec:sub(2, 2), rec:sub(4)
        local prev
        if x == "R" or x == "C" or y == "R" or y == "C" then
            prev = toks[i]
            i = i + 1
        end
        entries[#entries + 1] = { x = x, y = y, path = path, previous_path = prev }
    end
    return entries
end

-- parse `git diff --numstat -z` into a path -> {additions, deletions} map
-- (slice B). a normal record is `<add>\t<del>\t<path>`; a rename leaves the path
-- field empty and emits the old then new path as the next two NUL fields (we key
-- on the new path). binary files report `-` counts, which become 0
---@param out string
---@return table<string, { additions: integer, deletions: integer }>
function M.parse_numstat(out)
    local toks = nul_split(out)
    local counts, i = {}, 1
    while i <= #toks do
        local rec = toks[i]
        i = i + 1
        if rec == "" then
            break
        end
        local add, del, path = rec:match("^(%S+)\t(%S+)\t(.*)$")
        if add then
            if path == "" then -- rename: old then new follow
                path = toks[i + 1]
                i = i + 2
            end
            counts[path] = { additions = tonumber(add) or 0, deletions = tonumber(del) or 0 }
        end
    end
    return counts
end

-- parse a bare NUL-separated path list (`git diff --name-only -z`,
-- `git ls-files -z`). each path appears once; the trailing NUL leaves an
-- empty field we drop
---@param out string
---@return string[]
function M.parse_paths(out)
    local paths = {}
    for _, p in ipairs(nul_split(out)) do
        if p ~= "" then
            paths[#paths + 1] = p
        end
    end
    return paths
end

-- parse `git diff --name-only --diff-filter=U -z` into the conflicted paths
---@param out string
---@return string[]
function M.parse_unmerged(out)
    return M.parse_paths(out)
end

return M
