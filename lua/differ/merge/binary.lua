-- binary conflicts in the merge tool: git writes no markers into a binary file, so it
-- resolves by checking out one side's stage whole

local notify = require("differ.git.exec").notify

local M = {}

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

-- the notice an input pane shows for its side's stage
---@param blob differ.merge.Blob
---@return string
function M.describe(blob)
    return ("binary · %s · %s"):format(size(blob.size), blob.oid:sub(1, 7))
end

-- check out `side`'s stage and stage it; also a binary modify/delete's keep
---@param s differ.MergeSession
---@param side "ours"|"theirs"
function M.take(s, side)
    if not require("differ.git").take_side(s.root, s.path, side) then
        return
    end
    require("differ.merge.files").mark_staged(s)
    require("differ.merge")._show_notice(
        s.result_win,
        s.result_buf,
        ("took %s, staged"):format(side)
    )
end

---@param s differ.MergeSession
---@param choice "ours"|"theirs"|"both"|"base"|"none"
function M.resolve(s, choice)
    if s.staged then
        return notify(("%s is already resolved"):format(s.path))
    end
    if choice ~= "ours" and choice ~= "theirs" then
        return notify("a binary file can't be merged: take ours or theirs", vim.log.levels.WARN)
    end
    M.take(s, choice --[[@as "ours"|"theirs"]])
end

return M
