-- the diff view's staging for a row shown as HEAD↔worktree: s, u, S, U and X on its hunks and lines

local rev = require("differ.git.rev")
local exec = require("differ.git.exec")
local help = require("differ.ui.help")
local patch = require("differ.git.patch")
local notify = exec.notify
local content_ops = require("differ.git.content")
local raw_line = content_ops.raw_line
local union_models, union_pairs = content_ops.union_models, content_ops.union_pairs
local write = require("differ.git.staging.write")
local edits, MOVES_OTHERS = write.edits, write.MOVES_OTHERS
local put_index, index_unreadable = write.put_index, write.index_unreadable
local revert_worktree = write.revert_worktree
local selected = require("differ.git.staging.selection")

-- the mode of the side S (the worktree) or U (HEAD) takes, or nil when the index is
-- already there. a `diff --raw` line reads `:<src mode> <dst mode> ...`
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param staged boolean
---@return string|nil
local function side_mode(ctx, entry, staged)
    local line = raw_line(ctx.root, staged and {} or { "--cached" }, entry)
    if not line then
        return nil
    end
    local index_mode, work_mode = rev.parse_raw_modes(line)
    local want = staged and work_mode or index_mode
    local held = staged and index_mode or work_mode
    if not want or want == held or want:match("^0+$") then
        return nil
    end
    return want
end

-- whether the index holds a mode change the HEAD↔worktree diff can't show: staged,
-- then put back in the worktree
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return boolean
local function mode_hidden(ctx, entry)
    local cached = raw_line(ctx.root, { "--cached" }, entry)
    local unstaged = raw_line(ctx.root, {}, entry)
    if not (cached and unstaged) then
        return false
    end
    local head_mode, index_mode = rev.parse_raw_modes(cached)
    local _, work_mode = rev.parse_raw_modes(unstaged)
    return index_mode ~= head_mode and index_mode ~= work_mode
end

-- why `hunk` can't move on its own, either way naming the view where its change
-- is a hunk of its own and can be taken whole. `reaches` names another union
-- hunk a pair hunk would carry the op into; without one the two pairs line this
-- hunk's change up under a different one, leaving nothing here to write
---@param keys differ.KeymapSet
---@param take boolean
---@param reaches integer|nil
---@return string
local function refusal(keys, take, reaches)
    local whole = help.key(keys, "commit_preview")
    if take then
        whole = help.key(keys, "toggle_local")
    end
    if not reaches then
        if take then
            return ("this hunk can't be staged on its own here; stage it from %s"):format(whole)
        end
        return ("this hunk can't be unstaged on its own here; unstage it from %s"):format(whole)
    end
    local msg = "this hunk can't be unstaged without hunk %d; unstage it from %s"
    if take then
        msg = "this hunk can't be staged without hunk %d; stage it from %s"
    end
    return msg:format(reaches, whole)
end

-- why a selection can't move, staged (`take`), unstaged or reverted: the refusal,
-- then a hint naming the action's key
---@type table<differ.model.SelectRefusal, table<"stage"|"unstage"|"revert", string[]>>
local SELECT_REFUSALS = {
    between = {
        stage = {
            "these lines can't be staged on their own here",
            "stage them from %s",
            "toggle_local",
        },
        unstage = {
            "these lines can't be unstaged on their own here",
            "unstage them from %s",
            "commit_preview",
        },
        revert = { "these lines can't be reverted on their own here" },
    },
    large = {
        stage = {
            "this file's changes are too large to stage by line",
            "%s stages a hunk whole",
            "stage",
        },
        unstage = {
            "this file's changes are too large to unstage by line",
            "%s unstages a hunk whole",
            "unstage",
        },
        revert = {
            "this file's changes are too large to revert by line",
            "%s reverts a hunk whole",
            "discard",
        },
    },
    hidden = {
        stage = { "this hunk holds staged content it can't show", "%s stages it whole", "stage" },
        unstage = {
            "this hunk holds staged content it can't show",
            "%s unstages it whole",
            "unstage",
        },
        revert = {
            "this hunk holds staged content it can't show",
            "%s reverts it whole",
            "discard",
        },
    },
}

-- a selection's refusal for `op`, its hint dropped when the hint's action is disabled
---@param keys differ.KeymapSet
---@param refused differ.model.SelectRefusal
---@param op "stage"|"unstage"|"revert"
---@return string
local function select_refusal(keys, refused, op)
    local why, hint, action = unpack(SELECT_REFUSALS[refused][op])
    local key = action and help.key(keys, action)
    if not key then
        return why
    end
    return ("%s; %s"):format(why, hint:format(key))
end

