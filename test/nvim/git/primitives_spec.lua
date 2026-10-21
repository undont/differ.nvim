-- runs under headless nvim against a throwaway git repo: exercises the local git
-- source end-to-end (content reads, changed-file listing, rename handling,
-- merge-base resolution, and the :Differ picker building a correct DiffModel)
local git_src = require("differ.git")
local rev = require("differ.git.rev")
local helpers = require("test.nvim.git.helpers")
local git = helpers.git
local write = helpers.write
local V1 = helpers.V1
local fresh_repo = helpers.fresh_repo
local view_in_origin = helpers.view_in_origin

describe("git.read / changed_files", function()
    it("reads the committed version and the worktree version", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- uncommitted edit

        local head = { kind = "rev", rev = "HEAD", label = "HEAD" }
        local wt = { kind = "worktree", label = "WORKTREE" }
        assert.are.equal(V1, git_src.read(head, root, "a.lua"))
        assert.are.equal("local x = 2\nreturn x\n", git_src.read(wt, root, "a.lua"))
    end)

    it("returns nil for a path absent on a side (add/delete)", function()
        local root = fresh_repo()
        local head = { kind = "rev", rev = "HEAD", label = "HEAD" }
        assert.is_nil(git_src.read(head, root, "never.lua"))
    end)

    it("lists changed files for the default uncommitted source", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        local files = git_src.changed_files(rev.source({}), root)
        assert.are.same({ { status = "M", path = "a.lua" } }, files)
    end)

    it("keeps CRLF bytes intact for a rev read and an index read", function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git(root, "init", "-q")
        write(root .. "/f.txt", "a\r\nb\r\nc\r\n")
        git(root, "add", "f.txt")
        git(root, "commit", "-q", "-m", "base")
        write(root .. "/f.txt", "a\r\nB\r\nc\r\n")
        git(root, "add", "f.txt") -- stage the CRLF edit into the index, worktree untouched

        local head = { kind = "rev", rev = "HEAD", label = "HEAD" }
        local index = { kind = "index", label = "INDEX" }
        assert.are.equal("a\r\nb\r\nc\r\n", git_src.read(head, root, "f.txt"))
        assert.are.equal("a\r\nB\r\nc\r\n", git_src.read(index, root, "f.txt"))
    end)

    -- git stores a symlink as the path it points at, not the contents behind it
    it("reads a worktree symlink as its target path", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "local y = 1\n")
        vim.uv.fs_symlink("a.lua", root .. "/l")
        git(root, "add", "b.lua", "l")
        git(root, "commit", "-q", "-m", "link")
        os.remove(root .. "/l")
        vim.uv.fs_symlink("b.lua", root .. "/l")

        local wt = { kind = "worktree", label = "WORKTREE" }
        local index = { kind = "index", label = "INDEX" }
        assert.are.equal("a.lua", git_src.read(index, root, "l"))
        assert.are.equal("b.lua", git_src.read(wt, root, "l"))
    end)
end)

-- a file name with glob characters, next to a file its glob matches
describe("git pathspecs", function()
    it("unstages only the file named, not the files its glob matches", function()
        local root = fresh_repo()
        write(root .. "/a1.txt", "one\n")
        write(root .. "/a[1].txt", "bracket\n")
        git(root, "add", "a1.txt", "a[1].txt")
        git(root, "commit", "-q", "-m", "two")
        write(root .. "/a1.txt", "one staged\n")
        write(root .. "/a[1].txt", "bracket staged\n")
        git(root, "add", "--", "a1.txt", ":(literal)a[1].txt")

        assert.is_true(git_src.unstage(root, "a[1].txt"))
        local staged = git(root, "diff", "--cached", "--name-only")
        assert.are.equal("a1.txt\n", staged)
    end)
end)

