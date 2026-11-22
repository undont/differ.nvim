-- staging frozen at the index a view opened on: the commit preview and the local view

local rev = require("differ.git.rev")
local exec = require("differ.git.exec")
local help = require("differ.ui.help")
local index_ops = require("differ.git.index")
local patch = require("differ.git.patch")
local notify, git, git_ok = exec.notify, exec.git, exec.git_ok
local reload_buffer = exec.reload_buffer
local entry_paths = index_ops.entry_paths
local set_staged, index_path = index_ops.set_staged, index_ops.index_path
local content_ops = require("differ.git.content")
local read, raw_line = content_ops.read, content_ops.raw_line
local three_models, three_diffs = content_ops.three_models, content_ops.three_diffs
local INDEX = content_ops.INDEX
local write = require("differ.git.staging.write")
local gitmod, put_index, MOVES_OTHERS = write.gitmod, write.put_index, write.MOVES_OTHERS
local index_unreadable, revert_worktree = write.index_unreadable, write.revert_worktree
local file_lines, edits, REVERT_ENDING = write.file_lines, write.edits, write.REVERT_ENDING
local FILE_CHANGED = write.FILE_CHANGED
local whole_file = require("differ.git.staging.whole_file")
local whole_file_revert, unheld_entry = whole_file.whole_file_revert, whole_file.unheld_entry
local stage_prompt = whole_file.stage_prompt
local mode_hidden, live_modes = whole_file.mode_hidden, whole_file.live_modes
local diff_view = require("differ.git.staging.diff_view")
local hides_staged, select_refusal = diff_view.hides_staged, diff_view.select_refusal
local selected = require("differ.git.staging.selection")

-- the `update-index --chmod` flag that gives a file a mode
---@type table<string, string>
local CHMOD = { ["100644"] = "-x", ["100755"] = "+x" }

-- whether line `l` of the old side falls inside one of `hunks`
---@param hunks differ.Hunk[]
---@param l integer
---@return boolean
local function in_old_side(hunks, l)
    for _, h in ipairs(hunks) do
        if h.old_start <= l and l < h.old_start + h.old_count then
            return true
        end
    end
    return false
end

