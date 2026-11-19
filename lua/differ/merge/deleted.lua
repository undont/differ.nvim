-- conflicts where a side has no version (modify/delete, added by one side, deleted by both)
-- in the merge tool: taking the side without one deletes the file with git rm, taking the
-- other keeps it by writing it. deleted by both only deletes

local notify = require("differ.git.exec").notify

local M = {}

-- the case as the winbar names it, by the side with no version
---@param deleted "ours"|"theirs"|"both"
---@param no_ancestor boolean
---@return string
function M.state(deleted, no_ancestor)
    if deleted == "both" then
        return "deleted by both"
    end
    if not no_ancestor then
        return "deleted in " .. deleted
    end
    if deleted == "theirs" then
        return "added by us"
    end
    return "added by them"
end

-- the notice an input pane shows when its side has no version, or nil
---@param deleted "ours"|"theirs"|"both"|nil
---@param no_ancestor boolean
---@param side "ours"|"base"|"theirs"
---@return string|nil
function M.absent(deleted, no_ancestor, side)
    if side == "base" or (deleted ~= side and deleted ~= "both") then
        return nil
    end
    if no_ancestor then
        return "not in " .. side
    end
    return "deleted in " .. side
end

-- keep the file: write it as it stands and resolve it. a whole-file one is taken from the
-- index instead: a write from nvim can change a binary's bytes, and would write through a
-- symlink to its target
---@param s differ.MergeSession
local function keep_file(s)
    if s.whole then
        local surviving = "ours"
        if s.deleted == "ours" then
            surviving = "theirs"
        end
        return require("differ.merge.whole").take(s, surviving)
    end
    local ok, err = pcall(vim.api.nvim_buf_call, s.result_buf, function()
        vim.cmd("silent write")
    end)
    if not ok then
        return notify(tostring(err), vim.log.levels.ERROR)
    end
    require("differ.merge").resolve_written()
end

-- after a delete the file is gone, so the result window shows an empty read-only buffer
-- in place of the real one; a write there would recreate the file
---@param s differ.MergeSession
local function show_deleted(s)
    local merge = require("differ.merge")
    local real = s.result_buf
    merge._release_result(s)
    local buf = merge._make_buffer("deleted", s.path, {})
    local notice = s.path .. " deleted"
    if s.operation then
        notice = s.path .. " deletion staged"
    end
    -- acwrite, so a :w reaches the BufWriteCmd below rather than failing on the buftype
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].modified = false -- or stepping off would save it
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        group = s.aug,
        callback = function()
            notify(notice .. ": nothing to write")
        end,
    })
    s.bufs[#s.bufs + 1] = buf
    s.result_buf, s.held_keys = buf, {}
    vim.api.nvim_win_set_buf(s.result_win, buf)
    merge._dress(s.result_win)
    merge._show_notice(s.result_win, buf, notice)
    merge._bind_pane(buf)
    -- unloaded, so nvim doesn't report the file missing; a window outside the session keeps it
    if #vim.fn.win_findbuf(real) == 0 then
        pcall(vim.api.nvim_buf_delete, real, {})
    end
end

-- delete the file with git rm, once confirmed
---@param s differ.MergeSession
function M.delete(s)
    if vim.bo[s.result_buf].modified then
        return notify("unsaved changes: drop them with :e! to delete", vim.log.levels.WARN)
    end
    -- confirm() runs scheduled callbacks while it blocks, so the watcher can close the session
    if vim.fn.confirm(("Delete %s?"):format(s.path), "&Yes\n&No", 2) ~= 1 then
        return
    end
    if require("differ.merge").current() ~= s then
        return
    end
    if not require("differ.git").remove(s.root, s.path) then
        return
    end
    s.removed = true
    require("differ.merge.files").mark_resolved(s)
    show_deleted(s)
end

-- taking the side with no version deletes the file, taking the other keeps it
---@param s differ.MergeSession
---@param choice "ours"|"theirs"|"both"|"base"|"none"
function M.resolve(s, choice)
    if s.resolved then
        return notify(("%s is already resolved"):format(s.path))
    end
    local take = choice == "ours" or choice == "theirs"
    if s.deleted == "both" and not take then
        local msg = "%s was deleted by both: take ours or theirs to delete it"
        return notify(msg:format(s.path), vim.log.levels.WARN)
    end
    if s.deleted == "both" then
        return M.delete(s)
    end
    if not take and s.no_ancestor then
        return notify(
            "a file added by one side is kept or deleted: take ours or theirs",
            vim.log.levels.WARN
        )
    end
    if not take then
        return notify(
            "a modify/delete conflict is kept or deleted: take ours or theirs",
            vim.log.levels.WARN
        )
    end
    if choice == s.deleted then
        return M.delete(s)
    end
    keep_file(s)
end

return M
