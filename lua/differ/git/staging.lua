-- staging for one panel session's rows: the diff view's s/u/S/U/X, the commit preview's
-- frozen keys and the local view's. every op works out the content the index should
-- hold and writes it whole. the session passes in its root and its callbacks

local rev = require("differ.git.rev")
local exec = require("differ.git.exec")
local index_ops = require("differ.git.index")
local patch = require("differ.git.patch")
local notify, git, git_ok = exec.notify, exec.git, exec.git_ok
local reload_buffer = exec.reload_buffer
local write_index, entry_paths = index_ops.write_index, index_ops.entry_paths
local set_staged, index_path = index_ops.set_staged, index_ops.index_path

local M = {}

-- the whole-file rows X acts on: a file that came, went, or changed kind altogether.
-- `T` is a path swapped for a symlink or the other way round, which has no hunk to take
---@type table<string, boolean>
local REVERTABLE_WHOLE = { ["?"] = true, A = true, D = true, T = true }

---@class differ.git.StagingCtx
---@field root string
---@field stageable boolean                    -- a worktree source: rev-pair rows don't stage
---@field refresh fun()                        -- reload the panel's list
---@field retarget fun(outside: boolean)       -- re-source the view onto the row's state now
---@field preview_off fun()                    -- leave the commit preview
---@field current_view fun(): differ.View|nil

