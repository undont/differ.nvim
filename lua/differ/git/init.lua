-- local git source: the runtime half of the diff source layer. resolves a
-- repo, turns a rev spec (rev.lua) into concrete old/new content, and opens a
-- view. local diffs are fast and offline, so reads run synchronously here: the
-- latency discipline is about the PR sidecar hot path, not local git.
-- pure parsing/grammar lives in git/rev.lua; this module only does I/O + wiring

local rev = require("differ.git.rev")
local patch = require("differ.git.patch")
local log = require("differ.git.log")
local watch = require("differ.git.watch")
local text_util = require("differ.util.text")
local tab_util = require("differ.util.tab")
local open_session_tab, close_session_tab = tab_util.open_session, tab_util.close_session

local M = {}

-- the three working-tree side refs (slice B). staged diffs read HEAD↔index,
-- unstaged diffs read index↔worktree; an untracked file is absent from the index
-- so its index read returns nil and the diff renders as a pure add
local HEAD = { kind = "rev", rev = "HEAD", label = "HEAD" }
local INDEX = { kind = "index", label = "INDEX" }
local WORKTREE = { kind = "worktree", label = "WORKTREE" }

-- git's canonical empty-tree object: the "old" side for a root commit (no parent),
-- so its files list and read as pure adds (history)
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

-- git's mode for a submodule entry (a commit pointer)
local GITLINK = "160000"

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- how long a network git call may block the editor; `wait()` has no budget of its own
M.fetch_timeout_ms = 20000

-- roots we've already reported conflicts for, cleared once a tree is clean
local notified = {} ---@type table<string, true>

-- report conflicts and point at the merge tool
---@param root string
---@param paths string[]
---@param rerouted boolean|nil
function M.notify_conflicts(root, paths, rerouted)
    if #paths == 0 then
        notified[root] = nil
        return
    end
    local files = #paths == 1 and "1 file" or (#paths .. " files")
    if rerouted then
        return notify(files .. " conflicted, opening the merge tool")
    end
    if notified[root] then
        return
    end
    notified[root] = true
    notify(files .. " conflicted; :Differ mergetool to resolve")
end

-- what a network call runs under. git prompts for credentials on the controlling
-- terminal, which under nvim is one nothing can be typed into, so prompting off turns
-- a hang into an error. read per call: the budget is settable
---@return { timeout: integer, env: table<string, string> }
local function fetch_opts()
    return { timeout = M.fetch_timeout_ms, env = { GIT_TERMINAL_PROMPT = "0" } }
end

-- spawn git and wait. vim.system raises when the process can't start (no git on PATH,
-- a cwd that's gone), so the raise comes back as `err`. a nil res with no err is
-- wait() answering nothing at all; only the caller knows if a budget explains it
---@param cmd string[]
---@param opts table
---@return { code: integer, stdout: string|nil, stderr: string|nil }|nil res, string|nil err
local function run(cmd, opts)
    local ok, obj = pcall(vim.system, cmd, opts)
    if not ok then
        return nil, tostring(obj)
    end
    return obj:wait()
end

-- every path differ hands git is a real file name, never a glob
local GIT = { "git", "--literal-pathspecs" }