-- staging frozen at the index the view opened on: s and u rebuild it from the model's
-- old side plus the hunks marked staged, so a marked hunk stays on screen. an index
-- written outside differ since then would be lost to that rebuild, so they refuse
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel  -- read once, with at least one hunk
---@param staged boolean  -- every hunk's opening state
---@param reopen fun()
---@param place? fun(m: differ.DiffModel, reverted: differ.DiffModel): string|nil  -- X's file patch
---@return differ.view.Staging staging
---@return fun(m: differ.DiffModel, selection: differ.model.Selection, reverse: boolean): boolean, boolean? apply_lines
local function frozen_staging(ctx, entry, model, staged, reopen, place)
    local splice = require("differ.model.apply").splice
    local state = require("differ.model.marks").state
    -- the commit preview opens staged with the index as its new side; the local view
    -- opens unstaged with it as its old side
    local held = staged and model.new_text or model.old_text
    local held_sha ---@type string|nil -- held's blob id, once a listing has matched it
    local dropped = false -- the last apply took an add out of the index
    local held_mode ---@type string|nil -- the mode the last apply wrote
    local at_index = index_path(entry)
    local marks = { old = {}, new = {} }
    ---@param h differ.Hunk
    ---@param on boolean
    local function mark(h, on)
        for l = h.old_start, h.old_start + h.old_count - 1 do
            marks.old[l] = on
        end
        for l = h.new_start, h.new_start + h.new_count - 1 do
            marks.new[l] = on
        end
    end
    for _, h in ipairs(model.hunks) do
        mark(h, staged)
    end
    -- the index's mode, or false once the index has moved outside differ since the last
    -- write, which re-reads the view
    ---@return boolean unmoved, string|nil mode
    local function unmoved()
        local sha, mode = index_ops.index_entry(ctx.root, at_index, entry.path)
        if sha and sha ~= held_sha and not dropped then
            local index = content_ops.blob(ctx.root, sha)
            if index and index.text == held then
                held_sha = sha
            end
        end
        local moved = not sha or sha ~= held_sha
        if dropped then
            moved = sha ~= nil or mode ~= nil
            mode = held_mode
        end
        if moved then
            notify("the index changed outside differ: re-reading", vim.log.levels.WARN)
            vim.schedule(reopen)
            return false
        end
        return true, mode
    end
    ---@param text string
    ---@param mode string|nil
    ---@return boolean
    local function put(text, mode)
        local ok, written = put_index(ctx, entry, text, mode)
        if ok then
            -- put_index stages a rename at the new path
            held, held_sha, at_index = text, written, entry.path
            dropped, held_mode = written == nil, mode
        end
        return ok
    end
    ---@type differ.view.Staging
    local staging = {
        marks = marks,
        refresh = ctx.refresh,
        apply = function(_, hunk, reverse)
            if not hunk then
                return false
            end
            local ok, mode = unmoved()
            if not ok then
                return false
            end
            mark(hunk, not reverse)
            local applied = {}
            for i, h in ipairs(model.hunks) do
                applied[i] = state(marks, h) == "staged"
            end
            if put(splice(model, applied), mode) then
                return true
            end
            mark(hunk, reverse)
            return false
        end,
    }
    -- whether `selection` meets an unmarked `!` hunk, whose staged change u would drop
    ---@param m differ.DiffModel
    ---@param selection differ.model.Selection
    ---@return boolean
    local function meets_hidden(m, selection)
        for _, idx in ipairs(staging.hidden_in or {}) do
            local h = m.hunks[idx]
            if h and state(marks, h) == "unstaged" then
                for l = h.old_start, h.old_start + h.old_count - 1 do
                    if selection.old[l] then
                        return true
                    end
                end
                for l = h.new_start, h.new_start + h.new_count - 1 do
                    if selection.new[l] then
                        return true
                    end
                end
            end
        end
        return false
    end
    -- the index s, u or X on a selection writes: those lines of the model's pair, read
    -- back with the model's old side as base. no text where they're already there, or
    -- where it refuses (said why)
    ---@param m differ.DiffModel
    ---@param selection differ.model.Selection
    ---@param op "stage"|"unstage"|"revert"
    ---@return string|nil text, string|nil mode, boolean? refused
    local function index_lines(m, selection, op)
        local ok, mode = unmoved()
        if not ok then
            return nil, nil, true
        end
        local take = op == "stage"
        if not take and meets_hidden(m, selection) then
            notify(select_refusal(ctx.keys, "hidden", op), vim.log.levels.WARN)
            return nil, nil, true
        end
        local base, base_index, index_work =
            three_diffs(ctx.root, entry.path, m.old_text, held, m.new_text)
        local text, _, refused =
            selected.stage(ctx.root, entry.path, base, base_index, index_work, selection, take)
        -- held is the model's old side with whole hunks spliced in, so a cut that fails
        -- or reads back as others has no other view to send the lines to
        if refused == "unread" or refused == "moves_others" or refused == "between" then
            notify(MOVES_OTHERS, vim.log.levels.WARN)
            return nil, nil, true
        end
        if refused then
            ---@cast refused differ.model.SelectRefusal
            notify(select_refusal(ctx.keys, refused, op), vim.log.levels.WARN)
            return nil, nil, true
        end
        return text, mode
    end
    -- the marks number the lines the view opened on, so a line write re-reads the view
    local function reread()
        vim.schedule(function()
            local current = ctx.current_view()
            if current and current.staging == staging then
                reopen()
            end
        end)
    end
    -- s (`take`) or u on a selection
    ---@param m differ.DiffModel
    ---@param selection differ.model.Selection
    ---@param reverse boolean
    ---@return boolean, boolean?
    local function apply_lines(m, selection, reverse)
        local op, state_now = "unstage", "unstaged"
        if not reverse then
            op, state_now = "stage", "staged"
        end
        local text, mode, refused = index_lines(m, selection, op)
        if refused then
            return false, true
        end
        if not text then
            notify("these lines are already " .. state_now, vim.log.levels.INFO)
            return false
        end
        -- an emptied add leaves the index, and its mode with it
        if text == "" and entry.x == "A" and mode_hidden(live_modes(ctx, entry)) then
            notify(select_refusal(ctx.keys, "unheld", op), vim.log.levels.WARN)
            return false, true
        end
        if not put(text, mode) then
            return false
        end
        reread()
        return true
    end
    -- X on a selection: the index drops those lines as u does, and the file takes back
    -- what `place` patches ("" for none, nil where it refuses, said why). `check` runs
    -- every refusal and writes nothing
    ---@param m differ.DiffModel
    ---@param selection differ.model.Selection
    ---@param check boolean
    ---@return boolean ok, boolean? refused
    local function revert_lines(m, selection, check)
        local stage = require("differ.model.stage")
        local reverted, ending = stage.select_worktree(m, selection)
        if ending then
            notify(REVERT_ENDING[ending], vim.log.levels.WARN)
            return false, true
        end
        if not reverted then
            return false
        end
        local after = require("differ.model.diff").build({
            path = m.path,
            old_rev = m.old_rev,
            new_rev = m.new_rev,
            old_text = m.old_text,
            new_text = reverted.old_text,
        })
        local want = stage.reverted(m, { old = {}, new = {} }, selection)
        if not stage.file_reads_as(want, m.new_text, after, edits) then
            notify(MOVES_OTHERS, vim.log.levels.WARN)
            return false, true
        end
        local text, mode, refused = index_lines(m, selection, "revert")
        if refused then
            return false, true
        end
        local p = place(m, reverted)
        if not p then
            return false, true
        end
        local function stage_index()
            return text == nil or put(text, mode)
        end
        if check then
            if p ~= "" and not gitmod().revert_patch(ctx.root, p, true) then
                notify(FILE_CHANGED, vim.log.levels.WARN)
                return false, true
            end
            return true
        end
        local ok
        if p == "" then
            ok = stage_index()
        else
            ok = revert_worktree(ctx, entry, p, stage_index)
        end
        if ok then
            reread()
        end
        return ok
    end
    if place then
        staging.refuses_revert_lines = function(m, selection)
            local ok, refused = revert_lines(m, selection, true)
            return not ok and refused == true
        end
        staging.revert_lines = function(m, selection)
            return revert_lines(m, selection, false)
        end
    end
    return staging, apply_lines
