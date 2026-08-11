-- owner/repo + PR-number resolution for the PR frontend. parse_remote is
-- pure (no vim calls) so it's unit-tested against the url-form table like git/rev.lua;
-- resolve does the git-remote I/O. stays on git-remote parsing, not `gh repo view`,
-- so a token-only setup with no gh binary still resolves coords (auth is
-- token-first)

local M = {}

-- parse a github remote url into {owner, repo}, or nil for a non-github / unparsable
-- url. handles scp-style `git@github.com:owner/repo.git`, `https://github.com/owner/
-- repo(.git)` and `ssh://git@github.com/owner/repo`, stripping any trailing .git
---@param url string
---@return { owner: string, repo: string }|nil
function M.parse_remote(url)
    if type(url) ~= "string" then
        return nil
    end
    url = url:match("^%s*(.-)%s*$")
    if url == "" then
        return nil
    end

    local host, path
    if url:find("://", 1, true) then
        -- scheme://[user@]host/owner/repo
        host, path = url:match("^%a[%w+.%-]*://([^/]+)/(.+)$")
    else
        -- scp-like: [user@]host:owner/repo
        host, path = url:match("^([^:/]+):(.+)$")
    end
    if not (host and path) then
        return nil
    end
    host = host:gsub("^[^@]*@", "") -- strip any userinfo
    if host ~= "github.com" then
        return nil
    end

    path = path:gsub("%.git$", ""):gsub("/+$", "")
    local owner, repo = path:match("^([^/]+)/([^/]+)$")
    if not (owner and repo) or owner == "" or repo == "" then
        return nil
    end
    return { owner = owner, repo = repo }
end

-- the repo to operate on: the current file's repo if it's a real file, else cwd
---@return string|nil
local function repo_root()
    local file = vim.api.nvim_buf_get_name(0)
    local anchor = (file ~= "" and vim.fn.filereadable(file) == 1) and file or vim.fn.getcwd()
    return require("differ.git").root(anchor)
end

-- the configured remotes, in git's listing order
---@param root string
---@return string[]
local function list_remotes(root)
    local res = vim.system({ "git", "remote" }, { cwd = root, text = true }):wait()
    if res.code ~= 0 then
        return {}
    end
    return vim.split(vim.trim(res.stdout or ""), "%s+", { trimempty = true })
end

---@param name string
---@param root string
---@return string|nil
local function remote_url(name, root)
    local res = vim.system({ "git", "remote", "get-url", name }, { cwd = root, text = true }):wait()
    if res.code ~= 0 then
        return nil
    end
    return vim.trim(res.stdout or "")
end

-- resolve the repo coords for the cwd's repo and call cb(err, {owner, repo}).
-- precedence: an explicit `opts.coords` override; then `upstream` over `origin`
-- (an upstream remote is itself the fork signal, so this gives fork support with no
-- gh/API call); then `origin`; then the first github remote. a non-github remote is
-- a clear, once-surfaced error
---@param opts { coords?: { owner: string, repo: string } }|nil
---@param cb fun(err: table|nil, coords: { owner: string, repo: string }|nil)
function M.resolve(opts, cb)
    opts = opts or {}
    if opts.coords then
        return cb(nil, opts.coords)
    end
    local root = repo_root()
    if not root then
        return cb({ code = "bad_request", message = "not inside a git repository" })
    end

    local remotes = list_remotes(root)
    local seen = {}
    for _, name in ipairs(remotes) do
        seen[name] = true
    end
    -- upstream over origin, then origin, then the rest in listing order
    local order = {}
    if seen.upstream then
        order[#order + 1] = "upstream"
    end
    if seen.origin then
        order[#order + 1] = "origin"
    end
    for _, name in ipairs(remotes) do
        if name ~= "upstream" and name ~= "origin" then
            order[#order + 1] = name
        end
    end

    local saw_remote = false
    for _, name in ipairs(order) do
        local url = remote_url(name, root)
        if url and url ~= "" then
            saw_remote = true
            local coords = M.parse_remote(url)
            if coords then
                return cb(nil, coords)
            end
        end
    end
    local msg = saw_remote and "not a github remote" or "no git remotes configured"
    return cb({ code = "bad_request", message = msg })
end

-- whether `root` is a clone of `coords`. every github remote is checked, not just the
-- one resolve() would pick: on a fork both sides are legitimate local checkouts, and
-- which of them wins the precedence order says nothing about the pr being opened
---@param root string
---@param coords { owner: string, repo: string }
---@return boolean
function M.has_remote(root, coords)
    for _, name in ipairs(list_remotes(root)) do
        local url = remote_url(name, root)
        local c = url and url ~= "" and M.parse_remote(url) or nil
        if c and c.owner == coords.owner and c.repo == coords.repo then
            return true
        end
    end
    return false
end

return M
