-- shared helpers for the git specs: throwaway repos, panel sessions on them, a stubbed confirm
local git_src = require("differ.git")

-- run git in `cwd`, asserting success. identity is pinned inline so commits work
-- in CI without a global gitconfig
local function git(cwd, ...)
    local args =
        { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    local res = vim.system(args, { cwd = cwd, text = true }):wait()
    assert(
        res.code == 0,
        "git failed: " .. table.concat({ ... }, " ") .. "\n" .. (res.stderr or "")
    )
    return res.stdout
end

local function write(path, content)
    local fd = assert(io.open(path, "wb"))
    fd:write(content)
    fd:close()
end

-- a fresh repo with one committed file (a.lua = V1) on `main`
local V1 = "local x = 1\nreturn x\n"
local function fresh_repo()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", V1)
    git(root, "add", "a.lua")
    git(root, "commit", "-q", "-m", "init")
    return root
end

-- the panel row for `path`; `staged` narrows to a row with nothing unstaged (true) or
-- with something unstaged (false)
local function file_line(p, path, staged)
    for i, m in ipairs(p.meta) do
        if
            m.kind == "file"
            and m.entry.path == path
            and (staged == nil or (m.entry.y == " ") == staged)
        then
            return i
        end
    end
end

-- the diff view the panel drives. View.current keys off the focused buffer, and
-- panel keys leave focus on the panel, so it's looked up from the origin window
local function view_in_origin(p)
    vim.api.nvim_set_current_win(p.origin_win)
    return require("differ.view").current()
end

-- the panel session on the repo just built, and the diff it opens on the origin file
local function open_panel()
    git_src.panel({ rev = {}, open_first = true })
    local p = assert(require("differ.panel").current())
    return p, view_in_origin(p)
end

-- run `fn` with vim.fn.confirm answering `choice` (1 yes, 2 no), returning the prompt
-- it was shown
---@return string|nil prompt
local function confirming(choice, fn)
    local orig, prompt = vim.fn.confirm, nil
    vim.fn.confirm = function(msg)
        prompt = msg
        return choice
    end
    local ok, err = pcall(fn)
    vim.fn.confirm = orig
    assert(ok, err)
    return prompt
end
-- the staged (index) content of `path`
local function indexed(root, path)
    return git(root, "show", ":" .. path)
end
local function worktree(root, path)
    return table.concat(vim.fn.readfile(root .. "/" .. path), "\n") .. "\n"
end
local function committed(root, path)
    return git(root, "show", "HEAD:" .. path)
end
-- the buffer line hunk `n` starts on, in the view's primary column
local function hunk_line(v, n)
    for lnum, line in ipairs(v.columns[1].map.lines) do
        if line.hunk == n then
            return lnum
        end
    end
end

-- point `path`'s index entry at `content` without touching the worktree
local function index_as(root, path, content)
    local blob = root .. "/.blob"
    write(blob, content)
    local sha = vim.trim(git(root, "hash-object", "-w", blob))
    os.remove(blob)
    git(root, "update-index", "--cacheinfo", "100644," .. sha .. "," .. path)
end
-- a repo with a.lua committed as `head`, staged as `index` and on disk as `work`, and
-- the diff :Differ opens on it
local function staged_as(head, index, work)
    local root = fresh_repo()
    write(root .. "/a.lua", head)
    git(root, "commit", "-q", "-am", "head")
    index_as(root, "a.lua", index)
    write(root .. "/a.lua", work)
    vim.cmd.edit(root .. "/a.lua")
    local p = open_panel()
    return root, p, view_in_origin(p)
end
local function lines_of(t)
    return table.concat(t, "\n") .. "\n"
end

-- the winbar text over the diff column of `v`
local function winbar_of(v)
    vim.g.statusline_winid = v.columns[#v.columns].winid
    local text = require("differ.ui.winbar").diff()
    vim.g.statusline_winid = nil
    return text
end

-- the gutter drawn beside buffer line `lnum` of the diff column of `v`
local function gutter_of(v, lnum)
    local win = v.columns[#v.columns].winid
    local fmt = vim.wo[win].statuscolumn
    return vim.api.nvim_eval_statusline(fmt, { winid = win, use_statuscol_lnum = lnum }).str
end

-- two staged edits and a third on top in the worktree, far enough apart to diff as
-- three hunks
local function partly_staged_repo()
    local root = fresh_repo()
    write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n")
    git(root, "commit", "-q", "-am", "twelve lines")
    write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6x\n7\n8\n9\n10\n11\n12\n")
    git(root, "add", "a.lua")
    write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6x\n7\n8\n9\n10\n11\n12x\n")
    vim.cmd.edit(root .. "/a.lua")
    return root
end

-- HEAD's twelve numbered lines with `edits` (line -> text) applied
local function twelve(edits)
    local out = {}
    for n = 1, 12 do
        out[n] = edits[n] or tostring(n)
    end
    return table.concat(out, "\n") .. "\n"
end
-- line 1 staged as 1x, then the worktree set to `work`
local function staged_then(work)
    local root = fresh_repo()
    write(root .. "/a.lua", twelve({}))
    git(root, "commit", "-q", "-am", "twelve lines")
    write(root .. "/a.lua", twelve({ "1x" }))
    git(root, "add", "a.lua")
    write(root .. "/a.lua", work)
    vim.cmd.edit(root .. "/a.lua")
    return root
end
-- stage `content` as a.lua from outside differ, leaving the worktree file alone
local function stage_behind(root, content)
    local blob = vim.fn.tempname()
    write(blob, content)
    local sha = vim.trim(git(root, "hash-object", "-w", blob))
    os.remove(blob)
    git(root, "update-index", "--cacheinfo", "100644," .. sha .. ",a.lua")
end
local function paths(p)
    local out = {}
    for _, sec in ipairs(p.sections) do
        for _, e in ipairs(sec.entries) do
            out[#out + 1] = e.path
        end
    end
    table.sort(out)
    return out
end

return {
    git = git,
    write = write,
    V1 = V1,
    fresh_repo = fresh_repo,
    file_line = file_line,
    view_in_origin = view_in_origin,
    open_panel = open_panel,
    confirming = confirming,
    indexed = indexed,
    worktree = worktree,
    committed = committed,
    hunk_line = hunk_line,
    index_as = index_as,
    staged_as = staged_as,
    lines_of = lines_of,
    winbar_of = winbar_of,
    gutter_of = gutter_of,
    partly_staged_repo = partly_staged_repo,
    twelve = twelve,
    staged_then = staged_then,
    stage_behind = stage_behind,
    paths = paths,
}
