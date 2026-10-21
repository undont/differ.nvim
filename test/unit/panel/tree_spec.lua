local tree = require("differ.panel.tree")

local function entry(path, status)
    return { path = path, status = status or "M", additions = 0, deletions = 0 }
end

describe("panel.tree.build", function()
    it("folds single-child directory chains", function()
        local root = tree.build({ entry("lua/differ/git/init.lua") })
        -- the whole chain collapses to one dir node "lua/differ/git"
        assert.are.equal(1, #root.children)
        local dir = root.children[1]
        assert.are.equal("dir", dir.kind)
        assert.are.equal("lua/differ/git", dir.name)
        assert.are.equal("lua/differ/git", dir.path)
        assert.are.equal("init.lua", dir.children[1].name)
    end)

    it("stops folding where a directory branches", function()
        local root = tree.build({ entry("src/a.lua"), entry("src/sub/b.lua") })
        assert.are.equal(1, #root.children)
        local src = root.children[1]
        assert.are.equal("src", src.name) -- can't fold: two children
        -- dirs sort before files: sub/ then a.lua
        assert.are.equal("sub", src.children[1].name)
        assert.are.equal("a.lua", src.children[2].name)
    end)
end)

describe("panel.tree.common_dir", function()
    it("returns the dir prefix shared by every entry", function()
        local p = tree.common_dir({ entry("a/b/c/x.lua"), entry("a/b/d/y.lua") })
        assert.are.equal("a/b/", p)
    end)

    it("returns empty when nothing is shared", function()
        assert.are.equal("", tree.common_dir({ entry("a/x.lua"), entry("b/y.lua") }))
        assert.are.equal("", tree.common_dir({ entry("x.lua"), entry("a/y.lua") }))
    end)

    it("aligns on dir boundaries, not characters", function()
        -- "app/" and "apple/" share no dir even though they share a char prefix
        assert.are.equal("", tree.common_dir({ entry("app/x.lua"), entry("apple/y.lua") }))
    end)
end)

describe("panel.tree.build with strip", function()
    it("builds structure relative to the prefix but keeps full paths on entries", function()
        local root = tree.build({ entry("a/b/c/x.lua"), entry("a/b/d/y.lua") }, "a/b/")
        local rows = tree.rows(root, "tree", {})
        -- c/ and d/ are now top-level dirs; the files still carry their full path
        assert.are.equal("dir", rows[1].kind)
        assert.are.equal("c", rows[1].name)
        assert.are.equal(0, rows[1].depth)
        local file = rows[2]
        assert.are.equal("a/b/c/x.lua", file.entry.path) -- selection key unchanged
        assert.are.equal("x.lua", file.name)
    end)
end)

describe("panel.tree.dir_paths", function()
    it("lists every dir path regardless of collapse state", function()
        local root = tree.build({ entry("src/a.lua"), entry("src/sub/b.lua"), entry("lib/c.lua") })
        local got = tree.dir_paths(root)
        table.sort(got)
        assert.are.same({ "lib", "src", "src/sub" }, got)
    end)

    it("returns nothing when all files are top-level", function()
        assert.are.same({}, tree.dir_paths(tree.build({ entry("a.lua"), entry("b.lua") })))
    end)
end)

describe("panel.tree.rows", function()
    it("emits dirs before files, nested by depth, in tree mode", function()
        local root = tree.build({ entry("src/a.lua"), entry("src/sub/b.lua") })
        local rows = tree.rows(root, "tree", {})
        -- src/ (d0); sub/ before a.lua (dirs first); b.lua nested under sub
        local got = {}
        for _, r in ipairs(rows) do
            got[#got + 1] = ("%s:%s:%d"):format(r.kind, r.path, r.depth)
        end
        assert.are.same(
            { "dir:src:0", "dir:src/sub:1", "file:src/sub/b.lua:2", "file:src/a.lua:1" },
            got
        )
    end)

    it("hides children of a collapsed directory", function()
        local root = tree.build({ entry("src/a.lua"), entry("src/b.lua") })
        local all = tree.rows(root, "tree", {})
        assert.are.equal(3, #all) -- src, a.lua, b.lua
        local collapsed = tree.rows(root, "tree", { ["src"] = true })
        assert.are.equal(1, #collapsed) -- just src, children hidden
        assert.is_true(collapsed[1].collapsed)
    end)

    it("name mode leads with the basename and carries the parent as context", function()
        local root = tree.build({ entry("src/sub/b.lua"), entry("a.lua") })
        local rows = tree.rows(root, "name", {})
        assert.are.equal(2, #rows)
        local by_path = {}
        for _, r in ipairs(rows) do
            assert.are.equal(0, r.depth)
            by_path[r.path] = r
        end
        assert.are.equal("b.lua", by_path["src/sub/b.lua"].name)
        assert.are.equal("sub/", by_path["src/sub/b.lua"].context) -- immediate parent
        assert.are.equal("a.lua", by_path["a.lua"].name)
        assert.is_nil(by_path["a.lua"].context) -- root-level file has no parent
    end)
end)
