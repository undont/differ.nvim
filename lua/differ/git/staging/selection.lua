-- the texts s, u and X on a HEAD<->worktree selection write, read back before anything
-- is: over the three texts already read, with no git

local content = require("differ.git.content")
local edits = require("differ.git.staging.write").edits

local M = {}

---@alias differ.git.SelectionRefusal differ.model.SelectRefusal|"unread"|"moves_others"

-- the pairs `text` as the index makes, or nil and why where they read back as other
-- marks than `want`
---@param root string
---@param path string
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param hidden boolean  -- stage.marks_of's
---@param selection differ.model.Selection
---@param want differ.model.LineStates
---@param take boolean
---@param text string
---@return differ.DiffModel[]|nil after, "moves_others"|"unshown"|nil refusal
local function read_back(root, path, head_work, head_index, hidden, selection, want, take, text)
    local after = { content.three_diffs(root, path, head_work.old_text, text, head_work.new_text) }
    local before = {
        head_work = head_work,
        head_index = head_index,
        hidden = hidden,
        edits = edits,
        take = take,
    }
    local ok, unshown =
        require("differ.model.stage").reads_as(want, before, selection, unpack(after))
    if not ok then
        return nil, unshown or "moves_others"
    end
    return after
end

-- the pairs `text` as the index makes, or nil where they read back as other marks than
-- s (`take`) or u on `selection` leaves, or the file is too big to read
---@param root string
---@param path string
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@param selection differ.model.Selection
---@param take boolean
---@param text string
---@return differ.DiffModel[]|nil after, "unread"|"moves_others"|"unshown"|nil refusal
function M.checked(root, path, head_work, head_index, index_work, selection, take, text)
    local stage = require("differ.model.stage")
    local m, hidden, _, unread = stage.marks_of(head_work, head_index, index_work)
    if unread then
        return nil, "unread"
    end
    local want = stage.flipped(head_work, m, selection, take)
    return read_back(root, path, head_work, head_index, hidden, selection, want, take, text)
end

-- the index s (`take`) or u on `selection` writes and the pairs it makes. nil and why
-- where it refuses; nil alone where the drawn marks have every selected line where the
-- op puts it. a selected hunk holding a line neither side has refuses first
---@param root string
---@param path string
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@param selection differ.model.Selection
---@param take boolean
---@return string|nil text, differ.DiffModel[]|nil after, differ.git.SelectionRefusal|nil refusal
function M.stage(root, path, head_work, head_index, index_work, selection, take)
    local stage = require("differ.model.stage")
    local text, refused = stage.select_index(head_work, head_index, selection, take)
    if refused then
        return nil, nil, refused
    end
    local m, hidden, _, unread = stage.marks_of(head_work, head_index, index_work)
    local want = stage.flipped(head_work, m, selection, take)
    if want.enter == 0 and want.leave == 0 then
        return nil
    end
    if not text then
        -- the cut has the selection in place where the drawn marks don't
        return nil, nil, "between"
    end
    if unread then
        return nil, nil, "unread"
    end
    local after, refusal =
        read_back(root, path, head_work, head_index, hidden, selection, want, take, text)
    if not after then
        return nil, nil, refusal
    end
    return text, after
end

-- the index and file X on `selection` writes. nil and why where it refuses; nil alone
-- where it touches no hunk
---@param root string
---@param path string
---@param head_work differ.DiffModel
---@param head_index differ.DiffModel
---@param index_work differ.DiffModel
---@param selection differ.model.Selection
---@return string|nil index_text, differ.DiffModel|nil reverted, differ.git.SelectionRefusal|nil refusal
function M.revert(root, path, head_work, head_index, index_work, selection)
    local stage = require("differ.model.stage")
    local text, refused = stage.select_index(head_work, head_index, selection, false)
    if refused then
        return nil, nil, refused
    end
    local origins = stage.index_origins(head_work, head_index)
    local reverted, refusal = stage.select_worktree(head_work, selection, origins)
    if refusal then
        return nil, nil, refusal
    end
    if not reverted then
        return nil
    end
    local index_text = text or head_index.new_text
    local m, hidden = stage.marks_of(head_work, head_index, index_work)
    local want = stage.reverted(head_work, m, selection, origins)
    local after =
        { content.three_diffs(root, path, head_work.old_text, index_text, reverted.old_text) }
    local before = {
        head_work = head_work,
        head_index = head_index,
        hidden = hidden,
        edits = edits,
        take = false,
    }
    local ok, unshown = stage.reads_as(want, before, selection, unpack(after))
    if not ok then
        return nil, nil, unshown or "moves_others"
    end
    return index_text, reverted
end

return M
