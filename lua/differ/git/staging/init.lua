-- staging for one panel session's rows: the diff view's s/u/S/U/X, the commit preview's
-- frozen keys and the local view's. every op works out the content the index should
-- hold and writes it whole. the session passes in its root and its callbacks

local rev = require("differ.git.rev")
local help = require("differ.ui.help")
local index_ops = require("differ.git.index")
local set_staged = index_ops.set_staged
local raw_line = require("differ.git.content").raw_line
local union_staging = require("differ.git.staging.union").union_staging
local file_lines = require("differ.git.staging.write").file_lines
local whole_file = require("differ.git.staging.whole_file")
local whole_file_revert, row_state = whole_file.whole_file_revert, whole_file.row_state
local unheld_blob, stage_drops = whole_file.unheld_blob, whole_file.stage_drops
local frozen = require("differ.git.staging.frozen")
local for_index, for_preview, for_local = frozen.for_index, frozen.for_preview, frozen.for_local

local M = {}

-- the whole-file rows X acts on: a file that came, went, or changed kind altogether.
-- `T` is a path swapped for a symlink or the other way round, which has no hunk to take
---@type table<string, boolean>
local REVERTABLE_WHOLE = { ["?"] = true, A = true, D = true, T = true }

M.DROP_PROMPTS = whole_file.DROP_PROMPTS

---@class differ.git.StagingCtx
---@field root string
---@field keys differ.KeymapSet                -- the diff's, which its notices name
---@field stageable boolean                    -- a worktree source: rev-pair rows don't stage
---@field refresh fun()                        -- reload the panel's list
---@field retarget fun(outside: boolean)       -- re-source the view onto the row's state now
---@field retarget_later fun(refresh?: boolean) -- retarget once the op returns; `refresh` reloads the list first
---@field preview_off fun()                    -- leave the commit preview
---@field current_view fun(): differ.View|nil

-- whether the row stages by hunk once its diff has any. git records no rename, only
-- the old path gone from the index and the new one present, so a hunk stages an
-- ordinary blob and the move rides along untouched. the move is whole-file and
-- belongs to the panel row's keys
---@param entry differ.FileEntry
---@return boolean
local function by_line(entry)
    local content = entry.status == "M" or entry.status == "R" or entry.status == "C"
    local added = entry.status == "A" and entry.x == "A"
    return (content or added) and entry.x ~= "D" and entry.y ~= "T"
end

-- X's refusal on a selection of a file that reverts whole
---@param ctx differ.git.StagingCtx
---@param what string  -- the kind of file
---@param does string  -- what X does to it
---@return string
local function no_lines(ctx, what, does)
    local msg = what .. " has no lines to revert"
    local discard = help.key(ctx.keys, "discard")
    if discard then
        msg = ("%s; %s %s it whole"):format(msg, discard, does)
    end
    return msg
end

