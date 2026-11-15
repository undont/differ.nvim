-- conflicts git leaves without markers (a binary file, a symlink, a submodule commit, a file
-- set not to merge): they resolve by taking one side's stage whole. a file or symlink is
-- checked out from the index, which restores a symlink as a link; a submodule checks out
-- the side's commit inside it

local notify = require("differ.git.exec").notify
local GITLINK = require("differ.git.index").GITLINK

local STAGES = { base = 1, ours = 2, theirs = 3 }

local M = {}

-- what each kind is called in messages; the winbar uses the kind itself
local NOUNS = {
    binary = "binary file",
    symlink = "symlink",
    submodule = "submodule",
    text = "file git won't merge",
}

---@param bytes integer
---@return string
local function size(bytes)
    if bytes < 1024 then
        return bytes .. " B"
    end
    if bytes < 1024 * 1024 then
        return ("%.1f KB"):format(bytes / 1024)
    end
    return ("%.1f MB"):format(bytes / (1024 * 1024))
end

---@param kind differ.merge.WholeKind
---@return string
function M.noun(kind)
    return NOUNS[kind]
end

-- the notice an input pane shows for its side's stage
---@param side differ.merge.Side
---@return string
function M.describe(side)
    if side.kind == "symlink" then
        return "symlink → " .. side.target
    end
    if side.kind == "submodule" and side.subject then
        return ("commit %s · %s"):format(side.oid:sub(1, 7), side.subject)
    end
    if side.kind == "submodule" then
        return "commit " .. side.oid:sub(1, 7)
    end
    return ("%s · %s · %s"):format(side.kind, size(side.size), side.oid:sub(1, 7))
end

-- check out `side`'s stage and resolve the conflict with it; also a whole-file
-- modify/delete's keep
---@param s differ.MergeSession
---@param side "ours"|"base"|"theirs"
function M.take(s, side)
    local git = require("differ.git")
    local entry = git.stages(s.root, s.path)[STAGES[side]]
    local submodule = entry ~= nil and entry.mode == GITLINK
    local checked_out = submodule and git.checked_out(s.root, s.path)
    -- with no operation the resolution is unstaged, and only a checkout would keep it
    if submodule and not checked_out and not s.operation then
        local msg =
            "%s isn't checked out, and with no operation in progress nothing would keep the take"
        return notify(msg:format(s.path), vim.log.levels.WARN)
    end
    local ok
    if submodule then
        ok = git.take_commit(s.root, s.path, entry.oid)
    else
        ok = git.take_side(s.root, s.path, side)
    end
    if not ok then
        return
    end
    require("differ.merge.files").mark_resolved(s)
    local notice = "took " .. side
    if s.operation then
        notice = notice .. ", staged"
    end
    if submodule and not checked_out then
        notice = notice .. ": git submodule update --init checks it out"
    end
    require("differ.merge")._show_notice(s.result_win, s.result_buf, notice)
end

---@param s differ.MergeSession
---@param choice "ours"|"theirs"|"both"|"base"|"none"
function M.resolve(s, choice)
    if s.resolved then
        return notify(("%s is already resolved"):format(s.path))
    end
    if choice ~= "ours" and choice ~= "theirs" then
        local msg = "%s is a %s: take ours or theirs"
        return notify(msg:format(s.path, NOUNS[s.whole]), vim.log.levels.WARN)
    end
    M.take(s, choice --[[@as "ours"|"theirs"]])
end

return M
