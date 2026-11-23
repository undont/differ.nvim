-- helpers for rows that stage as one unit: X's revert, the row's state, and the
-- staged content s or u would lose

local exec = require("differ.git.exec")
local help = require("differ.ui.help")
local index_ops = require("differ.git.index")
local rev = require("differ.git.rev")
local raw_line = require("differ.git.content").raw_line
local git = exec.git
local index_path = index_ops.index_path
local gitmod = require("differ.git.staging.write").gitmod

local SYMLINK = "120000"

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
        local why = index_ops.discard_refusal(ctx.keys, entry)
        if why then
            return nil, nil, why
        end
        return function()
            return index_ops.restore_deleted(ctx.keys, ctx.root, entry)
        end,
            "restores the file"
    end
    local discard = function()
        return gitmod().discard(ctx.keys, ctx.root, entry, preview)
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

-- whether the index holds a mode change the HEAD<->worktree diff can't show: staged,
-- then put back in the worktree
---@param modes differ.git.Modes|nil
---@return boolean
local function mode_hidden(modes)
    if not modes then
        return false
    end
    return modes.index ~= modes.head and modes.index ~= modes.worktree
end

-- the row's modes as git holds them now, nil when either pair has no change left
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return differ.git.Modes|nil
local function live_modes(ctx, entry)
    local head_index = raw_line(ctx.root, { "--cached" }, entry)
    local index_work = raw_line(ctx.root, {}, entry)
    if not (head_index and index_work) then
        return nil
    end
    local head, index = rev.parse_raw_modes(head_index)
    local _, worktree = rev.parse_raw_modes(index_work)
    return { head = head, index = index, worktree = worktree }
end

-- whether the row's index entry holds a mode or blob that neither HEAD nor the file
-- on disk has, so taking it out of the index loses it
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return boolean
local function unheld_entry(ctx, entry)
    if mode_hidden(live_modes(ctx, entry)) then
        return true
    end
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
-- change deleted on disk stages as the deletion, dropping the index's blob and mode
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return boolean
local function stage_drops(ctx, entry)
    if entry.y ~= "D" or entry.x == " " or entry.x == "D" or entry.status == "U" then
        return false
    end
    return unheld_entry(ctx, entry)
end

-- the prompt s and S ask first when staging the row whole drops content now
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return string|nil
local function stage_prompt(ctx, entry)
    local dropping = gitmod().drops_now(ctx.root, { entry }, function(current)
        return stage_drops(ctx, current)
    end)
    if dropping[entry] then
        return DROP_PROMPTS.stage.one
    end
    return nil
end

-- whether the row stages a symlink as an add. emptying it by line leaves a regular
-- file, so it stages whole
---@param entry differ.FileEntry
---@return boolean
local function symlink_add(entry)
    return entry.x == "A" and entry.modes ~= nil and entry.modes.index == SYMLINK
end

-- what a row that stages whole is, for a selection's refusal. `letters` are the row's
-- status letters on the view's two sides, and `old` / `new` name those sides in its modes
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel
---@param letters string
---@param old "head"|"index"
---@param new "index"|"worktree"
---@return string
local function kind_of(ctx, entry, model, letters, old, new)
    local modes = entry.modes or {}
    local new_mode = modes[new]
    if not new_mode and new == "worktree" then
        local st = vim.uv.fs_lstat(ctx.root .. "/" .. entry.path)
        if st and st.type == "link" then
            new_mode = SYMLINK
        end
    end
    if entry.x == "A" and entry.y == "D" then
        return "a file gone from disk"
    end
    if letters:find("D") then
        return "a deleted file"
    end
    if letters:find("T") then
        return "a type change"
    end
    if modes[old] == index_ops.GITLINK or new_mode == index_ops.GITLINK then
        return "a submodule"
    end
    if model.binary then
        return "a binary file"
    end
    if new_mode == SYMLINK then
        return "a symlink"
    end
    if letters:find("[RC]") and #model.hunks == 0 then
        return "a move"
    end
    if modes[old] and new_mode and modes[old] ~= new_mode then
        return "a mode change"
    end
    return "this file"
end

-- s / u / X's refusals on a selection of a row that stages whole. X names what it
-- does instead where it acts on the row
---@param ctx differ.git.StagingCtx
---@param staging differ.view.Staging
---@param kind string  -- from kind_of
local function no_lines(ctx, staging, kind)
    staging.no_stage_lines = kind .. " stages whole, not by line"
    local msg = kind .. " has no lines to revert"
    local discard = help.key(ctx.keys, "discard")
    if staging.revert and staging.revert_label and discard then
        msg = ("%s; %s %s"):format(msg, discard, staging.revert_label)
    end
    staging.no_revert_lines = msg
end

return {
    DROP_PROMPTS = DROP_PROMPTS,
    symlink_add = symlink_add,
    kind_of = kind_of,
    no_lines = no_lines,
    whole_file_revert = whole_file_revert,
    row_state = row_state,
    mode_hidden = mode_hidden,
    live_modes = live_modes,
    unheld_entry = unheld_entry,
    stage_drops = stage_drops,
    stage_prompt = stage_prompt,
}