-- X's refusal for a selection. an index that can't be cut holds a change the
-- union can't show, or only repeats lines the cut can't place
---@param keys differ.KeymapSet
---@param refused differ.model.SelectRefusal
---@param union differ.DiffModel     -- HEAD↔worktree
---@param cached differ.DiffModel    -- HEAD↔index
---@param unstaged differ.DiffModel  -- index↔worktree
---@return string
local function revert_refusal(keys, refused, union, cached, unstaged)
    local marks = require("differ.model.marks")
    if refused ~= "between" then
        return select_refusal(keys, refused, "revert")
    end
    if not marks.complete(union.hunks, cached.hunks, unstaged.hunks) then
        local msg = "blocked by a staged change only %s shows (the ! hunk)"
        return msg:format(help.key(keys, "toggle_local"))
    end
    return select_refusal(keys, refused, "revert")
end

-- whether the diff still shows the file as it is. one drawn before the file or
-- HEAD moved would place an op by stale line numbers, so it refuses and re-reads
---@param ctx differ.git.StagingCtx
---@param model differ.DiffModel  -- the view's
---@param union differ.DiffModel  -- read fresh
---@return boolean
local function drawn_current(ctx, model, union)
    if model.old_text == union.old_text and model.new_text == union.new_text then
        return true
    end
    notify("the file changed since the diff was drawn: re-reading", vim.log.levels.WARN)
    ctx.retarget_later(true)
    return false
end

-- the index and file X on `selection` writes, read back before anything is. nil
-- and why where it refuses; nil alone where it touches no hunk
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@param selection differ.model.Selection
---@return string|nil index_text, differ.DiffModel|nil reverted, string|nil why
local function revert_texts(ctx, entry, union, cached, unstaged, selection)
    local index_text, reverted, refused =
        selected.revert(ctx.root, entry.path, union, cached, unstaged, selection)
    if refused == "moves_others" then
        return nil, nil, MOVES_OTHERS
    end
    if refused then
        ---@cast refused differ.model.SelectRefusal
        return nil, nil, revert_refusal(ctx.keys, refused, union, cached, unstaged)
    end
    return index_text, reverted
end

-- one HEAD↔worktree row's staging and what its ops read from it
---@class differ.git.UnionSource
---@field ctx differ.git.StagingCtx
---@field entry differ.FileEntry
---@field staging differ.view.Staging
---@field mode_change boolean  -- the index holds a mode change, which no hunk shows

-- the view keeps staging.marks, so a re-mark writes through it. marks come from
-- the index's own lines at each hunk, and from the two pairs only when the index
-- changes a line between hunks
---@param source differ.git.UnionSource
---@param union differ.DiffModel|nil  -- nil keeps the marks there are
---@param cached differ.DiffModel|nil
---@param unstaged differ.DiffModel|nil
local function remark(source, union, cached, unstaged)
    local stage = require("differ.model.stage")
    local staging = source.staging
    if not (union and cached and unstaged) then
        return
    end
    local m, hidden, hidden_in = stage.marks_of(union, cached, unstaged)
    staging.marks.old, staging.marks.new = m.old, m.new
    staging.hidden, staging.hidden_in = nil, nil
    if source.mode_change then
        staging.hidden = true
    end
    if hidden then
        staging.hidden, staging.hidden_in = true, hidden_in
    end
end

---@param source differ.git.UnionSource
---@param model differ.DiffModel
---@param hunk differ.Hunk|nil
---@param reverse boolean
---@return boolean, boolean|nil
local function apply(source, model, hunk, reverse)
    local stage = require("differ.model.stage")
    local ctx, entry = source.ctx, source.entry
    if not hunk then
        return false
    end
    local union, cached, unstaged = union_models(ctx.root, entry)
    if not (union and cached and unstaged) then
        return index_unreadable(entry)
    end
    if not drawn_current(ctx, model, union) then
        return false
    end
    local take = not reverse
    local text, reaches = stage.next_index(union, cached, unstaged, hunk, take)
    local after
    if text then
        local selection = stage.hunk_selection(hunk)
        after =
            selected.checked(ctx.root, entry.path, union, cached, unstaged, selection, take, text)
    end
    if not (text and after) then
        -- neither refusal is a failure: the key moves on, and the message says
        -- where this hunk's change can be taken whole
        notify(refusal(ctx.keys, take, reaches), vim.log.levels.WARN)
        return false, true
    end
    if not put_index(ctx, entry, text) then
        return false
    end
    remark(source, unpack(after))
    return true
end

