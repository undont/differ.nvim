-- session guards for the async pr callbacks: identity gates state reconciliation,
-- window validity gates ui touches. a nil'd view or a hidden sidebar is still a live
-- session (the overview hop does both), so the two questions answer separately

local M = {}

-- the session that issued the call is still the live one. what state reconciliation
-- gates on, since it has to run whether or not any window survived
---@param s table|nil
---@return boolean
function M.owns(s)
    return s ~= nil and require("differ.pr").current_session() == s
end

-- ours, and the sidebar buffer is still there to repaint: hide() drops the window,
-- :close wipes the buffer
---@param s table|nil
---@return boolean
function M.panel_alive(s)
    return s ~= nil and M.owns(s) and s.panel ~= nil and s.panel:is_alive()
end

return M