-- run git in `cwd`. returns stdout on success, or nil + stderr on failure.
-- `text = true` normalises `\r\n` to `\n` in stdout, which is right for plumbing
-- output (status/numstat/rev-parse/name-status/...) but would corrupt file
-- content read via `git show`; content reads use git_raw instead
---@param args string[]
---@param cwd string
---@param opts? { timeout?: integer, env?: table<string, string> }
---@return string|nil stdout, string|nil stderr
local function git(args, cwd, opts)
    local cmd = vim.list_extend({}, GIT)
    vim.list_extend(cmd, args)
    opts = opts or {}
    local res, err = run(cmd, {
        cwd = cwd,
        text = true,
        timeout = opts.timeout,
        env = opts.env,
    })
    if err then
        return nil, err -- never started
    end
    -- a killed process exits 124 with an empty stderr, or answers nothing at all when
    -- a child outlives it holding the pipes (a fetch's transport helper does). both are
    -- the budget, and neither says so itself
    if opts.timeout and (not res or res.code == 124) then
        return nil, ("git %s timed out after %ds"):format(args[1], opts.timeout / 1000)
    end
    if not res then
        return nil, "git exited without a result"
    end
    if res.code ~= 0 then
        return nil, res.stderr
    end
    return res.stdout
end

-- like `git`, but without `text = true`: stdout comes back byte-true (CRLF kept
-- intact) instead of newline-normalised. use for content-bearing reads (`git
-- show` on the index/a rev/a conflict stage), never for plumbing output
---@param args string[]
---@param cwd string
---@return string|nil stdout, string|nil stderr
local function git_raw(args, cwd)
    local cmd = vim.list_extend({}, GIT)
    vim.list_extend(cmd, args)
    local res, err = run(cmd, { cwd = cwd })
    if not res then
        return nil, err
    end
    if res.code ~= 0 then
        return nil, res.stderr
    end
    return res.stdout
end

-- strip trailing whitespace from a git output line (e.g. rev-parse, show, log)
local function chomp(s)
    return (s:gsub("%s+$", ""))
end

-- repo root containing `path` (a file or directory), or nil if not in a repo
---@param path string
---@return string|nil
function M.root(path)
    local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
    local out = git({ "rev-parse", "--show-toplevel" }, dir)
    return out and chomp(out) or nil
end

-- the repo's current HEAD sha, or nil outside a repo
---@param root string
---@return string|nil
function M.head_sha(root)
    local out = git({ "rev-parse", "HEAD" }, root)
    return out and chomp(out) or nil
end

-- does a local branch of this name already exist?
---@param root string
---@param ref string
---@return boolean
local function has_branch(root, ref)
    return git({ "rev-parse", "--verify", "--quiet", "refs/heads/" .. ref }, root) ~= nil
end

-- a fork PR's head branch lives on the contributor's repo, so origin carries it only
-- as refs/pull/<number>/head. fetch that and land on a local branch named for the head
-- ref, created only when it isn't there already: an existing one may hold local work,
-- and a stale one is what the session's head-mismatch warning is for. the branch fetch's
-- error is the one surfaced, since it names the ref the user actually asked for
---@param root string
---@param ref string
---@param number integer|nil
---@param fetch_err string  -- the failed branch fetch's stderr
---@return boolean ok, string|nil err
local function checkout_pull_ref(root, ref, number, fetch_err)
    if not number then
        return false, fetch_err
    end
    local _, perr =
        git({ "fetch", "origin", ("refs/pull/%d/head"):format(number) }, root, fetch_opts())
    if perr then
        return false, fetch_err
    end
    local args = has_branch(root, ref) and { "checkout", ref }
        or { "checkout", "-b", ref, "FETCH_HEAD" }
    local _, cerr = git(args, root)
    if cerr then
        return false, cerr
    end
    return true
end

-- check out a PR's head branch locally (client-side action): fetch the ref from
-- origin, then check it out. fetch first so the branch exists even before its first
-- local pull; if a local branch of that name already tracks the ref, checkout lands on
-- it. origin has no such branch for a cross-repo (fork) PR, so that fetch fails and the
-- pull ref is the fallback. returns true on success, or false + the git stderr to surface
---@param root string
---@param ref string  -- the PR head branch name (head_ref)
---@param number integer|nil  -- the PR number; enables the fork fallback
---@return boolean ok, string|nil err
function M.checkout(root, ref, number)
    if not rev.valid_ref(ref) then
        return false, ("unsafe branch name, refusing to run git: %s"):format(ref)
    end
    local _, ferr = git({ "fetch", "origin", ref }, root, fetch_opts())
    if ferr then
        return checkout_pull_ref(root, ref, number, ferr)
    end
    local _, cerr = git({ "checkout", ref }, root)
    if cerr then
        return false, cerr
    end
    return true
end

-- resolve an unresolved merge_base ref to a concrete rev; other refs pass through.
-- returns nil on failure (e.g. unrelated histories), with a notification
---@param ref differ.git.Ref
---@param root string
---@return differ.git.Ref|nil
local function resolve_ref(ref, root)
    if ref.kind ~= "merge_base" then
        return ref
    end
    local out = git({ "merge-base", ref.base, ref.head }, root)
    if not out then
        notify(("no merge-base between %s and %s"):format(ref.base, ref.head), vim.log.levels.ERROR)
        return nil
    end
    return { kind = "rev", rev = chomp(out), label = ref.label }
end

-- a file's bytes as they sit on disk, or nil when it isn't readable
---@param abs string
---@return string|nil
local function read_file(abs)
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

-- worktree bytes as `git add` would store them (the clean filter: eol
-- conversion, text attrs, custom filters), so worktree-side diffs compare in
-- the repo domain, like `git diff`, and the hunk patches built from the model
-- stage the same blob a `git add` of the file would write. runs the real
-- `git add` against a throwaway copy of the index and reads the entry back, so
-- every conversion rule (safe-crlf stickiness included) is git's own, not a
-- reimplementation. gated on a CR byte in non-binary content: LF-only content
-- can't convert differently, so the common case pays nothing. any failure
-- falls back to the raw bytes (the old behaviour)
---@param root string
---@param relpath string
---@param data string
---@return string
local function as_staged(root, relpath, data)
    if not data:find("\r", 1, true) or text_util.is_binary(data) then
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
        local data = read_file(root .. "/" .. relpath)
        return data and as_staged(root, relpath, data) or nil
    end
    -- a rev is `<rev>:path`; the index is `:0:path`, since `:path` reads a leading
    -- `1:` as a stage number
    local spec = (ref.kind == "index" and ":0:" or (ref.rev .. ":")) .. relpath
    return git_raw({ "show", spec }, root) -- nil if the path is absent in that tree
end

-- one conflict stage's full content for `relpath`: 1=base, 2=ours, 3=theirs.
-- `git show :N:path`. an absent stage (a modify/delete conflict has no :2:/:3:) reads
-- as "", mirroring M.read's nil->empty convention so the column renders an add/delete
---@param root string
---@param relpath string
---@param stage 1|2|3
---@return string
function M.read_stage(root, relpath, stage)
    return git_raw({ "show", (":%d:"):format(stage) .. relpath }, root) or ""
end

-- whether `relpath` has a stage N entry at all. read_stage folds an absent stage into "",
-- which a genuinely empty one also reads as, and the two want opposite handling: an add/add
-- conflict has no `:1:` and so no base to take, while an empty ancestor has one to take
---@param root string
---@param relpath string
---@param stage 1|2|3
---@return boolean
function M.has_stage(root, relpath, stage)
    local spec = (":%d:"):format(stage) .. relpath
    return vim.system({ "git", "cat-file", "-e", spec }, { cwd = root }):wait().code == 0
end

-- re-merge the three stage texts and return the result in diff3 conflict style (a base
-- slab between ||||||| and =======), whatever the user's merge.conflictStyle is. used to
-- recover base slabs when the worktree markers omit them (the default `merge` style).
-- git merge-file works on paths, so the stages go through temp files; a >0 exit is the
-- conflict count (expected), only a 255 exit is real trouble and returns nil
---@param ours_text string
---@param base_text string
---@param theirs_text string
---@return string|nil
function M.merge_file_diff3(ours_text, base_text, theirs_text)
    local paths = {}
    local function tmp(text)
        local p = vim.fn.tempname()
        local fd = io.open(p, "wb")
        if not fd then
            return nil
        end
        paths[#paths + 1] = p
        fd:write(text)
        fd:close()
        return p
    end
    local ours, base, theirs = tmp(ours_text), tmp(base_text), tmp(theirs_text)
    local out
    if ours and base and theirs then
        -- no text=true: it would strip the CRs git keeps, so a CRLF base slab would no
        -- longer match the :1: stage the input column locates it against
        local res = vim.system({ "git", "merge-file", "-p", "--diff3", ours, base, theirs }):wait()
        if res.code ~= 255 then
            out = res.stdout
        end
    end
    for _, p in ipairs(paths) do
        os.remove(p)
    end
    return out
end

-- repo-relative paths of the unmerged (conflicted) files, in git's order
---@param root string
---@return string[]
function M.conflicted(root)
    local out = git({ "diff", "--name-only", "--diff-filter=U", "-z" }, root)
    return out and rev.parse_unmerged(out) or {}
end

-- repo-relative paths of untracked files, respecting .gitignore, in git's order
---@param root string
---@return string[]
function M.untracked(root)
    local out = git({ "ls-files", "--others", "--exclude-standard", "-z" }, root)
    return out and rev.parse_paths(out) or {}
end

-- untracked line counts, keyed by repo path and invalidated by the file's own
-- mtime/size. every panel build and every refresh asks for all of them at once, and
-- a file that hasn't moved can't have a different count. wiped wholesale past a cap
-- rather than evicted one by one: the live set is whatever the panel lists, so a
-- table this size is a session that has walked many repos, not a working set
local untracked_counts, untracked_cached = {}, 0
local UNTRACKED_CACHE_MAX = 4096

-- an untracked file has no diff to numstat, so every line reads as an addition;
-- binary content counts as 0, matching how numstat's `-` markers already read
-- binary tracked changes as 0/0. read raw rather than through the clean filter
-- (M.read): eol conversion can't change how many lines there are, and the filter
-- costs three git processes and a loose blob per `\r`-carrying file
---@param root string
---@param relpath string
---@return integer
local function untracked_additions(root, relpath)
    local abs = root .. "/" .. relpath
    local st = (vim.uv or vim.loop).fs_stat(abs)
    if not st then
        return 0
    end
    local key = root .. "\0" .. relpath
    local stamp = ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size)
    local hit = untracked_counts[key]
    if hit and hit.stamp == stamp then
        return hit.additions
    end
    local content = read_file(abs)
    local additions = 0
    if content and not text_util.is_binary(content) then
        additions = #text_util.to_lines(content)
    end
    if untracked_cached >= UNTRACKED_CACHE_MAX then
        untracked_counts, untracked_cached = {}, 0
    end
    if not hit then
        untracked_cached = untracked_cached + 1
    end
    untracked_counts[key] = { stamp = stamp, additions = additions }
    return additions
end

-- whether `relpath` is currently conflicted
---@param root string
---@param relpath string
---@return boolean
function M.is_conflicted(root, relpath)
    for _, p in ipairs(M.conflicted(root)) do
        if p == relpath then
            return true
        end
    end
    return false
end

-- list changed files for a resolved source (used by the picker/panel). rev.source is
-- pure and can't tell a real ref from a typo, so this is the first call that finds
-- out: git's stderr rides along, else a typo reads as an empty change set
---@param source differ.git.Source
---@param root string
---@return differ.git.ChangedFile[] files, string|nil err
function M.changed_files(source, root)
    local args = { "diff", "--name-status", "-z" }
    vim.list_extend(args, rev.diff_args(source))
    local out, err = git(args, root)
    if not out then
        return {}, err
    end
    return rev.parse_name_status(out)
end

-- the commits behind a history request, newest first, plus git's stderr when the
-- run failed. a path with no history exits clean with no output, so an empty list
-- and no error is "nothing to show" rather than a failure. pure arg-building/parsing
-- live in git/log.lua
---@param root string
---@param opts differ.git.LogOpts
---@return differ.git.Commit[] commits, string|nil err
function M.log_commits(root, opts)
    local out, err = git(log.log_args(opts), root)
    return log.parse_log(out or ""), err
end

-- the "old" side for a commit's own diff: its first parent, or the empty tree when
-- it's a root commit (so the commit lists/reads as pure adds). history
---@param root string
---@param sha string
---@return differ.git.Ref
local function parent_or_empty(root, sha)
    local has_parent = git({ "rev-parse", "--verify", "--quiet", sha .. "^" }, root)
    if has_parent then
        return { kind = "rev", rev = sha .. "^", label = sha:sub(1, 7) .. "^" }
    end
    return { kind = "rev", rev = EMPTY_TREE, label = "(root)" }
end

-- the commits in a rev-range, newest first, for branch-range history (dp).
-- `--no-merges` drops merge commits; a symmetric `a...b` range adds `--right-only`
-- to keep only the right side (the branch's own commits), mirroring the dp flow
---@param root string
---@param range string
---@return differ.git.Commit[] commits, string|nil err
function M.range_commits(root, range)
    local extra = vim.split(range, "%s+", { trimempty = true })
    extra[#extra + 1] = "--no-merges"
    if range:find("...", 1, true) then
        extra[#extra + 1] = "--right-only"
    end
    return M.log_commits(root, { extra = extra })
end

-- the files one commit changed, as panel FileEntry[] with +N -M counts (range
-- history): the commit diffed against its parent (or the empty tree for a root commit)
---@param root string
---@param sha string
---@return differ.FileEntry[]
function M.commit_files(root, sha)
    local source = {
        old = parent_or_empty(root, sha),
        new = { kind = "rev", rev = sha, label = sha:sub(1, 7) },
    }
    -- the sha came from git's own log, so there's no revspec here to mistype
    return (M.file_entries(source, root))
end

-- resolve a source's refs to concrete revs (merge_base -> rev). returns nil if a
-- merge-base can't be found. do this once per source, then open each file against
-- the result; the picker and panel both share it
---@param source differ.git.Source
---@param root string
---@return differ.git.Source|nil
function M.resolve(source, root)
    local old = resolve_ref(source.old, root)
    local new = resolve_ref(source.new, root)
    if not (old and new) then
        return nil
    end
    return { old = old, new = new }
end

-- build a DiffModel for one changed file under an already-resolved source.
-- renames read the old side from `previous_path`; an absent side reads as empty.
-- `head` (the current branch) rides along for the synthetic buffer's statusline
---@param source differ.git.Source -- resolved (no merge_base refs)
---@param root string
---@param file { path: string, previous_path?: string } -- only the path(s) are read
---@param head string|nil
---@return differ.DiffModel
function M.model(source, root, file, head)
    local old_path = file.previous_path or file.path
    return require("differ.model.diff").build({
        path = file.path,
        old_rev = source.old.label,
        new_rev = source.new.label,
        old_text = M.read(source.old, root, old_path) or "",
        new_text = M.read(source.new, root, file.path) or "",
        head = head,
        root = root,
    })
end

-- the full commit message (subject + body) for `sha`, for the history details
-- float. read on demand (a keypress), so a synchronous local git call is fine
---@param root string
---@param sha string
---@return string
function M.commit_message(root, sha)
    local out = git({ "show", "-s", "--format=%B", sha }, root)
    return out and chomp(out) or ""
end

-- the current branch name (for the buffer statusline), or nil on a detached HEAD
---@param root string
---@return string|nil
local function head_branch(root)
    local out = git({ "rev-parse", "--abbrev-ref", "HEAD" }, root)
    local name = out and chomp(out) or nil
    return (name and name ~= "HEAD") and name or nil
end

-- the "Showing changes for:" footer label: the user's rev spec, or the
-- resolved HEAD commit for the default uncommitted view (mirrors diffview)
---@param args string[]
---@param root string
---@return string|nil
local function footer_label(args, root)
    if #args == 0 then
        local out = git({ "rev-parse", "HEAD" }, root)
        return out and chomp(out) or nil
    elseif #args == 2 then
        return args[1] .. ".." .. args[2]
    end
    return table.concat(args, " ")
end

-- open the diff for one changed file under an already-resolved source
---@param source differ.git.Source
---@param root string
---@param file differ.git.ChangedFile
---@return differ.View
function M.open_file(source, root, file)
    return require("differ").diff_model(M.model(source, root, file))
end

-- parse a `git diff --numstat -z [...]` run into a path -> counts map. returns an
-- empty map on git failure so callers degrade to zeroed counts
---@param args string[] -- extra args after `diff --numstat -z`
---@param root string
---@return table<string, { additions: integer, deletions: integer }>
local function numstat(args, root)
    local full = { "diff", "--numstat", "-z" }
    vim.list_extend(full, args)
    return rev.parse_numstat(git(full, root) or "")
end

-- the change set as panel FileEntry records: one flat list with `+N -M` counts,
-- used for rev-pair sources. working-tree sources use status_sections instead.
-- `git diff` never lists untracked files regardless of the refs passed to it, so
-- a worktree new-side (branch total, `:Differ <rev>`, ...) unions them in here,
-- with a real line count (see untracked_additions) so they carry their weight in
-- the panel's --stat totals. no overlap to dedupe: untracked means absent from
-- the index, which `changed_files` always reads through, so the two lists are
-- disjoint
---@param source differ.git.Source -- resolved
---@param root string
---@return differ.FileEntry[] entries, string|nil err
function M.file_entries(source, root)
    local files, err = M.changed_files(source, root)
    if err then
        return {}, err -- a failed listing isn't an empty one; the caller reports it
    end
    local counts = numstat(rev.diff_args(source), root)
    local out = {}
    for _, f in ipairs(files) do
        local c = counts[f.path] or {}
        out[#out + 1] = {
            path = f.path,
            status = f.status,
            additions = c.additions or 0,
            deletions = c.deletions or 0,
            previous_path = f.previous_path,
        }
    end
    if source.new.kind == "worktree" then
        for _, path in ipairs(M.untracked(root)) do
            out[#out + 1] = {
                path = path,
                status = "?",
                additions = untracked_additions(root, path),
                deletions = 0,
            }
        end
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
local function union_pairs(root, path, head, index, work)
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
-- a rename's old path, and so is the index for a rename only the worktree has made
-- (` R`), whose entry at the new path is an empty intent-to-add placeholder
---@param root string
---@param entry differ.FileEntry
---@return differ.DiffModel|nil union, differ.DiffModel|nil cached, differ.DiffModel|nil unstaged
function M.union_models(root, entry)
    local prev = entry.previous_path
    local at_head = prev or entry.path
    local at_index = entry.path
    if entry.y == "R" and prev then
        at_index = prev
    end
    local index = M.read(INDEX, root, at_index)
    if not index then
        return nil
    end
    return union_pairs(
        root,
        entry.path,
        M.read(HEAD, root, at_head) or "",
        index,
        M.read(WORKTREE, root, entry.path) or ""
    )
end

-- a porcelain entry's section and the letter its row shows. the section comes from
-- which of the index (X) and the worktree (Y) hold a change; the letter is the change
-- the row's HEAD↔worktree diff shows
---@param s { x: string, y: string }
---@return string section, string status
local function row_of(s)
    if s.x == "?" then
        return "Untracked", "?"
    end
    if s.x == "U" or s.y == "U" or (s.x == s.y and (s.x == "A" or s.x == "D")) then
        return "Conflicts", "U"
    end
    if s.y == " " then
        return "Staged", s.x
    end
    if s.x == " " then
        return "Unstaged", s.y
    end
    if s.y == "D" and s.x ~= "A" then
        return "Partial", "D"
    end
    return "Partial", s.x
end

-- the worktree's porcelain entries, and the set of paths it lists as untracked
---@param root string
---@return differ.git.StatusEntry[] entries, table<string, boolean> untracked, string|nil err
local function porcelain(root)
    local out, err = git({ "status", "--porcelain=v1", "-z", "-uall" }, root)
    local entries = rev.parse_status(out or "")
    local untracked = {}
    for _, s in ipairs(entries) do
        if s.x == "?" then
            untracked[s.path] = true
        end
    end
    return entries, untracked, err
end

-- a panel row for porcelain entry `s`, lettered `status` and counted from `counts`
---@param s differ.git.StatusEntry
---@param status string
---@param counts table<string, { additions: integer, deletions: integer }>
---@param untracked table<string, boolean>
---@return differ.FileEntry
local function status_row(s, status, counts, untracked)
    local c = counts[s.path] or {}
    return {
        path = s.path,
        status = status,
        additions = c.additions or 0,
        deletions = c.deletions or 0,
        x = s.x,
        y = s.y,
        previous_path = s.previous_path,
        kept = (s.x == "D" and untracked[s.path]) or nil,
    }
end

-- working-tree status as panel sections: Staged / Partial / Unstaged / Untracked
-- (slice B). git status compares HEAD/index/worktree, so it only models the
-- default HEAD-vs-worktree source; rev-pair sources use file_entries instead.
-- every changed path takes one row, counted against HEAD since that is the diff it
-- opens. a staged deletion counts against the index: porcelain lists a file removed
-- from the index but still on disk twice (`D ` and `??`), and its one row is the
-- deletion, marked `kept`. empty sections are dropped by the caller
---@param root string
---@return differ.panel.Section[] sections, string|nil err
function M.status_sections(root)
    local entries, untracked, err = porcelain(root)
    local staged_counts = numstat({ "--cached" }, root)
    local head_counts = numstat({ "HEAD" }, root)
    local removed = {}
    for _, s in ipairs(entries) do
        if s.x == "D" then
            removed[s.path] = true
        end
    end
    local rows = { Conflicts = {}, Staged = {}, Partial = {}, Unstaged = {}, Untracked = {} }
    for _, s in ipairs(entries) do
        if not (s.x == "?" and removed[s.path]) then
            local section, status = row_of(s)
            local counts = s.x == "D" and staged_counts or head_counts
            local row = status_row(s, status, counts, untracked)
            if status == "?" then
                row.additions = untracked_additions(root, s.path)
            end
            local list = rows[section]
            list[#list + 1] = row
        end
    end
    local sections = {
        { title = "Conflicts", entries = rows.Conflicts },
        { title = "Staged", entries = rows.Staged },
        { title = "Partial", entries = rows.Partial },
        { title = "Unstaged", entries = rows.Unstaged },
        { title = "Untracked", entries = rows.Untracked },
    }
    return sections, err
end

-- the rows a commit would take, as one section: every path the index changes, counted
-- and lettered against HEAD. conflicts and untracked files hold nothing to commit
---@param root string
---@return differ.panel.Section[] sections, string|nil err
function M.staged_sections(root)
    local entries, untracked, err = porcelain(root)
    local counts = numstat({ "--cached" }, root)
    local rows = {}
    for _, s in ipairs(entries) do
        local section = row_of(s)
        if section ~= "Untracked" and section ~= "Conflicts" and s.x ~= " " then
            rows[#rows + 1] = status_row(s, s.x, counts, untracked)
        end
    end
    return { { title = "Staged changes", entries = rows } }, err
end

-- file-level staging ops driven from the panel (slice C); each is whole-file
-- and operates on the repo root. hunk-level staging stays in the diff view

-- run git and report a failure where the user can see it, returning whether it landed.
-- these wrappers own their own message so callers only ever branch on the boolean: a
-- swallowed failure would leave the panel and the staged marks describing a state git
-- never reached
---@param args string[]
---@param cwd string
---@param what string  -- names the operation in the message
---@return boolean ok
local function git_ok(args, cwd, what)
    local out, err = git(args, cwd) -- nil out is exactly a non-zero exit; stderr can be empty
    if not out then
        notify(("%s failed: %s"):format(what, err or ""), vim.log.levels.ERROR)
        return false
    end
    return true
end

-- point `path`'s index entry at `text`, keeping its mode. the caller has already
-- worked out the exact content the index should hold, so this writes a blob and moves
-- the entry rather than applying a patch: no header to compute, no offset to carry, and
-- nothing that can half-apply. `text` must already be in index domain (M.read runs the
-- worktree side through the clean filter), so the blob is stored verbatim
---@param root string
---@param path string
---@param text string
---@return boolean ok
local function write_index(root, path, text)
    local listed = git({ "ls-files", "-s", "--", path }, root)
    local mode = listed and listed:match("^(%d+)%s")
    if not mode then
        notify(("%s has no index entry to update"):format(path), vim.log.levels.ERROR)
        return false
    end
    local hashed = vim.system({ "git", "hash-object", "-w", "--stdin" }, {
        cwd = root,
        stdin = text,
    }):wait()
    if hashed.code ~= 0 or not hashed.stdout then
        notify(("staging %s failed: %s"):format(path, hashed.stderr or ""), vim.log.levels.ERROR)
        return false
    end
    local spec = ("%s,%s,%s"):format(mode, chomp(hashed.stdout), path)
    return git_ok({ "update-index", "--cacheinfo", spec }, root, "staging " .. path)
end

---@param root string
---@param path string
---@return boolean ok
function M.stage(root, path)
    return git_ok({ "add", "--", path }, root, "stage")
end

---@param root string
---@param path string
---@return boolean ok
function M.unstage(root, path)
    return git_ok({ "reset", "-q", "HEAD", "--", path }, root, "unstage")
end

---@param root string
---@return boolean ok
function M.stage_all(root)
    return git_ok({ "add", "-A" }, root, "stage all")
end

---@param root string
---@return boolean ok
function M.unstage_all(root)
    return git_ok({ "reset", "-q", "HEAD" }, root, "unstage all")
end

-- the paths one entry's staging ops act on: a rename owns both ends of the move, a copy
-- only its new path
---@param entry differ.FileEntry
---@return string[]
local function entry_paths(entry)
    if entry.status == "R" and entry.previous_path then
        return { entry.path, entry.previous_path }
    end
    return { entry.path }
end

-- move every path an entry owns into or out of the index. the panel's file keys and the
-- diff view's whole-file staging share it
---@param root string
---@param entry differ.FileEntry
---@param staged boolean
---@return boolean ok
local function set_staged(root, entry, staged)
    local ok = true
    for _, p in ipairs(entry_paths(entry)) do
        if staged then
            ok = M.stage(root, p) and ok
        else
            ok = M.unstage(root, p) and ok
        end
    end
    return ok
end

-- apply a single-hunk patch, atomically. `--unidiff-zero` because the patch carries
-- no context (built straight from the hunk model); `--reverse` undoes rather than
-- applies. `target` picks the side written: the index for hunk staging, the worktree
-- for hunk revert. never `--index` (both at once), which checks the whole path is in
-- sync and so refuses on any file that has changes on the other side, hunk-unrelated
-- ones included; a revert that must reach both composes two calls instead. git apply
-- is atomic, so a non-applying patch fails cleanly with stderr rather than
-- half-writing. returns ok + git's stderr on failure
---@param root string
---@param text string  -- the unified diff to apply
---@param reverse boolean
---@param target? "index"|"worktree"  -- default "index"
---@param check? boolean  -- only test that it applies, writing nothing
---@return boolean ok, string|nil err
function M.apply_patch(root, text, reverse, target, check)
    local cmd = { "git", "apply", "--unidiff-zero", "--whitespace=nowarn" }
    if (target or "index") == "index" then
        cmd[#cmd + 1] = "--cached"
    end
    if reverse then
        cmd[#cmd + 1] = "--reverse"
    end
    if check then
        cmd[#cmd + 1] = "--check"
    end
    cmd[#cmd + 1] = "-"
    local res = vim.system(cmd, { cwd = root, stdin = text, text = true }):wait()
    if res.code ~= 0 then
        return false, res.stderr
    end
    return true
end

-- an open buffer on a file differ just rewrote keeps showing the old content until
-- something checks: a window switch doesn't, so a revert or discard would sit next to
-- a stale window. checktime reloads it, and leaves a buffer with unsaved edits alone
-- (nvim warns rather than clobbering), so this is safe to fire unconditionally
---@param root string
---@param relpath string
local function reload_buffer(root, relpath)
    local buf = require("differ.util.buf").find(root .. "/" .. relpath)
    if buf and vim.api.nvim_buf_is_loaded(buf) then
        -- silent!: the file may be gone entirely (a discarded untracked file)
        pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("silent! checktime")
        end)
    end
end

-- git_ok's counterpart for the one discard path that isn't a git call
---@param abs string
---@return boolean ok
local function remove_ok(abs)
    local ok, err = os.remove(abs)
    if not ok then
        notify(("discard failed: %s"):format(err or ""), vim.log.levels.ERROR)
        return false
    end
    return true
end

-- the entry's status as git reports it now, or nil when the path has no changes left.
-- the panel's entries are a snapshot taken before the confirm, and the same side of
-- the file the entry came from is the side to re-read
---@param root string
---@param entry differ.FileEntry
---@return string|nil status
local function live_status(root, entry)
    local args = { "status", "--porcelain=v1", "-z", "-uall", "--", entry.path }
    -- git pairs a rename only with both paths in the pathspec; with one it reports an add
    if entry.previous_path then
        args[#args + 1] = entry.previous_path
    end
    local out = git(args, root)
    for _, s in ipairs(rev.parse_status(out or "")) do
        -- a kept deletion's copy on disk is its own `??` line, and not this row's status
        if s.path == entry.path and not (s.x == "?" and entry.kept) then
            return select(2, row_of(s))
        end
    end
    return nil
end

-- the entry's `diff --raw` line under `args`'s pair, or nil when the pair no longer
-- lists it at all. git pairs a rename only with both paths in the pathspec
---@param root string
---@param args string[]
---@param entry differ.FileEntry
---@return string|nil
local function raw_line(root, args, entry)
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

-- the notice a zero-hunk entry opens on, or nil when it's stale (committed, staged
-- away or reverted outside differ) and the caller should re-source instead.
---@param root string
---@param entry differ.FileEntry
---@param model differ.DiffModel
---@param args string[]  -- names the entry's pair for `diff --raw`
---@return string|nil
local function empty_notice(root, entry, model, args)
    local reason = require("differ.model.diff").empty_reason(model)
    local empty_or_not = reason == "empty" and "Empty file" or "No content change"
    if entry.status == "?" then
        return live_status(root, entry) == entry.status and empty_or_not or nil
    end
    local out = raw_line(root, args, entry)
    if not out then
        -- a row changed on both sides whose worktree is back to HEAD: the staged change
        -- is real, it just has no HEAD↔worktree diff to show
        if entry.x ~= " " and entry.y ~= " " and raw_line(root, { "--cached" }, entry) then
            return "Staged changes the worktree has put back"
        end
        return nil
    end
    if (entry.status == "R" or entry.status == "C") and entry.previous_path then
        return ("Renamed from %s, content unchanged"):format(entry.previous_path)
    end
    local old_mode, new_mode = rev.parse_raw_modes(out)
    -- a gitlink has no blob behind it (`git show :path` fails), so both sides read
    -- empty however the pointer moved.
    if old_mode == GITLINK or new_mode == GITLINK then
        if old_mode ~= GITLINK then
            return "Submodule added"
        elseif new_mode ~= GITLINK then
            return "Submodule removed"
        end
        return "Submodule commit changed"
    end
    if old_mode and new_mode and old_mode ~= new_mode then
        return ("Mode changed %s → %s"):format(old_mode, new_mode)
    end
    return empty_or_not
end

-- discard a file's changes: untracked or a staged-add drops the file (unstaging
-- first if needed); anything tracked in HEAD reverts index + worktree to HEAD.
-- destructive, so the panel confirms before calling this. confirm() drains scheduled
-- callbacks while it blocks, so the status the caller holds can have moved under the
-- prompt: the three branches differ in whether they delete the file, so a status that
-- no longer matches refuses rather than picking by the stale one
---@param root string
---@param entry differ.FileEntry
---@return boolean ok
function M.discard(root, entry)
    if live_status(root, entry) ~= entry.status then
        notify(
            ("discard skipped: %s changed since the prompt"):format(entry.path),
            vim.log.levels.WARN
        )
        return false
    end
    -- restoring a staged deletion from HEAD would overwrite the copy still on disk
    if entry.kept then
        local msg = "discard skipped: %s is on disk untracked; u tracks it again"
        notify(msg:format(entry.path), vim.log.levels.WARN)
        return false
    end
    local abs = root .. "/" .. entry.path
    local ok
    if entry.status == "?" then
        ok = remove_ok(abs)
    elseif entry.status == "A" or entry.status == "C" then
        -- unstage the add before dropping the file, and don't drop it if that failed:
        -- the index would keep an add for a file no longer on disk. a copy's source is
        -- untouched, so its new path is an add
        ok = git_ok({ "reset", "-q", "HEAD", "--", entry.path }, root, "discard") and remove_ok(abs)
    elseif entry.status == "R" and entry.previous_path then
        -- undoing a move: the old path comes back from HEAD, the new one goes like an add
        ok = git_ok({ "checkout", "HEAD", "--", entry.previous_path }, root, "discard")
            and git_ok({ "reset", "-q", "HEAD", "--", entry.path }, root, "discard")
            and remove_ok(abs)
    else
        ok = git_ok({ "checkout", "HEAD", "--", entry.path }, root, "discard") -- index + worktree
    end
    if not ok then
        return false
    end
    reload_buffer(root, entry.path)
    if entry.previous_path then
        reload_buffer(root, entry.previous_path) -- back on disk, so a buffer on it is stale
    end
    return true
end

-- drop empty sections so the panel never shows a bare "Staged (0)" header; returns
-- the kept sections and their total entry count
---@param sections differ.panel.Section[]
---@return differ.panel.Section[] nonempty, integer total
local function nonempty_sections(sections)
    local out, total = {}, 0
    for _, sec in ipairs(sections) do
        if #sec.entries > 0 then
            out[#out + 1] = sec
            total = total + #sec.entries
        end
    end
    return out, total
end

-- the repo to operate on: the current file's repo if it's a real file, else cwd
---@return string|nil
local function repo_root()
    local file = vim.api.nvim_buf_get_name(0)
    local anchor = (file ~= "" and vim.fn.filereadable(file) == 1) and file or vim.fn.getcwd()
    return M.root(anchor)
end

-- true when `source` is the default HEAD-vs-worktree view: the only source git
-- status can model as Staged/Unstaged/Untracked sections (slice B). rev-pair
-- and merge-base sources (old is a sha, not HEAD) stay a single counted list
---@param source differ.git.Source -- resolved
---@return boolean
local function is_worktree_status(source)
    return source.old.kind == "rev" and source.old.rev == "HEAD" and source.new.kind == "worktree"
end

-- the configured base branch resolved to a ref, for the `base` shortcut.
-- explicit config wins; else the remote's default (origin/HEAD -> "origin/main");
-- else the first of main/master that exists. nil when none resolve
---@param root string
---@return string|nil
local function base_ref(root)
    local cfg = require("differ").get_config()
    if cfg.base and cfg.base ~= "" then
        return cfg.base
    end
    local out = git({ "rev-parse", "--abbrev-ref", "origin/HEAD" }, root)
    if out then
        return chomp(out) -- e.g. "origin/main"
    end
    for _, name in ipairs({ "main", "master" }) do
        if git({ "rev-parse", "--verify", "--quiet", name }, root) then
            return name
        end
    end
    return nil
end

-- repo root + resolved base for the `base` shortcut, notifying on failure. returns
-- the base ref the caller suffixes (`...HEAD` for log, `...` for diff), or nil
---@return string|nil
function M.resolve_base()
    local root = repo_root()
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    local base = base_ref(root)
    if not base then
        return notify("couldn't resolve a base branch (set `base` in config)", vim.log.levels.WARN)
    end
    return base
end

-- :Differ panel: open the file panel over a git change set (opts.toggle hides/shows
-- a live one). selecting a file re-sources the one View in place rather than spawning a new
-- one. `opts.rev` is the rev spec; position/listing/height/width pass through to
-- the panel and are runtime-adjustable via Panel.current(). `opts.open_first`
-- selects the first file straight away (DiffviewOpen-style: bare `:Differ`)
---@class differ.git.PanelOpts
---@field rev? string|string[]
---@field position? string
---@field listing? string
---@field height? integer
---@field width? integer
---@field open_first? boolean
---@field supersede? boolean  -- close a live session and reopen (`:Differ <rev>` idempotency)
---@field toggle? boolean  -- `:Differ panel`: hide/show the live sidebar in place
---@param opts differ.git.PanelOpts
---@return differ.Panel|nil
function M.panel(opts)
    local Panel = require("differ.panel")
    -- a live session, by gesture: `:Differ <rev>` (opts.supersede) re-runs idempotently —
    -- close the session and open a fresh diff of the new rev. `:Differ panel` (opts.toggle)
    -- hides/shows the sidebar in place. a bare `:Differ` just (re)opens — reveal a hidden
    -- sidebar and focus it, a no-op when already open, never toggling it shut. `:Differ
    -- close` ends the session
    local has_rev = (type(opts.rev) == "string" and opts.rev ~= "")
        or (type(opts.rev) == "table" and #opts.rev > 0)
    if opts.supersede then
        -- a log/history session isn't a Panel, so it's invisible to the check below;
        -- `opts.supersede` is set for both a bare `:Differ` and `:Differ <rev>` (unlike
        -- the has_rev-gated Panel branch, there's no "reveal" reading for History: it
        -- has no show/toggle). without this, either gesture leaves a live log session
        -- open, and its lingering `History.current()` then makes an unrelated view's
        -- goto_hunk think it's still inside a single-commit history diff (in_history
        -- stays true)
        local history = require("differ.history").current()
        if history then
            history:close() -- close cascades to the diff view + session tab; current = nil
        end
    end
    local existing = Panel.current()
    if existing then
        if opts.supersede and has_rev then
            existing:close() -- close cascades to the diff view + session tab; current = nil
        elseif opts.toggle then
            existing:toggle()
            return existing
        else
            existing:show() -- reveal if hidden; no-op if already open
            if existing:is_open() then
                vim.api.nvim_set_current_win(existing.winid)
            end
            return existing
        end
    end

    -- the file + position :Differ was invoked from, so open_first can open that file at
    -- that position (mapped into the diff) instead of the first listed file
    local origin_file = vim.api.nvim_buf_get_name(0)
    local origin_line, origin_col = unpack(vim.api.nvim_win_get_cursor(0))

    local root = repo_root()
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    -- repo-relative origin path; resolve symlinks so the prefix strip lines up with
    -- git's realpath toplevel (as M.history does), and only when the file is under it
    local origin_rel ---@type string|nil
    if origin_file ~= "" and vim.fn.filereadable(origin_file) == 1 then
        local resolved = vim.fn.resolve(origin_file)
        if resolved:sub(1, #root + 1) == root .. "/" then
            origin_rel = resolved:sub(#root + 2)
        end
    end
    -- normalise the rev spec to an arg list (bind to a local so type() narrows it)
    local rev_opt = opts.rev
    local args ---@type string[]
    if type(rev_opt) == "table" then
        args = rev_opt
    elseif rev_opt then
        args = { rev_opt }
    else
        args = {}
    end
    local source = M.resolve(rev.source(args), root)
    if not source then
        return
    end
    local branch = head_branch(root) -- once per source, for the buffer statuslines

    -- model_for picks the (old, new) pair per entry: a working-tree row diffs
    -- HEAD↔worktree, which staging never moves, while a rev-pair list diffs every entry
    -- against the one resolved source. a staged deletion diffs HEAD↔index, since its
    -- worktree copy is a row of its own. `actions` (file-level staging) is only
    -- meaningful for the worktree-status source
    local preview = false -- gs: the panel lists only what a commit would take
    local sections, model_for, raw_args_for, actions
    local list_err ---@type string|nil -- git's own words when the listing failed
    if is_worktree_status(source) then
        sections, list_err = M.status_sections(root)
        model_for = function(entry)
            local s = { old = HEAD, new = (preview or entry.x == "D") and INDEX or WORKTREE }
            -- re-read HEAD per build so a branch switch under an open panel updates
            -- the synthetic buffer's statusline label, not just the diff content
            return M.model(s, root, entry, head_branch(root))
        end
        -- the entry's own pair as `diff` args
        raw_args_for = function(entry)
            return (preview or entry.x == "D") and { "--cached" } or { "HEAD" }
        end
        actions = {
            stage = function(entry)
                if preview then
                    notify("the commit preview only unstages: gs goes back", vim.log.levels.WARN)
                    return false
                end
                set_staged(root, entry, true)
            end,
            unstage = function(entry)
                set_staged(root, entry, false)
            end,
            stage_all = function()
                if preview then
                    notify("the commit preview only unstages: gs goes back", vim.log.levels.WARN)
                    return false
                end
                M.stage_all(root)
            end,
            unstage_all = function()
                M.unstage_all(root)
            end,
            discard = function(entry)
                M.discard(root, entry)
            end,
            reload = function()
                local live = preview and M.staged_sections(root) or M.status_sections(root)
                return (nonempty_sections(live))
            end,
        }
    else
        local entries
        entries, list_err = M.file_entries(source, root)
        sections = { { title = "Changes", entries = entries } }
        model_for = function(entry)
            return M.model(source, root, entry, branch)
        end
        raw_args_for = function()
            return rev.diff_args(source)
        end
    end

    local nonempty, total = nonempty_sections(sections)
    if total == 0 then
        -- an empty list and a failed one look the same from here, and a mistyped
        -- revspec only ever lands as the second: report what git said
        if list_err then
            return notify(chomp(list_err), vim.log.levels.ERROR)
        end
        return notify("no changes for this source")
    end

    local view ---@type differ.View|nil -- the single diff view the panel drives
    local panel ---@type differ.Panel|nil -- forward ref so staging can refresh it
    local watcher ---@type differ.git.Watcher|nil -- fs watcher, set for worktree panels
    local retarget_view ---@type fun(outside: boolean): boolean -- assigned below
    local set_preview ---@type fun(on: boolean) -- assigned below

    -- hunk-level staging. content edits stage by hunk; anything with no lines to stage
    -- sets `whole_file`. `apply` stages one hunk, or unstages it with `reverse`
    local stageable = is_worktree_status(source)
    local active_entry ---@type differ.FileEntry|nil -- the file the view currently shows

    -- a cheap fingerprint of the diff's inputs: HEAD + porcelain status + the shown
    -- file's index blobs (the index side) + its mtime/size (the worktree side). external
    -- refreshes act only when it moved, so a stray event doesn't re-source over an
    -- in-progress in-differ staging session, and a differ stage records it so the index
    -- write it caused doesn't read as outside
    local function git_signature()
        if not stageable then
            return ""
        end
        local sig = (git({ "rev-parse", "HEAD" }, root) or "")
            .. "\0"
            .. (git({ "status", "--porcelain=v1", "-z", "-uall" }, root) or "")
        if active_entry then
            -- a partial stage that leaves the row MM moves only the blob
            local blobs = { "ls-files", "-s", "--", active_entry.path, active_entry.previous_path }
            sig = sig .. "\0" .. (git(blobs, root) or "")
            local st = (vim.uv or vim.loop).fs_stat(root .. "/" .. active_entry.path)
            if st and st.mtime then
                sig = sig .. "\0" .. st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size
            end
        end
        return sig
    end
    local last_sig = git_signature()
    -- record the state the list now reflects, so the next external event doesn't read an
    -- in-differ op as an outside change and re-source over the in-place staged marks.
    -- wired as the panel's on_refresh, which is the one point every reload passes through:
    -- the panel's own staging keys never come through refresh_panel, and used to leave the
    -- signature stale enough that the watcher tore down an in-progress hunk review
    local function record_state()
        last_sig = git_signature()
    end
    local function refresh_panel()
        if panel then
            panel:refresh() -- fires on_refresh -> record_state
        else
            record_state()
        end
    end
    -- bring a deleted file back. a staged deletion is recorded in the index, so only
    -- HEAD still has the content; an unstaged one is still in the index, so restoring
    -- from HEAD instead would silently drop edits staged before the delete. a staged
    -- deletion whose file is still on disk would have that copy overwritten, so it refuses
    ---@param entry differ.FileEntry
    ---@return boolean
    local function restore_deleted(entry)
        if entry.kept then
            local msg = "%s is on disk untracked; u tracks it again"
            notify(msg:format(entry.path), vim.log.levels.WARN)
            return false
        end
        local cmd = entry.x == "D" and { "checkout", "HEAD", "--", entry.path }
            or { "checkout", "--", entry.path }
        local _, err = git(cmd, root)
        if err then
            notify(("restore failed: %s"):format(err), vim.log.levels.ERROR)
            return false
        end
        reload_buffer(root, entry.path)
        return true
    end

    -- the indices of the hunks in `hunks` that do (or don't) meet `anchor`
    ---@param hunks differ.Hunk[]
    ---@param side "old"|"new"  -- the side of `hunks` compared
    ---@param anchor differ.Hunk
    ---@param anchor_side "old"|"new"
    ---@param want boolean  -- true picks the hunks that meet it, false the rest
    ---@return table<integer, boolean>
    local function select_hunks(hunks, side, anchor, anchor_side, want)
        local meets = require("differ.model.marks").meets
        local applied = {}
        for i, h in ipairs(hunks) do
            applied[i] = meets(h, side, anchor, anchor_side) == want
        end
        return applied
    end

    -- write `text` as `entry`'s staged content. an add left with nothing staged leaves
    -- the index, and a rename only the worktree has made is staged along with its
    -- content; both change the row's status, so the view re-sources onto it
    ---@param entry differ.FileEntry
    ---@param text string
    ---@return boolean ok
    local function put_index(entry, text)
        if entry.x == "A" and text == "" then
            if not M.unstage(root, entry.path) then
                return false
            end
            vim.schedule(function()
                retarget_view(false)
            end)
            return true
        end
        if not write_index(root, entry.path, text) then
            return false
        end
        if entry.y == "R" and entry.previous_path then
            local drop = { "update-index", "--force-remove", "--", entry.previous_path }
            if not git_ok(drop, root, "staging " .. entry.path) then
                return false
            end
            vim.schedule(function()
                retarget_view(false)
            end)
        end
        return true
    end

    -- whether the index holds a mode change the HEAD↔worktree diff can't show: staged,
    -- then put back in the worktree
    ---@param entry differ.FileEntry
    ---@return boolean
    local function mode_hidden(entry)
        local cached = raw_line(root, { "--cached" }, entry)
        local unstaged = raw_line(root, {}, entry)
        if not (cached and unstaged) then
            return false
        end
        local head_mode, index_mode = rev.parse_raw_modes(cached)
        local _, work_mode = rev.parse_raw_modes(unstaged)
        return index_mode ~= head_mode and index_mode ~= work_mode
    end

    -- an op built on a failed index read would write the file's index from nothing
    ---@param entry differ.FileEntry
    ---@return false
    local function index_unreadable(entry)
        notify(("couldn't read %s from the index"):format(entry.path), vim.log.levels.WARN)
        return false
    end

    -- staging for a row shown as HEAD↔worktree. both directions work out the content
    -- the index should hold and write it whole rather than patching: staging a hunk
    -- means the index takes the worktree's version of the lines it covers, and
    -- unstaging means the index keeps every staged change except those. each op reads
    -- the pairs once and re-marks from the text it wrote
    ---@param entry differ.FileEntry
    ---@return differ.view.Staging
    local function union_staging(entry)
        local marks = require("differ.model.marks")
        local splice = require("differ.model.apply").splice
        local join = require("differ.model.apply").join
        local mode_why ---@type string|nil
        if entry.x ~= " " and entry.y ~= " " and mode_hidden(entry) then
            mode_why = "the index holds a mode change"
        end
        ---@type differ.view.Staging
        local staging = { marks = { old = {}, new = {} }, refresh = refresh_panel }

        -- the index's lines at each union hunk, and the union with a last line and its
        -- ending read as one (apply.ended). the blocks are nil unless the index holds
        -- every unchanged line between them and rejoins to exactly its own text
        ---@param union differ.DiffModel
        ---@param cached differ.DiffModel
        ---@return string[][]|nil blocks, differ.DiffModel ended
        local function index_blocks(union, cached)
            local ended_lines = require("differ.util.text").ended_lines
            local ended = require("differ.model.apply").ended(union)
            local index = cached.new_text
            local blocks =
                marks.blocks(ended.hunks, ended_lines(union.old_text), ended_lines(index))
            if not blocks or join(ended, blocks) ~= index then
                return nil, ended
            end
            return blocks, ended
        end

        -- the view keeps staging.marks, so a re-mark writes through it. marks come from
        -- the index's own lines at each hunk, and from the two pairs only when the index
        -- changes a line between hunks
        ---@param union differ.DiffModel|nil  -- nil keeps the marks there are
        ---@param cached differ.DiffModel|nil
        ---@param unstaged differ.DiffModel|nil
        local function remark(union, cached, unstaged)
            if not (union and cached and unstaged) then
                return
            end
            staging.hidden_in = nil
            local blocks, ended = index_blocks(union, cached)
            local held, hidden_in = nil, {} ---@type differ.model.Marks|nil, integer[]
            if blocks then
                held, hidden_in = marks.of_blocks(ended.hunks, blocks)
            end
            if held then
                staging.marks.old, staging.marks.new = held.old, held.new
                staging.hidden = mode_why
                if not mode_why and #hidden_in > 0 then
                    staging.hidden = "the index holds a line neither HEAD nor the worktree has"
                    staging.hidden_in = hidden_in
                end
                return
            end
            local fresh = marks.classify(union.hunks, cached.hunks, unstaged.hunks)
            staging.marks.old, staging.marks.new = fresh.old, fresh.new
            local complete, why = marks.complete(union.hunks, cached.hunks, unstaged.hunks)
            if mode_why then
                staging.hidden = mode_why
            elseif complete then
                staging.hidden = nil
            else
                staging.hidden = why
                local head = require("differ.util.text").to_lines(union.old_text)
                staging.hidden_in = marks.hidden_in(head, union.hunks, cached.hunks, fresh)
            end
        end

        -- a pair hunk that also reaches another union hunk holds index-only content
        -- between the two, and taking it whole would carry the op into that hunk
        ---@param union differ.DiffModel
        ---@param pair differ.DiffModel  -- index↔worktree on the new side, HEAD↔index on the old
        ---@param side "old"|"new"
        ---@param hunk differ.Hunk
        ---@return boolean
        local function shared(union, pair, side, hunk)
            local other = marks.shared_with(union.hunks, hunk, pair.hunks, side)
            if not other then
                return false
            end
            local msg = "this hunk's staged change also covers hunk %d: "
                .. "u on the ! hunk in dw, or in gs, unstages it whole"
            if side == "new" then
                msg = "this hunk's unstaged change also covers hunk %d: s in dw stages it whole"
            end
            notify(msg:format(other), vim.log.levels.WARN)
            return true
        end

        -- where `hunk` sits in a fresh read of the union, by its line ranges
        ---@param union differ.DiffModel
        ---@param hunk differ.Hunk
        ---@return integer|nil
        local function hunk_index(union, hunk)
            for i, u in ipairs(union.hunks) do
                if
                    u.old_start == hunk.old_start
                    and u.old_count == hunk.old_count
                    and u.new_start == hunk.new_start
                    and u.new_count == hunk.new_count
                then
                    return i
                end
            end
            return nil
        end

        -- the text the index takes when `hunk` is staged (`take`) or unstaged, or nil
        -- when the op would reach another hunk. the index's lines at the hunk become the
        -- hunk's new or old lines; an index that changes a line between hunks moves by
        -- the pair hunks meeting it on the side that pair shares
        ---@param union differ.DiffModel
        ---@param cached differ.DiffModel
        ---@param unstaged differ.DiffModel
        ---@param hunk differ.Hunk
        ---@param take boolean
        ---@return string|nil
        local function next_index(union, cached, unstaged, hunk, take)
            local blocks, ended = index_blocks(union, cached)
            local i = hunk_index(union, hunk)
            if blocks and i then
                blocks[i] = ended.hunks[i].old_lines
                if take then
                    blocks[i] = ended.hunks[i].new_lines
                end
                return join(ended, blocks)
            end
            local from, side = unstaged, "new"
            if not take then
                from, side = cached, "old"
            end
            if shared(union, from, side, hunk) then
                return nil
            end
            return splice(from, select_hunks(from.hunks, side, hunk, side, take))
        end

        -- whether the diff still shows the file as it is. one drawn before the file or
        -- HEAD moved would place an op by stale line numbers, so it refuses and re-reads
        ---@param model differ.DiffModel  -- the view's
        ---@param union differ.DiffModel  -- read fresh
        ---@return boolean
        local function drawn_current(model, union)
            if model.old_text == union.old_text and model.new_text == union.new_text then
                return true
            end
            notify("the file changed since the diff was drawn: re-reading", vim.log.levels.WARN)
            vim.schedule(function()
                refresh_panel()
                retarget_view(false)
            end)
            return false
        end

        remark(M.union_models(root, entry))
        staging.apply = function(model, hunk, reverse)
            if not hunk then
                return false
            end
            local union, cached, unstaged = M.union_models(root, entry)
            if not (union and cached and unstaged) then
                return index_unreadable(entry)
            end
            if not drawn_current(model, union) then
                return false
            end
            local text = next_index(union, cached, unstaged, hunk, not reverse)
            if not text or not put_index(entry, text) then
                return false
            end
            remark(union_pairs(root, entry.path, union.old_text, text, union.new_text))
            return true
        end
        -- X throws the hunk away on both sides at once: the index gives up whatever of
        -- it it holds and the worktree gives up the rest. the worktree half is checked
        -- first, so a file that changed those lines refuses before the index moves. it
        -- goes through a patch, not a write: the model's new side was read through the
        -- clean filter, so writing it back would push that conversion to disk
        staging.revert = function(model, idx)
            local union, cached, unstaged = M.union_models(root, entry)
            if not (union and cached and unstaged) then
                return index_unreadable(entry)
            end
            if not drawn_current(model, union) then
                return false
            end
            local hunk = model.hunks[idx]
            local text = next_index(union, cached, unstaged, hunk, false)
            if not text then
                return false
            end
            local p = patch.hunk(model.path, hunk, model.old_text, model.new_text, 0, "new")
            if not M.apply_patch(root, p, true, "worktree", true) then
                notify("the file has changed these lines: nothing reverted", vim.log.levels.WARN)
                return false
            end
            if text ~= cached.new_text and not put_index(entry, text) then
                return false
            end
            local ok, err = M.apply_patch(root, p, true, "worktree")
            reload_buffer(root, entry.path)
            if not ok then
                notify(("hunk revert failed: %s"):format(err or ""), vim.log.levels.ERROR)
                remark(M.union_models(root, entry))
                return false
            end
            local work = require("differ.model.diff").revert_hunk(model, idx).new_text
            remark(union_pairs(root, entry.path, union.old_text, text, work))
            return true
        end
        -- S and U: the index takes the worktree's or HEAD's text whole, staged content no
        -- hunk shows included. the entry's mode is left as it is
        staging.set_all = function(model, staged)
            local union, cached = M.union_models(root, entry)
            if not (union and cached) then
                return index_unreadable(entry)
            end
            if not drawn_current(model, union) then
                return false
            end
            local text = union.old_text
            if staged then
                text = union.new_text
            end
            if text == cached.new_text or not put_index(entry, text) then
                return false
            end
            remark(union_pairs(root, entry.path, union.old_text, text, union.new_text))
            return true
        end
        return staging
    end

    -- a whole-file row's staged state, from its status letters
    ---@param entry differ.FileEntry
    ---@return differ.model.HunkState
    local function row_state(entry)
        if entry.x == " " or entry.x == "?" then
            return "unstaged"
        end
        if entry.y == " " then
            return "staged"
        end
        return "partial"
    end

    ---@param entry differ.FileEntry
    ---@param diff differ.DiffModel  -- the entry's built model; only its hunk count is read
    ---@return differ.view.Staging|nil
    local function stage_for(entry, diff)
        if not stageable then
            return nil
        end
        -- git records no rename, only the old path gone from the index and the new one
        -- present, so a hunk stages an ordinary blob and the move rides along untouched.
        -- the move is whole-file and belongs to the panel row's keys
        local content = entry.status == "M" or entry.status == "R" or entry.status == "C"
        local added = entry.status == "A" and entry.x == "A"
        if (content or added) and entry.x ~= "D" and #diff.hunks > 0 then
            local staging = union_staging(entry)
            if added then
                -- throwing away an add is deleting the file, not reverting a hunk of it
                staging.revert = function()
                    return M.discard(root, entry)
                end
                staging.revert_label = "deletes the file"
            end
            return staging
        end
        -- whole-file from here: no lines to stage (a mode change, a submodule pointer, a
        -- binary file, a change git normalises away, a bare rename or copy), or a file
        -- added, untracked or deleted as one unit
        ---@type differ.view.Staging
        local staging = {
            initial = row_state(entry),
            whole_file = true,
            apply = function(_, _, reverse)
                return set_staged(root, entry, not reverse)
            end,
            refresh = refresh_panel,
        }
        if content then
            return staging
        end
        if entry.status == "?" or entry.status == "A" then
            -- `discard` drops the staged add before removing the file
            staging.revert = function()
                return M.discard(root, entry)
            end
            staging.revert_label = "deletes the file"
            return staging
        end
        if entry.status == "D" then
            staging.revert = function()
                return restore_deleted(entry)
            end
            staging.revert_label = "restores the file"
            return staging
        end
        return nil
    end

    -- a row with a staged change and more on top of it: the one kind with a local view
    ---@param entry differ.FileEntry
    ---@return boolean
    local function partly_staged(entry)
        if entry.status == "U" or entry.x == "?" or entry.y == "D" then
            return false
        end
        return entry.x ~= " " and entry.y ~= " "
    end

    -- staging frozen at the index the view opened on: s and u rewrite the index as the
    -- model's old side plus the hunks marked staged, so a marked hunk stays on screen
    -- and the opposite key puts it back. an index written outside differ since then
    -- would be overwritten by that rebuild, so s and u refuse and `reopen` re-reads
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel  -- read once, with at least one hunk
    ---@param staged boolean  -- every hunk's opening state
    ---@param reopen fun()
    ---@return differ.view.Staging
    local function frozen_staging(entry, model, staged, reopen)
        local splice = require("differ.model.apply").splice
        local state = require("differ.model.marks").state
        -- the commit preview opens staged with the index as its new side; the local view
        -- opens unstaged with it as its old side
        local held = staged and model.new_text or model.old_text
        -- a rename only the worktree has made leaves the index at the old path
        local at_index = entry.y == "R" and entry.previous_path or entry.path
        local marks = { old = {}, new = {} }
        ---@param h differ.Hunk
        ---@param on boolean
        local function mark(h, on)
            for l = h.old_start, h.old_start + h.old_count - 1 do
                marks.old[l] = on
            end
            for l = h.new_start, h.new_start + h.new_count - 1 do
                marks.new[l] = on
            end
        end
        for _, h in ipairs(model.hunks) do
            mark(h, staged)
        end
        return {
            marks = marks,
            refresh = refresh_panel,
            apply = function(_, hunk, reverse)
                if not hunk then
                    return false
                end
                if (M.read(INDEX, root, at_index) or "") ~= held then
                    notify("the index changed outside differ: re-reading", vim.log.levels.WARN)
                    vim.schedule(reopen)
                    return false
                end
                mark(hunk, not reverse)
                local applied = {}
                for i, h in ipairs(model.hunks) do
                    applied[i] = state(marks, h) == "staged"
                end
                local text = splice(model, applied)
                if put_index(entry, text) then
                    held, at_index = text, entry.path -- put_index stages a rename at the new path
                    return true
                end
                mark(hunk, reverse)
                return false
            end,
        }
    end

    -- whole-file staging frozen at the index the view opened on: u resets the row's
    -- paths to HEAD, s puts back the entries the index held then
    ---@param entry differ.FileEntry
    ---@return differ.view.Staging
    local function snapshot_staging(entry)
        local paths = entry_paths(entry)
        local held = {} ---@type table<string, string> -- path -> update-index cacheinfo
        local listed = git(vim.list_extend({ "ls-files", "-s", "-z", "--" }, paths), root) or ""
        for mode, sha, path in listed:gmatch("(%d+) (%x+) %d+\t([^%z]+)") do
            held[path] = ("%s,%s,%s"):format(mode, sha, path)
        end
        return {
            initial = "staged",
            whole_file = true,
            refresh = refresh_panel,
            apply = function(_, _, reverse)
                if reverse then
                    return set_staged(root, entry, false)
                end
                local ok = true
                for _, path in ipairs(paths) do
                    local cmd = { "update-index", "--force-remove", "--", path }
                    if held[path] then
                        cmd = { "update-index", "--add", "--cacheinfo", held[path] }
                    end
                    ok = git_ok(cmd, root, "staging " .. path) and ok
                end
                return ok
            end,
        }
    end

    -- X in a frozen view (the commit preview, the local view): the hunk leaves the index
    -- if marked staged, and the file takes its old lines back. the file half is checked
    -- first, so a file that changed those lines refuses before the index moves; then
    -- `reopen` re-reads the view. a last hunk leaves nothing to reopen, and the view
    -- hands over to the panel itself
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel
    ---@param staging differ.view.Staging
    ---@param idx integer
    ---@param offset integer  -- the model's new-side lines to the file's, see patch.hunk
    ---@param reopen fun()
    ---@return boolean
    local function revert_frozen(entry, model, staging, idx, offset, reopen)
        local hunk = model.hunks[idx]
        local p = patch.hunk(model.path, hunk, model.old_text, model.new_text, offset, "new")
        if not M.apply_patch(root, p, true, "worktree", true) then
            notify("the file has changed these lines: nothing reverted", vim.log.levels.WARN)
            return false
        end
        local marked = require("differ.model.marks").state(staging.marks, hunk) == "staged"
        if marked and not (staging.apply and staging.apply(model, hunk, true)) then
            return false
        end
        local ok, err = M.apply_patch(root, p, true, "worktree")
        reload_buffer(root, entry.path)
        if not ok then
            notify(("hunk revert failed: %s"):format(err or ""), vim.log.levels.ERROR)
            return false
        end
        if #model.hunks > 1 then
            vim.schedule(function()
                if view and view.staging == staging then
                    reopen()
                end
            end)
        end
        return true
    end

    -- X on a whole-file commit-preview row, and what it does to the file
    ---@param entry differ.FileEntry
    ---@return fun(): boolean revert, string label
    local function whole_file_revert(entry)
        local label = "puts it back as HEAD has it"
        local revert = function()
            return M.discard(root, entry)
        end
        if entry.x == "D" then
            label = "restores the file"
            revert = function()
                return restore_deleted(entry)
            end
        elseif entry.x == "A" then
            label = "deletes the file"
        end
        return revert, label
    end

    -- staging for a commit-preview row, HEAD↔index. an add or a deletion is one unit
    -- whose index entry comes and goes, so it stages as a file
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel  -- HEAD↔index
    ---@return differ.view.Staging
    local function preview_staging(entry, model)
        local staging
        if #model.hunks > 0 and entry.x ~= "A" and entry.x ~= "D" then
            staging = frozen_staging(entry, model, true, function()
                retarget_view(false)
            end)
            -- the model's new side is the index, so its lines move by whatever the
            -- worktree has added or dropped above them since
            staging.revert = function(m, idx)
                local h = m.hunks[idx]
                local _, _, unstaged = M.union_models(root, entry)
                if not unstaged then
                    return index_unreadable(entry)
                end
                local at = h.new_count > 0 and h.new_start or h.new_start + 1
                local offset = require("differ.model.marks").shift(unstaged.hunks, at, "old")
                return revert_frozen(entry, m, staging, idx, offset, function()
                    retarget_view(false)
                end)
            end
        else
            staging = snapshot_staging(entry)
            staging.revert, staging.revert_label = whole_file_revert(entry)
        end
        staging.badge = "STAGED"
        staging.no_local = "the commit preview has no local view: gs goes back"
        staging.leave = function()
            set_preview(false)
        end
        return staging
    end

    local show_local ---@type fun(entry: differ.FileEntry)

    -- u on a `!` hunk in the local view: the index takes HEAD's lines under it, dropping
    -- the staged change the worktree undid, then the view re-reads against that index.
    -- the hunk's lines are the index's at open, moved by whatever s has staged since
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel  -- index↔worktree, as the view opened on it
    ---@param staging differ.view.Staging
    ---@param idx integer
    ---@return boolean
    local function drop_hidden(entry, model, staging, idx)
        local marks = require("differ.model.marks")
        local splice = require("differ.model.apply").splice
        local applied, moved = {}, {} ---@type table<integer, boolean>, differ.Hunk[]
        for i, h in ipairs(model.hunks) do
            applied[i] = marks.state(staging.marks, h) == "staged"
            if applied[i] then
                moved[#moved + 1] = h
            end
        end
        local _, cached = M.union_models(root, entry)
        if not cached then
            return index_unreadable(entry)
        end
        if cached.new_text ~= splice(model, applied) then
            notify("the index changed outside differ: re-reading", vim.log.levels.WARN)
            vim.schedule(function()
                show_local(entry)
            end)
            return false
        end
        local hunk = model.hunks[idx]
        local placed = vim.tbl_extend("force", hunk, {
            old_start = hunk.old_start + marks.shift(moved, hunk.old_start, "old"),
        })
        local keep = select_hunks(cached.hunks, "new", placed, "old", false)
        if not put_index(entry, splice(cached, keep)) then
            return false
        end
        refresh_panel()
        show_local(entry)
        return true
    end

    -- swap the open view onto `entry`'s local view, index↔worktree. back goes through
    -- retarget_view, which re-reads the row, since staging here can move it to another
    -- section
    ---@param entry differ.FileEntry
    show_local = function(entry)
        if not (view and view:is_open()) then
            return
        end
        local focus_line, focus_col = view:cursor_new_line()
        -- a rename only the worktree has made leaves the index at the old path
        local at_index = entry.y == "R" and entry.previous_path or nil
        local file = { path = entry.path, status = entry.status, previous_path = at_index }
        local model = M.model({ old = INDEX, new = WORKTREE }, root, file, head_branch(root))
        local staging ---@type differ.view.Staging
        if #model.hunks > 0 then
            staging = frozen_staging(entry, model, false, function()
                show_local(entry)
            end)
            local _, cached = M.union_models(root, entry)
            if cached then
                staging.hidden_in =
                    require("differ.model.marks").restaged(model.hunks, cached.hunks)
            end
            staging.unstage_hidden = function(idx)
                return drop_hidden(entry, model, staging, idx)
            end
            staging.revert = function(m, idx)
                return revert_frozen(entry, m, staging, idx, 0, function()
                    show_local(entry)
                end)
            end
        else
            if not model.binary then
                model.notice = empty_notice(root, entry, model, {}) or "No local content change"
            end
            staging = { refresh = refresh_panel }
        end
        local function back()
            retarget_view(false)
        end
        staging.badge, staging.toggle_local, staging.leave = "LOCAL", back, back
        local focus = focus_line and { focus_line = focus_line, focus_col = focus_col } or nil
        view:set_source(model, staging, focus)
        last_sig = git_signature()
    end

    -- (re)source the diff view from an entry's current git state. false when the
    -- entry has no diff anymore (committed / fully staged / reverted outside differ).
    -- `source_opts` goes to View:set_source when the view is open
    ---@param entry differ.FileEntry
    ---@param source_opts? differ.view.SourceOpts
    ---@return boolean shown
    local function show_entry(entry, source_opts)
        local model = model_for(entry)
        if #model.hunks == 0 and not model.binary then
            -- a real change with no lines to show (a mode change, a rename, a final
            -- newline, an empty new file) opens on a notice, like a binary file does;
            -- a stale entry has no notice and tells the caller to re-source
            local notice = empty_notice(root, entry, model, raw_args_for(entry))
            if not notice then
                return false
            end
            model.notice = notice
        end
        if entry.status == "U" then
            model.banner = "conflicted: resolve with :Differ mergetool"
        elseif entry.kept then
            model.banner = "still on disk, untracked: u tracks it again"
        end
        local staging ---@type differ.view.Staging|nil
        if preview then
            staging = preview_staging(entry, model)
        else
            staging = stage_for(entry, model)
        end
        if staging and not preview and partly_staged(entry) then
            staging.toggle_local = function()
                show_local(entry)
            end
        end
        if view and view:is_open() then
            view:set_source(model, staging, source_opts)
        else
            view = require("differ").diff_model(model, {
                staging = staging,
                can_stage = stageable,
            })
        end
        active_entry = entry
        if watcher then
            watcher:watch_file(root .. "/" .. entry.path)
        end
        last_sig = git_signature() -- record the state we're now showing
        return true
    end

    -- the current changed-file entries for a path: an external op (lazygit) can move it
    -- to another section or out of the change set
    ---@param path string
    ---@return differ.FileEntry[]
    local function entries_for_path(path)
        local out = {}
        local live = preview and M.staged_sections(root) or M.status_sections(root)
        for _, sec in ipairs(live) do
            for _, e in ipairs(sec.entries) do
                if e.path == path then
                    out[#out + 1] = e
                end
            end
        end
        return out
    end

    -- re-source the view onto the shown file's current row, else the nearest surviving
    -- change. `outside` announces a landing on a different change
    ---@param outside boolean
    ---@return boolean sourced
    retarget_view = function(outside)
        if not (view and view:is_open() and active_entry) then
            return false
        end
        -- hold the cursor near where it was rather than snapping to the top
        local focus_line, focus_col = view:cursor_new_line()
        local pick = entries_for_path(active_entry.path)[1]
        local was = active_entry
        local source_opts = { focus_line = focus_line, focus_col = focus_col, keep_folds = true }
        if pick and show_entry(pick, source_opts) then
            if outside and pick.status ~= was.status then
                notify(("%s changed outside differ"):format(pick.path))
            end
            return true
        end
        -- restore focus: nothing here came from a keypress
        local focused = vim.api.nvim_get_current_win()
        if panel:open_nearest(true) then
            if vim.api.nvim_win_is_valid(focused) then
                vim.api.nvim_set_current_win(focused)
            end
            return true
        end
        return false
    end

    -- gs: flip the panel between every change and the commit preview, then reopen the
    -- file on screen in the new listing, else the nearest one
    set_preview = function(on)
        if on then
            local _, staged_total = nonempty_sections((M.staged_sections(root)))
            if staged_total == 0 then
                return notify("nothing staged to preview")
            end
        end
        preview = on
        local path = active_entry and active_entry.path
        panel:refresh()
        if not panel:is_alive() then
            return
        end
        if not (path and panel:goto_path(path, true)) then
            panel:open_nearest(true)
        end
    end

    -- after an external git change (lazygit, a tmux-pane commit, `:!git`): refresh the
    -- list, then re-source the open diff so it reflects the new state too rather than
    -- staying frozen. gated on the signature so unrelated terminal events are no-ops
    local function refresh_external()
        -- a debounced watcher fire (or a queued schedule) can land after the panel is
        -- gone; bail before touching its deleted buffer. a hidden sidebar is still live
        -- (and still driving a visible diff), so it refreshes like an open one
        if not (panel and panel:is_alive()) then
            return
        end
        if git_signature() == last_sig then
            return
        end
        panel:refresh()
        if not panel:is_alive() then
            return -- the change set emptied and on_empty ended the session
        end
        -- a merge started under a live session runs no command, so the dispatch gate
        -- never sees it
        M.notify_conflicts(root, M.conflicted(root))
        if retarget_view(true) then
            return
        end
        -- no view, and nothing to hand over to: just record the state
        record_state()
    end

    -- watch the git dir and the shown file's dir so an external change (lazygit, an
    -- editor, a commit) re-sources instantly, not just on focus. worktree panels only:
    -- rev-pair diffs are against immutable SHAs and never go stale
    if stageable then
        local git_dir = git({ "rev-parse", "--absolute-git-dir" }, root)
        git_dir = git_dir and chomp(git_dir) or nil
        if git_dir then
            watcher = watch.new({ git_dir = git_dir, on_change = refresh_external })
        end
    end

    -- per-call opts (e.g. `:Differ panel`) win, else the resolved config's panel
    -- defaults, else Panel.new's own hardcoded fallbacks
    local cfg = require("differ").get_config()
    local panel_cfg = cfg.panel or {}
    local panel_keys = cfg.keymaps.panel or require("differ.config").defaults.keymaps
    local return_tab, session_tab = open_session_tab()
    panel = Panel.new({
        sections = nonempty,
        root = vim.fn.fnamemodify(root, ":~"), -- ~-relative repo path for the header
        footer = footer_label(args, root),
        actions = actions,
        on_external_change = refresh_external,
        on_refresh = record_state,
        -- the panel's keys move the pair the diff was built from, so the window follows.
        -- only for the file on screen: another row's diff keeps its frozen marks
        on_staged = function(paths)
            if active_entry and not (paths and not paths[active_entry.path]) then
                retarget_view(false)
            end
        end,
        keymaps = cfg.keymaps.panel --[[@as differ.KeymapSet]],
        extra_keymaps = stageable and {
            {
                spec = panel_keys.commit_preview,
                fn = function()
                    set_preview(not preview)
                end,
                desc = "commit preview: staged changes only",
            },
        } or nil,
        listing = opts.listing or panel_cfg.listing,
        position = opts.position or panel_cfg.position,
        height = opts.height or panel_cfg.height,
        width = opts.width or panel_cfg.width,
        icons = panel_cfg.icons,
        progress = panel_cfg.progress,
        on_select = function(entry)
            if show_entry(entry) then
                return true
            end
            -- a stale entry (committed or changed outside differ) has an empty diff;
            -- refresh the list rather than opening a blank view. that refresh can end
            -- the session (it was the last entry), which says so on its own. false tells
            -- the panel nothing was opened, so a review walk carries on past it instead
            -- of reporting the walk over
            refresh_panel()
            if panel and panel:is_alive() then
                notify(("no changes for %s"):format(entry.path))
            end
            return false
        end,
        -- the change set emptied under the session (a commit, or the last change
        -- reverted): there's nothing left to review, so end it rather than leave an
        -- empty sidebar next to a diff of a file that's now clean. only the worktree
        -- source can reach this; a rev-pair list never reloads
        on_empty = function()
            if preview then
                return set_preview(false) -- everything unstaged: back to the whole list
            end
            notify("no changes left")
            local back = panel and panel.return_tab
            if panel then
                panel:close() -- cascades to the diff view + the session tab
            end
            if back and vim.api.nvim_tabpage_is_valid(back) then
                vim.api.nvim_set_current_tabpage(back)
            end
        end,
        on_close = function()
            if watcher then
                watcher:stop()
            end
            if view then
                view:close() -- idempotent, and :q leaves the window already gone
            end
            close_session_tab(session_tab)
        end,
    }):open()
    panel.return_tab = return_tab
    if opts.open_first then
        -- land on the file (and line) :Differ was run from when it's in the change
        -- set, else the first file with unstaged work (skipping the Staged section);
        -- leave the cursor in the diff, not the panel
        local on_origin = origin_rel and panel:focus_file(origin_rel)
        if not on_origin then
            panel:focus_first_unstaged()
        end
        panel:select(true)
        if on_origin and view then
            -- hold the exact origin position when it's a changed line, so opening deep in
            -- a hunk stays put (column included) rather than snapping to the hunk's top;
            -- a cursor on unchanged context still falls back to the nearest hunk to review
            view:focus_new_line(origin_line, true, origin_col)
        end
    end
    return panel
end

-- close any live local session (panel or history) so a fresh history opener supersedes it
-- in place rather than stacking a second session in its own tab. the two kinds are tracked
-- by independent singletons, so an opener tears down both to keep a single live session. the
-- panel opener doesn't share this: its bare `:Differ` / `:Differ panel` gestures reveal or
-- toggle a live panel, so it supersedes history and panel on its own terms
local function supersede_local_session()
    local panel = require("differ.panel").current()
    if panel then
        panel:close()
    end
    local history = require("differ.history").current()
    if history then
        history:close()
    end
end

-- :Differ log [path] / the `dh` verb: single-file history. lists the file's
-- commits in a dedicated history panel; selecting/stepping a commit re-sources the
-- one driven View to that commit vs its parent. read-only (no staging). `opts.path`
-- defaults to the current buffer's file; position passes through to the panel
---@class differ.git.HistoryOpts
---@field path? string
---@field position? string
---@return differ.History|nil
function M.history(opts)
    local History = require("differ.history")
    -- re-running `:Differ log` over any live local session supersedes it (mirrors `:Differ
    -- <rev>`'s panel idempotency): close a live panel (`:Differ base`/`<rev>`) or history and
    -- fall through to open the new one, so we never stack a second session in its own tab
    supersede_local_session()

    -- the cursor position :Differ log was invoked from, to open the first commit's diff
    -- at that position when history is for the file we're sitting in (resolved below)
    local origin_line, origin_col = unpack(vim.api.nvim_win_get_cursor(0))
    local origin_buf = vim.fn.resolve(vim.api.nvim_buf_get_name(0))

    local file = opts.path and vim.fn.fnamemodify(opts.path, ":p") or vim.api.nvim_buf_get_name(0)
    if file == "" or vim.fn.filereadable(file) == 0 then
        return notify("no file to show history for", vim.log.levels.WARN)
    end
    -- resolve symlinks so the prefix strip below lines up with git's toplevel, which
    -- is itself realpath-resolved (e.g. macOS /var -> /private/var)
    file = vim.fn.resolve(file)
    local root = M.root(file)
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    local relpath = file:sub(#root + 2) -- strip "<root>/"; file is under root

    -- carry the cursor line into the first commit's diff only when history targets the
    -- file we're in; a `:Differ log <other>` has no meaningful origin line
    local origin = (origin_buf ~= "" and origin_buf == file) and origin_line or nil

    local commits, err = M.log_commits(root, { path = relpath })
    if #commits == 0 then
        if err then
            return notify(chomp(err), vim.log.levels.ERROR)
        end
        return notify("no history for " .. relpath)
    end
    local branch = head_branch(root)

    -- a commit's diff is the patch it introduced: the file at <commit> vs its
    -- parent. the root commit's parent (<sha>^) doesn't resolve, so M.read returns
    -- nil -> empty old side -> a pure add, which is correct for the introducing commit
    ---@param commit differ.git.Commit
    ---@return differ.DiffModel
    local function model_for(commit)
        local source = {
            old = { kind = "rev", rev = commit.short .. "^", label = commit.short .. "^" },
            new = { kind = "rev", rev = commit.sha, label = commit.short },
        }
        return M.model(source, root, { path = relpath }, branch)
    end

    local view ---@type differ.View|nil -- the single diff view the panel drives
    local opened_origin = false -- the first commit shown holds the origin line, then stop
    local cfg = require("differ").get_config()
    local hist_cfg = cfg.history or {}
    local return_tab, session_tab = open_session_tab()
    local history = History.new({
        commits = commits,
        path = vim.fn.fnamemodify(file, ":~"),
        keymaps = cfg.keymaps.history --[[@as differ.KeymapSet]],
        relative_dates = cfg.relative_dates,
        position = opts.position or hist_cfg.position,
        height = hist_cfg.height,
        width = hist_cfg.width,
        commit_message = function(commit)
            return M.commit_message(root, commit.sha)
        end,
        on_select = function(commit)
            local model = model_for(commit)
            if view and view:is_open() then
                view:set_source(model)
            else
                view = require("differ").diff_model(model)
            end
            -- on the first commit shown, hold the origin line: a line changed by that
            -- commit lands exactly, otherwise it falls back to the first hunk. later
            -- commit steps land on the first hunk like before
            if origin and not opened_origin then
                opened_origin = true
                view:focus_new_line(origin, true, origin_col)
            end
        end,
        on_close = function()
            if view then
                view:close() -- idempotent, and :q leaves the window already gone
            end
            close_session_tab(session_tab)
        end,
    }):open()
    history.return_tab = return_tab
    return history
end

-- :Differ log <range> / the `dp` verb: branch-range history. lists the
-- range's commits in the history panel; a commit expands to its files (lazy), and
-- selecting/stepping a file re-sources the one driven View to that file at the
-- commit vs its parent. one expandable panel, read-only (no staging)
---@class differ.git.RangeHistoryOpts
---@field range? string
---@field position? string
---@return differ.History|nil
function M.range_history(opts)
    local History = require("differ.history")
    -- re-running `:Differ log <range>` over any live local session supersedes it (mirrors
    -- `:Differ <rev>`'s panel idempotency): close a live panel (`:Differ base`/`<rev>`) or
    -- history, then open the new one, so we never stack a second session in its own tab
    supersede_local_session()

    local range = opts.range
    if not range or range == "" then
        return notify("range history needs a rev-range (e.g. main...HEAD)", vim.log.levels.WARN)
    end
    local root = repo_root()
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    local commits, err = M.range_commits(root, range)
    if #commits == 0 then
        if err then
            return notify(chomp(err), vim.log.levels.ERROR)
        end
        return notify("no commits in " .. range)
    end
    local branch = head_branch(root)

    local view ---@type differ.View|nil -- the single diff view the panel drives
    local cfg = require("differ").get_config()
    local hist_cfg = cfg.history or {}
    local return_tab, session_tab = open_session_tab()
    local history = History.new({
        commits = commits,
        mode = "range",
        path = range, -- the header shows the range in place of a file path
        keymaps = cfg.keymaps.history --[[@as differ.KeymapSet]],
        relative_dates = cfg.relative_dates,
        position = opts.position or hist_cfg.position,
        height = hist_cfg.height,
        width = hist_cfg.width,
        commit_message = function(commit)
            return M.commit_message(root, commit.sha)
        end,
        expand = function(commit)
            return M.commit_files(root, commit.sha)
        end,
        on_file = function(commit, entry)
            local source = {
                old = parent_or_empty(root, commit.sha),
                new = { kind = "rev", rev = commit.sha, label = commit.short },
            }
            local model = M.model(source, root, entry, branch)
            if view and view:is_open() then
                view:set_source(model)
            else
                view = require("differ").diff_model(model)
            end
        end,
        on_close = function()
            if view then
                view:close() -- idempotent, and :q leaves the window already gone
            end
            close_session_tab(session_tab)
        end,
    }):open()
    history.return_tab = return_tab
    return history
end

-- the user navigated away in place inside a differ window (a picker / :edit swapped a
-- buffer into the diff, panel or compose window). the session's windows live in their
-- own tabpage, so end the session and carry the swapped-in buffer out to the tab it was
-- launched from, else the navigation dies with the tab. shared by every window's
-- navigate-away guard; a no-op once the session is already gone (idempotent)
---@param repurposed integer|nil  the buffer the user navigated to, to re-home
---@param fallback_view differ.View|nil  a bare diff view to close when there's no owner
function M.navigate_away(repurposed, fallback_view)
    local owner = require("differ.panel").current() or require("differ.history").current()
    if not owner then
        -- a bare diff (no panel / history): just close it; the _discard guard leaves the
        -- navigated window in place, so there's nothing to carry out
        if fallback_view then
            fallback_view:close()
        end
        return
    end
    local return_tab = owner.return_tab
    owner:close() -- on_close cascades to the diff view + the session tab
    if
        repurposed
        and vim.api.nvim_buf_is_valid(repurposed)
        and #vim.fn.win_findbuf(repurposed) == 0
    then
        if return_tab and vim.api.nvim_tabpage_is_valid(return_tab) then
            vim.api.nvim_set_current_tabpage(return_tab)
        end
        vim.api.nvim_set_current_buf(repurposed)
    end
end

-- :Differ close: tear down the whole local session: the panel (which closes the
-- diff view it drives via on_close) or, failing that, a bare diff view
function M.close()
    local panel = require("differ.panel").current()
    if panel then
        return panel:close()
    end
    local history = require("differ.history").current()
    if history then
        return history:close()
    end
    local view = require("differ.view").current()
    if view then
        return view:close()
    end
    notify("no differ view open")
end

return M
