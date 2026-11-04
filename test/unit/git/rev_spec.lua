local rev = require("differ.git.rev")

describe("git.rev.editable", function()
    -- the daily staging sources put the file on disk on the new side; that pairing is
    -- what binds df, and what reroutes to the merge tool mid-conflict
    it("accepts the staging pairings", function()
        assert.is_true(rev.editable("HEAD", "WORKTREE"))
        assert.is_true(rev.editable("INDEX", "WORKTREE"))
        assert.is_true(rev.editable("HEAD", "INDEX"))
    end)

    it("rejects a committed rev on either side", function()
        assert.is_false(rev.editable("HEAD~1", "WORKTREE"))
        assert.is_false(rev.editable("main...", "WORKTREE"))
        assert.is_false(rev.editable("abc", "def"))
        assert.is_false(rev.editable("INDEX", "HEAD"))
    end)

    it("agrees with what source() resolves the arg forms to", function()
        local function editable(args)
            local s = rev.source(args)
            return rev.editable(s.old.label, s.new.label)
        end
        assert.is_true(editable({}))
        assert.is_true(editable({ "HEAD" }))
        assert.is_false(editable({ "HEAD~1" }))
        assert.is_false(editable({ "main..." }))
        assert.is_false(editable({ "abc..def" }))
        assert.is_false(editable({ "abc", "def" }))
    end)
end)

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

describe("git.rev.parse_raw", function()
    it("parses modes, status and paths, with old then new on a rename", function()
        local out = ":160000 160000 abc def M\0sub\0"
            .. ":100644 100644 abc abc R100\0old/name.lua\0new/name.lua\0"
        assert.are.same({
            { status = "M", old_mode = "160000", new_mode = "160000", path = "sub" },
            {
                status = "R",
                old_mode = "100644",
                new_mode = "100644",
                path = "new/name.lua",
                previous_path = "old/name.lua",
            },
        }, rev.parse_raw(out))
    end)

    it("returns nothing for empty output", function()
        assert.are.same({}, rev.parse_raw(""))
    end)
end)

describe("git.rev.parse_status", function()
    local Z = ("0"):rep(40)
    -- a `1` record's fields before the path
    local function ordinary(xy, path)
        return ("1 %s N... 100644 100644 100644 %s %s %s\0"):format(xy, Z, Z, path)
    end
    local MODES = { head = "100644", index = "100644", worktree = "100644" }
    -- the entry `ordinary` parses to
    local function tracked(x, y, path, previous_path)
        return {
            x = x,
            y = y,
            path = path,
            previous_path = previous_path,
            modes = MODES,
            index_sha = Z,
        }
    end

    it("splits XY into staged (x) and unstaged (y) state, `.` as unchanged", function()
        local out = ordinary("MM", "src/keep.txt")
            .. "? src/new.txt\0"
            .. ordinary(".M", "src/edit.txt")
        assert.are.same({
            tracked("M", "M", "src/keep.txt"),
            { x = "?", y = "?", path = "src/new.txt" },
            tracked(" ", "M", "src/edit.txt"),
        }, rev.parse_status(out))
    end)

    it("keeps spaces in a path", function()
        local out = ordinary("A.", "a dir/b c.txt") .. "? x y\0"
        assert.are.same({
            tracked("A", " ", "a dir/b c.txt"),
            { x = "?", y = "?", path = "x y" },
        }, rev.parse_status(out))
    end)

    it("attaches previous_path from the next field on a rename", function()
        local rename = ("2 R. N... 100644 100644 100644 %s %s R100 deep/new.txt\0deep/old.txt\0"):format(
            Z,
            Z
        )
        assert.are.same({
            tracked("R", " ", "deep/new.txt", "deep/old.txt"),
            tracked("M", " ", "src/a.txt"),
        }, rev.parse_status(rename .. ordinary("M.", "src/a.txt")))
    end)

    it("reads each side's mode and the index blob, HEAD's blob aside", function()
        local head_sha, index_sha = ("a"):rep(40), ("b"):rep(40)
        local out = ("1 MM N... 100644 100755 120000 %s %s x.sh\0"):format(head_sha, index_sha)
        local entry = rev.parse_status(out)[1]
        assert.are.same({ head = "100644", index = "100755", worktree = "120000" }, entry.modes)
        assert.are.equal(index_sha, entry.index_sha)
    end)

    it("reads an unmerged record and an ignored one", function()
        local out = ("u UU N... 100644 100644 100644 100644 %s %s %s c.txt\0! build/out\0"):format(
            Z,
            Z,
            Z
        )
        assert.are.same({
            { x = "U", y = "U", path = "c.txt" },
            { x = "!", y = "!", path = "build/out" },
        }, rev.parse_status(out))
    end)

    it("reads HEAD and the branch from the headers, skipping the upstream ones", function()
        local out = "# branch.oid abc123\0# branch.head main\0# branch.upstream origin/main\0"
            .. "# branch.ab +? -?\0"
            .. ordinary(".M", "a.txt")
        local entries, head, branch = rev.parse_status(out)
        assert.are.same({ tracked(" ", "M", "a.txt") }, entries)
        assert.are.equal("abc123", head)
        assert.are.equal("main", branch)
    end)

    it("reads no HEAD on an unborn branch and no branch when detached", function()
        local _, head, branch = rev.parse_status("# branch.oid (initial)\0# branch.head main\0")
        assert.is_nil(head)
        assert.are.equal("main", branch)
        _, head, branch = rev.parse_status("# branch.oid abc123\0# branch.head (detached)\0")
        assert.are.equal("abc123", head)
        assert.is_nil(branch)
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

    it("consumes both path fields of a rename before the next record", function()
        local out = "1\t1\t\0old/a.txt\0new/a.txt\0"
            .. "0\t0\t\0old/b.txt\0new/b.txt\0"
            .. "5\t2\ttail.txt\0"
        assert.are.same({
            ["new/a.txt"] = { additions = 1, deletions = 1 },
            ["new/b.txt"] = { additions = 0, deletions = 0 },
            ["tail.txt"] = { additions = 5, deletions = 2 },
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
