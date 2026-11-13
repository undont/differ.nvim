-- conflicts git leaves without markers (a binary file, a symlink, a file set not to merge):
-- they resolve by checking out one side's stage whole, which restores a symlink as a link

local notify = require("differ.git.exec").notify

local M = {}

-- what each kind is called in messages; the winbar uses the kind itself
local NOUNS = { binary = "binary file", symlink = "symlink", text = "file git won't merge" }

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

---@param kind "binary"|"symlink"|"text"
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
    return ("%s · %s · %s"):format(side.kind, size(side.size), side.oid:sub(1, 7))
end

-- check out `side`'s stage and resolve the conflict with it; also a whole-file
-- modify/delete's keep
---@param s differ.MergeSession
---@param side "ours"|"theirs"
function M.take(s, side)
    if not require("differ.git").take_side(s.root, s.path, side) then
        return
    end
    require("differ.merge.files").mark_resolved(s)
    local notice = "took " .. side
    if s.operation then
        notice = notice .. ", staged"
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
