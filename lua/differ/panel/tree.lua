-- file-tree model for the panel: turn a flat FileEntry list into a folded
-- directory tree, and flatten it to display rows (tree or flat). pure lua, no
-- nvim API; the structural logic is unit-testable; rendering/highlighting and
-- the window live in panel/init.lua

local M = {}

---@class differ.FileEntry
---@field path string
---@field status "A"|"M"|"D"|"R"|"C"|"U"|"?"
---@field additions integer
---@field deletions integer
---@field staged boolean|nil       -- which local section it belongs to
---@field previous_path string|nil -- renames/copies
---@field viewed boolean|nil       -- PR only

---@class differ.panel.Node
---@field kind "dir"|"file"
---@field name string                       -- display segment (folded path for dirs)
---@field path string                        -- full path; collapse key (dir) / entry key (file)
---@field children differ.panel.Node[]|nil   -- dirs only
---@field entry differ.FileEntry|nil         -- files only

---@class differ.panel.Row
---@field depth integer
---@field kind "dir"|"file"
---@field name string
---@field path string
---@field collapsed boolean|nil   -- dir rows
---@field entry differ.FileEntry|nil
---@field context string|nil      -- dimmed "parent/" trailer (name listing only)

---@param p string
---@return string[]
local function split_path(p)
    local parts, start = {}, 1
    while true do
        local s = p:find("/", start, true)
        if not s then
            parts[#parts + 1] = p:sub(start)
            break
        end
        parts[#parts + 1] = p:sub(start, s - 1)
        start = s + 1
    end
    return parts
end

-- sort each dir's children: directories first, then files, alphabetical within
---@param node differ.panel.Node
local function sort_tree(node)
    if node.kind ~= "dir" then
        return
    end
    table.sort(node.children, function(a, b)
        if a.kind ~= b.kind then
            return a.kind == "dir"
        end
        return a.name < b.name
    end)
    for _, c in ipairs(node.children) do
        sort_tree(c)
    end
end

-- collapse single-child directory chains into one node (common-prefix folding,
-- gitHub/diffview-style): a dir whose only child is a dir becomes "parent/child".
-- recurses children first so chains fold maximally. the root is never folded
---@param node differ.panel.Node
---@return differ.panel.Node
local function fold(node)
    if node.kind == "file" then
        return node
    end
    for i, c in ipairs(node.children) do
        node.children[i] = fold(c)
    end
    while #node.children == 1 and node.children[1].kind == "dir" do
        local only = node.children[1]
        node.name = node.name == "" and only.name or (node.name .. "/" .. only.name)
        node.path = only.path
        node.children = only.children
    end
    return node
end

-- the directory prefix shared by every entry (dir-boundary aligned), e.g.
-- {"a/b/x.lua", "a/b/c/y.lua"} -> "a/b/". "" when nothing is shared. the panel
-- strips this in tree mode and shows it once as a header subtitle, reclaiming the
-- indentation a deep common prefix would otherwise eat
---@param entries differ.FileEntry[]
---@return string
function M.common_dir(entries)
    if #entries == 0 then
        return ""
    end
    local function dir_parts(p)
        local parts = split_path(p)
        parts[#parts] = nil -- drop the filename
        return parts
    end
    local pref = dir_parts(entries[1].path)
    for i = 2, #entries do
        local d = dir_parts(entries[i].path)
        local k = 0
        while k < #pref and k < #d and pref[k + 1] == d[k + 1] do
            k = k + 1
        end
        for j = #pref, k + 1, -1 do
            pref[j] = nil
        end
        if #pref == 0 then
            break
        end
    end
    return #pref == 0 and "" or (table.concat(pref, "/") .. "/")
end

-- build a folded directory tree from a flat entry list. `strip` (a trailing-slash
-- dir prefix, usually from `common_dir`) is removed from each path for the tree
-- *structure*; the file node keeps the original full path + entry for selection
---@param entries differ.FileEntry[]
---@param strip string|nil
---@return differ.panel.Node root
function M.build(entries, strip)
    strip = strip or ""
    local root = { kind = "dir", name = "", path = "", children = {} }
    local dirs = { [""] = root } -- dir path -> node, so siblings share a parent
    for _, e in ipairs(entries) do
        local rel = strip ~= "" and e.path:sub(#strip + 1) or e.path
        local parts = split_path(rel)
        local parent, acc = root, ""
        for i = 1, #parts - 1 do
            acc = acc == "" and parts[i] or (acc .. "/" .. parts[i])
            local dir = dirs[acc]
            if not dir then
                dir = { kind = "dir", name = parts[i], path = acc, children = {} }
                dirs[acc] = dir
                parent.children[#parent.children + 1] = dir
            end
            parent = dir
        end
        parent.children[#parent.children + 1] =
            { kind = "file", name = parts[#parts], path = e.path, entry = e }
    end
    sort_tree(root)
    for i, c in ipairs(root.children) do
        root.children[i] = fold(c)
    end
    return root
end

-- every directory path in the tree (regardless of collapse state), for the
-- close-all / open-all fold ops. paths match the dir.path keys tree.rows reads
---@param root differ.panel.Node
---@return string[]
function M.dir_paths(root)
    local out = {}
    local function walk(node)
        for _, c in ipairs(node.children or {}) do
            if c.kind == "dir" then
                out[#out + 1] = c.path
                walk(c)
            end
        end
    end
    walk(root)
    return out
end

-- flatten the tree to display rows. `listing` is "tree" (nested, honouring the
-- `collapsed` set of dir paths) or "name" (leaves only, basename-first with a
-- dimmed "parent/" trailer)
---@param root differ.panel.Node
---@param listing "tree"|"name"
---@param collapsed table<string, boolean>|nil
---@return differ.panel.Row[]
function M.rows(root, listing, collapsed)
    collapsed = collapsed or {}
    local out = {}
    if listing == "name" then
        local function leaves(node)
            for _, c in ipairs(node.children or {}) do
                if c.kind == "file" then
                    local parts = split_path(c.entry.path)
                    out[#out + 1] = {
                        depth = 0,
                        kind = "file",
                        name = parts[#parts],
                        path = c.path,
                        entry = c.entry,
                        context = #parts > 1 and (parts[#parts - 1] .. "/") or nil,
                    }
                else
                    leaves(c)
                end
            end
        end
        leaves(root)
        return out
    end
    local function walk(node, depth)
        for _, c in ipairs(node.children or {}) do
            if c.kind == "dir" then
                local is_collapsed = collapsed[c.path] == true
                out[#out + 1] = {
                    depth = depth,
                    kind = "dir",
                    name = c.name,
                    path = c.path,
                    collapsed = is_collapsed,
                }
                if not is_collapsed then
                    walk(c, depth + 1)
                end
            else
                out[#out + 1] =
                    { depth = depth, kind = "file", name = c.name, path = c.path, entry = c.entry }
            end
        end
    end
    walk(root, 0)
    return out
end

return M