describe("git.read_stage", function()
    it("keeps CRLF bytes intact for each conflict stage (base/ours/theirs)", function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git(root, "init", "-q")
        write(root .. "/f.txt", "a\r\nb\r\nc\r\n")
        git(root, "add", "f.txt")
        git(root, "commit", "-q", "-m", "base")
        git(root, "checkout", "-q", "-b", "feature")
        write(root .. "/f.txt", "a\r\nTHEIRS\r\nc\r\n")
        git(root, "commit", "-q", "-am", "theirs")
        git(root, "checkout", "-q", "main")
        write(root .. "/f.txt", "a\r\nOURS\r\nc\r\n")
        git(root, "commit", "-q", "-am", "ours")
        -- merging conflicts (non-zero exit), which is expected here: use raw
        -- vim.system directly rather than the asserting `git` helper above, but still
        -- pin identity so the merge doesn't abort before conflicting on runners with no
        -- global gitconfig
        vim.system({
            "git",
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "merge",
            "feature",
        }, { cwd = root, text = true }):wait()

        assert.are.equal("a\r\nb\r\nc\r\n", git_src.read_stage(root, "f.txt", 1)) -- base
        assert.are.equal("a\r\nOURS\r\nc\r\n", git_src.read_stage(root, "f.txt", 2)) -- ours
        assert.are.equal("a\r\nTHEIRS\r\nc\r\n", git_src.read_stage(root, "f.txt", 3)) -- theirs
    end)
end)

describe("git.checkout", function()
    -- a clone of a bare "origin", standing in for the github remote
    local function repo_with_origin()
        local origin = vim.fn.tempname()
        vim.fn.mkdir(origin, "p")
        git(origin, "init", "-q", "--bare")
        local seed = fresh_repo()
        git(seed, "remote", "add", "origin", origin)
        git(seed, "push", "-q", "origin", "main")
        local root = vim.fn.tempname()
        git(origin, "clone", "-q", origin, root)
        return root, seed
    end

    -- commit `content` on a branch off main in `seed`, publish it to origin under `ref`,
    -- and leave seed back on main. a same-repo PR publishes refs/heads/<branch>; a fork
    -- PR only ever reaches origin as refs/pull/<n>/head
    local function publish(seed, branch, content, ref)
        git(seed, "checkout", "-q", "-b", branch)
        write(seed .. "/a.lua", content)
        git(seed, "commit", "-q", "-am", "head")
        local sha = vim.trim(git(seed, "rev-parse", "HEAD"))
        git(seed, "push", "-q", "origin", "HEAD:" .. ref)
        git(seed, "checkout", "-q", "main")
        return sha
    end

    local function head(root)
        return vim.trim(git(root, "rev-parse", "--abbrev-ref", "HEAD")),
            vim.trim(git(root, "rev-parse", "HEAD"))
    end

    it("fetches and checks out a same-repo PR's head branch", function()
        local root, seed = repo_with_origin()
        local sha = publish(seed, "feature", "same repo\n", "refs/heads/feature")

        assert.is_true(git_src.checkout(root, "feature", 7))
        local branch, at = head(root)
        assert.are.equal("feature", branch)
        assert.are.equal(sha, at)
    end)

    it("falls back to the pull ref for a fork PR whose branch isn't on origin", function()
        local root, seed = repo_with_origin()
        local sha = publish(seed, "feat/forked", "fork\n", "refs/pull/26/head")

        -- precondition: the branch itself really is absent from origin
        local direct = vim.system({ "git", "fetch", "origin", "feat/forked" }, { cwd = root })
            :wait()
        assert.are_not.equal(0, direct.code)

        assert.is_true(git_src.checkout(root, "feat/forked", 26))
        local branch, at = head(root)
        assert.are.equal("feat/forked", branch) -- named for the head ref, not detached
        assert.are.equal(sha, at)
    end)

    it("lands on an existing local branch of that name without moving it", function()
        local root, seed = repo_with_origin()
        publish(seed, "feat/forked", "fork\n", "refs/pull/26/head")
        git(root, "checkout", "-q", "-b", "feat/forked") -- local work already under that name
        write(root .. "/a.lua", "local edit\n")
        git(root, "commit", "-q", "-am", "local")
        local _, before = head(root)
        git(root, "checkout", "-q", "main")

        assert.is_true(git_src.checkout(root, "feat/forked", 26))
        local branch, at = head(root)
        assert.are.equal("feat/forked", branch)
        assert.are.equal(before, at) -- left where it was; the session's head warning covers it
    end)

    it("reports the branch fetch's error when there's no pull ref to fall back to", function()
        local root = repo_with_origin()

        local ok, err = git_src.checkout(root, "feat/missing", 26)
        assert.is_false(ok)
        assert.is_truthy(err:find("feat/missing", 1, true)) -- names the ref that was asked for
    end)

    -- head_ref is attacker-controlled: anyone can open a PR. git reads a positional
    -- beginning with `-` as an option and runs an --upload-pack value through a shell,
    -- and `${IFS}` stands in for the space check-ref-format would reject, so the payload
    -- is a branch name github could host. origin here is a local path, the transport the
    -- attack actually fires on. the assertion that matters is the last one: nothing ran
    it("refuses a branch name git would read as an option, and runs nothing", function()
        local root = repo_with_origin()
        local marker = root .. "/pwned"

        local ok, err = git_src.checkout(root, "--upload-pack=touch${IFS}" .. marker, 26)
        assert.are.equal(0, vim.fn.filereadable(marker), "the injected command executed")
        assert.is_false(ok)
        assert.is_truthy(err:find("unsafe branch name", 1, true))
    end)

    it("reports the branch fetch's error when no PR number is passed", function()
        local root, seed = repo_with_origin()
        publish(seed, "feat/forked", "fork\n", "refs/pull/26/head")

        local ok, err = git_src.checkout(root, "feat/forked")
        assert.is_false(ok)
        assert.is_truthy(err:find("feat/forked", 1, true))
    end)
end)

