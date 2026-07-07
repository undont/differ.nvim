-- read-only CI checks view: :Differ pr checks lists the status-check rollup and
-- each check, coloured on the semantic palette; <CR> opens the selected check's url via
-- vim.ui.open. no rerun/dispatch (reserved); the sidecar fetch is the only I/O

local client = require("differ.pr.client")

local M = {}

-- a check's coarse state, collapsing github's status + conclusion enums to the three
-- semantic buckets the palette colours. a check still running (status not COMPLETED)
-- is pending regardless of conclusion; once complete, SUCCESS-family is green, the
-- soft outcomes (NEUTRAL/SKIPPED) are neutral, everything else (FAILURE/ERROR/…) is a
-- failure. pure, so the mapping is unit-testable
---@param check { status: string|nil, conclusion: string|nil }
---@return "success"|"failure"|"pending"|"neutral"
function M.state_of(check)
    local status = check.status or ""
    if status ~= "COMPLETED" and status ~= "" then
        return "pending"
    end
    local c = check.conclusion or ""
    if c == "SUCCESS" then
        return "success"
    elseif c == "NEUTRAL" or c == "SKIPPED" then
        return "neutral"
    elseif c == "PENDING" or c == "EXPECTED" then
        return "pending"
    end
    return "failure"
end

-- the rollup state -> its bucket, reusing the per-check mapping (the rollup is a status
-- word, not a check, so it has no `status` field to gate on)
---@param rollup string|nil
---@return "success"|"failure"|"pending"|"neutral"
function M.rollup_state(rollup)
    return M.state_of({ conclusion = rollup })
end

-- bucket -> a defined highlight group (reusing the panel status palette: green/red/
-- yellow fg, grey for neutral) and a glyph for the float
---@type table<string, { hl: string, glyph: string }>
local STYLE = {
    success = { hl = "differPanelAdd", glyph = "✓" },
    failure = { hl = "differPanelDelete", glyph = "✗" },
    pending = { hl = "differPanelModify", glyph = "●" },
    neutral = { hl = "differPanelHelp", glyph = "○" },
}

---@param state string
---@return { hl: string, glyph: string }
function M.style_of(state)
    return STYLE[state] or STYLE.neutral
end

-- one display row for a check: "<glyph> <name> · <status/conclusion>". the trailing
-- label prefers the conclusion once complete, else the running status
---@param check { name: string|nil, status: string|nil, conclusion: string|nil }
---@return string
function M.format(check)
    local state = M.state_of(check)
    local label = check.conclusion
    if label == nil or label == "" or (check.status and check.status ~= "COMPLETED") then
        label = check.status
    end
    return ("%s %s · %s"):format(M.style_of(state).glyph, check.name or "?", label or "?")
end

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- the float: a scratch buffer, one row per check coloured by state, the rollup in the
-- title. <CR>/o opens the check under the cursor; q/<Esc> closes
---@param checks table  -- get_checks result { rollup, checks }
local function render(checks)
    local items = checks.checks or {}
    if #items == 0 then
        return notify("no checks for this pull request")
    end

    local lines, urls, hls = {}, {}, {}
    for i, c in ipairs(items) do
        lines[i] = M.format(c)
        urls[i] = c.url
        hls[i] = M.style_of(M.state_of(c)).hl
    end

    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.max(width, 24)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("differ.checks")
    for i, hl in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
            end_row = i,
            end_col = 0,
            hl_group = hl,
        })
    end
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local rollup = checks.rollup
    local title = (" checks · %s "):format(
        (rollup ~= nil and rollup ~= "") and rollup or "no rollup"
    )
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width + 1,
        height = math.min(#lines, math.max(1, vim.o.lines - 6)),
        row = math.floor((vim.o.lines - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = title,
        title_pos = "center",
    })
    vim.wo[win].cursorline = true

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    local function open_under_cursor()
        local row = vim.api.nvim_win_get_cursor(win)[1]
        local url = urls[row]
        if url and url ~= "" then
            close()
            vim.ui.open(url)
        else
            notify("this check has no url", vim.log.levels.WARN)
        end
    end
    vim.keymap.set("n", "<CR>", open_under_cursor, { buffer = buf, nowait = true })
    vim.keymap.set("n", "o", open_under_cursor, { buffer = buf, nowait = true })
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true })
    end
end

-- :Differ pr checks — fetch the rollup for the live session's PR and show the float
---@param session table  -- the live pr session ({ pr = { owner, repo, number } })
function M.show(session)
    client.get_checks(session.pr, function(err, checks)
        if err then
            return require("differ.pr").notify_err(err)
        end
        render(checks)
    end)
end

return M