end

-- whole-file staging frozen at the index the view opened on: u resets the row's
-- paths to HEAD, s puts back the entries the index held then. both refuse once the
-- index moves outside differ
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param reopen fun()
---@return differ.view.Staging
local function snapshot_staging(ctx, entry, reopen)
    local paths = entry_paths(entry)
    local function ls_files()
        return git(vim.list_extend({ "ls-files", "-s", "-z", "--" }, paths), ctx.root) or ""
    end
    local listed = ls_files()
    local held = {} ---@type table<string, string> -- path -> update-index cacheinfo
    for mode, sha, path in listed:gmatch("(%d+) (%x+) %d+\t([^%z]+)") do
        held[path] = ("%s,%s,%s"):format(mode, sha, path)
    end
    ---@param reverse boolean
    local function stage(reverse)
        if reverse then
            return set_staged(ctx.root, entry, false)
        end
        local ok = true
        for _, path in ipairs(paths) do
            local cmd = { "update-index", "--force-remove", "--", path }
            if held[path] then
                cmd = { "update-index", "--add", "--cacheinfo", held[path] }
            end
            ok = git_ok(cmd, ctx.root, "staging " .. path) and ok
        end
        return ok
    end
    return {
        initial = "staged",
        whole_file = true,
        refresh = ctx.refresh,
        unheld = function()
            -- an add's index lines still on disk aren't lost, wherever disk adds to them
            if entry.x == "A" then
                return hides_staged(ctx, entry)
            end
            return unheld_entry(ctx, entry)
        end,
        apply = function(_, _, reverse)
            if ls_files() ~= listed then
                notify("the index changed outside differ: re-reading", vim.log.levels.WARN)
                vim.schedule(reopen)
                return false
            end
            local ok = stage(reverse)
            listed = ls_files()
            return ok
        end,
    }
end

-- X in a frozen view (the commit preview, the local view): the hunk leaves the index
-- if marked staged, and the file takes its old lines back, then `reopen` re-reads the
-- view. a last hunk leaves nothing to reopen, and the view hands over to the panel
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel
---@param staging differ.view.Staging
---@param idx integer
---@param offset integer  -- the model's new-side lines to the file's, see patch.hunk
---@param reopen fun()
---@param index_only? boolean  -- the file already holds the hunk's old lines
---@return boolean
local function revert_frozen(ctx, entry, model, staging, idx, offset, reopen, index_only)
    local hunk = model.hunks[idx]
    local function stage_index()
        if require("differ.model.marks").state(staging.marks, hunk) ~= "staged" then
            return true
        end
        if not staging.apply then
            return false
        end
        return staging.apply(model, hunk, true)
    end
    local ok
    if index_only then
        ok = stage_index()
    else
        local p = patch.hunk(model.path, hunk, model.old_text, model.new_text, offset, "new")
        ok = revert_worktree(ctx, entry, p, stage_index)
    end
    if not ok then
        return false
    end
    if #model.hunks > 1 then
        vim.schedule(function()
            local current = ctx.current_view()
            if current and current.staging == staging then
                reopen()
            end
        end)
    end
    return true