-- s and u on a visual selection: those lines alone move. lines already where the
-- op would put them leave the index as it is
---@param source differ.git.UnionSource
---@param model differ.DiffModel
---@param selection differ.model.Selection
---@param reverse boolean
---@return boolean, boolean?
local function apply_lines(source, model, selection, reverse)
    local ctx, entry = source.ctx, source.entry
    local union, cached, unstaged = union_models(ctx.root, entry)
    if not (union and cached and unstaged) then
        return index_unreadable(entry)
    end
    if not drawn_current(ctx, model, union) then
        return false
    end
    local take = not reverse
    local text, after, refused =
        selected.stage(ctx.root, entry.path, union, cached, unstaged, selection, take)
    if refused == "unread" or refused == "moves_others" then
        notify(MOVES_OTHERS, vim.log.levels.WARN)
        return false, true
    end
    if refused then
        ---@cast refused differ.model.SelectRefusal
        local op = "unstage"
        if take then
            op = "stage"
        end
        notify(select_refusal(ctx.keys, refused, op), vim.log.levels.WARN)
        return false, true
    end
    if not (text and after) then
        local state = "unstaged"
        if take then
            state = "staged"
        end
        notify("these lines are already " .. state, vim.log.levels.INFO)
        return false
    end
    if not put_index(ctx, entry, text) then
        return false
    end
    remark(source, unpack(after))
    return true
end

-- the index and file X on hunk `idx` writes, read back before anything is: the drawn
-- reading's index, as for u. nil and why where it refuses
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel
---@param idx integer
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@return string|nil index_text, string|nil work_text, string|nil why
local function revert_hunk_texts(ctx, entry, model, idx, union, cached, unstaged)
    local stage = require("differ.model.stage")
    local hunk = model.hunks[idx]
    local text, reaches = stage.next_index(union, cached, unstaged, hunk, false)
    if reaches then
        return nil, nil, ("this hunk can't be reverted without hunk %d"):format(reaches)
    end
    -- a hunk the index holds nothing of on its own leaves the index where it is,
    -- and the worktree still has the whole change to give back
    local index_text = text or cached.new_text
    local work_text = require("differ.model.diff").revert_hunk(model, idx).new_text
    local m, hidden, _, unread = stage.marks_of(union, cached, unstaged)
    local selection = stage.hunk_selection(hunk)
    local want = stage.reverted(union, m, selection)
    local before = { union = union, cached = cached, hidden = hidden, edits = edits }
    local after = { union_pairs(ctx.root, entry.path, union.old_text, index_text, work_text) }
    if unread or not stage.reads_as(want, before, selection, unpack(after)) then
        return nil, nil, "this hunk can't be reverted on its own here"
    end
    return index_text, work_text
end

-- X's refusals on a hunk, said before the prompt, which says as much itself: a
-- drawing the file has moved on from, and any revert_hunk_texts gives
---@param source differ.git.UnionSource
---@param model differ.DiffModel
---@param idx integer
---@return boolean
local function refuses_revert(source, model, idx)
    local ctx, entry = source.ctx, source.entry
    local union, cached, unstaged = union_models(ctx.root, entry)
    if not (union and cached and unstaged) then
        index_unreadable(entry)
        return true
    end
    if not drawn_current(ctx, model, union) then
        return true
    end
    local _, _, why = revert_hunk_texts(ctx, entry, model, idx, union, cached, unstaged)
    if why then
        notify(why, vim.log.levels.WARN)
        return true
    end
    return false
end

-- X throws the hunk away on both sides at once: the index gives up whatever of
-- it it holds and the worktree gives up the rest
---@param source differ.git.UnionSource
---@param model differ.DiffModel
---@param idx integer
---@return boolean
local function revert(source, model, idx)
    local ctx, entry = source.ctx, source.entry
    local union, cached, unstaged = union_models(ctx.root, entry)
    if not (union and cached and unstaged) then
        return index_unreadable(entry)
    end
    if not drawn_current(ctx, model, union) then
        return false
    end
    local index_text, work_text, why =
        revert_hunk_texts(ctx, entry, model, idx, union, cached, unstaged)
    if why then
        notify(why, vim.log.levels.WARN)
        return false
    end
    if not (index_text and work_text) then
        return false
    end
    local p = patch.hunk(model.path, model.hunks[idx], model.old_text, model.new_text, 0, "new")
    local ok = revert_worktree(ctx, entry, p, function()
        return index_text == cached.new_text or put_index(ctx, entry, index_text)
    end)
    if not ok then
        remark(source, union_models(ctx.root, entry))
        return false
    end
    remark(source, union_pairs(ctx.root, entry.path, union.old_text, index_text, work_text))
    return true
end

-- the selection's revert_lines refusals, said before X's prompt
---@param source differ.git.UnionSource
---@param model differ.DiffModel
---@param selection differ.model.Selection
---@return boolean
local function refuses_revert_lines(source, model, selection)
    local ctx, entry = source.ctx, source.entry
    local union, cached, unstaged = union_models(ctx.root, entry)
    if not (union and cached and unstaged) then
        index_unreadable(entry)
        return true
    end
    if not drawn_current(ctx, model, union) then
        return true
    end
    local _, _, why = revert_texts(ctx, entry, union, cached, unstaged, selection)
    if why then
        notify(why, vim.log.levels.WARN)
        return true
    end
    return false
