-- a file's content on each working-tree side, read in the repo domain, and the diff
-- pairs a row's staging marks come from

local exec = require("differ.git.exec")
local index_path = require("differ.git.index").index_path
local text_util = require("differ.util.text")
local GIT = exec.GIT
local chomp, git, git_raw = exec.chomp, exec.git, exec.git_raw

local M = {}

-- the three working-tree side refs (slice B). staged diffs read HEAD↔index,
-- unstaged diffs read index↔worktree; an untracked file is absent from the index
-- so its index read returns nil and the diff renders as a pure add
local HEAD = { kind = "rev", rev = "HEAD", label = "HEAD" }
local INDEX = { kind = "index", label = "INDEX" }
local WORKTREE = { kind = "worktree", label = "WORKTREE" }
M.HEAD, M.INDEX, M.WORKTREE = HEAD, INDEX, WORKTREE

-- a file's bytes as they sit on disk, or nil when it isn't readable
---@param abs string
---@return string|nil
function M.read_file(abs)
    local uv = vim.uv or vim.loop
    local st = uv.fs_lstat(abs)
    if st and st.type == "link" then
        return uv.fs_readlink(abs) -- git stores a symlink as its target path
    end
    if vim.fn.filereadable(abs) == 0 then
        return nil
    end
    local fd = io.open(abs, "rb")
    if not fd then
        return nil
    end
    local data = fd:read("*a")
    fd:close()
    return data
end

-- whether an attribute that rewrites LF-only content on `git add` is set for `relpath`
---@param root string
---@param relpath string
---@return boolean
function M.has_clean_attr(root, relpath)
    local attrs = { "filter", "ident", "working-tree-encoding" }
    local out =
        git(vim.list_extend({ "check-attr" }, vim.list_extend(attrs, { "--", relpath })), root)
    if not out then
        return false
    end
    for line in out:gmatch("[^\n]+") do
        local value = line:match(": ([^:]*)$")
        if value ~= "unspecified" and value ~= "unset" then
            return true
        end
    end
    return false
end

-- worktree bytes as `git add` would store them (the clean filter: eol
-- conversion, text attrs, custom filters), so worktree-side diffs compare in
-- the repo domain, like `git diff`, and the hunk patches built from the model
-- stage the same blob a `git add` of the file would write. runs the real
-- `git add` against a throwaway copy of the index and reads the entry back, so
-- every conversion rule (safe-crlf stickiness included) is git's own, not a
-- reimplementation. gated on non-binary content that has a CR byte or a
-- converting attribute (has_clean_attr): nothing else converts, so the common
-- case pays one check-attr. any failure falls back to the raw bytes
---@param root string
---@param relpath string
---@param data string
---@return string
local function as_staged(root, relpath, data)
    if text_util.is_binary(data) then
        return data
    end
    if not data:find("\r", 1, true) and not M.has_clean_attr(root, relpath) then
        return data
    end
    local index = git({ "rev-parse", "--git-path", "index" }, root)
    if not index then
        return data
    end
    index = chomp(index)
    if index:sub(1, 1) ~= "/" then
        index = root .. "/" .. index -- --git-path can print relative to the cwd
    end
    local tmp = vim.fn.tempname()
    local src = io.open(index, "rb") -- absent in a fresh repo: git add creates tmp
    if src then
        local blob = src:read("*a")
        src:close()
        local dst = io.open(tmp, "wb")
        if not dst then
            return data
        end
        dst:write(blob)
        dst:close()
    end
    local env = { GIT_INDEX_FILE = tmp }
    local add_cmd = vim.list_extend(vim.list_extend({}, GIT), { "add", "--", relpath })
    local add = vim.system(add_cmd, { cwd = root, env = env }):wait()
    if add.code ~= 0 then
        os.remove(tmp)
        return data
    end
    -- raw read, no text=true: that would strip the CRs git chose to keep
    local show = vim.system({ "git", "show", ":0:" .. relpath }, { cwd = root, env = env }):wait()
    os.remove(tmp)
    if show.code ~= 0 or not show.stdout then
        return data
    end
    return show.stdout
end

-- read a side's content for `relpath` (repo-root-relative). returns the content
-- (possibly ""), or nil when the file is absent on that side (added/deleted);
-- callers treat nil as an empty file so the diff renders an add/delete.
-- the worktree side reads through the clean filter (as_staged) so it lands in
-- the same domain as the index/rev sides
---@param ref differ.git.Ref
---@param root string
---@param relpath string
---@return string|nil
function M.read(ref, root, relpath)
    if ref.kind == "worktree" then
        local data = M.read_file(root .. "/" .. relpath)
        return data and as_staged(root, relpath, data) or nil
    end
    -- a rev is `<rev>:path`; the index is `:0:path`, since `:path` reads a leading
    -- `1:` as a stage number
    local spec = (ref.kind == "index" and ":0:" or (ref.rev .. ":")) .. relpath
    return git_raw({ "show", spec }, root) -- nil if the path is absent in that tree
end

-- the entry's `diff --raw` line under `args`'s pair, or nil when the pair no longer
-- lists it at all. git pairs a rename only with both paths in the pathspec
---@param root string
---@param args string[]
---@param entry differ.FileEntry
---@return string|nil
function M.raw_line(root, args, entry)
    local full = { "diff", "--raw" }
    vim.list_extend(full, args)
    vim.list_extend(full, { "--", entry.path })
    if entry.previous_path then
        full[#full + 1] = entry.previous_path
    end
    local out = git(full, root)
    if not out or chomp(out) == "" then
        return nil
    end
    return out
end

-- a file's three diffs over texts already read: HEAD↔worktree to show, and the two
-- real pairs its marks come from
---@param root string
---@param path string
---@param head string
---@param index string
---@param work string
---@return differ.DiffModel union, differ.DiffModel cached, differ.DiffModel unstaged
function M.union_pairs(root, path, head, index, work)
    local build = require("differ.model.diff").build
    local function pair(old_rev, new_rev, old_text, new_text)
        return build({
            path = path,
            old_rev = old_rev,
            new_rev = new_rev,
            old_text = old_text,
            new_text = new_text,
            root = root,
        })
    end
    return pair("HEAD", "WORKTREE", head, work),
        pair("HEAD", "INDEX", head, index),
        pair("INDEX", "WORKTREE", index, work)
end

-- a row's three diffs, read fresh, or nil when the index can't be read. HEAD is read at
-- a rename's old path
---@param root string
---@param entry differ.FileEntry
---@return differ.DiffModel|nil union, differ.DiffModel|nil cached, differ.DiffModel|nil unstaged
function M.union_models(root, entry)
    local at_head = entry.previous_path or entry.path
    local index = M.read(INDEX, root, index_path(entry))
    if not index then
        return nil
    end
    return M.union_pairs(
        root,
        entry.path,
        M.read(HEAD, root, at_head) or "",
        index,
        M.read(WORKTREE, root, entry.path) or ""
    )
end

return M
