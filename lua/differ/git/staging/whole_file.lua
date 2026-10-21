-- helpers for rows that stage as one unit: X's revert, the row's state, and the
-- staged content s or u would lose

local exec = require("differ.git.exec")
local index_ops = require("differ.git.index")
local git = exec.git
local index_path = index_ops.index_path
local gitmod = require("differ.git.staging.write").gitmod

-- the confirms before s/S or u/U drop staged content nothing else holds, in the panel
-- and a file's own view
---@type differ.panel.DropPrompts
local DROP_PROMPTS = {
    stage = {
        one = "Stage the deletion of %s? The staged file will be lost.",
        many = "Stage these files? Staged changes in %s will be lost.",
    },
    unstage = {
        one = "Unstage %s? The staged change will be lost.",
        many = "Unstage these files? Staged changes in %s will be lost.",
    },
}

-- X on a whole-file row, and what it does to the file. `letter` owns the change the
-- row shows: its status for a worktree row, the index's (x) in the commit preview.
-- a row X can't act on has no revert and says why instead, so the key refuses
-- before the prompt rather than after it
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param letter string
---@param preview boolean  -- the entry is lettered by its index side
---@return (fun(): boolean)|nil revert, string|nil label, string|nil no_revert
local function whole_file_revert(ctx, entry, letter, preview)
    if letter == "D" then
        local why = index_ops.discard_refusal(entry)
        if why then
            return nil, nil, why
        end
        return function()
            return index_ops.restore_deleted(ctx.root, entry)
        end,
            "restores the file"
    end
    local discard = function()
        return gitmod().discard(ctx.root, entry, preview)
    end
    if letter == "A" or letter == "?" then
        return discard, "deletes the file"
    end
    return discard, "resets it to HEAD"
end

-- a whole-file row's staged state. a conflict holds both sides at once, which the
-- view has no third state for
---@param entry differ.FileEntry
---@return differ.model.HunkState
local function row_state(entry)
    if entry.review == "staged" then
        return "staged"
    end
    if entry.review == "partial" or entry.review == "conflict" then
        return "partial"
    end
    return "unstaged"
end

-- whether the index holds a blob for the row that neither HEAD nor the file on disk
-- has, so taking it out of the index loses it
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return boolean
local function unheld_blob(ctx, entry)
    local listed = git({ "ls-files", "-s", "--", index_path(entry) }, ctx.root) or ""
    local sha = listed:match("^%d+ (%x+)")
    if not sha then
        return false
    end
    local head = git(
        { "rev-parse", "-q", "--verify", "HEAD:" .. (entry.previous_path or entry.path) },
        ctx.root
    )
    if head and vim.trim(head) == sha then
        return false
    end
    local abs = ctx.root .. "/" .. entry.path
    if vim.uv.fs_lstat(abs) then
        local work = git({ "hash-object", "--path=" .. entry.path, abs }, ctx.root)
        if work and vim.trim(work) == sha then
            return false
        end
    end
    return true
end

-- whether staging the whole row loses staged content nothing else holds: a staged
-- change deleted on disk stages as the deletion, dropping the index's blob
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return boolean
local function stage_drops(ctx, entry)
    if entry.y ~= "D" or entry.x == " " or entry.x == "D" or entry.status == "U" then
        return false
    end
    return unheld_blob(ctx, entry)
end

return {
    DROP_PROMPTS = DROP_PROMPTS,
    whole_file_revert = whole_file_revert,
    row_state = row_state,
    unheld_blob = unheld_blob,
    stage_drops = stage_drops,
}
