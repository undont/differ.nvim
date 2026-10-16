-- modify/delete conflicts in the merge tool: taking the deleting side deletes the file with
-- git rm, taking the other keeps it by writing it

local notify = require("differ.git.exec").notify

local M = {}

-- keep the file: write it as it stands, which stages it like any write. a binary file is
-- staged from disk instead, since a write from nvim can change its bytes
---@param s differ.MergeSession
local function keep_file(s)
    if s.binary then
        local surviving = "ours"
        if s.deleted == "ours" then
            surviving = "theirs"
        end
        return require("differ.merge.binary").take(s, surviving)
    end
    local ok, err = pcall(vim.api.nvim_buf_call, s.result_buf, function()
        vim.cmd("silent write")
    end)
    if not ok then
        notify(tostring(err), vim.log.levels.ERROR)
    end
end

-- after a delete the file is gone, so the result window shows an empty read-only buffer
-- in place of the real one; a write there would recreate the file
---@param s differ.MergeSession
local function show_deleted(s)
    local merge = require("differ.merge")
    local real = s.result_buf
    merge._release_result(s)
    local buf = merge._make_buffer("deleted", s.path, {})
    local notice = s.path .. " deletion staged"
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
local function delete_file(s)
    if vim.bo[s.result_buf].modified then
        return notify("unsaved changes: drop them with :e! to delete", vim.log.levels.WARN)
    end
    -- confirm() runs scheduled callbacks while it blocks, so the watcher can close the session
    if vim.fn.confirm(("Delete %s?"):format(s.path), "&Yes\n&No", 2) ~= 1 then
        return
    end
    if require("differ.merge").current() ~= s then
        return notify("the merge tool closed while the prompt was up; nothing was deleted")
    end
    if not require("differ.git").remove(s.root, s.path) then
        return
    end
    s.removed = true
    require("differ.merge.files").mark_staged(s)
    show_deleted(s)
end

-- taking the deleting side deletes the file, taking the other keeps it
---@param s differ.MergeSession
---@param choice "ours"|"theirs"|"both"|"base"|"none"
function M.resolve(s, choice)
    if s.staged then
        return notify(("%s is already resolved"):format(s.path))
    end
    if choice ~= "ours" and choice ~= "theirs" then
        return notify(
            "a modify/delete conflict is kept or deleted: take ours or theirs",
            vim.log.levels.WARN
        )
    end
    if choice == s.deleted then
        return delete_file(s)
    end
    keep_file(s)
end

return M