describe("git.merge_file_diff3", function()
    local conflict = require("differ.git.conflict")
    local to_lines = require("differ.util.text").to_lines

    it("re-merges the three stages into diff3 style with a base slab", function()
        local out = git_src.merge_file_diff3("a\nOURS\nc\n", "a\nb\nc\n", "a\nTHEIRS\nc\n")
        local regions = conflict.parse(to_lines(out))
        assert.are.equal(1, #regions)
        assert.are.same({ "OURS" }, regions[1].ours)
        assert.are.same({ "b" }, regions[1].base)
        assert.are.same({ "THEIRS" }, regions[1].theirs)
    end)

    it("keeps CRLF bytes in the recovered base slab", function()
        local out = git_src.merge_file_diff3(
            "a\r\nOURS\r\nc\r\n",
            "a\r\nb\r\nc\r\n",
            "a\r\nTHEIRS\r\nc\r\n"
        )
        local regions = conflict.parse(to_lines(out))
        assert.are.equal(1, #regions)
        assert.are.same({ "b\r" }, regions[1].base) -- the CR survives, matching the :1: stage
    end)

    it("returns marker-free text when the stages merge cleanly", function()
        local out = git_src.merge_file_diff3("a\nb\nc\n", "a\nb\nc\n", "a\nZZZ\nc\n")
        assert.is_not_nil(out)
        assert.is_nil(out:find("<<<<<<<", 1, true))
    end)
end)

describe("git.read (worktree clean filter)", function()
    local wt = { kind = "worktree", label = "WORKTREE" }

    -- raw git stdout: the spec-level git() uses text=true, which collapses \r\n,
    -- so byte-exact blob assertions read through vim.system directly
    local function raw_indexed(root, path)
        local res = vim.system({ "git", "show", ":" .. path }, { cwd = root }):wait()
        assert(res.code == 0, res.stderr)
        return res.stdout
    end

    it("cleans CRLF worktree content the way git add would (autocrlf=input)", function()
        local root = fresh_repo()
        git(root, "config", "core.autocrlf", "input")
        -- a tool rewrote the tracked (LF-blob) file with CRLF endings
        write(root .. "/a.lua", "local x = 1\r\nNEW LINE\r\nreturn x\r\n")
        assert.are.equal("local x = 1\nNEW LINE\nreturn x\n", git_src.read(wt, root, "a.lua"))
    end)

    it("keeps CRLF when the index blob already has CRLF (safe-crlf stickiness)", function()
        local root = fresh_repo()
        git(root, "config", "core.autocrlf", "false")
        write(root .. "/c.txt", "one\r\ntwo\r\n")
        git(root, "add", "c.txt")
        git(root, "commit", "-q", "-m", "crlf blob")
        git(root, "config", "core.autocrlf", "input")
        write(root .. "/c.txt", "one\r\ntwo\r\nthree\r\n")
        -- git add wouldn't renormalise a file whose index blob has CRLF; nor do we
        assert.are.equal("one\r\ntwo\r\nthree\r\n", git_src.read(wt, root, "c.txt"))
    end)

    it("passes CRLF through untouched when no conversion is configured", function()
        local root = fresh_repo()
        git(root, "config", "core.autocrlf", "false")
        write(root .. "/c.txt", "one\r\ntwo\r\n")
        assert.are.equal("one\r\ntwo\r\n", git_src.read(wt, root, "c.txt"))
    end)

    it("staging stores the same blob a git add would (no CRLF leak)", function()
        local root = fresh_repo()
        git(root, "config", "core.autocrlf", "input")
        write(root .. "/c.txt", "one\r\ntwo\r\n")
        git(root, "add", "c.txt")
        git(root, "commit", "-q", "-m", "crlf")
        write(root .. "/c.txt", "one\r\nNEW LINE\r\ntwo\r\n")

        vim.cmd.edit(root .. "/c.txt")
        git_src.panel({ rev = {}, open_first = true })
        local p = require("differ.panel").current()
        view_in_origin(p):stage_all()
        p:close()
        -- the staged blob is byte-identical to what `git add` would have written
        assert.are.equal("one\nNEW LINE\ntwo\n", raw_indexed(root, "c.txt"))
    end)

    -- a repo whose `filter` driver drops `secret` lines from conf.txt on the way in
    local function filtered_repo()
        local root = fresh_repo()
        git(root, "config", "filter.strip.clean", "sed /^secret/d")
        git(root, "config", "filter.strip.smudge", "cat")
        write(root .. "/.gitattributes", "conf.txt filter=strip\n")
        write(root .. "/conf.txt", "a\nb\n")
        git(root, "add", ".gitattributes", "conf.txt")
        git(root, "commit", "-q", "-m", "filtered file")
        return root
    end

    it("runs a custom clean filter over LF-only worktree content", function()
        local root = filtered_repo()
        write(root .. "/conf.txt", "a\nsecret 1\nb\n")
        assert.are.equal("a\nb\n", git_src.read(wt, root, "conf.txt"))

        local source = { old = { kind = "index", label = "INDEX" }, new = wt }
        local model = git_src.model(source, root, { path = "conf.txt" })
        assert.are.equal(0, #model.hunks)
    end)

    it("hunk staging leaves filtered-out lines out of the index", function()
        local root = filtered_repo()
        write(root .. "/conf.txt", "a\nsecret 1\nNEW\nb\n")

        local source = { old = { kind = "index", label = "INDEX" }, new = wt }
        local model = git_src.model(source, root, { path = "conf.txt" })
        assert.are.equal(1, #model.hunks)
        local text = require("differ.model.apply").splice(model, { true })
        assert.is_true(require("differ.git.index").write_index(root, "conf.txt", text))
        assert.are.equal("a\nNEW\nb\n", raw_indexed(root, "conf.txt"))
    end)

    it("collapses an expanded ident keyword the way git add would", function()
        local root = fresh_repo()
        write(root .. "/.gitattributes", "id.txt ident\n")
        write(root .. "/id.txt", "$Id: 0123abcd $\n")
        assert.are.equal("$Id$\n", git_src.read(wt, root, "id.txt"))
    end)

    it("reads a file with no filter attribute raw", function()
        local root = filtered_repo()
        write(root .. "/a.lua", "secret 1\n")
        assert.are.equal("secret 1\n", git_src.read(wt, root, "a.lua"))
    end)
end)

describe("git.revert_patch", function()
    local patch = require("differ.git.patch")
    local INDEX = { kind = "index", label = "INDEX" }
    local WT = { kind = "worktree", label = "WORKTREE" }

    -- committed and indexed as `a b c d e`, with the worktree carrying two
    -- independent single-line edits, so a patch can name one hunk and leave the other
    local BASE = "a\nb\nc\nd\ne\n"
    local EDITED = "a\nB\nc\nD\ne\n"
    local function two_hunk_repo()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git(root, "init", "-q")
        write(root .. "/f.txt", BASE)
        git(root, "add", "f.txt")
        git(root, "commit", "-q", "-m", "init")
        write(root .. "/f.txt", EDITED)
        return root
    end

    -- the index-vs-worktree model, whose hunks are the ones the diff view holds frozen
    local function unstaged_model(root)
        return git_src.model({ old = INDEX, new = WT }, root, { path = "f.txt" })
    end

    -- the revert patches the file, so its hunk sits at the model's new-side lines
    ---@param model differ.DiffModel
    ---@param idx integer
    local function hunk_patch(model, idx)
        return patch.hunk("f.txt", model.hunks[idx], model.old_text, model.new_text, 0, "new")
    end

    it("reverses one hunk in the worktree and leaves the index alone", function()
        local root = two_hunk_repo()
        local model = unstaged_model(root)
        assert.are.equal(2, #model.hunks)

        assert.is_true(git_src.revert_patch(root, hunk_patch(model, 2)))
        -- only the second edit is undone; the first survives, as does the index
        assert.are.equal("a\nB\nc\nd\ne\n", git_src.read(WT, root, "f.txt"))
        assert.are.equal(BASE, git_src.read(INDEX, root, "f.txt"))
    end)

    -- the revert-on-a-staged-hunk path composes two calls, and the worktree one is
    -- located against content the user may have edited since; it must fail whole
    it("fails without writing when the worktree no longer holds the hunk's content", function()
        local root = two_hunk_repo()
        local model = unstaged_model(root)
        write(root .. "/f.txt", "a\nB\nc\nZZZ\ne\n") -- the D line was rewritten since

        local ok, err = git_src.revert_patch(root, hunk_patch(model, 2))
        assert.is_false(ok)
        assert.is_not_nil(err)
        assert.are.equal("a\nB\nc\nZZZ\ne\n", git_src.read(WT, root, "f.txt"))
    end)

    -- the patch carries the model's frozen line numbers, so an edit above the hunk
    -- desynchronises them; `--unidiff-zero` relocates by content instead
    it("relocates a zero-context hunk when lines shifted above it", function()
        local root = two_hunk_repo()
        local model = unstaged_model(root)
        write(root .. "/f.txt", "x1\nx2\nx3\na\nB\nc\nD\ne\n") -- D moves from line 4 to 7

        assert.is_true(git_src.revert_patch(root, hunk_patch(model, 2)))
        assert.are.equal("x1\nx2\nx3\na\nB\nc\nd\ne\n", git_src.read(WT, root, "f.txt"))
    end)
end)

-- the missing-final-newline bug was never that the patch text looked wrong: it looked
-- plausible, git apply reported success, and the file silently gained a joined line.
-- the unit fixtures pin the text; only real git can pin the bytes it writes, and under
-- `--unidiff-zero` a side with no lines leaves git trusting the header rather than
-- failing loudly. an over-eager widening is caught too: the revert has to land back on
-- the original file byte-for-byte
describe("git hunk revert (real git apply, EOF terminators)", function()
    local patch = require("differ.git.patch")
    local INDEX = { kind = "index", label = "INDEX" }
    local WT = { kind = "worktree", label = "WORKTREE" }

    -- raw bytes, no readfile: that collapses the very terminators under test
    local function on_disk(root, path)
        local fd = assert(io.open(root .. "/" .. path, "rb"))
        local data = fd:read("*a")
        fd:close()
        return data
    end

    -- committed, so the index starts equal to HEAD, with the worktree carrying the edit
    local function repo_with(base, edited)
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git(root, "init", "-q")
        write(root .. "/f.txt", base)
        git(root, "add", "f.txt")
        git(root, "commit", "-q", "-m", "base")
        write(root .. "/f.txt", edited)
        return root
    end

    -- X's own path: reverse the hunk against the file, which has to put back the base
    -- bytes exactly. one hunk, so no offset
    local function revert_back(base, edited)
        local root = repo_with(base, edited)
        local model = git_src.model({ old = INDEX, new = WT }, root, { path = "f.txt" })
        assert.are.equal(1, #model.hunks)
        local p = patch.hunk("f.txt", model.hunks[1], model.old_text, model.new_text, 0, "new")

        local ok, err = git_src.revert_patch(root, p)
        assert.is_true(ok, "revert failed: " .. tostring(err) .. "\n" .. p)
        assert.are.equal(base, on_disk(root, "f.txt"))
    end

    it("takes back an append that gave the last line its newline", function()
        revert_back("a\nb", "a\nb\nc\n")
    end)

    it("puts back a deleted tail, with the newline it had", function()
        revert_back("a\nb\nc\n", "a\nb")
    end)

    it("takes back an unterminated append onto an unterminated file", function()
        revert_back("a\nb", "a\nb\nc")
    end)

    -- the control: an unterminated file whose hunk stops short of EOF must not widen,
    -- and must not quietly acquire a trailing newline on the way through
    it("leaves an unterminated file unterminated when the hunk is mid-file", function()
        revert_back("a\nb", "a\nX\nb")
    end)
end)

describe("git.file_entries (rev-pair sources)", function()
    it("unions in untracked files for a worktree new-side, but not a rev new-side", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- tracked, modified
        write(root .. "/u.lua", "untracked\n") -- untracked, no diff can ever see it

        local wt_entries = git_src.file_entries(git_src.resolve(rev.source({}), root), root)
        table.sort(wt_entries, function(x, y)
            return x.path < y.path
        end)
        assert.are.same({
            { status = "M", path = "a.lua", additions = 1, deletions = 1 },
            { status = "?", path = "u.lua", additions = 1, deletions = 0 },
        }, wt_entries)

        -- a rev-vs-rev source (no worktree side) never gains untracked files
        git(root, "checkout", "-q", "-b", "feature")
        git(root, "commit", "-q", "-am", "feature change")
        local rev_source = git_src.resolve({
            old = { kind = "rev", rev = "main", label = "main" },
            new = {
                kind = "rev",
                rev = "HEAD",
                label = "HEAD",
            },
        }, root)
        local rev_entries = git_src.file_entries(rev_source, root)
        assert.are.same(
            { { status = "M", path = "a.lua", additions = 1, deletions = 1 } },
            rev_entries
        )
    end)

    it("counts an untracked file's real lines, but 0 for binary content", function()
        local root = fresh_repo()
        write(root .. "/multi.lua", "one\ntwo\nthree\n")
        write(root .. "/bin.dat", "abc\0def")

        local entries = git_src.file_entries(git_src.resolve(rev.source({}), root), root)
        table.sort(entries, function(x, y)
            return x.path < y.path
        end)
        assert.are.same({
            { status = "?", path = "bin.dat", additions = 0, deletions = 0 },
            { status = "?", path = "multi.lua", additions = 3, deletions = 0 },
        }, entries)
    end)
end)

describe("git.status_sections", function()
    it("counts an untracked file's real lines, same as file_entries", function()
        local root = fresh_repo()
        write(root .. "/multi.lua", "one\ntwo\nthree\n")

        local sections = git_src.status_sections(root)
        local untracked
        for _, sec in ipairs(sections) do
            if sec.title == "Untracked" then
                untracked = sec.entries
            end
        end
        assert.are.same({
            {
                path = "multi.lua",
                status = "?",
                additions = 3,
                deletions = 0,
                x = "?",
                y = "?",
                review = "unstaged",
            },
        }, untracked)
    end)

    -- every row as { section, path, status, kept }
    local function rows_of(root)
        local out = {}
        for _, sec in ipairs(git_src.status_sections(root)) do
            for _, e in ipairs(sec.entries) do
                out[#out + 1] = { sec.title, e.path, e.status, e.kept or false }
            end
        end
        return out
    end

    -- `git rm --cached` leaves the file on disk, so porcelain lists the path twice
    it("folds a kept deletion's copy on disk into its one Staged row", function()
        local root = fresh_repo()
        git(root, "rm", "-q", "--cached", "a.lua")
        assert.are.same({ { "Staged", "a.lua", "D", true } }, rows_of(root))
    end)

    it("refuses to discard a kept deletion over its copy on disk", function()
        local root = fresh_repo()
        git(root, "rm", "-q", "--cached", "a.lua")
        write(root .. "/a.lua", "mine\n")
        local entry
        for _, sec in ipairs(git_src.status_sections(root)) do
            entry = entry or sec.entries[1]
        end
        _G.notifs = {}
        assert.is_false(git_src.discard(root, entry))
        assert.is_truthy(_G.notifs[#_G.notifs].msg:find("overwrite a.lua on disk", 1, true))
        assert.are.equal("mine\n", table.concat(vim.fn.readfile(root .. "/a.lua"), "\n") .. "\n")
    end)

    it("lists a conflict once, in a Conflicts section ahead of the rest", function()
        local root = fresh_repo()
        git(root, "checkout", "-q", "-b", "side")
        write(root .. "/a.lua", "side\n")
        git(root, "commit", "-q", "-am", "side")
        git(root, "checkout", "-q", "main")
        write(root .. "/a.lua", "main\n")
        git(root, "commit", "-q", "-am", "main")
        -- conflicts, so the asserting helper can't run it; the identity is pinned inline
        -- or a runner with no global gitconfig aborts the merge before it conflicts
        vim.system(
            { "git", "-c", "user.email=t@t", "-c", "user.name=t", "merge", "-q", "side" },
            { cwd = root }
        ):wait()
        write(root .. "/b.lua", "b\n")

        assert.are.same({
            { "Conflicts", "a.lua", "U", false },
            { "Untracked", "b.lua", "?", false },
        }, rows_of(root))
    end)
end)

describe("git.open_file", function()
    it("reads the rename's old side from previous_path", function()
        local root = fresh_repo()
        git(root, "mv", "a.lua", "b.lua")
        write(root .. "/b.lua", "local x = 2\nreturn x\n")
        git(root, "commit", "-q", "-am", "rename + edit")

        local source = assert(git_src.resolve(rev.source({ "HEAD~1", "HEAD" }), root))
        local v = git_src.open_file(
            source,
            root,
            { status = "R", path = "b.lua", previous_path = "a.lua" }
        )
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal(V1, v.model.old_text) -- a.lua @ HEAD~1
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- b.lua @ HEAD
        v:close()
    end)
end)

-- rev.source turns any leftover arg into a rev ref, so a typo reaches git as a real
-- lookup and comes back as a failed listing. reporting it as "no changes" hides that
describe("git listing errors", function()
    local Panel = require("differ.panel")

    -- the notification the call under test produced, if any
    local function last_notif()
        return _G.notifs[#_G.notifs]
    end

    it("carries git's stderr off a failed listing instead of an empty list", function()
        local root = fresh_repo()
        local source = {
            old = { kind = "rev", rev = "nosuchref", label = "nosuchref" },
            new = {
                kind = "worktree",
                label = "WORKTREE",
            },
        }
        local files, err = git_src.changed_files(source, root)
        assert.are.same({}, files)
        assert.is_truthy(err)
        assert.is_truthy(err:find("nosuchref", 1, true))

        -- file_entries stops at the failure rather than listing untracked files past it
        local entries, ferr = git_src.file_entries(source, root)
        assert.are.same({}, entries)
        assert.are.equal(err, ferr)
    end)

    it("reports a mistyped revspec at ERROR, in git's words", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a real change, so INFO would lie
        vim.cmd.edit(root .. "/a.lua")

        _G.notifs = {}
        local p = git_src.panel({ rev = { "nosuchref" } })
        assert.is_nil(p) -- no session opened
        assert.is_nil(Panel.current())
        local n = last_notif()
        assert.are.equal(vim.log.levels.ERROR, n.level)
        assert.is_truthy(n.msg:find("nosuchref", 1, true))
        assert.is_nil(n.msg:find("no changes to show", 1, true))
    end)

    it("still reports a genuinely empty source at INFO", function()
        local root = fresh_repo() -- clean worktree: nothing to show, and no failure
        vim.cmd.edit(root .. "/a.lua")

        _G.notifs = {}
        assert.is_nil(git_src.panel({}))
        local n = last_notif()
        assert.are.equal("differ: no changes to show", n.msg)
        assert.are.equal(vim.log.levels.INFO, n.level)
    end)

    it("reports a mistyped rev-range history at ERROR too", function()
        local root = fresh_repo()
        vim.cmd.edit(root .. "/a.lua")

        _G.notifs = {}
        git_src.range_history({ range = "nosuchref...HEAD" })
        local n = last_notif()
        assert.are.equal(vim.log.levels.ERROR, n.level)
        assert.is_truthy(n.msg:find("nosuchref", 1, true))
    end)
end)

-- the panel counts every untracked file's lines on every build and every refresh.
-- reading them through the clean filter meant three git processes and a loose blob
-- per CRLF-carrying file, every time
describe("git.untracked_additions (cost)", function()
    -- the number of loose objects in the repo's object store
    local function loose_objects(root)
        return #vim.fn.glob(root .. "/.git/objects/??/*", false, true)
    end
    local function untracked_entry(sections, path)
        for _, sec in ipairs(sections) do
            for _, e in ipairs(sec.entries) do
                if e.path == path and e.status == "?" then
                    return e
                end
            end
        end
    end

    it("counts a CRLF untracked file without writing a blob into .git/objects", function()
        local root = fresh_repo()
        write(root .. "/crlf.txt", "one\r\ntwo\r\nthree\r\n")
        local before = loose_objects(root)

        for _ = 1, 3 do -- a build and two refreshes
            local sections = git_src.status_sections(root)
            assert.are.equal(3, untracked_entry(sections, "crlf.txt").additions)
        end

        assert.are.equal(before, loose_objects(root))
    end)

    it("reuses the count until the file's mtime or size moves", function()
        local root = fresh_repo()
        local path = root .. "/u.txt"
        local uv = vim.uv or vim.loop
        write(path, "a\nb\n") -- 4 bytes, two lines
        assert(uv.fs_utime(path, 1700000000, 1700000000))

        local sections = git_src.status_sections(root)
        assert.are.equal(2, untracked_entry(sections, "u.txt").additions)

        -- same byte count, same timestamp, different content: a re-read would say 1
        write(path, "abc\n")
        assert(uv.fs_utime(path, 1700000000, 1700000000))
        sections = git_src.status_sections(root)
        assert.are.equal(2, untracked_entry(sections, "u.txt").additions) -- served from cache

        -- moving the timestamp is what lets the new count through
        assert(uv.fs_utime(path, 1700000001, 1700000001))
        sections = git_src.status_sections(root)
        assert.are.equal(1, untracked_entry(sections, "u.txt").additions)
    end)
end)

-- a fetch is the one git call that talks to a network, and it ran unbounded: a slow
-- remote froze nvim until git gave up, and a credential prompt never came back
describe("git.checkout (network budget)", function()
    -- a `git` earlier on PATH than the real one, running `body`
    local function fake_git(body)
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = dir .. "/git"
        write(path, "#!/bin/sh\n" .. body .. "\n")
        assert((vim.uv or vim.loop).fs_chmod(path, 493))
        return dir
    end

    it("kills a fetch that outlasts its budget, and says so", function()
        local root = fresh_repo()
        local git_src_mod = require("differ.git")
        local budget, path = git_src_mod.fetch_timeout_ms, vim.env.PATH
        git_src_mod.fetch_timeout_ms = 300
        vim.env.PATH = fake_git("sleep 30") .. ":" .. path

        local started = (vim.uv or vim.loop).now()
        local ok, err = git_src_mod.checkout(root, "feature", nil)
        local took = (vim.uv or vim.loop).now() - started

        git_src_mod.fetch_timeout_ms, vim.env.PATH = budget, path
        assert.is_false(ok)
        assert.is_truthy(err)
        assert.is_truthy(err:find("timed out", 1, true))
        assert.is_true(took < 10000) -- killed, not waited out
    end)

    it("returns the spawn error instead of raising it", function()
        -- a cwd that isn't there fails to spawn the same way a missing git does
        local ok, err = require("differ.git").checkout("/no/such/repo", "feature", nil)
        assert.is_false(ok)
        assert.is_truthy(err)
        assert.is_truthy(err:find("ENOENT", 1, true))
    end)

    it("runs the fetch with terminal prompts disabled", function()
        local root = fresh_repo()
        local marker = vim.fn.tempname()
        local path = vim.env.PATH
        -- the fake records the env it saw, then fails so checkout stops there
        vim.env.PATH = fake_git('printf "%s" "$GIT_TERMINAL_PROMPT" > ' .. marker .. "\nexit 1")
            .. ":"
            .. path

        require("differ.git").checkout(root, "feature", nil)

        vim.env.PATH = path
        assert.are.equal("0", table.concat(vim.fn.readfile(marker), ""))
    end)
end)
