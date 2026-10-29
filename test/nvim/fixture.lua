-- throwaway repos built once per busted process, handed to each test as its own copy
local M = {}

-- wraps a repo builder so each distinct argument list builds once into a template, and
-- every call returns a fresh `cp -R` of it
---@generic F: fun(...): string
---@param build F
---@return F
function M.cached(build)
    local templates = {}
    return function(...)
        local key = vim.inspect({ ... })
        if not templates[key] then
            templates[key] = build(...)
        end
        local root = vim.fn.tempname()
        local res = vim.system({ "cp", "-R", templates[key], root }):wait()
        assert(res.code == 0, "cp failed: " .. (res.stderr or ""))
        -- the copy's index holds the template's stat data, so every file reads as modified
        -- until refreshed. exits non-zero on unmerged paths, which is expected
        vim.system({ "git", "update-index", "-q", "--refresh" }, { cwd = root }):wait()
        return root
    end
end

return M
