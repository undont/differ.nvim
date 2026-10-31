-- the texts s, u and X on a HEAD↔worktree selection write, read back before anything
-- is: over the three texts already read, with no git

local content = require("differ.git.content")
local edits = require("differ.git.staging.write").edits

local M = {}

---@alias differ.git.SelectionRefusal differ.model.SelectRefusal|"unread"|"moves_others"

-- the pairs `text` as the index makes, or nil where they read back as other marks than
-- `want`
---@param root string
---@param path string
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param hidden boolean  -- stage.marks_of's
---@param selection differ.model.Selection
---@param want differ.model.LineStates
---@param take boolean
---@param text string
---@return differ.DiffModel[]|nil
local function read_back(root, path, union, cached, hidden, selection, want, take, text)
    local after = { content.union_pairs(root, path, union.old_text, text, union.new_text) }
    local towards = union.old_text
    if take then
        towards = union.new_text
    end
    local before =
        { union = union, cached = cached, hidden = hidden, edits = edits, towards = towards }
    if not require("differ.model.stage").reads_as(want, before, selection, unpack(after)) then
        return nil
    end
    return after
end

-- the pairs `text` as the index makes, or nil where they read back as other marks than
-- s (`take`) or u on `selection` leaves, or the file is too big to read
---@param root string
---@param path string
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@param selection differ.model.Selection
---@param take boolean
---@param text string
---@return differ.DiffModel[]|nil after, "unread"|"moves_others"|nil refusal
function M.checked(root, path, union, cached, unstaged, selection, take, text)
    local stage = require("differ.model.stage")
    local m, hidden, _, unread = stage.marks_of(union, cached, unstaged)
    if unread then
        return nil, "unread"
    end
    local want = stage.flipped(union, m, selection, take)
    local after = read_back(root, path, union, cached, hidden, selection, want, take, text)
    if not after then
        return nil, "moves_others"
    end
    return after
end

-- the index s (`take`) or u on `selection` writes and the pairs it makes. nil and why
-- where it refuses; nil alone where the drawn marks have every selected line where the
-- op puts it. a selected hunk holding a line neither side has refuses first
---@param root string
---@param path string
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@param selection differ.model.Selection
---@param take boolean
---@return string|nil text, differ.DiffModel[]|nil after, differ.git.SelectionRefusal|nil refusal
function M.stage(root, path, union, cached, unstaged, selection, take)
    local stage = require("differ.model.stage")
    local text, refused = stage.select_index(union, cached, selection, take)
    if refused then
        return nil, nil, refused
    end
    local m, hidden, _, unread = stage.marks_of(union, cached, unstaged)
    local want = stage.flipped(union, m, selection, take)
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
    local after = read_back(root, path, union, cached, hidden, selection, want, take, text)
    if not after then
        return nil, nil, "moves_others"
    end
    return text, after
end

-- the index and file X on `selection` writes. nil and why where it refuses; nil alone
-- where it touches no hunk
---@param root string
---@param path string
---@param union differ.DiffModel
---@param cached differ.DiffModel
---@param unstaged differ.DiffModel
---@param selection differ.model.Selection
---@return string|nil index_text, differ.DiffModel|nil reverted, differ.git.SelectionRefusal|nil refusal
function M.revert(root, path, union, cached, unstaged, selection)
    local stage = require("differ.model.stage")
    local text, refused = stage.select_index(union, cached, selection, false)
    if refused then
        return nil, nil, refused
    end
    local origins = stage.index_origins(union, cached)
    local reverted, refusal = stage.select_worktree(union, selection, origins)
    if refusal then
        return nil, nil, refusal
    end
    if not reverted then
        return nil
    end
    local index_text = text or cached.new_text
    local m, hidden = stage.marks_of(union, cached, unstaged)
    local want = stage.reverted(union, m, selection, origins)
    local after = { content.union_pairs(root, path, union.old_text, index_text, reverted.old_text) }
    local before = {
        union = union,
        cached = cached,
        hidden = hidden,
        edits = edits,
        towards = union.old_text,
    }
    if not stage.reads_as(want, before, selection, unpack(after)) then
        return nil, nil, "moves_others"
    end
    return index_text, reverted
end

return M