end

-- where the file stands on hunk `h` of a HEAD<->index model, from `drift`, the index's
-- lines against the file's: "put_back" when a drift hunk replaces exactly h's index
-- lines with its HEAD lines, "touched" when one overlaps them otherwise, nil when the
-- file leaves them alone. a zero-line side sits between two lines
---@param drift differ.Hunk[]
---@param m differ.DiffModel
---@param h differ.Hunk
---@param work string
---@return "put_back"|"touched"|nil
local function placed_on(drift, m, h, work)
    local to_lines = require("differ.util.text").to_lines
    local function span(start, count)
        if count == 0 then
            return start + 0.5, start + 0.5
        end
        return start, start + count - 1
    end
    local lo, hi = span(h.new_start, h.new_count)
    for _, w in ipairs(drift) do
        local wlo, whi = span(w.old_start, w.old_count)
        if w.old_start == h.new_start and w.old_count == h.new_count then
            local head =
                vim.list_slice(to_lines(m.old_text), h.old_start, h.old_start + h.old_count - 1)
            local file = vim.list_slice(to_lines(work), w.new_start, w.new_start + w.new_count - 1)
            return vim.deep_equal(head, file) and "put_back" or "touched"
        end
        if wlo <= hi and lo <= whi then
            return "touched"
        end
    end
    return nil
end

-- X on a HEAD<->index row as a whole file: refused where the worktree has changes on
-- top, which this view doesn't show
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param staging differ.view.Staging
---@param preview boolean
local function index_file_revert(ctx, entry, staging, preview)
    staging.revert, staging.revert_label, staging.no_revert =
        whole_file_revert(ctx, entry, entry.x, preview)
    if entry.x == "A" and entry.y == "D" then
        staging.revert_label = "deletes the staged file"
    end
    -- read again at X: an edit since the view opened counts as well
    local why = "discard is disabled"
    local discard_key = help.key(ctx.keys, "discard")
    if discard_key then
        why = ("%s would also discard the unstaged changes to %s"):format(discard_key, entry.path)
    end
    local function unstaged_on_top(y)
        return y ~= " " and y ~= "D"
    end
    local discard = staging.revert
    if unstaged_on_top(entry.y) then
        staging.revert, staging.revert_label, staging.no_revert = nil, nil, why
        return
    end
    if not discard then
        return
    end
    staging.revert = function(...)
        local live = gitmod().live_row(ctx.root, entry)
        -- u here took the change out of the index: X has nothing staged to
        -- discard, and s puts it back
        if live and (live.x == " " or live.x == "?") then
            local msg = "%s has nothing staged now: %s stages it back"
            notify(msg:format(entry.path, help.key(ctx.keys, "stage")))
            return false
        end
        if live and unstaged_on_top(live.y) then
            notify(why, vim.log.levels.WARN)
            return false
        end
        return discard(...)
    end
end