-- staging for a row's HEAD↔worktree diff: by hunk through union_staging, else the file as one unit
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param diff differ.DiffModel  -- the entry's built model; its hunk count and binary flag are read
---@return differ.view.Staging|nil
local function for_union(ctx, entry, diff)
    if not ctx.stageable then
        return nil
    end
    if by_line(entry) and #diff.hunks > 0 then
        local staging = union_staging(ctx, entry)
        if entry.x == "A" then
            -- throwing away an add is deleting the file, not reverting a hunk of it
            staging.revert, staging.revert_label, staging.no_revert =
                whole_file_revert(ctx, entry, "A", false)
        end
        return staging
    end
    -- whole-file from here: nothing to stage by line (a mode change, a submodule, a
    -- binary file, a bare rename, a file swapped for a symlink), or a file added,
    -- untracked or deleted as one unit
    ---@type differ.view.Staging
    local staging = {
        initial = row_state(entry),
        whole_file = true,
        apply = function(_, _, reverse)
            if not set_staged(ctx.root, entry, not reverse) then
                return false
            end
            -- the op moves the row's letters, which X and the next s or u act on
            ctx.retarget_later()
            return true
        end,
        unheld = function()
            return unheld_blob(ctx, entry)
        end,
        refresh = ctx.refresh,
    }
    if stage_drops(ctx, entry) then
        staging.confirm_stage = M.DROP_PROMPTS.stage.one
    end
    -- X puts a mode change or a binary file back as HEAD has it. a move stays with the
    -- panel row's keys, and a submodule has no X
    if entry.status == "M" then
        local head_mode, work_mode =
            rev.parse_raw_modes(raw_line(ctx.root, { "HEAD" }, entry) or "")
        local why = index_ops.discard_refusal(ctx.keys, entry, head_mode, work_mode)
        if why then
            staging.no_revert = why
            staging.no_revert_lines = "a submodule has no lines to revert"
        else
            staging.revert, staging.revert_label = whole_file_revert(ctx, entry, "M", false)
            staging.no_revert_lines = no_lines(ctx, "a mode change", "resets")
            if diff.binary then
                staging.no_revert_lines = no_lines(ctx, "a binary file", "resets")
            end
        end
    end
    if entry.status == "M" or entry.status == "R" or entry.status == "C" then
        if entry.status == "R" or entry.status == "C" then
            staging.no_revert = "the move reverts from the panel row, where discard is disabled"
            local discard = help.key(help.keys("panel"), "discard")
            if discard then
                staging.no_revert = ("%s on the panel row undoes the move"):format(discard)
            end
        end
        return staging
    end
    -- an add's discard drops the staged entry before removing the file; a
    -- typechange's puts HEAD's own kind of file back over the one on disk
    if REVERTABLE_WHOLE[entry.status] then
        staging.revert, staging.revert_label, staging.no_revert =
            whole_file_revert(ctx, entry, entry.status, false)
        if entry.status == "D" then
            staging.no_revert_lines = no_lines(ctx, "a deleted file", "restores")
        elseif diff.binary then
            staging.no_revert_lines = no_lines(ctx, "a binary file", "resets")
        elseif entry.status == "?" and #diff.hunks > 0 then
            -- an untracked file goes back to nothing, so its selected lines just leave it
            file_lines(ctx, entry, staging, function()
                return ""
            end, function()
                ctx.refresh()
                ctx.retarget(false)
            end)
        end
        return staging
    end
    return nil
end

-- whether unstaging the whole row loses staged content nothing else holds: what U
-- in the row's diff view confirms on
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param work_model fun(): differ.DiffModel  -- HEAD↔worktree, built only when read
---@return boolean
local function unstage_drops(ctx, entry, work_model)
    if entry.x == " " or entry.x == "?" then
        return false
    end
    if by_line(entry) and #work_model().hunks > 0 then
        return union_staging(ctx, entry).hidden == true
    end
    return unheld_blob(ctx, entry)
end

-- a row with a staged change and more on top of it: the one kind with a local view.
-- of the rows whose file is then deleted, only an add has one: the others stage the
-- deletion from their whole change, and an add's whole change is HEAD↔index
---@param entry differ.FileEntry
---@return boolean
local function partly_staged(entry)
    if entry.status == "U" or entry.x == "?" then
        return false
    end
    if entry.y == "D" and entry.x ~= "A" then
        return false
    end
    return entry.x ~= " " and entry.y ~= " "
end

---@param ctx differ.git.StagingCtx
---@return table
function M.new(ctx)
    return {
        for_union = function(entry, diff)
            return for_union(ctx, entry, diff)
        end,
        for_local = function(entry, model, reopen)
            return for_local(ctx, entry, model, reopen)
        end,
        for_preview = function(entry, model)
            return for_preview(ctx, entry, model)
        end,
        for_index = function(entry, model, preview)
            return for_index(ctx, entry, model, preview)
        end,
        partly_staged = partly_staged,
        stage_drops = function(entry)
            return stage_drops(ctx, entry)
        end,
        unstage_drops = function(entry, work_model)
            return unstage_drops(ctx, entry, work_model)
        end,
    }
end

return M
