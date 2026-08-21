-- session tabpage open/close, shared by every surface that runs in its own tab
-- (local git, pr, merge)

local M = {}

-- run a session in its own tabpage (like diffview): the tab :Differ was invoked
-- from is never touched, so ending the session drops the tab and returns there with
-- the dashboard / file / window layout intact. `tab split` carries the current buffer
-- in, so it stays displayed in the invoking tab and isn't wiped when the diff takes
-- the session window. returns the tab to return to and the new session tab
---@return integer return_tab, integer session_tab
function M.open_session()
    local return_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tab split")
    return return_tab, vim.api.nvim_get_current_tabpage()
end

-- close a session's tabpage, never leaving zero tabs (mirrors diffview). a no-op when
-- it's already gone: closing the last session window can collapse the tab first
---@param tab integer|nil
function M.close_session(tab)
    if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then
        return
    end
    if #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd("tabnew")
    end
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
end

return M