end

-- X on a visual selection: those lines go back to HEAD in the index and the file
-- at once. an index already without them stays as it is
---@param source differ.git.UnionSource
---@param model differ.DiffModel
---@param selection differ.model.Selection
---@return boolean, boolean?, differ.DiffModel?
local function revert_lines(source, model, selection)
    local ctx, entry = source.ctx, source.entry
    local union, cached, unstaged = union_models(ctx.root, entry)
    if not (union and cached and unstaged) then
        return index_unreadable(entry)
    end
    if not drawn_current(ctx, model, union) then
        return false
    end
    local index_text, reverted, why = revert_texts(ctx, entry, union, cached, unstaged, selection)
    if why then
        notify(why, vim.log.levels.WARN)
        return false, true
    end
    if not (index_text and reverted) then
        return false
    end
    -- last to first, so each hunk's lines are still where the file has them
    local patches = {}
    for i = #reverted.hunks, 1, -1 do
        local h = reverted.hunks[i]
        patches[#patches + 1] =
            patch.hunk(model.path, h, reverted.old_text, reverted.new_text, 0, "new")
    end
    local ok = revert_worktree(ctx, entry, table.concat(patches), function()
        return index_text == cached.new_text or put_index(ctx, entry, index_text)
    end)
    if not ok then
        remark(source, union_models(ctx.root, entry))
        return false
    end
    remark(source, union_pairs(ctx.root, entry.path, union.old_text, index_text, reverted.old_text))
    return true, nil, reverted
end

-- S and U: the index takes the worktree's or HEAD's side of the file whole,
-- staged content no hunk shows and the mode included. the move a rename made
-- stays staged either way; the panel row's keys own that
---@param source differ.git.UnionSource
---@param model differ.DiffModel
---@param staged boolean
---@return boolean, boolean?
local function set_all(source, model, staged)
    local ctx, entry = source.ctx, source.entry
    local union, cached = union_models(ctx.root, entry)
    if not (union and cached) then
        return index_unreadable(entry), true
    end
    if not drawn_current(ctx, model, union) then
        return false, true
    end
    local text = staged and union.new_text or union.old_text
    local mode = side_mode(ctx, entry, staged)
    if text == cached.new_text and not mode then
        return false
    end
    if not put_index(ctx, entry, text, mode) then
        return false, true
    end
    remark(source, union_pairs(ctx.root, entry.path, union.old_text, text, union.new_text))
    return true
end

-- the `!` hunks hold staged content neither side shows, and U takes all of it. a
-- hunk u can't move on its own drops nothing: its refusal needs no prompt first
---@param source differ.git.UnionSource
---@param model differ.DiffModel
---@param idx integer|nil
---@return boolean
local function unheld(source, model, idx)
    local stage = require("differ.model.stage")
    local ctx, entry, staging = source.ctx, source.entry, source.staging
    if not idx then
        return staging.hidden == true
    end
    if not vim.tbl_contains(staging.hidden_in or {}, idx) then
        return false
    end
    local union, cached, unstaged = union_models(ctx.root, entry)
    if not (union and cached and unstaged) then
        return true
    end
    return stage.next_index(union, cached, unstaged, model.hunks[idx], false) ~= nil
end

-- staging for a row shown as HEAD↔worktree. staging a hunk gives the index the
-- worktree's version of its lines, unstaging keeps every staged change except those;
-- each op reads the pairs once and re-marks from the text it wrote
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return differ.view.Staging
local function union_staging(ctx, entry)
    local mode_change = false
    if entry.x ~= " " and entry.y ~= " " and mode_hidden(ctx, entry) then
        mode_change = true
    end
    ---@type differ.view.Staging
    local staging = { marks = { old = {}, new = {} }, refresh = ctx.refresh }
    ---@type differ.git.UnionSource
    local source = { ctx = ctx, entry = entry, staging = staging, mode_change = mode_change }

    remark(source, union_models(ctx.root, entry))
    staging.apply = function(model, hunk, reverse)
        return apply(source, model, hunk, reverse)
    end
    staging.apply_lines = function(model, selection, reverse)
        return apply_lines(source, model, selection, reverse)
    end
    staging.refuses_revert = function(model, idx)
        return refuses_revert(source, model, idx)
    end
    staging.revert = function(model, idx)
        return revert(source, model, idx)
    end
    staging.refuses_revert_lines = function(model, selection)
        return refuses_revert_lines(source, model, selection)
    end
    staging.revert_lines = function(model, selection)
        return revert_lines(source, model, selection)
    end
    staging.set_all = function(model, staged)
        return set_all(source, model, staged)
    end
    staging.unheld = function(model, idx)
        return unheld(source, model, idx)
    end
    return staging
end

return { union_staging = union_staging }
