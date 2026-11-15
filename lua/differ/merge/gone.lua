-- a text file both sides kept (UU/AA) that is missing from the worktree: a take restores
-- that stage, both writes the file again with its markers and reopens it, none deletes it.
-- a one-sided code with the file missing keeps or deletes through merge/deleted.lua

local notify = require("differ.git.exec").notify

local M = {}

-- recreate the markers with checkout -m and reopen the file as a marker-editing conflict
---@param s differ.MergeSession
local function remerge(s)
    if not require("differ.git").remerge(s.root, s.path) then
        return
    end
    local model = require("differ.merge.files").build_or_warn(s.root, s.path)
    if not model then
        return
    end
    if model.gone then
        local msg = "%s still isn't in the working tree after git checkout -m"
        return notify(msg:format(s.path), vim.log.levels.ERROR)
    end
    require("differ.merge")._lay_out(s.root, s.path, model, s.layout, s.files)
end

---@param s differ.MergeSession
---@param choice "ours"|"theirs"|"both"|"base"|"none"
function M.resolve(s, choice)
    if s.resolved then
        return notify(("%s is already resolved"):format(s.path))
    end
    if choice == "base" and s.no_ancestor then
        local msg = "%s was added by both: no base version to take"
        return notify(msg:format(s.path), vim.log.levels.WARN)
    end
    if choice == "both" then
        return remerge(s)
    end
    if choice == "none" then
        return require("differ.merge.deleted").delete(s)
    end
    require("differ.merge.whole").take(s, choice --[[@as "ours"|"base"|"theirs"]])
end

return M
