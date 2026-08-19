local rev = require("differ.git.rev")

describe("git.rev.source", function()
    it("defaults to HEAD vs worktree (uncommitted changes)", function()
        local s = rev.source({})
        assert.are.same({ kind = "rev", rev = "HEAD", label = "HEAD" }, s.old)
        assert.are.equal("worktree", s.new.kind)
    end)

    it("treats a lone rev as <rev> vs worktree", function()
        local s = rev.source({ "HEAD~2" })
        assert.are.same({ kind = "rev", rev = "HEAD~2", label = "HEAD~2" }, s.old)
        assert.are.equal("worktree", s.new.kind)
    end)

    it("reads a two-dot range as a plain rev pair", function()
        local s = rev.source({ "abc..def" })
        assert.are.equal("def", s.new.rev)
        assert.are.equal("abc", s.old.rev)
        assert.are.equal("rev", s.old.kind)
    end)

    it("reads two separate args as a rev pair", function()
        local s = rev.source({ "abc", "def" })
        assert.are.equal("abc", s.old.rev)
        assert.are.equal("def", s.new.rev)
    end)

    it("reads three-dot as merge-base(a,b) vs b", function()
        local s = rev.source({ "main...feature" })
        assert.are.same(
            { kind = "merge_base", base = "main", head = "feature", label = "main...feature" },
            s.old
        )
        assert.are.same({ kind = "rev", rev = "feature", label = "feature" }, s.new)
    end)

    it("reads empty-RHS three-dot as merge-base(a,HEAD) vs worktree", function()
        -- the <leader>dt branch-total form: everything since we diverged from main,
        -- including uncommitted work
        local s = rev.source({ "main..." })
        assert.are.same(
            { kind = "merge_base", base = "main", head = "HEAD", label = "main..." },
            s.old
        )
        assert.are.equal("worktree", s.new.kind)
    end)
end)

describe("git.rev.diff_args", function()
    it("lists a rev-vs-worktree diff with a single rev", function()
        assert.are.same({ "HEAD" }, rev.diff_args(rev.source({})))
    end)

    it("lists a rev pair as two args", function()
        assert.are.same({ "abc", "def" }, rev.diff_args(rev.source({ "abc..def" })))
    end)
end)

describe("git.rev.parse_name_status", function()
    it("parses NUL-delimited modify/add/delete records", function()
        local out = "M\0lua/a.lua\0A\0lua/b.lua\0D\0lua/c.lua\0"
        assert.are.same({
            { status = "M", path = "lua/a.lua" },
            { status = "A", path = "lua/b.lua" },
            { status = "D", path = "lua/c.lua" },
        }, rev.parse_name_status(out))
    end)

    it("captures previous_path on a rename record", function()
        local out = "R100\0old/name.lua\0new/name.lua\0"
        assert.are.same({
            { status = "R", path = "new/name.lua", previous_path = "old/name.lua" },
        }, rev.parse_name_status(out))
    end)

    it("returns nothing for empty output", function()
        assert.are.same({}, rev.parse_name_status(""))
    end)
end)

describe("git.rev.parse_status", function()
    it("splits XY into staged (x) and unstaged (y) state", function()
        -- mM = staged + unstaged edit; ?? = untracked; " M" = unstaged-only
        local out = "MM src/keep.txt\0?? src/new.txt\0 M src/edit.txt\0"
        assert.are.same({
            { x = "M", y = "M", path = "src/keep.txt" },
            { x = "?", y = "?", path = "src/new.txt" },
            { x = " ", y = "M", path = "src/edit.txt" },
        }, rev.parse_status(out))
    end)

    it("attaches previous_path from the next field on a rename", function()
        local out = "R  deep/new.txt\0deep/old.txt\0M  src/a.txt\0"
        assert.are.same({
            { x = "R", y = " ", path = "deep/new.txt", previous_path = "deep/old.txt" },
            { x = "M", y = " ", path = "src/a.txt" },
        }, rev.parse_status(out))
    end)

    it("returns nothing for empty output", function()
        assert.are.same({}, rev.parse_status(""))
    end)
end)

describe("git.rev.parse_numstat", function()
    it("maps paths to additions/deletions", function()
        local out = "2\t1\tsrc/keep.txt\0" .. "10\t0\tsrc/add.txt\0"
        assert.are.same({
            ["src/keep.txt"] = { additions = 2, deletions = 1 },
            ["src/add.txt"] = { additions = 10, deletions = 0 },
        }, rev.parse_numstat(out))
    end)

    it("keys a rename on the new path (empty path field + old, new)", function()
        local out = "0\t0\t\0deep/old.txt\0deep/new.txt\0"
        assert.are.same({
            ["deep/new.txt"] = { additions = 0, deletions = 0 },
        }, rev.parse_numstat(out))
    end)

    it("treats binary `-` counts as zero", function()
        local out = "-\t-\timg.png\0"
        assert.are.same({ ["img.png"] = { additions = 0, deletions = 0 } }, rev.parse_numstat(out))
    end)

    it("returns nothing for empty output", function()
        assert.are.same({}, rev.parse_numstat(""))
    end)
end)

describe("git.rev.valid_ref", function()
    -- git parses a leading-dash positional as an option, and the upload-pack value is
    -- run through a shell, so this is arbitrary command execution off a branch name.
    -- `${IFS}` stands in for the space that check-ref-format would otherwise reject,
    -- which is what makes the payload a branch github could actually host
    it("rejects a ref git would read as an option", function()
        assert.is_false(rev.valid_ref("--upload-pack=touch${IFS}/tmp/pwned"))
        assert.is_false(rev.valid_ref("-x"))
        assert.is_false(rev.valid_ref("--exec=sh"))
    end)

    it("rejects names git's own check-ref-format refuses", function()
        for _, bad in ipairs({
            "",
            "@",
            "has space",
            "tilde~1",
            "caret^",
            "colon:name",
            "star*",
            "question?",
            "brack[et",
            "back\\slash",
            "ctrl\tchar",
            "dot..dot",
            "at@{brace",
            "/leading",
            "trailing/",
            "double//slash",
            "trailing.",
            "branch.lock",
        }) do
            assert.is_false(rev.valid_ref(bad), "should reject: " .. bad)
        end
    end)

    it("accepts the branch names people actually use", function()
        for _, ok in ipairs({
            "main",
            "feature/add-thing",
            "release/1.2.3",
            "user/fix.the-thing_now",
            "dependabot/npm_and_yarn/acme/pkg-1.2.3",
            "WIP",
            "v2",
        }) do
            assert.is_true(rev.valid_ref(ok), "should accept: " .. ok)
        end
    end)
end)

describe("git.rev.parse_raw_modes", function()
    it("reads both modes off a --raw line", function()
        local old, new = rev.parse_raw_modes(":100644 100755 e69de29 e69de29 M\ta.lua\n")
        assert.are.equal("100644", old)
        assert.are.equal("100755", new)
    end)

    it("reads a rename line, whose path half carries two paths", function()
        local old, new =
            rev.parse_raw_modes(":100644 100644 aaaaaaa aaaaaaa R100\told.lua\tnew.lua\n")
        assert.are.equal("100644", old)
        assert.are.equal("100644", new)
    end)

    it("is nil when the run listed nothing", function()
        assert.is_nil(rev.parse_raw_modes(""))
    end)
end)