---@param ctx differ.git.StagingCtx
---@return table
function M.new(ctx)
    local gitmod = require("differ.git")
    local root, stageable = ctx.root, ctx.stageable
    local refresh_panel, retarget_view = ctx.refresh, ctx.retarget

    -- write `text` as `entry`'s staged content. an add left with nothing staged leaves
    -- the index, and a worktree rename stages with its content; both move the row
    ---@param entry differ.FileEntry
    ---@param text string
    ---@param mode? string  -- the mode the entry takes; nil keeps the one it has
    ---@return boolean ok
    local function put_index(entry, text, mode)
        if entry.x == "A" and text == "" then
            if not gitmod.unstage(root, entry.path) then
                return false
            end
            vim.schedule(function()
                retarget_view(false)
            end)
            return true
        end
        if not write_index(root, entry.path, text, mode) then
            return false
        end
        if entry.y == "R" and entry.previous_path then
            local drop = { "update-index", "--force-remove", "--", entry.previous_path }
            if not git_ok(drop, root, "staging " .. entry.path) then
                return false
            end
            vim.schedule(function()
                retarget_view(false)
            end)
        end
        return true
    end

    -- the mode of the side S (the worktree) or U (HEAD) takes, or nil when the index is
    -- already there. a `diff --raw` line reads `:<src mode> <dst mode> ...`
    ---@param entry differ.FileEntry
    ---@param staged boolean
    ---@return string|nil
    local function side_mode(entry, staged)
        local line = gitmod.raw_line(root, staged and {} or { "--cached" }, entry)
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
    ---@param entry differ.FileEntry
    ---@return boolean
    local function mode_hidden(entry)
        local cached = gitmod.raw_line(root, { "--cached" }, entry)
        local unstaged = gitmod.raw_line(root, {}, entry)
        if not (cached and unstaged) then
            return false
        end
        local head_mode, index_mode = rev.parse_raw_modes(cached)
        local _, work_mode = rev.parse_raw_modes(unstaged)
        return index_mode ~= head_mode and index_mode ~= work_mode
    end

    -- an op built on a failed index read would write the file's index from nothing
    ---@param entry differ.FileEntry
    ---@return false
    local function index_unreadable(entry)
        notify(("couldn't read %s from the index"):format(entry.path), vim.log.levels.WARN)
        return false
    end

    -- X on a hunk: the file gives those lines back, and `stage_index` moves the index's
    -- half. the file is checked first, so one that changed those lines refuses before the
    -- index moves. it patches rather than writes: the new side came through the clean
    -- filter, and writing it back would push that conversion to disk
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel
    ---@param hunk differ.Hunk
    ---@param offset integer  -- the model's new-side lines to the file's, see patch.hunk
    ---@param stage_index fun(): boolean
    ---@return boolean
    local function revert_worktree(entry, model, hunk, offset, stage_index)
        local p = patch.hunk(model.path, hunk, model.old_text, model.new_text, offset, "new")
        if not gitmod.revert_patch(root, p, true) then
            notify("the file has changed these lines: nothing reverted", vim.log.levels.WARN)
            return false
        end
        if not stage_index() then
            return false
        end
        local ok, err = gitmod.revert_patch(root, p)
        reload_buffer(root, entry.path)
        if not ok then
            notify(("hunk revert failed: %s"):format(err or ""), vim.log.levels.ERROR)
            return false
        end
        return true
    end

    -- staging for a row shown as HEAD↔worktree. staging a hunk gives the index the
    -- worktree's version of its lines, unstaging keeps every staged change except those;
    -- each op reads the pairs once and re-marks from the text it wrote
    ---@param entry differ.FileEntry
    ---@return differ.view.Staging
    local function union_staging(entry)
        local marks = require("differ.model.marks")
        local stage = require("differ.model.stage")
        local mode_change = false
        if entry.x ~= " " and entry.y ~= " " and mode_hidden(entry) then
            mode_change = true -- the index holds a mode change, which no hunk shows
        end
        ---@type differ.view.Staging
        local staging = { marks = { old = {}, new = {} }, refresh = refresh_panel }

        -- the view keeps staging.marks, so a re-mark writes through it. marks come from
        -- the index's own lines at each hunk, and from the two pairs only when the index
        -- changes a line between hunks
        ---@param union differ.DiffModel|nil  -- nil keeps the marks there are
        ---@param cached differ.DiffModel|nil
        ---@param unstaged differ.DiffModel|nil
        local function remark(union, cached, unstaged)
            if not (union and cached and unstaged) then
                return
            end
            staging.hidden_in = nil
            local blocks, ended = stage.index_blocks(union, cached.new_text)
            local held, hidden_in = nil, {} ---@type differ.model.Marks|nil, integer[]
            if blocks then
                held, hidden_in = marks.of_blocks(ended.hunks, blocks)
            end
            if held then
                staging.marks.old, staging.marks.new = held.old, held.new
                staging.hidden = nil
                if mode_change then
                    staging.hidden = true
                elseif #hidden_in > 0 then
                    staging.hidden = true
                    staging.hidden_in = hidden_in
                end
                return
            end
            local fresh = marks.classify(union.hunks, cached.hunks, unstaged.hunks)
            staging.marks.old, staging.marks.new = fresh.old, fresh.new
            local complete = marks.complete(union.hunks, cached.hunks, unstaged.hunks)
            if mode_change then
                staging.hidden = true
            elseif complete then
                staging.hidden = nil
            else
                staging.hidden = true
                local head = require("differ.util.text").to_lines(union.old_text)
                staging.hidden_in = marks.hidden_in(head, union.hunks, cached.hunks, fresh)
            end
        end

        -- why `hunk` can't move on its own, either way naming the view where its change
        -- is a hunk of its own and can be taken whole. `reaches` names another union
        -- hunk a pair hunk would carry the op into; without one the two pairs line this
        -- hunk's change up under a different one, leaving nothing here to write
        ---@param take boolean
        ---@param reaches integer|nil
        ---@return string
        local function refusal(take, reaches)
            if not reaches then
                if take then
                    return "this hunk's unstaged change sits under another hunk: "
                        .. "s in dw stages it whole"
                end
                return "this hunk's staged change sits under another hunk: "
                    .. "u in gs unstages it whole"
            end
            local msg = "this hunk's staged change also covers hunk %d: "
                .. "u on the ! hunk in dw, or in gs, unstages it whole"
            if take then
                msg = "this hunk's unstaged change also covers hunk %d: s in dw stages it whole"
            end
            return msg:format(reaches)
        end

        -- whether the diff still shows the file as it is. one drawn before the file or
        -- HEAD moved would place an op by stale line numbers, so it refuses and re-reads
        ---@param model differ.DiffModel  -- the view's
        ---@param union differ.DiffModel  -- read fresh
        ---@return boolean
        local function drawn_current(model, union)
            if model.old_text == union.old_text and model.new_text == union.new_text then
                return true
            end
            notify("the file changed since the diff was drawn: re-reading", vim.log.levels.WARN)
            vim.schedule(function()
                refresh_panel()
                retarget_view(false)
            end)
            return false
        end

        remark(gitmod.union_models(root, entry))
        staging.apply = function(model, hunk, reverse)
            if not hunk then
                return false
            end
            local union, cached, unstaged = gitmod.union_models(root, entry)
            if not (union and cached and unstaged) then
                return index_unreadable(entry)
            end
            if not drawn_current(model, union) then
                return false
            end
            local take = not reverse
            local text, reaches = stage.next_index(union, cached, unstaged, hunk, take)
            if not text then
                -- neither refusal is a failure: the key moves on, and the message says
                -- where this hunk's change can be taken whole
                notify(refusal(take, reaches), vim.log.levels.WARN)
                return false, true
            end
            if not put_index(entry, text) then
                return false
            end
            remark(gitmod.union_pairs(root, entry.path, union.old_text, text, union.new_text))
            return true
        end
        -- X throws the hunk away on both sides at once: the index gives up whatever of
        -- it it holds and the worktree gives up the rest
        staging.revert = function(model, idx)
            local union, cached, unstaged = gitmod.union_models(root, entry)
            if not (union and cached and unstaged) then
                return index_unreadable(entry)
            end
            if not drawn_current(model, union) then
                return false
            end
            local hunk = model.hunks[idx]
            local text, reaches = stage.next_index(union, cached, unstaged, hunk, false)
            if reaches then
                notify(refusal(false, reaches), vim.log.levels.WARN)
                return false
            end
            -- a hunk the index holds nothing of on its own leaves the index where it is,
            -- and the worktree still has the whole change to give back
            local index_text = text or cached.new_text
            local ok = revert_worktree(entry, model, hunk, 0, function()
                return index_text == cached.new_text or put_index(entry, index_text)
            end)
            if not ok then
                remark(gitmod.union_models(root, entry))
                return false
            end
            local work = require("differ.model.diff").revert_hunk(model, idx).new_text
            remark(gitmod.union_pairs(root, entry.path, union.old_text, index_text, work))
            return true
        end
        -- S and U: the index takes the worktree's or HEAD's side of the file whole,
        -- staged content no hunk shows and the mode included. the move a rename made
        -- stays staged either way; the panel row's keys own that
        staging.set_all = function(model, staged)
            local union, cached = gitmod.union_models(root, entry)
            if not (union and cached) then
                return index_unreadable(entry)
            end
            if not drawn_current(model, union) then
                return false
            end
            local text = staged and union.new_text or union.old_text
            local mode = side_mode(entry, staged)
            if text == cached.new_text and not mode then
                return false
            end
            if not put_index(entry, text, mode) then
                return false
            end
            remark(gitmod.union_pairs(root, entry.path, union.old_text, text, union.new_text))
            return true
        end
        return staging
    end

    -- X on a whole-file row, and what it does to the file. `letter` owns the change the
    -- row shows: its status for a worktree row, the index's (x) in the commit preview.
    -- a row X can't act on has no revert and says why instead, so the key refuses
    -- before the prompt rather than after it
    ---@param entry differ.FileEntry
    ---@param letter string
    ---@param preview boolean  -- the entry is lettered by its index side
    ---@return (fun(): boolean)|nil revert, string|nil label, string|nil no_revert
    local function whole_file_revert(entry, letter, preview)
        if letter == "D" then
            if entry.kept then
                local why = "X would overwrite the untracked copy of %s on disk"
                return nil, nil, why:format(entry.path)
            end
            return function()
                return index_ops.restore_deleted(root, entry)
            end,
                "restores the file"
        end
        local discard = function()
            return gitmod.discard(root, entry, preview)
        end
        if letter == "A" or letter == "?" then
            return discard, "deletes the file"
        end
        return discard, "puts it back as HEAD has it"
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

    ---@param entry differ.FileEntry
    ---@param diff differ.DiffModel  -- the entry's built model; only its hunk count is read
    ---@return differ.view.Staging|nil
    local function stage_for(entry, diff)
        if not stageable then
            return nil
        end
        -- git records no rename, only the old path gone from the index and the new one
        -- present, so a hunk stages an ordinary blob and the move rides along untouched.
        -- the move is whole-file and belongs to the panel row's keys
        local content = entry.status == "M" or entry.status == "R" or entry.status == "C"
        local added = entry.status == "A" and entry.x == "A"
        if (content or added) and entry.x ~= "D" and #diff.hunks > 0 then
            local staging = union_staging(entry)
            if added then
                -- throwing away an add is deleting the file, not reverting a hunk of it
                staging.revert, staging.revert_label, staging.no_revert =
                    whole_file_revert(entry, "A", false)
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
                return set_staged(root, entry, not reverse)
            end,
            refresh = refresh_panel,
        }
        if content then
            return staging
        end
        -- an add's discard drops the staged entry before removing the file; a
        -- typechange's puts HEAD's own kind of file back over the one on disk
        if REVERTABLE_WHOLE[entry.status] then
            staging.revert, staging.revert_label, staging.no_revert =
                whole_file_revert(entry, entry.status, false)
            return staging
        end
        return nil
    end

    -- a row with a staged change and more on top of it: the one kind with a local view
    ---@param entry differ.FileEntry
    ---@return boolean
    local function partly_staged(entry)
        if entry.status == "U" or entry.x == "?" or entry.y == "D" then
            return false
        end
        return entry.x ~= " " and entry.y ~= " "
    end

    -- staging frozen at the index the view opened on: s and u rebuild it from the model's
    -- old side plus the hunks marked staged, so a marked hunk stays on screen. an index
    -- written outside differ since then would be lost to that rebuild, so they refuse
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel  -- read once, with at least one hunk
    ---@param staged boolean  -- every hunk's opening state
    ---@param reopen fun()
    ---@return differ.view.Staging
    local function frozen_staging(entry, model, staged, reopen)
        local splice = require("differ.model.apply").splice
        local state = require("differ.model.marks").state
        -- the commit preview opens staged with the index as its new side; the local view
        -- opens unstaged with it as its old side
        local held = staged and model.new_text or model.old_text
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
        return {
            marks = marks,
            refresh = refresh_panel,
            apply = function(_, hunk, reverse)
                if not hunk then
                    return false
                end
                if (gitmod.read(gitmod.INDEX, root, at_index) or "") ~= held then
                    notify("the index changed outside differ: re-reading", vim.log.levels.WARN)
                    vim.schedule(reopen)
                    return false
                end
                mark(hunk, not reverse)
                local applied = {}
                for i, h in ipairs(model.hunks) do
                    applied[i] = state(marks, h) == "staged"
                end
                local text = splice(model, applied)
                if put_index(entry, text) then
                    held, at_index = text, entry.path -- put_index stages a rename at the new path
                    return true
                end
                mark(hunk, reverse)
                return false
            end,
        }
    end

    -- whole-file staging frozen at the index the view opened on: u resets the row's
    -- paths to HEAD, s puts back the entries the index held then
    ---@param entry differ.FileEntry
    ---@return differ.view.Staging
    local function snapshot_staging(entry)
        local paths = entry_paths(entry)
        local held = {} ---@type table<string, string> -- path -> update-index cacheinfo
        local listed = git(vim.list_extend({ "ls-files", "-s", "-z", "--" }, paths), root) or ""
        for mode, sha, path in listed:gmatch("(%d+) (%x+) %d+\t([^%z]+)") do
            held[path] = ("%s,%s,%s"):format(mode, sha, path)
        end
        return {
            initial = "staged",
            whole_file = true,
            refresh = refresh_panel,
            apply = function(_, _, reverse)
                if reverse then
                    return set_staged(root, entry, false)
                end
                local ok = true
                for _, path in ipairs(paths) do
                    local cmd = { "update-index", "--force-remove", "--", path }
                    if held[path] then
                        cmd = { "update-index", "--add", "--cacheinfo", held[path] }
                    end
                    ok = git_ok(cmd, root, "staging " .. path) and ok
                end
                return ok
            end,
        }
    end

    -- X in a frozen view (the commit preview, the local view): the hunk leaves the index
    -- if marked staged, and the file takes its old lines back, then `reopen` re-reads the
    -- view. a last hunk leaves nothing to reopen, and the view hands over to the panel
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel
    ---@param staging differ.view.Staging
    ---@param idx integer
    ---@param offset integer  -- the model's new-side lines to the file's, see patch.hunk
    ---@param reopen fun()
    ---@return boolean
    local function revert_frozen(entry, model, staging, idx, offset, reopen)
        local hunk = model.hunks[idx]
        local ok = revert_worktree(entry, model, hunk, offset, function()
            if require("differ.model.marks").state(staging.marks, hunk) ~= "staged" then
                return true
            end
            if not staging.apply then
                return false
            end
            return staging.apply(model, hunk, true)
        end)
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

    -- staging for a row drawn HEAD↔index, in the commit preview or where that is the
    -- only diff the row has. an add or a deletion is one unit whose index entry comes
    -- and goes, so it stages as a file
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel  -- HEAD↔index
    ---@param preview boolean  -- the row comes from the commit preview's listing
    ---@return differ.view.Staging
    local function staged_staging(entry, model, preview)
        local staging
        if #model.hunks > 0 and entry.x ~= "A" and entry.x ~= "D" then
            staging = frozen_staging(entry, model, true, function()
                retarget_view(false)
            end)
            -- the model's new side is the index, so its lines move by whatever the
            -- worktree has added or dropped above them since
            staging.revert = function(m, idx)
                local h = m.hunks[idx]
                local _, _, unstaged = gitmod.union_models(root, entry)
                if not unstaged then
                    return index_unreadable(entry)
                end
                local at = h.new_count > 0 and h.new_start or h.new_start + 1
                local offset = require("differ.model.marks").shift(unstaged.hunks, at, "old")
                return revert_frozen(entry, m, staging, idx, offset, function()
                    retarget_view(false)
                end)
            end
        else
            staging = snapshot_staging(entry)
            staging.revert, staging.revert_label, staging.no_revert =
                whole_file_revert(entry, entry.x, preview)
        end
        staging.badge = "INDEX"
        return staging
    end

    -- staging for a commit-preview row: the HEAD↔index keys, plus the way back out
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel  -- HEAD↔index
    ---@return differ.view.Staging
    local function preview_staging(entry, model)
        local staging = staged_staging(entry, model, true)
        staging.badge = "STAGED"
        staging.no_local = "the commit preview has no local view: gs goes back"
        staging.leave = function()
            ctx.preview_off()
        end
        return staging
    end

    -- u on a `!` hunk in the local view: the index takes HEAD's lines there, dropping the
    -- staged change the worktree undid. its lines are the index's at open, moved by
    -- whatever s has staged since
    ---@param entry differ.FileEntry
    ---@param model differ.DiffModel  -- index↔worktree, as the view opened on it
    ---@param staging differ.view.Staging
    ---@param idx integer
    ---@return boolean
    local function drop_hidden(entry, model, staging, idx, reopen)
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
        local _, cached = gitmod.union_models(root, entry)
        if not cached then
            return index_unreadable(entry)
        end
        if cached.new_text ~= splice(model, applied) then
            notify("the index changed outside differ: re-reading", vim.log.levels.WARN)
            vim.schedule(function()
                reopen()
            end)
            return false
        end
        local hunk = model.hunks[idx]
        local placed = vim.tbl_extend("force", hunk, {
            old_start = hunk.old_start + marks.shift(moved, hunk.old_start, "old"),
        })
        local keep = stage.select_hunks(cached.hunks, "new", placed, "old", false)
        if not put_index(entry, splice(cached, keep)) then
            return false
        end
        refresh_panel()
        reopen()
        return true
    end

    return {
        for_entry = stage_for,
        preview = preview_staging,
        staged_only = staged_staging,
        frozen = frozen_staging,
        revert_frozen = revert_frozen,
        drop_hidden = drop_hidden,
        partly_staged = partly_staged,
    }
end

return M
