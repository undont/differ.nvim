-- moving content in and out of the index, and the paths one row's ops act on. the
-- whole-file keys and the diff view's hunk staging both write through here

local exec = require("differ.git.exec")
local git, git_ok, notify = exec.git, exec.git_ok, exec.notify

local M = {}

-- git's mode for a submodule entry (a commit pointer)
M.GITLINK = "160000"

-- why discard refuses an entry, or nil: a staged deletion's copy on disk would be
-- overwritten, and a submodule's checkout can't be moved. the modes are HEAD's and the
-- worktree's; `keys` is the set of the surface the refusal shows on
---@param keys differ.KeymapSet
---@param entry differ.FileEntry
---@param old_mode? string
---@param new_mode? string
---@return string|nil
function M.discard_refusal(keys, entry, old_mode, new_mode)
    local submodule = old_mode == M.GITLINK or new_mode == M.GITLINK
    if not (entry.kept or submodule) then
        return nil
    end
    local help = require("differ.ui.help")
    local discard = help.key(keys, "discard")
    if not discard then
        return "discard is disabled"
    end
    if entry.kept then
        local msg = "%s would overwrite %s on disk; %s unstages the deletion instead"
        return msg:format(discard, entry.path, help.key(keys, "unstage"))
    end
    return ("%s can't move the checkout inside the submodule %s"):format(discard, entry.path)
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
---@param path string
---@return boolean ok
function M.remove(root, path)
    return git_ok({ "rm", "-q", "--", path }, root, "delete")
end

-- resolve a conflict to one side's stage: check it out over the worktree file, then stage it
---@param root string
---@param path string
---@param side "ours"|"theirs"
---@return boolean ok
function M.take_side(root, path, side)
    if not git_ok({ "checkout", "--" .. side, "--", path }, root, "take " .. side) then
        return false
    end
    return M.stage(root, path)
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

-- point `path`'s index entry at `text`: a blob write and an entry move, so there's no
-- header to compute and nothing that can half-apply. `text` must already be in index
-- domain (M.read runs the worktree side through the clean filter). the entry keeps the
-- mode it has unless `mode` names another
---@param root string
---@param path string
---@param text string
---@param mode? string
---@return boolean ok
function M.write_index(root, path, text, mode)
    local listed = git({ "ls-files", "-s", "--", path }, root)
    local held = listed and listed:match("^(%d+)%s")
    if not held then
        notify(("%s has no index entry to update"):format(path), vim.log.levels.ERROR)
        return false
    end
    mode = mode or held
    local hashed = vim.system({ "git", "hash-object", "-w", "--stdin" }, {
        cwd = root,
        stdin = text,
    }):wait()
    if hashed.code ~= 0 or not hashed.stdout then
        notify(
            exec.with_stderr(("staging %s failed"):format(path), hashed.stderr),
            vim.log.levels.ERROR
        )
        return false
    end
    local spec = ("%s,%s,%s"):format(mode, exec.chomp(hashed.stdout), path)
    return git_ok({ "update-index", "--cacheinfo", spec }, root, "staging " .. path)
end

-- the paths one entry's staging ops act on: a rename owns both ends of the move, a copy
-- only its new path. a staged rename the worktree then deleted is lettered D
---@param entry differ.FileEntry
---@return string[]
function M.entry_paths(entry)
    if (entry.status == "R" or entry.x == "R") and entry.previous_path then
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
function M.set_staged(root, entry, staged)
    local ok = true
    for _, p in ipairs(M.entry_paths(entry)) do
        if not staged then
            ok = M.unstage(root, p) and ok
        elseif p == entry.previous_path then
            -- a staged move's old path is in neither the index nor the worktree, which
            -- `git add` refuses as a pathspec that matches nothing
            local drop = { "rm", "-q", "--cached", "--ignore-unmatch", "--", p }
            ok = git_ok(drop, root, "stage") and ok
        else
            ok = M.stage(root, p) and ok
        end
    end
    return ok
end

-- the path an entry's index entry sits at: a rename only the worktree has made (` R`)
-- leaves it at the old path, the new one holding an empty intent-to-add placeholder
---@param entry differ.FileEntry
---@return string
function M.index_path(entry)
    if entry.y == "R" and entry.previous_path then
        return entry.previous_path
    end
    return entry.path
end

-- bring a deleted file back: from HEAD for a staged deletion, which only HEAD still
-- has, else from the index, which holds any edits staged before the delete. a staged
-- deletion whose file is on disk would lose that copy, so it refuses
---@param keys differ.KeymapSet  -- the surface the refusal shows on
---@param root string
---@param entry differ.FileEntry
---@return boolean
function M.restore_deleted(keys, root, entry)
    local why = M.discard_refusal(keys, entry)
    if why then
        notify(why, vim.log.levels.WARN)
        return false
    end
    local cmd = entry.x == "D" and { "checkout", "HEAD", "--", entry.path }
        or { "checkout", "--", entry.path }
    local _, err = git(cmd, root)
    if err then
        notify(exec.with_stderr("restore failed", err), vim.log.levels.ERROR)
        return false
    end
    exec.reload_buffer(root, entry.path)
    return true
end

return M