-- staging for a row drawn HEAD<->index, in the commit preview or where that is the
-- only diff the row has. a deletion, or an add whose file is gone, is one unit whose
-- index entry comes and goes, so it stages as a file
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel  -- HEAD<->index
---@param preview boolean  -- the row comes from the commit preview's listing
---@return differ.view.Staging
local function for_index(ctx, entry, model, preview)
    local staging
    local whole = entry.x == "D" or (entry.x == "A" and entry.y == "D")
    if #model.hunks > 0 and not whole then
        -- the file against the index this view opened on: s and u move the index
        -- since, never the file
        ---@param m differ.DiffModel
        ---@return differ.Hunk[]|nil drift, string|nil work
        local function drift_of(m)
            local head_work = three_models(ctx.root, entry)
            if not head_work then
                return nil
            end
            local drift = require("differ.model.diff").build({
                path = entry.path,
                old_rev = "INDEX",
                new_rev = "WORKTREE",
                old_text = m.new_text,
                new_text = head_work.new_text,
            }).hunks
            return drift, head_work.new_text
        end
        -- the patch X on a selection reverse-applies to the file: each block the index
        -- gives back, where the file has its lines. a block the file already put back
        -- needs none, and one it has changed refuses
        ---@param m differ.DiffModel
        ---@param reverted differ.DiffModel
        ---@return string|nil
        local function file_patch(m, reverted)
            local drift, work = drift_of(m)
            if not (drift and work) then
                index_unreadable(entry)
                return nil
            end
            local blocks = require("differ.model.diff").build({
                path = entry.path,
                old_rev = m.new_rev,
                new_rev = m.new_rev,
                old_text = reverted.old_text,
                new_text = m.new_text,
            })
            local patches = {}
            -- last to first, so each block's lines are still where the file has them
            for i = #blocks.hunks, 1, -1 do
                local h = blocks.hunks[i]
                local placed = placed_on(drift, blocks, h, work)
                if placed == "touched" then
                    notify(FILE_CHANGED, vim.log.levels.WARN)
                    return nil
                end
                if not placed then
                    local at = h.new_count > 0 and h.new_start or h.new_start + 1
                    local offset = require("differ.model.marks").shift(drift, at, "old")
                    patches[#patches + 1] =
                        patch.hunk(entry.path, h, blocks.old_text, blocks.new_text, offset, "new")
                end
            end
            return table.concat(patches)
        end
        local apply_lines
        staging, apply_lines = frozen_staging(ctx, entry, model, true, function()
            ctx.retarget(false)
        end, file_patch)
        local state = require("differ.model.marks").state
        -- a staged hunk whose index lines the file doesn't hold goes with u
        staging.unheld = function(m, idx)
            -- an add is one hunk against an empty HEAD: u empties it, and the entry
            -- leaves the index with a mode the file may not have
            if entry.x == "A" and mode_hidden(live_modes(ctx, entry)) then
                return true
            end
            local drift, work = drift_of(m)
            if not (drift and work) then
                return false
            end
            for i, h in ipairs(m.hunks) do
                local wanted = idx == nil or i == idx
                if
                    wanted
                    and state(staging.marks, h) == "staged"
                    and placed_on(drift, m, h, work)
                then
                    return true
                end
            end
            return false
        end
        -- whether u on `selection` takes out a staged index line the file has changed
        ---@param m differ.DiffModel
        ---@param selection differ.model.Selection
        ---@return boolean
        local function drops_unheld(m, selection)
            local drift = drift_of(m)
            if not drift then
                return false
            end
            for _, h in ipairs(m.hunks) do
                if state(staging.marks, h) == "staged" then
                    for l = h.new_start, h.new_start + h.new_count - 1 do
                        if selection.new[l] and in_old_side(drift, l) then
                            return true
                        end
                    end
                end
            end
            return false
        end
        staging.apply_lines = function(m, selection, reverse)
            if reverse and drops_unheld(m, selection) then
                notify(select_refusal(ctx.keys, "unheld", "unstage"), vim.log.levels.WARN)
                return false, true
            end
            return apply_lines(m, selection, reverse)
        end
        staging.revert = function(m, idx)
            local h = m.hunks[idx]
            local drift, work = drift_of(m)
            if not (drift and work) then
                return index_unreadable(entry)
            end
            local function reopen()
                ctx.retarget(false)
            end
            local placed = placed_on(drift, m, h, work)
            if placed == "put_back" then
                return revert_frozen(ctx, entry, m, staging, idx, 0, reopen, true)
            end
            if placed == "touched" then
                notify(FILE_CHANGED, vim.log.levels.WARN)
                return false
            end
            local at = h.new_count > 0 and h.new_start or h.new_start + 1
            local offset = require("differ.model.marks").shift(drift, at, "old")
            return revert_frozen(ctx, entry, m, staging, idx, offset, reopen)
        end
        if entry.x == "A" then
            staging.drops_entry = true
            -- throwing away an add is deleting the file, not reverting a hunk of it
            index_file_revert(ctx, entry, staging, preview)
        end
    else
        staging = snapshot_staging(ctx, entry, function()
            ctx.retarget(false)
        end)
        index_file_revert(ctx, entry, staging, preview)
    end
    staging.badge = "INDEX"
    return staging
end

-- staging for a commit-preview row: the HEAD<->index keys, plus the way back out
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel  -- HEAD<->index
---@return differ.view.Staging
local function for_preview(ctx, entry, model)
    local staging = for_index(ctx, entry, model, true)
    staging.badge = "STAGED"
    local back = help.key(ctx.keys, "commit_preview")
    local discard = help.key(ctx.keys, "discard")
    staging.no_local = ("the commit preview has no local view: %s goes back"):format(back)
    staging.no_revert_lines = "discard is disabled"
    if discard then
        local msg = "%s reverts lines from the whole change; %s goes back"
        staging.no_revert_lines = msg:format(discard, back)
    end
    staging.leave = function()
        ctx.preview_off()
    end
    return staging
end

-- what u on `!` hunk `idx` of the local view writes: the index takes HEAD's lines
-- there, dropping the staged change the worktree undid. only the lines the hunk
-- rewrote go back where the staged block they sit in maps line for line; otherwise the
-- whole block does, and `scope` names the index lines it reaches. the hunk's lines are
-- the index's at open, moved by whatever s has staged since. no text, and why, when
-- the index can't be read or has changed outside differ
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel  -- index<->worktree, as the view opened on it
---@param staging differ.view.Staging
---@param idx integer
---@param index? differ.git.Blob  -- the index blob, identified in this op
---@return string|nil text, string|nil scope, "unreadable"|"changed"|nil why
local function drop_index(ctx, entry, model, staging, idx, index)
    local marks = require("differ.model.marks")
    local stage = require("differ.model.stage")
    local splice = require("differ.model.apply").splice
    local applied, moved = {}, {} ---@type table<integer, boolean>, differ.Hunk[]
    for i, h in ipairs(model.hunks) do
        applied[i] = marks.state(staging.marks, h) == "staged"
        if applied[i] then
            moved[#moved + 1] = h
        end
    end
    local _, head_index = three_models(ctx.root, entry, nil, index)
    if not head_index then
        return nil, nil, "unreadable"
    end
    if head_index.new_text ~= splice(model, applied) then
        return nil, nil, "changed"
    end
    local hunk = model.hunks[idx]
    local placed = vim.tbl_extend("force", hunk, {
        old_start = hunk.old_start + marks.shift(moved, hunk.old_start, "old"),
    })
    local meets = stage.select_hunks(head_index.hunks, "new", placed, "old", true)
    local first, last = placed.old_start, placed.old_start + placed.old_count - 1
    local met, lo, hi = {}, math.huge, -math.huge ---@type integer[], number, number
    for i, c in ipairs(head_index.hunks) do
        if meets[i] then
            met[#met + 1] = i
            if c.new_count > 0 then
                lo, hi = math.min(lo, c.new_start), math.max(hi, c.new_start + c.new_count - 1)
            end
        end
    end
    local c = #met == 1 and head_index.hunks[met[1]] or nil
    if
        c
        and placed.old_count > 0
        and c.old_count == c.new_count
        and first >= c.new_start
        and last <= c.new_start + c.new_count - 1
    then
        return stage.drop_lines(head_index, met[1], first, last)
    end
    local keep = stage.select_hunks(head_index.hunks, "new", placed, "old", false)
    local text = splice(head_index, keep)
    if lo >= first and hi <= last then
        return text
    end
    if lo == hi then
        return text, ("line %d"):format(lo)
    end
    return text, ("lines %d-%d"):format(lo, hi)
end

-- u on `!` hunk `idx`: the index drops the staged change the hunk undoes
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel
---@param staging differ.view.Staging
---@param idx integer
---@param reopen fun()
---@return boolean
local function drop_hidden(ctx, entry, model, staging, idx, reopen)
    local sha, mode = index_ops.index_entry(ctx.root, index_path(entry), entry.path)
    local index = nil
    if sha then
        index = content_ops.blob(ctx.root, sha)
    end
    if not index then
        return index_unreadable(entry)
    end
    local text, _, why = drop_index(ctx, entry, model, staging, idx, index)
    if why == "unreadable" then
        return index_unreadable(entry)
    end
    if not text then
        notify("the index changed outside differ: re-reading", vim.log.levels.WARN)
        vim.schedule(function()
            reopen()
        end)
        return false
    end
    if not put_index(ctx, entry, text, mode) then
        return false
    end
    ctx.refresh()
    reopen()
    return true
end

-- u in a whole-file local view: the index takes HEAD's side where it holds what the
-- worktree doesn't. an add goes, a binary takes HEAD's blob, and a mode HEAD's mode,
-- keeping the staged content. nil when the index holds nothing of the kind
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel  -- index<->worktree
---@return (fun(): boolean)|nil
local function local_file_unstage(ctx, entry, model)
    if entry.x == "A" or model.binary then
        return function()
            return index_ops.unstage(ctx.root, entry.path)
        end
    end
    local head_mode, index_mode =
        rev.parse_raw_modes(raw_line(ctx.root, { "--cached" }, entry) or "")
    local flag = CHMOD[head_mode]
    if not flag or head_mode == index_mode then
        return nil
    end
    return function()
        return git_ok({ "update-index", "--chmod=" .. flag, "--", entry.path }, ctx.root, "unstage")
    end
end

-- X in a whole-file local view: the worktree takes the index's side, its mode, its
-- blob, or a deleted file back as the index holds it
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@return boolean
local function local_file_revert(ctx, entry)
    if not git_ok({ "checkout", "--", entry.path }, ctx.root, "revert") then
        return false
    end
    reload_buffer(ctx.root, entry.path)
    return true
end

-- the local view's staging, index<->worktree
---@param ctx differ.git.StagingCtx
---@param entry differ.FileEntry
---@param model differ.DiffModel  -- index<->worktree
---@param reopen fun()
---@return differ.view.Staging
local function for_local(ctx, entry, model, reopen)
    if #model.hunks > 0 and entry.y ~= "D" and entry.y ~= "T" then
        local staging, apply_lines = frozen_staging(ctx, entry, model, false, reopen)
        staging.apply_lines = apply_lines
        local _, head_index = three_models(ctx.root, entry)
        -- an add has no HEAD lines for a rewritten line to go back to
        if head_index and entry.x ~= "A" then
            staging.hidden_in =
                require("differ.model.marks").restaged(model.hunks, head_index.hunks)
        end
        staging.unstage_hidden = function(idx)
            return drop_hidden(ctx, entry, model, staging, idx, reopen)
        end
        staging.drop_scope = function(idx)
            local _, scope = drop_index(ctx, entry, model, staging, idx)
            return scope
        end
        staging.revert = function(m, idx)
            return revert_frozen(ctx, entry, m, staging, idx, 0, reopen)
        end
        file_lines(
            ctx,
            entry,
            staging,
            function()
                return read(INDEX, ctx.root, index_path(entry)) or ""
            end,
            reopen,
            function()
                -- the frozen marks number the lines the view opened on
                vim.schedule(function()
                    local current = ctx.current_view()
                    if current and current.staging == staging then
                        reopen()
                    end
                end)
            end
        )
        -- staging the last hunk empties "changes since staging", so there's nothing
        -- left for this view to show and it hands back to the whole change
        local stage_hunk = staging.apply
        staging.apply = function(m, hunk, reverse)
            if not (stage_hunk and stage_hunk(m, hunk, reverse)) then
                return false
            end
            local state = require("differ.model.marks").state
            for _, h in ipairs(model.hunks) do
                if state(staging.marks, h) ~= "staged" then
                    return true
                end
            end
            ctx.retarget_later()
            return true
        end
        return staging
    end
    -- s stages the file whole: what's left has no lines to take, or is the file's
    -- deletion, which a hunk would stage as an empty file. that leaves this view
    -- nothing to show. u has no reverse here: unstaging the row would take its
    -- staged content with it
    ---@type differ.view.Staging
    local staging = {
        initial = "unstaged",
        whole_file = true,
        refresh = ctx.refresh,
        apply = function(_, _, reverse)
            if reverse or not set_staged(ctx.root, entry, true) then
                return false
            end
            ctx.retarget_later()
            return true
        end,
        confirm_stage = function()
            return stage_prompt(ctx, entry)
        end,
    }
    staging.revert = function()
        return local_file_revert(ctx, entry)
    end
    staging.revert_label = "resets it to the index"
    local drop = local_file_unstage(ctx, entry, model)
    if drop then
        staging.hidden_in = { 1 }
        staging.unstage_hidden = function()
            if not drop() then
                return false
            end
            ctx.refresh()
            ctx.retarget(false)
            return true
        end
    end
    return staging
end

return {
    for_index = for_index,
    for_preview = for_preview,
    for_local = for_local,
}
