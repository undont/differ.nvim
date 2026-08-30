-- runs under headless nvim: the shared compose window (comments, replies, review
-- summaries) in isolation. compose.open needs no session and no sidecar, so each case
-- opens it directly, drives a buffer-local key, and asserts on what it fired

require("differ").setup({})

local compose = require("differ.ui.compose")

---@param key string
local function feed(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

---@param opts table|nil
local function open(opts)
    local state = { submitted = nil, cancelled = false }
    local handle = compose.open(vim.tbl_extend("force", {
        title = "Comment",
        on_submit = function(text)
            state.submitted = text
        end,
        on_cancel = function()
            state.cancelled = true
        end,
    }, opts or {}))
    state.win = vim.api.nvim_get_current_win()
    state.buf = vim.api.nvim_get_current_buf()
    state.handle = handle
    vim.cmd("stopinsert") -- open() lands in insert; these keys are normal-mode
    return state
end

---@param lines string[]
local function type_body(state, lines)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
end

describe("the compose window", function()
    before_each(function()
        vim.cmd("silent! only")
    end)

    it("keeps the body on <Esc>, so leaving insert never discards a draft", function()
        local state = open()
        type_body(state, { "half a thought" })

        feed("<Esc>")
        feed("<Esc>") -- the reflex double-tap out of insert

        assert.is_true(vim.api.nvim_win_is_valid(state.win))
        assert.is_false(state.cancelled)
        assert.are.same({ "half a thought" }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
        state.handle.close()
    end)

    it("binds no normal-mode <Esc> on the compose buffer", function()
        local state = open()
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
            assert.are_not.equal("<Esc>", m.lhs)
        end
        state.handle.close()
    end)

    it("cancels on q", function()
        local state = open()
        type_body(state, { "abandon this" })

        feed("q")

        assert.is_false(vim.api.nvim_win_is_valid(state.win))
        assert.is_true(state.cancelled)
    end)

    it("cancels on :q, via the close autocmd", function()
        local state = open()

        vim.api.nvim_win_close(state.win, true)

        assert.is_true(vim.wait(1000, function()
            return state.cancelled
        end, 10))
    end)

    it("submits the body on <CR>", function()
        local state = open()
        type_body(state, { "ship it", "", "looks right" })

        feed("<CR>")

        assert.are.equal("ship it\n\nlooks right", state.submitted)
        assert.is_false(vim.api.nvim_win_is_valid(state.win))
        assert.is_false(state.cancelled)
    end)

    it("seeds the body from opts.initial, as the conflict retry path does", function()
        local state = open({ initial = "first attempt" })
        assert.are.same({ "first attempt" }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
        state.handle.close()
    end)
end)
