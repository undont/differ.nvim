-- buffer-local keymap binding from the resolved keymaps config. the one
-- place that understands the action value shape: a string, a list of strings
-- (multiple binds), or false/nil to disable

local M = {}

-- bind `fn` to every lhs in `spec` on `bufnr`. a false/nil spec is a no-op (the action
-- is disabled); a string binds one lhs, a list binds several. `mode` is the keymap mode
-- (a string or list), defaulting to normal; the pr range-comment binds visual ("x")
---@param bufnr integer
---@param spec string|string[]|false|nil
---@param fn fun()
---@param desc string
---@param mode? string|string[]
function M.bind(bufnr, spec, fn, desc, mode)
    if not spec then
        return
    end
    local list = type(spec) == "table" and spec or { spec }
    for _, lhs in ipairs(list) do
        vim.keymap.set(mode or "n", lhs, fn, { buffer = bufnr, desc = desc, nowait = true })
    end
end

-- drop every lhs in `spec` from `bufnr`, the inverse of bind. for the buffers we don't
-- own (the merge result is the user's real file), where teardown can't just delete the
-- buffer. an lhs that isn't mapped is not an error
---@param bufnr integer
---@param spec string|string[]|false|nil
---@param mode? string|string[]
function M.unbind(bufnr, spec, mode)
    if not spec or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local list = type(spec) == "table" and spec or { spec }
    for _, lhs in ipairs(list) do
        pcall(vim.keymap.del, mode or "n", lhs, { buffer = bufnr })
    end
end

---@class differ.keymap.Held
---@field lhs string
---@field fn fun()
---@field prior table|nil -- the buffer-local maparg() dict bind replaced

-- live holds per buffer and lhs, oldest first, so a release under another hold can
-- hand its prior up instead of having it put back over a live map
---@type table<integer, table<string, differ.keymap.Held[]>>
local stacks = {}
local wipe_group = nil

---@param bufnr integer
---@param h differ.keymap.Held
local function push(bufnr, h)
    if not wipe_group then
        wipe_group = vim.api.nvim_create_augroup("differ.keymap.hold", { clear = true })
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = wipe_group,
            callback = function(args)
                stacks[args.buf] = nil
            end,
        })
    end
    stacks[bufnr] = stacks[bufnr] or {}
    local stack = stacks[bufnr][h.lhs] or {}
    stacks[bufnr][h.lhs] = stack
    stack[#stack + 1] = h
end

-- take `h` off its stack; a hold that replaced h's map takes h's prior
---@param bufnr integer
---@param h differ.keymap.Held
local function splice(bufnr, h)
    local stack = stacks[bufnr] and stacks[bufnr][h.lhs]
    if not stack then
        return
    end
    for i = #stack, 1, -1 do
        local other = stack[i]
        if other == h then
            table.remove(stack, i)
        elseif other.prior and other.prior.callback == h.fn then
            other.prior = h.prior
        end
    end
    if #stack == 0 then
        stacks[bufnr][h.lhs] = nil
    end
end

-- bind on a buffer we don't own, keeping each lhs's prior buffer-local map for release
---@param bufnr integer
---@param spec string|string[]|false|nil
---@param fn fun()
---@param desc string
---@return differ.keymap.Held[]
function M.hold(bufnr, spec, fn, desc)
    if not spec then
        return {}
    end
    local held = {}
    vim.api.nvim_buf_call(bufnr, function()
        for _, lhs in ipairs(type(spec) == "table" and spec or { spec }) do
            local prior = vim.fn.maparg(lhs, "n", false, true)
            local h = { lhs = lhs, fn = fn, prior = prior.buffer == 1 and prior or nil }
            held[#held + 1] = h
            push(bufnr, h)
        end
    end)
    M.bind(bufnr, spec, fn, desc)
    return held
end

-- the inverse of hold: drop each map still ours and put back the one it replaced. a map
-- set over ours since (an LSP attaching mid-session) stays, and a hold over ours puts
-- back our prior when it releases
---@param bufnr integer
---@param held differ.keymap.Held[]
function M.release(bufnr, held)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    vim.api.nvim_buf_call(bufnr, function()
        for _, h in ipairs(held) do
            local now = vim.fn.maparg(h.lhs, "n", false, true)
            if now.buffer == 1 and now.callback == h.fn then
                vim.keymap.del("n", h.lhs, { buffer = bufnr })
                if h.prior then
                    vim.fn.mapset(h.prior)
                end
            end
            splice(bufnr, h)
        end
    end)
end

-- true when every lhs in `spec` is mapped buffer-locally on `bufnr`
---@param bufnr integer
---@param spec string|string[]|false|nil
---@param mode? string
---@return boolean
function M.mapped(bufnr, spec, mode)
    if not spec or not vim.api.nvim_buf_is_valid(bufnr) then
        return true
    end
    local list = type(spec) == "table" and spec or { spec }
    local all = true
    -- maparg, not get_keymap: it normalises <leader> / termcodes as keymap.set did
    vim.api.nvim_buf_call(bufnr, function()
        for _, lhs in ipairs(list) do
            local m = vim.fn.maparg(lhs, mode or "n", false, true)
            if vim.tbl_isempty(m) or m.buffer ~= 1 then
                all = false
            end
        end
    end)
    return all
end

return M
