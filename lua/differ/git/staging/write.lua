-- the index and worktree writes the staging views share

local exec = require("differ.git.exec")
local patch = require("differ.git.patch")
local notify, git_ok = exec.notify, exec.git_ok
local reload_buffer = exec.reload_buffer
local write_index = require("differ.git.index").write_index
local content_ops = require("differ.git.content")
local read, WORKTREE = content_ops.read, content_ops.WORKTREE

-- lazy: differ.git requires this module
local function gitmod()
    return require("differ.git")
end

-- the lines a minimal diff drops from `a` and adds to reach `b`
---@param a string
---@param b string
---@return integer dropped, integer added
local function edits(a, b)
    local dropped, added = 0, 0
    local hunks = vim.text.diff(a, b, { result_type = "indices", algorithm = "minimal" })
    ---@cast hunks integer[][]
    for _, h in ipairs(hunks) do
        dropped, added = dropped + h[2], added + h[4]
    end
    return dropped, added
end

-- why a selection whose texts read back as other marks writes nothing
local MOVES_OTHERS = "these lines can't be moved on their own without changing others"

-- write `text` as `entry`'s staged content. an add left with nothing staged leaves
-- the index, and a worktree rename stages with its content; both move the row
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param text string
---@param mode? string  -- the mode the entry takes; nil keeps the one it has
---@return boolean ok
local function put_index(ctx, entry, text, mode)
    if entry.x == "A" and text == "" then
        if not gitmod().unstage(ctx.root, entry.path) then
            return false
        end
        ctx.retarget_later()
        return true
    end
    if not write_index(ctx.root, entry.path, text, mode) then
        return false
    end
    if entry.y == "R" and entry.previous_path then
        local drop = { "update-index", "--force-remove", "--", entry.previous_path }
        if not git_ok(drop, ctx.root, "staging " .. entry.path) then
            return false
        end
        ctx.retarget_later()
    end
    return true
end

-- an op built on a failed index read would write the file's index from nothing
---@param entry differ.FileEntry
---@return false
local function index_unreadable(entry)
    notify(("couldn't read %s from the index"):format(entry.path), vim.log.levels.WARN)
    return false
end

-- X on a hunk or a selection: the file gives those lines back, and `stage_index`
-- moves the index's half. the file is checked first, so one that changed those lines
-- refuses before the index moves. it patches rather than writes: the new side came
-- through the clean filter, and writing it back would push that conversion to disk
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param p string  -- the patch to reverse-apply to the file
---@param stage_index fun(): boolean
---@return boolean
local function revert_worktree(ctx, entry, p, stage_index)
    if not gitmod().revert_patch(ctx.root, p, true) then
        notify("the file has changed these lines: nothing reverted", vim.log.levels.WARN)
        return false
    end
    if not stage_index() then
        return false
    end
    local ok, err = gitmod().revert_patch(ctx.root, p)
    reload_buffer(ctx.root, entry.path)
    if not ok then
        notify(exec.with_stderr("revert failed", err), vim.log.levels.ERROR)
        return false
    end
    return true
end

-- visual X where the view's old side is what the file goes back to: the selected
-- lines leave the file and the index stays as it is. both sides are read fresh, so a
-- view drawn before either moved refuses and re-reads, and the file's text reads back
-- before the prompt
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param staging differ.view.Staging
---@param base fun(): string  -- the view's old side, read now
---@param reread fun()         -- re-sources the view
---@param written? fun()       -- runs once the file is patched
local function file_lines(ctx, entry, staging, base, reread, written)
    local stage = require("differ.model.stage")
    ---@param model differ.DiffModel
    ---@param selection differ.model.Selection
    ---@return differ.DiffModel|nil reverted, boolean|nil refused
    local function reverted_text(model, selection)
        local work = read(WORKTREE, ctx.root, entry.path) or ""
        if base() ~= model.old_text or work ~= model.new_text then
            notify("the file changed since the diff was drawn: re-reading", vim.log.levels.WARN)
            vim.schedule(reread)
            return nil, true
        end
        local reverted = stage.select_worktree(model, selection)
        if not reverted then
            return nil
        end
        local after = require("differ.model.diff").build({
            path = model.path,
            old_rev = model.old_rev,
            new_rev = model.new_rev,
            old_text = model.old_text,
            new_text = reverted.old_text,
        })
        local want = stage.reverted(model, { old = {}, new = {} }, selection)
        if not stage.file_reads_as(want, work, after, edits) then
            notify(MOVES_OTHERS, vim.log.levels.WARN)
            return nil, true
        end
        return reverted
    end
    staging.refuses_revert_lines = function(model, selection)
        local _, refused = reverted_text(model, selection)
        return refused == true
    end
    staging.revert_lines = function(model, selection)
        local reverted, refused = reverted_text(model, selection)
        if not reverted then
            return false, refused
        end
        -- last to first, so each hunk's lines are still where the file has them
        local patches = {}
        for i = #reverted.hunks, 1, -1 do
            local h = reverted.hunks[i]
            patches[#patches + 1] =
                patch.hunk(model.path, h, reverted.old_text, reverted.new_text, 0, "new")
        end
        local ok = revert_worktree(ctx, entry, table.concat(patches), function()
            return true
        end)
        if ok and written then
            written()
        end
        return ok
    end
end

return {
    gitmod = gitmod,
    edits = edits,
    MOVES_OTHERS = MOVES_OTHERS,
    put_index = put_index,
    index_unreadable = index_unreadable,
    revert_worktree = revert_worktree,
    file_lines = file_lines,
}
