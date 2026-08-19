-- runs under headless nvim against a throwaway git repo: exercises the local git
-- source end-to-end (content reads, changed-file listing, rename handling,
-- merge-base resolution, and the :Differ picker building a correct DiffModel)
local git_src = require("differ.git")
local rev = require("differ.git.rev")

-- run git in `cwd`, asserting success. identity is pinned inline so commits work
-- in CI without a global gitconfig
local function git(cwd, ...)
    local args =
        { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    local res = vim.system(args, { cwd = cwd, text = true }):wait()
    assert(
        res.code == 0,
        "git failed: " .. table.concat({ ... }, " ") .. "\n" .. (res.stderr or "")
    )
    return res.stdout
end

local function write(path, content)
    local fd = assert(io.open(path, "wb"))
    fd:write(content)
    fd:close()
end

-- a fresh repo with one committed file (a.lua = V1) on `main`
local V1 = "local x = 1\nreturn x\n"
local function fresh_repo()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", V1)
    git(root, "add", "a.lua")
    git(root, "commit", "-q", "-m", "init")
    return root
end

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

    it("hunk staging stores the same blob a git add would (no CRLF leak)", function()
        local root = fresh_repo()
        git(root, "config", "core.autocrlf", "input")
        write(root .. "/a.lua", "local x = 1\r\nNEW LINE\r\nreturn x\r\n")

        local source = {
            old = { kind = "index", label = "INDEX" },
            new = { kind = "worktree", label = "WORKTREE" },
        }
        local model = git_src.model(source, root, { path = "a.lua" })
        assert.are.equal(1, #model.hunks) -- the insert only, no phantom eol hunks
        local patch = require("differ.git.patch")
        local p = patch.hunk("a.lua", model.hunks[1], model.old_text, model.new_text, 0, false)
        assert.is_true(git_src.apply_patch(root, p, false))
        -- the staged blob is byte-identical to what `git add` would have written
        assert.are.equal("local x = 1\nNEW LINE\nreturn x\n", raw_indexed(root, "a.lua"))
    end)
end)

describe("git.apply_patch (target)", function()
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

    ---@param model differ.DiffModel
    ---@param idx integer
    ---@param reverse boolean
    local function hunk_patch(model, idx, reverse)
        return patch.hunk("f.txt", model.hunks[idx], model.old_text, model.new_text, 0, reverse)
    end

    it("reverse-applies to the worktree and leaves the index alone", function()
        local root = two_hunk_repo()
        local model = unstaged_model(root)
        assert.are.equal(2, #model.hunks)

        assert.is_true(git_src.apply_patch(root, hunk_patch(model, 2, true), true, "worktree"))
        -- only the second edit is undone; the first survives, as does the index
        assert.are.equal("a\nB\nc\nd\ne\n", git_src.read(WT, root, "f.txt"))
        assert.are.equal(BASE, git_src.read(INDEX, root, "f.txt"))
    end)

    it("defaults to the index and leaves the worktree alone", function()
        local root = two_hunk_repo()
        local model = unstaged_model(root)

        assert.is_true(git_src.apply_patch(root, hunk_patch(model, 1, false), false))
        assert.are.equal("a\nB\nc\nd\ne\n", git_src.read(INDEX, root, "f.txt"))
        assert.are.equal(EDITED, git_src.read(WT, root, "f.txt"))
    end)

    -- the revert-on-a-staged-hunk path composes two calls, and the worktree one is
    -- located against content the user may have edited since; it must fail whole
    it("fails without writing when the worktree no longer holds the hunk's content", function()
        local root = two_hunk_repo()
        local model = unstaged_model(root)
        write(root .. "/f.txt", "a\nB\nc\nZZZ\ne\n") -- the D line was rewritten since

        local ok, err = git_src.apply_patch(root, hunk_patch(model, 2, true), true, "worktree")
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

        assert.is_true(git_src.apply_patch(root, hunk_patch(model, 2, true), true, "worktree"))
        assert.are.equal("x1\nx2\nx3\na\nB\nc\nd\ne\n", git_src.read(WT, root, "f.txt"))
    end)
end)

-- the missing-final-newline bug was never that the patch text looked wrong: it looked
-- plausible, git apply reported success, and the index silently gained a joined line.
-- the unit fixtures pin the text; only real git can pin the bytes it writes, and under
-- `--unidiff-zero` a side with no lines leaves git trusting the header rather than
-- failing loudly. every shape here round-trips, so an over-eager widening is caught
-- too: unstaging has to land back on the original blob byte-for-byte
describe("git hunk staging round-trip (real git apply, EOF terminators)", function()
    local patch = require("differ.git.patch")
    local INDEX = { kind = "index", label = "INDEX" }
    local WT = { kind = "worktree", label = "WORKTREE" }

    -- raw stdout, no text=true: that collapses the very terminators under test
    local function indexed(root, path)
        local res = vim.system({ "git", "cat-file", "blob", ":" .. path }, { cwd = root }):wait()
        assert(res.code == 0, res.stderr)
        return res.stdout
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

    -- stage the hunk, then unstage the same patch, checking the index blob at each
    -- step. one hunk, so no offset: `reverse` only picks which way git reads it, which
    -- is exactly what the staging keys do
    local function round_trip(base, edited)
        local root = repo_with(base, edited)
        local model = git_src.model({ old = INDEX, new = WT }, root, { path = "f.txt" })
        assert.are.equal(1, #model.hunks)
        local p = patch.hunk("f.txt", model.hunks[1], model.old_text, model.new_text, 0, "old")

        local ok, err = git_src.apply_patch(root, p, false)
        assert.is_true(ok, "stage failed: " .. tostring(err) .. "\n" .. p)
        assert.are.equal(edited, indexed(root, "f.txt"))

        ok, err = git_src.apply_patch(root, p, true)
        assert.is_true(ok, "unstage failed: " .. tostring(err) .. "\n" .. p)
        assert.are.equal(base, indexed(root, "f.txt"))
    end

    it("appends past an unterminated last line, giving it its newline", function()
        round_trip("a\nb", "a\nb\nc\n")
    end)

    it("deletes the tail, leaving the new last line unterminated", function()
        round_trip("a\nb\nc\n", "a\nb")
    end)

    it("appends unterminated onto unterminated", function()
        round_trip("a\nb", "a\nb\nc")
    end)

    -- the control: an unterminated file whose hunk stops short of EOF must not widen,
    -- and must not quietly acquire a trailing newline on the way through
    it("leaves an unterminated file unterminated when the hunk is mid-file", function()
        round_trip("a\nb", "a\nX\nb")
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
            { path = "multi.lua", status = "?", additions = 3, deletions = 0, staged = false },
        }, untracked)
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

describe(":Differ panel", function()
    local Panel = require("differ.panel")

    -- 1-based line of the file row for `path` (optionally pinned to a staged/unstaged
    -- section), located via the panel's meta so tests don't hardcode header offsets
    local function file_line(p, path, staged)
        for i, m in ipairs(p.meta) do
            if
                m.kind == "file"
                and m.entry.path == path
                and (staged == nil or m.entry.staged == staged)
            then
                return i
            end
        end
    end

    -- the View driven by the panel, read without moving focus (which the focus-steal
    -- assertions below depend on): it lives in the origin window
    local function view_at(p)
        return require("differ.view").for_buf(vim.api.nvim_win_get_buf(p.origin_win))
    end

    -- the section content only: strip the 3-line header (root/help/blank) and the
    -- 3-line footer (blank/"Showing changes for:"/rev) so assertions don't depend on
    -- the temp-dir path or the HEAD sha
    local function body(p)
        assert.are.equal("Help: g?", p.lines[2]) -- header present
        assert.are.equal("Showing changes for:", p.lines[#p.lines - 1]) -- footer present
        return vim.list_slice(p.lines, 4, #p.lines - 3)
    end

    it("opens the default panel; bare :Differ re-opens, :Differ panel toggles", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- modified, not staged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        assert.is_not_nil(p)
        assert.is_true(p:is_open())
        -- empty Staged/Untracked sections are dropped, leaving one Unstaged section.
        -- the +/- counts aren't in the text: they're a right-aligned virt_text extmark
        assert.are.same({ "Unstaged (1)", "M a.lua" }, body(p))

        -- a bare :Differ over a live session just (re)opens; it never toggles shut
        git_src.panel({})
        assert.are.equal(p, Panel.current())
        assert.is_true(p:is_open())

        -- :Differ panel (opts.toggle) is the explicit hide/show gesture
        git_src.panel({ toggle = true }) -- hides the sidebar; the session stays alive
        assert.are.equal(p, Panel.current())
        assert.is_false(p:is_open())
        git_src.panel({ toggle = true }) -- shows it again
        assert.is_true(p:is_open())

        -- `:Differ panel <pos>` reveals a hidden sidebar at the requested edge
        git_src.panel({ toggle = true }) -- hide
        require("differ.command").panel("left")
        assert.is_true(p:is_open())
        assert.are.equal("left", p.position)

        -- a bare :Differ reveals a hidden sidebar too (show, not toggle)
        git_src.panel({ toggle = true }) -- hide
        assert.is_false(p:is_open())
        git_src.panel({})
        assert.is_true(p:is_open())

        require("differ.git").close() -- :Differ close ends the session
        assert.is_nil(Panel.current())
    end)

    it("steps ]f / [f from the diff while the sidebar is hidden", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua modified, unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua modified, unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true }) -- lands on a.lua (the origin file)
        local p = Panel.current()
        assert.are.equal(file_line(p, "a.lua"), p.selected_row)

        git_src.panel({ toggle = true }) -- hide the sidebar; the diff view + session stay alive
        assert.is_false(p:is_open())

        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        v:step_file("next") -- ]f with no sidebar window to read the cursor from
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(file_line(p, "z.lua"), p.selected_row)
        assert.is_false(p:is_open()) -- still hidden; stepping didn't reopen it

        v:step_file("prev") -- [f back to a.lua
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(file_line(p, "a.lua"), p.selected_row)

        require("differ.git").close()
    end)

    it("the panel winbar reports the cursor's file position", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua modified, unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua modified, unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local winbar = require("differ.ui.winbar")
        vim.g.statusline_winid = p.winid
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        assert.is_truthy(winbar.panel():find("file 1/2", 1, true))
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "z.lua"), 0 })
        assert.is_truthy(winbar.panel():find("file 2/2", 1, true))
        vim.g.statusline_winid = nil
        p:close()
    end)

    it("runs the session in its own tabpage and returns to the origin tab on close", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local origin_tab = vim.api.nvim_get_current_tabpage()
        local origin_buf = vim.api.nvim_get_current_buf()
        local ntabs = #vim.api.nvim_list_tabpages()

        git_src.panel({ open_first = true })
        -- the diff opened in a fresh tabpage; the invoking tab is untouched
        assert.are.equal(ntabs + 1, #vim.api.nvim_list_tabpages())
        assert.are_not.equal(origin_tab, vim.api.nvim_get_current_tabpage())
        assert.matches("differ://", vim.api.nvim_buf_get_name(0))

        require("differ.git").close()
        -- back in the origin tab, original buffer intact, the session tab dropped
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages())
        assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(origin_buf, vim.api.nvim_get_current_buf())
    end)

    it("ends the session and carries the file out when navigated into the diff window", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/elsewhere.lua", "return 99\n")
        vim.cmd.edit(root .. "/a.lua")
        local origin_tab = vim.api.nvim_get_current_tabpage()
        local ntabs = #vim.api.nvim_list_tabpages()

        git_src.panel({ open_first = true })
        local other = vim.fn.bufadd(root .. "/elsewhere.lua")
        vim.fn.bufload(other)
        local diff_win = vim.api.nvim_get_current_win() -- open_first leaves us in the diff
        vim.api.nvim_win_set_buf(diff_win, other) -- a picker / :edit into the diff window
        vim.wait(500, function()
            return Panel.current() == nil
        end)
        assert.is_nil(Panel.current()) -- the whole session tore down
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages()) -- session tab dropped
        assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage()) -- back in origin tab
        assert.are.equal("elsewhere.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    end)

    it("ends the session and carries the file out when navigated into the panel window", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/elsewhere.lua", "return 99\n")
        vim.cmd.edit(root .. "/a.lua")
        local origin_tab = vim.api.nvim_get_current_tabpage()
        local ntabs = #vim.api.nvim_list_tabpages()

        git_src.panel({ open_first = true })
        local p = Panel.current()
        local other = vim.fn.bufadd(root .. "/elsewhere.lua")
        vim.fn.bufload(other)
        vim.api.nvim_win_set_buf(p.winid, other) -- a picker / :edit into the panel window
        vim.wait(500, function()
            return Panel.current() == nil
        end)
        assert.is_nil(Panel.current()) -- the whole session tore down
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages()) -- session tab dropped
        assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal("elsewhere.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    end)

    it("keeps the session alive when the panel sidebar is merely toggled off", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ open_first = true })
        local p = Panel.current()
        git_src.panel({ toggle = true }) -- toggle hides the sidebar (closes the panel window)
        vim.wait(100) -- give any (wrongly) scheduled teardown a chance to fire
        assert.are.equal(p, Panel.current()) -- still the same live session
        require("differ.git").close()
    end)

    it("opens the real file in the origin tab on jump-to-file (gofile)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local origin_tab = vim.api.nvim_get_current_tabpage()
        local ntabs = #vim.api.nvim_list_tabpages()

        git_src.panel({ open_first = true })
        require("differ").jump_to_file()
        -- the session tab is gone and we're back in the origin tab on the real file
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages())
        assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal("a.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    end)

    it("carries the diff cursor's column to the real file on jump-to-file", function()
        local root = fresh_repo()
        -- add a long line so a non-zero column is meaningful; line 2 is new-side only
        write(root .. "/a.lua", "local x = 1\nlocal answer = 42\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ open_first = true })
        local col = require("differ.view").current().columns[1]
        local brow
        for i, l in ipairs(col.map.lines) do
            if l.new == 2 then -- buffer row of new-side line 2
                brow = i
                break
            end
        end
        assert.is_not_nil(brow)
        vim.api.nvim_win_set_cursor(col.winid, { brow, 6 }) -- the "a" of "answer"
        require("differ").jump_to_file()

        assert.are.equal("a.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
        assert.are.same({ 2, 6 }, vim.api.nvim_win_get_cursor(0)) -- exact line + column
    end)

    it("binds f/b quarter-scroll in the panel window too", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.bufnr, "n")) do
            lhs[m.lhs] = true
        end
        assert.is_true(lhs["f"])
        assert.is_true(lhs["b"])
        -- invoking must not error (regression: the method was shadowed by the field)
        p:scroll("down")
        p:scroll("up")
        p:close()
    end)

    it("groups staged / unstaged / untracked into sections with counts", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged modify of a.lua
        write(root .. "/z.lua", "local z = 9\n")
        git(root, "add", "z.lua") -- staged add
        write(root .. "/u.lua", "untracked\n") -- untracked
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        assert.are.same({
            "Staged (1)",
            "A z.lua",
            "Unstaged (1)",
            "M a.lua",
            "Untracked (1)",
            "? u.lua",
        }, body(p))
        p:close()
    end)

    it("re-sources one View in place as files are selected", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged modify (Unstaged)
        write(root .. "/z.lua", "local z = 9\n")
        git(root, "add", "z.lua") -- staged add (Staged)
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "z.lua"), 0 }) -- staged: HEAD vs index
        p:select()
        local diff_buf = vim.api.nvim_win_get_buf(p.origin_win)
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 }) -- unstaged: index vs worktree
        p:select()
        -- same window + buffer: the View was re-sourced, not recreated
        assert.are.equal(diff_buf, vim.api.nvim_win_get_buf(p.origin_win))
        p:close()
    end)

    -- the change set surviving isn't enough: if the file the diff was on is the one
    -- that went clean, the window is left on a diff of a file that matches HEAD, and
    -- every later refresh walks into the same dead end (active_entry never moves on)
    it(
        "hands the diff to a surviving change when its own file goes clean outside differ",
        function()
            local root = fresh_repo()
            write(root .. "/a.lua", "local x = 2\nreturn x\n")
            write(root .. "/keep.lua", "kept\n") -- a survivor the diff should land on
            vim.cmd.edit(root .. "/a.lua")

            git_src.panel({ rev = {}, open_first = true })
            local p = Panel.current()
            assert.are.equal("a.lua", view_at(p).model.path)

            git(root, "checkout", "HEAD", "--", "a.lua") -- only the shown file goes clean
            vim.api.nvim_set_current_win(p.winid) -- reviewing from the sidebar
            p.on_external_change()

            assert.are.equal(p, Panel.current()) -- keep.lua survives, so the session does
            assert.are.equal("keep.lua", view_at(p).model.path)
            -- the refresh isn't user-driven, so it must not yank focus into the diff
            assert.are.equal(p.winid, vim.api.nvim_get_current_win())
            p:close()
        end
    )

    -- R is the manual counterpart of the watcher, pressed precisely because something
    -- changed outside differ, so it has to re-source the diff and not just the list: a
    -- list-only reload re-baselines the change signature, which would then stop the
    -- watcher from ever catching the diff up
    it("R re-sources the diff, not just the file list", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        assert.are.equal(1, #view_at(p).model.hunks)

        write(root .. "/a.lua", "local x = 2\nreturn x\nlocal y = 3\n") -- edited outside
        vim.api.nvim_set_current_win(p.winid)
        vim.api.nvim_feedkeys("R", "x", false)

        assert.are.equal(2, #view_at(p).model.hunks) -- the diff picked the edit up
        p:close()
    end)

    -- the panel refreshes on any of these: regaining focus, an in-nvim `:!`, or a
    -- terminal git UI (lazygit) closing in a float (TermClose/TermLeave)
    for _, ev in ipairs({ "FocusGained", "ShellCmdPost", "TermClose", "TermLeave" }) do
        it("refreshes on " .. ev .. " so external git changes appear", function()
            local root = fresh_repo()
            write(root .. "/a.lua", "local x = 2\nreturn x\n")
            write(root .. "/keep.lua", "kept\n") -- survives the commit, so the session does too
            vim.cmd.edit(root .. "/a.lua")

            git_src.panel({})
            local p = Panel.current()
            assert.is_not_nil(file_line(p, "a.lua")) -- listed as modified

            git(root, "commit", "-q", "-am", "external change") -- committed outside differ
            -- scoped to the panel's group so the headless harness's own TermClose
            -- handler stays out of it
            vim.api.nvim_exec_autocmds(ev, { group = p.augroup })
            vim.wait(200, function() -- the refresh is scheduled, so let it run
                return file_line(p, "a.lua") == nil
            end)

            assert.is_nil(file_line(p, "a.lua")) -- the panel picked up the clean state
            p:close()
        end)
    end

    it("refresh after close is a no-op, not a crash on the deleted buffer", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        p:close()
        -- a debounced watcher / queued autocmd refresh can land after close; it must
        -- bail rather than render into the wiped buffer
        assert.has_no.errors(function()
            p:refresh()
        end)
    end)

    it("guards a stale entry: selecting a now-clean file refreshes, no blank view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/keep.lua", "kept\n") -- a survivor, so the refresh doesn't end the session
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        local origin_buf = vim.api.nvim_win_get_buf(p.origin_win)
        git(root, "checkout", "HEAD", "--", "a.lua") -- revert outside differ → stale entry

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
        p:select()
        -- no diff opened: the origin window still shows its original buffer
        assert.are.equal(origin_buf, vim.api.nvim_win_get_buf(p.origin_win))
        assert.is_nil(file_line(p, "a.lua")) -- and the stale entry is gone after refresh
        p:close()
    end)

    it("opens a pure rename's diff instead of reporting no changes", function()
        local root = fresh_repo()
        -- a staged rename with no content edit: old and new sides are identical, so
        -- the file diffs to zero hunks but is still a real change worth showing
        git(root, "mv", "a.lua", "b.lua")
        vim.cmd.edit(root .. "/b.lua")

        git_src.panel({})
        local p = Panel.current()
        local origin_buf = vim.api.nvim_win_get_buf(p.origin_win)

        local before = #_G.notifs
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", true), 0 })
        p:select()

        -- the diff opened (a new differ:// buffer replaced the origin buffer)...
        assert.are_not.equal(origin_buf, vim.api.nvim_win_get_buf(p.origin_win))
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.is_not_nil(v)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal(V1, v.model.old_text) -- a.lua @ HEAD
        assert.are.equal(V1, v.model.new_text) -- b.lua @ index (identical)
        -- ...and no "no changes for b.lua" notification fired
        for i = before + 1, #_G.notifs do
            assert.is_nil((_G.notifs[i].msg or ""):find("no changes", 1, true))
        end
        p:close()
    end)

    it("open_first skips content-less renames and lands on the first real change", function()
        local root = fresh_repo()
        write(root .. "/keep.lua", "keep\n") -- an untouched tracked file to open from
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "keep.lua", "z.lua")
        git(root, "commit", "-q", "-am", "more files")
        git(root, "mv", "a.lua", "renamed.lua") -- staged pure rename, zero content delta
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua modified in the worktree (real change)
        -- open from keep.lua: it's in the repo (so the root resolves) but not in the
        -- change set, so open_first falls through to its first-changed pick
        vim.cmd.edit(root .. "/keep.lua")

        git_src.panel({ open_first = true })
        local p = Panel.current()
        -- the rename is the first listed file (Staged section), but it diffs to nothing;
        -- the landing skips it for z.lua, the first entry with real content
        assert.are.equal(file_line(p, "z.lua"), p.selected_row)
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.is_not_nil(v)
        assert.are.equal("z.lua", v.model.path)
        require("differ.git").close()
    end)

    it("diffs a staged entry HEAD↔index and an unstaged entry index↔worktree", function()
        local root = fresh_repo()
        -- stage one version of a.lua, then edit further in the worktree
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "local x = 3\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({})
        local p = Panel.current()
        -- p:select returns focus to the panel, so look the View up via the origin
        -- window's buffer (View.current keys off the focused buffer)
        local function view_in_origin()
            vim.api.nvim_set_current_win(p.origin_win)
            return require("differ.view").current()
        end
        -- a.lua is "MM": it appears in both the Staged and Unstaged sections
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", true), 0 })
        p:select()
        local v = view_in_origin()
        assert.are.equal(V1, v.model.old_text) -- HEAD
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- index

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", false), 0 })
        p:select()
        v = view_in_origin()
        assert.are.equal("local x = 2\nreturn x\n", v.model.old_text) -- index
        assert.are.equal("local x = 3\nreturn x\n", v.model.new_text) -- worktree
        p:close()
    end)
end)

describe(":Differ panel staging (slice C)", function()
    local Panel = require("differ.panel")

    -- the FileEntry for `path`, optionally pinned to staged/unstaged, via the panel
    -- meta (which is rebuilt by refresh after each op)
    local function entry_of(p, path, staged)
        for _, m in ipairs(p.meta) do
            if
                m.kind == "file"
                and m.entry.path == path
                and (staged == nil or m.entry.staged == staged)
            then
                return m.entry
            end
        end
    end
    local function file_line(p, path, staged)
        for i, m in ipairs(p.meta) do
            if
                m.kind == "file"
                and m.entry.path == path
                and (staged == nil or m.entry.staged == staged)
            then
                return i
            end
        end
    end
    local function keymaps(p)
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.bufnr, "n")) do
            lhs[m.lhs] = true
        end
        return lhs
    end
    -- 1-based line of the dir row whose full path is `dir_path`
    local function dir_line(p, dir_path)
        for i, m in ipairs(p.meta) do
            if m.kind == "dir" and m.dir_path == dir_path then
                return i
            end
        end
    end
    -- 1-based line of the section header whose title is `title`
    local function header_line(p, title)
        for i, m in ipairs(p.meta) do
            if m.kind == "header" and m.title == title then
                return i
            end
        end
    end

    it("stages and unstages the file under the cursor", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged modify
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        assert.is_not_nil(entry_of(p, "a.lua", false)) -- starts unstaged

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", false), 0 })
        p:stage_op("stage")
        assert.is_not_nil(entry_of(p, "a.lua", true)) -- now staged
        assert.is_nil(entry_of(p, "a.lua", false))

        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua", true), 0 })
        p:stage_op("unstage")
        assert.is_not_nil(entry_of(p, "a.lua", false)) -- back to unstaged
        p:close()
    end)

    it("stages and unstages all", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- modified
        write(root .. "/b.lua", "new\n") -- untracked
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()

        p:stage_op("stage_all")
        assert.is_not_nil(entry_of(p, "a.lua", true))
        assert.is_not_nil(entry_of(p, "b.lua", true)) -- untracked got added too

        p:stage_op("unstage_all")
        assert.is_nil(entry_of(p, "a.lua", true))
        p:close()
    end)

    it("discards a tracked file back to HEAD (after confirm)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })

        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.is_nil(entry_of(p, "a.lua")) -- no longer a change
        assert.are.equal(V1, table.concat(vim.fn.readfile(root .. "/a.lua"), "\n") .. "\n")
        -- the file's own buffer is reloaded too, not left showing the discarded edit
        local filebuf = vim.fn.bufnr(root .. "/a.lua")
        assert.are.equal(
            V1,
            table.concat(vim.api.nvim_buf_get_lines(filebuf, 0, -1, false), "\n") .. "\n"
        )
        p:close()
    end)

    it("discards an untracked file by deleting it", function()
        local root = fresh_repo()
        write(root .. "/u.lua", "untracked\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "u.lua"), 0 })

        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.are.equal(0, vim.fn.filereadable(root .. "/u.lua"))
        p:close()
    end)

    -- confirm() drains scheduled callbacks while it blocks, so the entry's status can
    -- move under the prompt. an untracked file staged from outside is the sharp case:
    -- the "?" branch deletes it while the index keeps the add
    it("refuses to discard a file whose status moved under the prompt", function()
        local root = fresh_repo()
        write(root .. "/u.lua", "untracked\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "u.lua"), 0 })

        _G.notifs = {}
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            git(root, "add", "u.lua") -- "?" -> a staged add, from outside differ
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.are.equal(1, vim.fn.filereadable(root .. "/u.lua"))
        -- and the index still has the add, so the two can't disagree
        assert.are.equal("untracked\n", git(root, "show", ":u.lua"))
        assert.is_truthy(_G.notifs[#_G.notifs].msg:find("discard skipped: u.lua", 1, true))
        p:close()
    end)

    it("stages and unstages every file under a directory row", function()
        local root = fresh_repo()
        -- two files under src/, plus a sibling at the root so src/ stays a foldable
        -- dir row (a sole common prefix 2+ deep would be stripped to a subtitle)
        vim.fn.mkdir(root .. "/src", "p")
        write(root .. "/src/a.lua", "a\n")
        write(root .. "/src/b.lua", "b\n")
        write(root .. "/top.lua", "t\n")
        vim.cmd.edit(root .. "/top.lua")
        git_src.panel({})
        local p = Panel.current()
        assert.is_not_nil(entry_of(p, "src/a.lua", false))
        assert.is_not_nil(entry_of(p, "src/b.lua", false))

        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })
        p:stage_op("stage")
        assert.is_not_nil(entry_of(p, "src/a.lua", true)) -- both files staged
        assert.is_not_nil(entry_of(p, "src/b.lua", true))
        assert.is_nil(entry_of(p, "top.lua", true)) -- the sibling is untouched

        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })
        p:stage_op("unstage")
        assert.is_not_nil(entry_of(p, "src/a.lua", false)) -- both back to unstaged
        assert.is_not_nil(entry_of(p, "src/b.lua", false))
        p:close()
    end)

    it("unstages a whole section from its header (deep prefix stripped, no dir row)", function()
        local root = fresh_repo()
        -- every staged file shares a 2+-level prefix, so the tree strips it to a
        -- header subtitle and emits no dir row: the header is the only group target
        vim.fn.mkdir(root .. "/lua/panel", "p")
        write(root .. "/lua/panel/init.lua", "i\n")
        write(root .. "/lua/panel/render.lua", "r\n")
        git(root, "add", "lua/panel/init.lua", "lua/panel/render.lua")
        write(root .. "/loose.lua", "l\n") -- an unstaged file so the panel isn't all-staged
        vim.cmd.edit(root .. "/loose.lua")
        git_src.panel({})
        local p = Panel.current()
        assert.is_nil(dir_line(p, "lua/panel")) -- confirm: prefix stripped, no dir row
        assert.is_not_nil(entry_of(p, "lua/panel/init.lua", true))

        vim.api.nvim_win_set_cursor(p.winid, { header_line(p, "Staged"), 0 })
        p:stage_op("unstage")
        assert.is_nil(entry_of(p, "lua/panel/init.lua", true)) -- whole section unstaged
        assert.is_nil(entry_of(p, "lua/panel/render.lua", true))
        assert.is_not_nil(entry_of(p, "lua/panel/init.lua", false))
        p:close()
    end)

    it("discards every file under a directory row (after confirm)", function()
        local root = fresh_repo()
        vim.fn.mkdir(root .. "/src", "p")
        write(root .. "/src/a.lua", "a\n")
        write(root .. "/src/b.lua", "b\n")
        write(root .. "/top.lua", "t\n")
        vim.cmd.edit(root .. "/top.lua")
        git_src.panel({})
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { dir_line(p, "src"), 0 })

        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            return 1
        end
        p:discard()
        vim.fn.confirm = orig

        assert.are.equal(0, vim.fn.filereadable(root .. "/src/a.lua")) -- both deleted
        assert.are.equal(0, vim.fn.filereadable(root .. "/src/b.lua"))
        assert.are.equal(1, vim.fn.filereadable(root .. "/top.lua")) -- sibling kept
        p:close()
    end)

    it("binds staging keys for the worktree source", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = Panel.current()
        local lhs = keymaps(p)
        for _, k in ipairs({ "s", "u", "S", "U", "X", "R" }) do
            assert.is_true(lhs[k])
        end
        p:close()
    end)

    it("does not bind staging keys for a rev-pair source", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "commit", "-q", "-am", "edit")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = "HEAD~1..HEAD" })
        local p = Panel.current()
        local lhs = keymaps(p)
        assert.is_nil(lhs["s"])
        assert.is_nil(lhs["X"])
        p:close()
    end)

    it("honours a disabled panel action from setup config (keymaps)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        require("differ").setup({ keymaps = { panel = { discard = false } } })
        git_src.panel({})
        local p = Panel.current()
        local lhs = keymaps(p)
        assert.is_nil(lhs["X"]) -- discard disabled
        assert.is_true(lhs["s"]) -- other staging keys unaffected
        p:close()
        require("differ").setup({}) -- restore defaults for the rest of the suite
    end)
end)

describe(":Differ diff hunk staging", function()
    local Panel = require("differ.panel")

    -- p:select returns focus to the panel, so the View lives in the origin window
    local function view_in_origin(p)
        vim.api.nvim_set_current_win(p.origin_win)
        return require("differ.view").current()
    end
    -- the staged (index) content of `path`
    local function indexed(root, path)
        return git(root, "show", ":" .. path)
    end
    local function worktree(root, path)
        return table.concat(vim.fn.readfile(root .. "/" .. path), "\n") .. "\n"
    end
    -- the buffer line hunk `n` starts on, in the view's primary column
    local function hunk_line(v, n)
        for lnum, line in ipairs(v.columns[1].map.lines) do
            if line.hunk == n then
                return lnum
            end
        end
    end
    local function keymaps(bufnr)
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
            lhs[m.lhs] = true
        end
        return lhs
    end

    it("stages one hunk in place: index updated, worktree kept, diff stays frozen", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two far-apart edits
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("unstaged", v.staging.initial) -- index↔worktree opens unstaged
        assert.are.equal(2, #v.model.hunks) -- two distinct hunks (lines 1 and 8)
        local before = vim.api.nvim_buf_get_lines(v.columns[1].bufnr, 0, -1, false)

        -- cursor on the first hunk (buffer line 1), stage it
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()

        -- the first edit is in the index; the second isn't; the worktree keeps both
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8\n", indexed(root, "a.lua"))
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8x\n", worktree(root, "a.lua"))
        -- the diff didn't vanish or re-source: same hunks, same buffer, hunk 1 marked
        assert.are.equal(2, #v.model.hunks)
        assert.are.same(before, vim.api.nvim_buf_get_lines(v.columns[1].bufnr, 0, -1, false))
        assert.is_true(v.staged_hunks[1])
        assert.is_nil(v.staged_hunks[2])
        p:close()
    end)

    -- the in-place staged marks are the whole point of the frozen diff, and the watcher
    -- protects them by re-sourcing only when git moved for a reason differ didn't cause.
    -- a staging key pressed in the sidebar writes the index too, so it has to re-baseline
    -- that signature or the next watcher fire reads it as an outside change
    it("keeps in-place staged marks across a staging op driven from the panel", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two hunks to mark
        write(root .. "/z.lua", "z1x\nz2\n") -- a second file to stage from the panel
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk() -- mark hunk 1 in place, leaving hunk 2 unstaged
        assert.is_true(v.staged_hunks[1])

        -- stage a *different* file whole, from the sidebar
        vim.api.nvim_set_current_win(p.winid)
        assert.is_true(p:focus_file("z.lua"))
        p:stage_op("stage")
        assert.are.equal("z1x\nz2\n", indexed(root, "z.lua")) -- z.lua really is staged

        -- the index write that caused: the watcher fires, and must read it as differ's
        -- own doing rather than re-sourcing a.lua's diff out from under the marks
        p.on_external_change()

        assert.are.equal(2, #v.model.hunks) -- still frozen on the same two hunks
        assert.is_true(v.staged_hunks[1]) -- and hunk 1 is still marked staged
        assert.is_nil(v.staged_hunks[2])
        p:close()
    end)

    it("unstages a staged hunk in place, then re-stages it", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- whole change staged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("staged", v.staging.initial) -- a staged (HEAD↔index) diff
        assert.is_true(v.staged_hunks[1]) -- opens marked staged
        assert.are.equal("local x = 2\nreturn x\n", indexed(root, "a.lua"))

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:unstage_hunk()
        assert.are.equal(V1, indexed(root, "a.lua")) -- index reverted to HEAD
        assert.is_false(v.staged_hunks[1]) -- now marked unstaged, still visible

        v:stage_hunk() -- u then s on the same hunk: the mark toggles back
        assert.are.equal("local x = 2\nreturn x\n", indexed(root, "a.lua"))
        assert.is_true(v.staged_hunks[1])
        p:close()
    end)

    it("notifies rather than re-applying when a hunk is already in the target state", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two far-apart edits
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()
        assert.is_true(v.staged_hunks[1])

        -- s/u on a hunk already in the target state re-enter the review flow instead
        -- (stage_hunk/unstage_hunk step past it), so _toggle_hunk itself is called
        -- directly here to exercise its own already-staged/already-unstaged guard
        _G.notifs = {}
        v:_toggle_hunk(true)
        assert.are.equal("differ: hunk already staged", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)
        assert.is_true(v.staged_hunks[1]) -- state untouched

        v:_toggle_hunk(false) -- actually unstage it, so the mirror check below is real
        assert.is_false(v.staged_hunks[1])
        _G.notifs = {}
        v:_toggle_hunk(false)
        assert.are.equal("differ: hunk already unstaged", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)
        assert.is_false(v.staged_hunks[1]) -- state untouched
        p:close()
    end)

    it("stages an untracked file as one whole-file hunk instead of warning", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "alpha\nbeta\n") -- untracked, the only change
        vim.cmd.edit(root .. "/new.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.is_not_nil(v.staging) -- a new file now offers (whole-file) staging
        assert.are.equal("unstaged", v.staging.initial)
        assert.are.equal(1, #v.model.hunks) -- empty<->content is a single hunk

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()
        assert.are.equal("alpha\nbeta\n", indexed(root, "new.lua")) -- whole file staged
        assert.is_true(v.staged_hunks[1])

        v:unstage_hunk() -- u back: leaves the index, untracked again
        assert.is_false(v.staged_hunks[1])
        local porc = vim.system(
            { "git", "status", "--porcelain", "--", "new.lua" },
            { cwd = root, text = true }
        )
            :wait().stdout
        assert.are.equal("?? new.lua\n", porc)
        p:close()
    end)

    it("re-sources the open diff on an external change, not just the panel list", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua modified
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text)

        -- outside differ: edit the viewed file further, and change git state (stage a
        -- second file) so the signature moves and the refresh fires
        write(root .. "/a.lua", "local x = 99\nreturn x\n")
        write(root .. "/b.lua", "new\n")
        git(root, "add", "b.lua")
        vim.api.nvim_exec_autocmds("FocusGained", { group = p.augroup })
        vim.wait(200, function()
            return v.model.new_text == "local x = 99\nreturn x\n"
        end)

        assert.are.equal("local x = 99\nreturn x\n", v.model.new_text) -- diff re-sourced
        p:close()
    end)

    it("opens on the current file, snapping to the hunk nearest the cursor", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n") -- hunks at lines 1 and 10
        write(root .. "/m.lua", "new\n")
        git(root, "add", "m.lua") -- a staged file that sorts ahead of a.lua

        vim.cmd.edit(root .. "/a.lua")
        vim.api.nvim_win_set_cursor(0, { 10, 0 }) -- near the second hunk

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)

        -- opened a.lua (the current file) though m.lua sorts first in the list
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n", v.model.new_text)
        -- and snapped to the second hunk (nearest the cursor), not the first
        local col = v.columns[#v.columns]
        local row = vim.api.nvim_win_get_cursor(col.winid)[1]
        assert.are.equal(2, col.map.lines[row].hunk)
        p:close()
    end)

    -- an "MM" file lists under Staged and Unstaged, and Staged renders first. the origin
    -- line is a worktree line, so it only means anything against the index↔worktree pair:
    -- landing on the staged row reads it in index coordinates and snaps to a stray hunk
    it("opens the unstaged side of an MM file, holding the exact origin line", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n") -- staged: a hunk at line 1
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n") -- unstaged: a hunk at line 10

        vim.cmd.edit(root .. "/a.lua")
        vim.api.nvim_win_set_cursor(0, { 10, 2 }) -- on the unstaged change

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)

        -- the index↔worktree pair, not HEAD↔index (whose hunk sits at line 1)
        assert.are.equal(indexed(root, "a.lua"), v.model.old_text)
        assert.are.equal(worktree(root, "a.lua"), v.model.new_text)

        -- line 10 is a changed line there, so it's held exactly (column included)
        -- rather than falling back to the nearest hunk
        local col = v.columns[#v.columns]
        local row, ccol = unpack(vim.api.nvim_win_get_cursor(col.winid))
        assert.are.equal(10, col.map.lines[row].new)
        assert.is_not_nil(col.map.lines[row].hunk)
        assert.are.equal(2, ccol)
        p:close()
    end)

    -- preferring the unstaged row only means preferring it: a file staged outright has
    -- no unstaged side to land on, so the staged row is the one it has
    it("falls back to the staged row for a fully staged origin file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- staged, with nothing left in the worktree
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("staged", v.staging.initial)
        assert.are.equal(V1, v.model.old_text) -- HEAD↔index, the only pair it has
        assert.are.equal(indexed(root, "a.lua"), v.model.new_text)
        p:close()
    end)

    -- staging a file's last unstaged hunk drops its Unstaged row, so every row below
    -- slides up one. restoring the panel cursor by line number then lands it on a
    -- different file, and ]f / [f step from there
    it("keeps the panel cursor on its file when the row leaves the section", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n") -- staged: a hunk at line 1
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- unstaged: a hunk at line 8
        write(root .. "/z.lua", "z1x\nz2\n") -- a neighbour to slide into the vacated row

        vim.cmd.edit(root .. "/a.lua")
        vim.api.nvim_win_set_cursor(0, { 8, 0 })

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("unstaged", v.staging.initial) -- a.lua's index↔worktree side
        local before = p:current_entry()
        assert.are.equal("a.lua", before.path)
        assert.is_falsy(before.staged)

        -- the open landed on the line-8 hunk already; stage it, emptying the unstaged side
        vim.api.nvim_set_current_win(p.origin_win)
        local col = v.columns[#v.columns]
        assert.is_not_nil(col.map.lines[vim.api.nvim_win_get_cursor(col.winid)[1]].hunk)
        v:stage_hunk()
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua"))

        -- a.lua moved to the Staged section; the cursor follows the file there rather
        -- than staying on the line z.lua just slid into
        local after = p:current_entry()
        assert.are.equal("a.lua", after.path)
        assert.is_true(after.staged)
        -- and the selection ]f / [f step from tracks it too
        assert.are.equal("a.lua", p.meta[p.selected_row].entry.path)
        p:close()
    end)

    -- staging a file's last unstaged hunk leaves the index↔worktree pair with nothing in
    -- it, so the view follows the file to its staged pair rather than sitting on a diff
    -- git no longer has. the reviewer's line comes along: it's a side swap, not a file
    -- switch, and the two sides agree on line numbers now the unstaged one is empty
    it("follows to the staged side when the last unstaged hunk is staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n") -- staged: a hunk at line 1
        git(root, "add", "a.lua")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n") -- unstaged: a hunk at line 10

        vim.cmd.edit(root .. "/a.lua")
        vim.api.nvim_win_set_cursor(0, { 10, 2 })

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("unstaged", v.staging.initial)
        assert.are.equal(1, #v.model.hunks) -- just the line-10 change

        vim.api.nvim_set_current_win(p.origin_win)
        v:stage_hunk()

        -- the staged pair, carrying both edits, with every hunk marked staged
        assert.are.equal("staged", v.staging.initial)
        assert.are.equal(2, #v.model.hunks) -- the line-1 and line-10 changes together
        assert.is_true(v.staged_hunks[1])
        assert.is_true(v.staged_hunks[2])

        -- and the cursor held line 10 rather than snapping to the first hunk
        local col = v.columns[#v.columns]
        local row, ccol = unpack(vim.api.nvim_win_get_cursor(col.winid))
        assert.are.equal(10, col.map.lines[row].new)
        assert.are.equal(2, ccol)
        p:close()
    end)

    -- only the unstaged side follows. emptying the staged one stays put, which is what
    -- lets s put the hunk straight back where it was rather than ping-ponging the view
    it("stays on the staged pair when its last staged hunk is unstaged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- staged outright: the diff opens on HEAD↔index
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("staged", v.staging.initial)
        assert.are.equal(1, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 1), 0 })
        v:unstage_hunk() -- the staged side is empty now, but the view holds
        assert.are.equal(V1, indexed(root, "a.lua")) -- back to HEAD
        assert.are.equal("staged", v.staging.initial)
        assert.are.equal("a.lua", v.model.path)
        assert.is_false(v.staged_hunks[1])

        v:stage_hunk() -- and s puts it back in place, on the same pair
        assert.is_true(v.staged_hunks[1])
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    it("re-sources on a worktree-only edit (no status change) via the signature", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua modified
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)

        -- edit only the worktree (status stays " M"): the content-aware signature still
        -- moves, so the diff re-sources where the old HEAD+status signature would miss it
        write(root .. "/a.lua", "local x = 12345\nreturn x\n")
        vim.api.nvim_exec_autocmds("FocusGained", { group = p.augroup })
        vim.wait(200, function()
            return v.model.new_text == "local x = 12345\nreturn x\n"
        end)

        assert.are.equal("local x = 12345\nreturn x\n", v.model.new_text)
        p:close()
    end)

    it("follows a file to its staged side when staged wholesale outside differ", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua modified, unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("unstaged", v.staging.initial) -- viewing the unstaged side

        git(root, "add", "a.lua") -- stage the whole file in "lazygit"
        vim.api.nvim_exec_autocmds("FocusGained", { group = p.augroup })
        vim.wait(200, function()
            return v.staging.initial == "staged"
        end)

        -- the diff followed the file to its staged side rather than going blank
        assert.are.equal("staged", v.staging.initial)
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- HEAD↔index
        p:close()
    end)

    it("offsets later hunks by earlier staged ones (line-count shift)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\nc\nd\n")
        git(root, "commit", "-q", "-am", "abcd")
        -- hunk 1 inserts two lines (changes the line count); hunk 2 edits d
        write(root .. "/a.lua", "a\nINS1\nINS2\nb\nc\nD\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 2, 0 }) -- the insertion hunk
        v:stage_hunk()
        assert.are.equal("a\nINS1\nINS2\nb\nc\nd\n", indexed(root, "a.lua"))

        -- staging hunk 2 now must shift past the +2 lines hunk 1 added, or git apply
        -- would reject the patch (its frozen line numbers are two short)
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 6, 0 }) -- the d -> D hunk
        v:stage_hunk()
        assert.are.equal("a\nINS1\nINS2\nb\nc\nD\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- git relocates a zero-context hunk by content, but a pure insertion gives its `-`
    -- side no content to match, so it falls back to the header's `+` number. leave that
    -- side in worktree coordinates and the lines land wherever the worktree put them
    it("stages a pure insertion behind an unstaged hunk at the right line", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        -- hunk 1 inserts two lines and is left alone; hunk 2 inserts one, eleven
        -- worktree lines below where it sits in the index
        write(root .. "/a.lua", "1\nA1\nA2\n2\n3\n4\n5\n6\nB1\n7\n8\n9\n10\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 })
        v:stage_hunk()
        assert.is_true(v.staged_hunks[2])
        assert.is_falsy(v.staged_hunks[1])

        -- B1 after line 6, where the hunk actually is; not after line 8, where the
        -- worktree's own numbering would put it
        assert.are.equal("1\n2\n3\n4\n5\n6\nB1\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- the mirror: unstaging a pure deletion leaves the `+` side empty, so git reads the
    -- `-` side. it applied cleanly with a stale number there, silently restoring the
    -- lines in the wrong place rather than failing
    it("unstages a pure deletion behind a staged hunk at the right line", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        git(root, "commit", "-q", "-am", "ten lines")
        -- hunk 1 inserts two lines, hunk 2 deletes two, hunk 3 keeps the unstaged side
        -- alive so the view stays frozen on it
        write(root .. "/a.lua", "1\nINS1\nINS2\n2\n3\n4\n7\n8\n9\nZ\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(3, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        for _, n in ipairs({ 1, 2 }) do
            vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, n), 0 })
            v:stage_hunk()
            assert.is_true(v.staged_hunks[n])
        end
        assert.are.equal("1\nINS1\nINS2\n2\n3\n4\n7\n8\n9\n10\n", indexed(root, "a.lua"))

        -- put the deletion back: lines 5 and 6 belong after 4, not earlier
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 })
        v:unstage_hunk()
        assert.is_false(v.staged_hunks[2])
        assert.are.equal("1\nINS1\nINS2\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", indexed(root, "a.lua"))
        p:close()
    end)

    -- the panel row for `path`, optionally pinned to its staged or unstaged side
    local function file_line(p, path, staged)
        for i, m in ipairs(p.meta) do
            if
                m.kind == "file"
                and m.entry.path == path
                and (staged == nil or m.entry.staged == staged)
            then
                return i
            end
        end
    end

    -- answer the revert confirm with `choice` for the duration of `fn`
    local function confirming(choice, fn)
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            return choice
        end
        local ok, err = pcall(fn)
        vim.fn.confirm = orig
        assert(ok, err)
    end

    it("reverts one hunk from the worktree, leaving the others and the index", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 }) -- the 1 -> 1x hunk
        confirming(1, function()
            v:revert_hunk()
        end)

        -- the first edit is gone from disk, the second survives, the index never moved
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8x\n", worktree(root, "a.lua"))
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8\n", indexed(root, "a.lua"))
        -- the model was spliced, not re-read: one hunk left, and it's the survivor
        assert.are.equal(1, #v.model.hunks)
        assert.are.same({ "8x" }, v.model.hunks[1].new_lines)
        p:close()
    end)

    it("leaves the worktree alone when the confirm is declined", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(2, function() -- "No"
            v:revert_hunk()
        end)

        assert.are.equal("local x = 2\nreturn x\n", worktree(root, "a.lua"))
        assert.are.equal(1, #v.model.hunks)
        p:close()
    end)

    -- confirm() drains scheduled callbacks while it blocks, so a watcher fire can
    -- re-source the view between the prompt and the revert. the stub stands in for that
    -- drain by doing what refresh_external ends at: a set_source under the open prompt
    it("reverts nothing when the same file is re-sourced under the prompt", function()
        local root = fresh_repo()
        local base = {}
        for i = 1, 30 do
            base[i] = ("line%02d"):format(i)
        end
        write(root .. "/a.lua", table.concat(base, "\n") .. "\n")
        git(root, "commit", "-q", "-am", "30 lines")
        local edited = vim.deepcopy(base)
        edited[5], edited[15], edited[25] = "CHANGED05", "CHANGED15", "CHANGED25"
        write(root .. "/a.lua", table.concat(edited, "\n") .. "\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(3, #v.model.hunks)
        local asked_on = v.model

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 }) -- the CHANGED15 hunk

        _G.notifs = {}
        local swapped -- read inside the stub, so it holds however the revert goes on
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            -- the first hunk goes away outside differ, so hunk 2 is now CHANGED25
            local dropped = vim.deepcopy(edited)
            dropped[5] = base[5]
            write(root .. "/a.lua", table.concat(dropped, "\n") .. "\n")
            p:refresh()
            vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "a.lua"), 0 })
            p:select()
            swapped = v.model ~= asked_on
            return 1
        end
        local ok, err = pcall(function()
            v:revert_hunk()
        end)
        vim.fn.confirm = orig
        assert(ok, err)

        assert.is_true(swapped) -- the re-source landed, so this isn't vacuous
        local after = worktree(root, "a.lua")
        assert.is_not_nil(after:find("CHANGED15", 1, true)) -- the hunk the prompt named
        assert.is_not_nil(after:find("CHANGED25", 1, true)) -- the one index 2 slid onto
        assert.are.equal(
            "differ: the diff changed while the prompt was up; nothing was reverted",
            _G.notifs[#_G.notifs].msg
        )
        p:close()
    end)

    -- when the shown file goes clean mid-prompt the watcher hands the window to another
    -- file, and revert is path-agnostic: it would patch whatever model it was handed
    it("reverts nothing when a different file is re-sourced under the prompt", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "local z = 9\nreturn z\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-m", "add z")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/z.lua", "local z = 99\nreturn z\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })

        _G.notifs = {}
        local swapped_to -- read inside the stub, so it holds however the revert goes on
        local orig = vim.fn.confirm
        vim.fn.confirm = function()
            vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "z.lua"), 0 })
            p:select()
            swapped_to = v.model.path
            return 1
        end
        local ok, err = pcall(function()
            v:revert_hunk()
        end)
        vim.fn.confirm = orig
        assert(ok, err)

        assert.are.equal("z.lua", swapped_to) -- the re-source landed
        -- the prompt named a.lua, so z.lua was never in the question
        assert.are.equal("local z = 99\nreturn z\n", worktree(root, "z.lua"))
        assert.are.equal("local x = 2\nreturn x\n", worktree(root, "a.lua"))
        assert.are.equal(
            "differ: the diff changed while the prompt was up; nothing was reverted",
            _G.notifs[#_G.notifs].msg
        )
        p:close()
    end)

    it("reverts a staged hunk out of the index and the worktree together", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        git(root, "add", "a.lua") -- both edits staged; the worktree matches the index
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("staged", v.staging.initial)
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        -- gone from both sides, so the file has no unstaged residue to clean up
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8x\n", indexed(root, "a.lua"))
        assert.are.equal("1\n2\n3\n4\n5\n6\n7\n8x\n", worktree(root, "a.lua"))
        assert.are.equal(1, #v.model.hunks)
        p:close()
    end)

    -- reverting only the worktree copy of a hunk already pushed to the index would
    -- leave the two differing the other way round, so the key refuses instead
    it("refuses to revert a hunk staged during the session", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        -- two hunks, so staging one leaves the unstaged pair live and the view frozen on
        -- it: a marked hunk on a worktree diff is exactly the state the guard is for
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()
        assert.is_true(v.staged_hunks[1])
        assert.are.equal("WORKTREE", v.model.new_rev) -- still the unstaged pair

        confirming(1, function() -- would say yes, but it never gets asked
            v:revert_hunk()
        end)
        assert.are.equal("1x\n2\n3\n4\n5\n6\n7\n8x\n", worktree(root, "a.lua"))
        assert.are.equal(2, #v.model.hunks)
        p:close()
    end)

    -- a new file's content is its only hunk, so reverting it deletes the file; the
    -- confirm has to say that rather than counting hunks at the user
    it("reverts a new file by deleting it, warning that it will", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "fresh\n") -- untracked
        vim.cmd.edit(root .. "/new.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("deletes the file", v.staging.revert_label)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        local asked
        local orig = vim.fn.confirm
        vim.fn.confirm = function(msg)
            asked = msg
            return 1
        end
        local ok, err = pcall(function()
            v:revert_hunk()
        end)
        vim.fn.confirm = orig
        assert(ok, err)

        assert.are.equal("Revert all of new.lua? This deletes the file.", asked)
        assert.are.equal(0, vim.fn.filereadable(root .. "/new.lua"))
        p:close()
    end)

    it("reverts a staged add by dropping the file and its staged entry", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "fresh\n")
        git(root, "add", "new.lua") -- staged add: "A"
        vim.cmd.edit(root .. "/new.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(0, vim.fn.filereadable(root .. "/new.lua"))
        assert.is_nil(git(root, "ls-files", "--", "new.lua"):match("new%.lua")) -- unstaged too
        p:close()
    end)

    -- deleting the file out from under the diff would otherwise strand the window on a
    -- path that no longer exists, showing "hunk 0/0" against an empty buffer
    it("moves to another file after a whole-file revert, not an empty diff", function()
        local root = fresh_repo()
        write(root .. "/keep.lua", "kept\n")
        git(root, "add", "keep.lua")
        git(root, "commit", "-q", "-m", "keep")
        write(root .. "/keep.lua", "kept and edited\n") -- a real change to land on
        write(root .. "/gone.lua", "temporary\n") -- untracked, about to go
        vim.cmd.edit(root .. "/gone.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("gone.lua", v.model.path)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(0, vim.fn.filereadable(root .. "/gone.lua"))
        -- the view followed the panel onto the surviving change
        local after = view_in_origin(p)
        assert.are.equal("keep.lua", after.model.path)
        assert.is_true(#after.model.hunks > 0)
        p:close()
    end)

    -- the cursor used to be pulled to the nearest surviving hunk, because the line a
    -- revert leaves you on is unchanged context and the re-source focus snaps to hunks
    it("keeps the cursor where the reverted hunk was, not on the next one", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n")
        git(root, "commit", "-q", "-am", "12 lines")
        -- hunks far apart, so being pulled to the second one is unmistakable
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 }) -- the 1 -> 1x hunk
        confirming(1, function()
            v:revert_hunk()
        end)

        -- the surviving hunk is the last line of the file; landing on it would mean a
        -- new-side line of 12, and the whole point is that we didn't move there
        local col = v.columns[#v.columns]
        local lnum = vim.api.nvim_win_get_cursor(col.winid)[1]
        local mapped = col.map.lines[lnum]
        assert.is_not_nil(mapped)
        assert.are.equal(1, mapped.new) -- still on line 1, now restored context
        assert.is_nil(mapped.hunk) -- and it is context, not a hunk line
        p:close()
    end)

    it("moves on when the revert takes the file's last hunk", function()
        local root = fresh_repo()
        write(root .. "/keep.lua", "kept\n")
        git(root, "add", "keep.lua")
        git(root, "commit", "-q", "-m", "keep")
        write(root .. "/keep.lua", "kept and edited\n") -- a survivor to land on
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua has one hunk
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(1, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(V1, worktree(root, "a.lua")) -- reverted
        local after = view_in_origin(p)
        assert.are.equal("keep.lua", after.model.path) -- not left on an empty a.lua
        assert.is_true(#after.model.hunks > 0)
        p:close()
    end)

    -- with nothing left to review, an open sidebar next to a diff of a file that's now
    -- clean is a dead end: every key is a no-op and the diff is frozen on a stale model
    it("ends the session when the last change in the set is reverted", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- the only change in the repo
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(1, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        _G.notifs = {}
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(V1, worktree(root, "a.lua"))
        assert.is_nil(Panel.current()) -- the session is gone, not left empty
        assert.is_false(p:is_alive())
        assert.is_false(v:is_open()) -- and it took the diff view with it
        assert.are.equal("differ: no changes left", _G.notifs[1].msg)
        assert.are.equal(1, #_G.notifs) -- said once, not once per teardown step
    end)

    it("lands back in the tab :Differ was invoked from", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        local invoked_from = vim.api.nvim_get_current_tabpage()

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        assert.is_false(invoked_from == vim.api.nvim_get_current_tabpage()) -- own tab
        local v = view_in_origin(p)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(invoked_from, vim.api.nvim_get_current_tabpage())
    end)

    -- the file list can also empty from outside differ: a commit in a tmux pane, a
    -- lazygit discard. the watcher's refresh has to end the session the same way
    it("ends the session when an outside commit empties the change set", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.is_true(v:is_open())

        git(root, "commit", "-q", "-am", "committed elsewhere")
        _G.notifs = {}
        p.on_external_change() -- what the fs watcher / FocusGained fire

        assert.is_nil(Panel.current())
        assert.is_false(p:is_alive())
        assert.is_false(v:is_open())
        assert.are.equal("differ: no changes left", _G.notifs[1].msg)
    end)

    it("keeps the session when other changes survive the revert", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        write(root .. "/b.lua", "kept\n") -- a second change, untracked
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(p, Panel.current()) -- still live, on the surviving change
        assert.are.equal("b.lua", view_in_origin(p).model.path)
        p:close()
    end)

    -- an unstaged deletion is still in the index, and that's what its diff compares
    -- against, so it must come back from there and not from HEAD
    it("restores an unstaged deletion from the index, keeping earlier staged edits", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\ntwo\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        write(root .. "/b.lua", "one\nSTAGED\n") -- an edit staged before the delete
        git(root, "add", "b.lua")
        os.remove(root .. "/b.lua")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", false), 0 })
        p:select()
        local v = view_in_origin(p)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("restores the file", v.staging.revert_label)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        -- the staged version comes back, not HEAD's
        assert.are.equal("one\nSTAGED\n", worktree(root, "b.lua"))
        p:close()
    end)

    it("restores a staged deletion from HEAD, into the index and worktree", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\ntwo\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        git(root, "rm", "-q", "b.lua") -- deletion staged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", true), 0 })
        p:select()
        local v = view_in_origin(p)
        assert.are.equal("b.lua", v.model.path)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal("one\ntwo\n", worktree(root, "b.lua"))
        assert.are.equal("one\ntwo\n", indexed(root, "b.lua")) -- no staged deletion left
        p:close()
    end)

    -- a deletion is the mirror of an added file: one whole-file hunk against an empty
    -- new side, staged and unstaged wholesale by s / u. X still restores the file
    it("stages and unstages a deletion from the diff view", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "one\ntwo\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        os.remove(root .. "/b.lua")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        vim.api.nvim_win_set_cursor(p.winid, { file_line(p, "b.lua", false), 0 })
        p:select()
        local v = view_in_origin(p)
        assert.are.equal("b.lua", v.model.path)
        assert.is_not_nil(v.staging.apply) -- stageable now, wholesale
        assert.is_not_nil(v.staging.revert) -- and still restorable
        assert.is_true(v:_can_stage_hunk())

        -- the open landed on the file's only hunk
        vim.api.nvim_set_current_win(p.origin_win)
        local lnum = vim.api.nvim_win_get_cursor(p.origin_win)[1]
        assert.is_not_nil(v.columns[1].map.lines[lnum].hunk)

        v:stage_hunk()
        -- the removal is in the index, and the view followed the file to its staged side
        assert.are.equal("", git(root, "ls-files", "--", "b.lua"))
        assert.are.equal("staged", v.staging.initial)
        assert.are.equal(0, vim.fn.filereadable(root .. "/b.lua")) -- still gone from disk

        vim.api.nvim_set_current_win(p.origin_win)
        v:unstage_hunk() -- u puts the deletion back to worktree-only
        assert.are.equal("b.lua\n", git(root, "ls-files", "--", "b.lua"))
        p:close()
    end)

    -- a whole-file stage used to report success whatever git did, so a refused `git add`
    -- still marked the hunk and painted it staged: the marks described a state git never
    -- reached. an index lock is the cheapest way to make git refuse on demand
    it("leaves the hunk unmarked when git refuses a whole-file stage", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "z1\nz2\n") -- untracked: staged wholesale, not by hunk
        vim.cmd.edit(root .. "/z.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("z.lua", v.model.path)

        _G.notifs = {}
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 1), 0 })
        write(root .. "/.git/index.lock", "")
        v:stage_hunk()
        os.remove(root .. "/.git/index.lock") -- dropped before the asserts, not after

        assert.is_falsy(v.staged_hunks[1]) -- no mark for something git didn't stage
        assert.are.equal("", git(root, "ls-files", "--", "z.lua")) -- and it really didn't
        assert.is_truthy(
            (_G.notifs[1] and _G.notifs[1].msg or ""):find("stage failed", 1, true),
            _G.notifs[1] and _G.notifs[1].msg or "no notification"
        )
        p:close()
    end)

    it("reloads an open buffer of the file it just reverted", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        vim.cmd.edit(root .. "/a.lua") -- the real file is open in a buffer
        local filebuf = vim.api.nvim_get_current_buf()

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        -- without a checktime this buffer would still hold the reverted line
        local lines = vim.api.nvim_buf_get_lines(filebuf, 0, -1, false)
        assert.are.equal("1", lines[1])
        assert.is_false(vim.bo[filebuf].modified)
        p:close()
    end)

    it("keeps staged marks on the hunks that outlive a revert", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        git(root, "commit", "-q", "-am", "9 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5x\n6\n7\n8\n9x\n") -- three hunks
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(3, #v.model.hunks)

        -- stage the first, then revert the second: the mark has to follow hunk 1
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk()

        vim.api.nvim_set_current_win(p.origin_win)
        local second = nil
        for lnum, line in ipairs(v.columns[1].map.lines) do
            if line.hunk == 2 then
                second = lnum
                break
            end
        end
        vim.api.nvim_win_set_cursor(p.origin_win, { assert(second), 0 })
        confirming(1, function()
            v:revert_hunk()
        end)

        assert.are.equal(2, #v.model.hunks)
        assert.is_true(v.staged_hunks[1]) -- still the 1 -> 1x hunk
        assert.is_nil(v.staged_hunks[2]) -- what was hunk 3, unstaged, renumbered down
        assert.are.same({ "9x" }, v.model.hunks[2].new_lines)
        p:close()
    end)

    it("lands the cursor on the first hunk, not the leading context", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n")
        git(root, "commit", "-q", "-am", "six")
        write(root .. "/a.lua", "1\n2\n3\nX\n5\n6\n") -- only line 4 changes
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        local cur = vim.api.nvim_win_get_cursor(p.origin_win)[1]
        assert.is_not_nil(v.columns[1].map.lines[cur].hunk) -- on a hunk, not context
        assert.are.equal(v:_first_review_line(v.columns[1]), cur)
        p:close()
    end)

    it("lands on the first unstaged hunk, skipping staged ones", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- hunks at lines 1 and 8
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(1, v:_first_review_line(v.columns[1])) -- both unstaged -> hunk 1

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        v:stage_hunk() -- stage hunk 1; the next place to review is hunk 2 (buffer line 9)
        assert.are.equal(9, v:_first_review_line(v.columns[1]))
        p:close()
    end)

    it("df on a staged diff unstages the file and re-sources to its worktree view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n")
        git(root, "commit", "-q", "-am", "base")
        write(root .. "/a.lua", "1x\n2\n3\n") -- modify
        git(root, "add", "a.lua") -- and stage it (fully staged: worktree == index)
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("INDEX", v.model.new_rev) -- opens on the staged HEAD<->index diff

        v:edit_file() -- flow C: unstage + re-source to index<->worktree
        assert.are.equal("WORKTREE", v.model.new_rev) -- the diff now reflects the worktree
        assert.is_truthy(v.edit_win) -- and the editable window opened
        local staged = git(root, "diff", "--cached", "--name-only") or ""
        assert.is_nil(staged:find("a.lua", 1, true)) -- a.lua is no longer staged
        p:close()
    end)

    -- the file half of "search by state": from the bottom of the list the walk carries
    -- on past the end rather than reporting there's nothing left
    it("wraps the review walk past the end of the file list", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n")
        write(root .. "/z.lua", "z1x\nz2\n")
        vim.cmd.edit(root .. "/z.lua") -- open on the last file in the list

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("z.lua", v.model.path)

        _G.notifs = {}
        assert.is_true(p:step_review("next", false, true))
        assert.are.equal("a.lua", v.model.path) -- wrapped round to the file above
        -- its own wording: goto_file's would claim the first file, not the first with
        -- anything left to do
        assert.are.equal(
            "differ: wrapped to the first file left to stage",
            _G.notifs[1] and _G.notifs[1].msg
        )
        p:close()
    end)

    -- a file's own staged row sits above its unstaged one, so the forward walk meets
    -- staged rows constantly; they hold nothing to stage and must not be landed on
    it("skips staged rows when walking for something to stage", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b1\nb2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "b.lua", "z.lua")
        git(root, "commit", "-q", "-am", "three files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- a.lua: staged only, nothing left to stage
        write(root .. "/b.lua", "b1x\nb2\n") -- b.lua: unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: unstaged
        vim.cmd.edit(root .. "/z.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("z.lua", v.model.path)
        -- the staged a.lua row renders first, so the wrap meets it before b.lua
        assert.is_true(file_line(p, "a.lua", true) < file_line(p, "b.lua", false))

        assert.is_true(p:step_review("next", false, true))
        assert.are.equal("b.lua", v.model.path) -- stepped over the staged a.lua
        p:close()
    end)

    -- the walk stops short of the file it started on: what's left inside it is the
    -- caller's business, and re-opening would re-source the frozen diff
    it("returns false when the open file is the only one left to stage", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- staged only
        write(root .. "/z.lua", "z1x\nz2\n") -- the only unstaged file
        vim.cmd.edit(root .. "/z.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("z.lua", v.model.path)
        local hunks_before = #v.model.hunks

        assert.is_false(p:step_review("next", false, true))
        assert.are.equal("z.lua", v.model.path) -- stayed put
        assert.are.equal(hunks_before, #v.model.hunks) -- and wasn't re-sourced
        p:close()
    end)

    -- the mirror: u hunts backward for a file with something staged
    it("walks backward for a file with staged hunks", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- the staged file, rendered first
        write(root .. "/z.lua", "z1x\nz2\n") -- unstaged
        vim.cmd.edit(root .. "/z.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("z.lua", v.model.path)

        assert.is_true(p:step_review("prev", true, true))
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("staged", v.staging.initial)
        p:close()
    end)

    -- the reported bug: starting partway down a file leaves hunk 1 behind the cursor,
    -- where a walk that only ever moves forward can't reach it. the file it started in
    -- comes first, so the leftovers are picked up before the review moves on
    it("picks up the hunks left behind when review starts mid-file", function()
        local root = fresh_repo()
        write(root .. "/z.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- a.lua: one hunk, above z.lua
        write(root .. "/z.lua", "1x\n2\n3\n4\n5x\n6\n7\n8\n9x\n") -- z.lua: three hunks
        vim.cmd.edit(root .. "/z.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(3, #v.model.hunks)

        -- stage from hunk 2 down, deliberately leaving hunk 1 alone
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 })
        v:stage_hunk() -- stage hunk 2
        v:stage_hunk() -- advance to hunk 3
        assert.are.equal(hunk_line(v, 3), vim.api.nvim_win_get_cursor(p.origin_win)[1])
        v:stage_hunk() -- stage hunk 3
        assert.is_true(v.staged_hunks[2])
        assert.is_true(v.staged_hunks[3])
        assert.is_falsy(v.staged_hunks[1])

        -- at the bottom of the file: back round to the hunk left behind, not off to
        -- another file, and without re-sourcing the frozen diff
        _G.notifs = {}
        v:stage_hunk()
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(3, #v.model.hunks)
        assert.are.equal(hunk_line(v, 1), vim.api.nvim_win_get_cursor(p.origin_win)[1])
        assert.are.equal(
            "differ: wrapped to the first hunk left to stage",
            _G.notifs[1] and _G.notifs[1].msg
        )

        v:stage_hunk() -- stage it: z.lua is done, and follows to its staged side
        assert.are.equal(worktree(root, "z.lua"), indexed(root, "z.lua"))
        assert.are.equal("staged", v.staging.initial)

        -- only now does the review leave, for the file it never opened
        vim.api.nvim_set_current_win(p.origin_win)
        v:stage_hunk()
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("unstaged", v.staging.initial)
        p:close()
    end)

    -- the minimal case: one file, so the wrap is the only place left to look
    it("wraps back to an earlier hunk in the same file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        git(root, "commit", "-q", "-am", "nine lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5x\n6\n7\n8\n9x\n") -- the only file, three hunks
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(3, #v.model.hunks)

        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 2), 0 })
        v:stage_hunk() -- stage hunk 2
        v:stage_hunk() -- advance to hunk 3
        v:stage_hunk() -- stage hunk 3

        _G.notifs = {}
        v:stage_hunk() -- past the last hunk: back round to hunk 1
        assert.are.equal("a.lua", v.model.path) -- same file, not re-sourced
        assert.are.equal(3, #v.model.hunks)
        assert.are.equal(hunk_line(v, 1), vim.api.nvim_win_get_cursor(p.origin_win)[1])
        assert.are.equal(
            "differ: wrapped to the first hunk left to stage",
            _G.notifs[1] and _G.notifs[1].msg
        )

        -- and it stages there, finishing the file
        v:stage_hunk()
        assert.is_true(v.staged_hunks[1])
        assert.are.equal(worktree(root, "a.lua"), indexed(root, "a.lua"))
        p:close()
    end)

    -- the mirror of the forward wrap: u looks backward, so it rounds to the *last* hunk
    -- still staged rather than the first left to stage
    it("wraps round to a later staged hunk in the same file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        git(root, "commit", "-q", "-am", "nine lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5x\n6\n7\n8\n9x\n") -- the only file, three hunks
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(3, #v.model.hunks)

        -- stage 1 and 2, leaving 3 alone: the unstaged side survives, so the view stays
        -- frozen on it rather than following the file to its staged pair
        vim.api.nvim_set_current_win(p.origin_win)
        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 1), 0 })
        v:stage_hunk() -- stage hunk 1
        v:stage_hunk() -- advance to hunk 2
        v:stage_hunk() -- stage hunk 2
        assert.is_true(v.staged_hunks[1])
        assert.is_true(v.staged_hunks[2])
        assert.is_falsy(v.staged_hunks[3])

        vim.api.nvim_win_set_cursor(p.origin_win, { hunk_line(v, 1), 0 })
        v:unstage_hunk() -- unstage hunk 1, in place
        assert.is_false(v.staged_hunks[1])

        _G.notifs = {}
        v:unstage_hunk() -- nothing staged behind it: round to hunk 2
        assert.are.equal("a.lua", v.model.path) -- same file, not re-sourced
        assert.are.equal(hunk_line(v, 2), vim.api.nvim_win_get_cursor(p.origin_win)[1])
        assert.are.equal(
            "differ: wrapped to the last hunk left to unstage",
            _G.notifs[1] and _G.notifs[1].msg
        )
        p:close()
    end)

    it("reviews hunk-by-hunk: s stages then advances, stepping to the next file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- a.lua: two hunks
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)
        -- opened from new-file line 1 (the "1" -> "1x" change), so it lands on that
        -- line's new-side row (row 2, under the deleted old "1"), not the hunk's top
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.origin_win)[1]) -- on hunk 1

        v:stage_hunk() -- stage hunk 1; cursor stays put, marked
        assert.is_true(v.staged_hunks[1])
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.origin_win)[1])

        v:stage_hunk() -- second s: advance to hunk 2 (buffer line 9)
        assert.are.equal(9, vim.api.nvim_win_get_cursor(p.origin_win)[1])

        v:stage_hunk() -- stage hunk 2
        assert.is_true(v.staged_hunks[2])

        v:stage_hunk() -- second s on the last hunk: step to the next file
        assert.are.equal("z.lua", v.model.path)
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        p:close()
    end)

    it("reviews backward: u unstages then retreats, stepping to the previous file", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- a.lua: two hunks
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        git(root, "add", "a.lua", "z.lua") -- stage both: a staged (HEAD↔index) review
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        v:step_file("next") -- move forward to z.lua (the last file)
        assert.are.equal("z.lua", v.model.path)

        v:unstage_hunk() -- unstage z.lua's hunk; cursor stays, now unstaged
        assert.is_false(v.staged_hunks[1])

        v:unstage_hunk() -- second u: no earlier hunk -> step back to a.lua's last hunk
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(9, vim.api.nvim_win_get_cursor(p.origin_win)[1]) -- last hunk start
        p:close()
    end)

    it("stages and unstages every hunk with S / U", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "a\nb\nc\nd\n")
        git(root, "commit", "-q", "-am", "abcd")
        -- an insertion plus a later edit: two hunks, line-count-shifting
        write(root .. "/a.lua", "a\nINS1\nINS2\nb\nc\nD\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal(2, #v.model.hunks)

        v:stage_all() -- both hunks into the index in one go
        assert.are.equal("a\nINS1\nINS2\nb\nc\nD\n", indexed(root, "a.lua"))
        assert.is_true(v.staged_hunks[1])
        assert.is_true(v.staged_hunks[2])

        v:unstage_all() -- back out of the index entirely
        assert.are.equal("a\nb\nc\nd\n", indexed(root, "a.lua")) -- == HEAD
        assert.is_false(v.staged_hunks[1])
        assert.is_false(v.staged_hunks[2])
        p:close()
    end)

    it("S steps to the next file when every hunk is already staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        v:stage_all() -- a.lua now fully staged; we stay put
        assert.are.equal("a.lua", v.model.path)
        v:stage_all() -- nothing left to stage: step to z.lua
        assert.are.equal("z.lua", v.model.path)
        p:close()
    end)

    -- S carried the same positional walk s did: from the bottom of the list it claimed
    -- there were no files left, and it would land on staged rows where it does nothing
    it("S wraps past the end of the list, skipping rows with nothing to stage", function()
        local root = fresh_repo()
        write(root .. "/b.lua", "b1\nb2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "b.lua", "z.lua")
        git(root, "commit", "-q", "-am", "three files")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "add", "a.lua") -- a.lua: staged only, nothing left to stage
        write(root .. "/b.lua", "b1x\nb2\n") -- b.lua: unstaged, above z.lua
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: unstaged, last in the list
        vim.cmd.edit(root .. "/z.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("z.lua", v.model.path)

        v:stage_all() -- z.lua fully staged; the view follows to its staged side
        assert.are.equal("z1x\nz2\n", indexed(root, "z.lua"))

        v:stage_all() -- nothing left here: round the end and past the staged a.lua
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("unstaged", v.staging.initial)
        p:close()
    end)

    -- U steps back to a file it can actually unstage something in, not merely to the
    -- previous one: a file with nothing staged is somewhere U would do nothing
    it("U steps back to a file with something staged", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n")
        git(root, "add", "a.lua") -- a.lua: one hunk, staged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, unstaged
        vim.cmd.edit(root .. "/z.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("z.lua", v.model.path)

        v:unstage_all() -- nothing staged here: back to a.lua, on its last staged hunk
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("staged", v.staging.initial)
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        p:close()
    end)

    it("bounded step_file stops at the list ends, but ]f / [f still wrap", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk, left unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, left unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        -- u / U at the first file with nothing staged: stay put, no wrap to the last
        v:unstage_hunk()
        assert.are.equal("a.lua", v.model.path)
        v:unstage_all()
        assert.are.equal("a.lua", v.model.path)

        _G.notifs = {}
        v:step_file("next") -- ]f to z.lua (the last file)
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(0, #_G.notifs) -- a plain step, not a wrap

        _G.notifs = {}
        v:step_file("next", false) -- the bounded step ]c / [c use: no wrap off the last file
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(0, #_G.notifs) -- wrap disabled, so no wrap notify either

        _G.notifs = {}
        v:step_file("next") -- ]f / [f: wraps to the first
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal("differ: wrapped to the first file", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)
        p:close()
    end)

    it("]c / [c flow into the next / previous file at the boundary hunks", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        v:goto_hunk("next") -- past a.lua's only (last) hunk: flow into z.lua
        assert.are.equal("z.lua", v.model.path)
        -- lands on a real hunk row in the file it stepped into, not just anywhere in it
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        v:goto_hunk("prev") -- before z.lua's only (first) hunk: flow back into a.lua
        assert.are.equal("a.lua", v.model.path)
        assert.is_not_nil(v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]].hunk)
        p:close()
    end)

    it(
        "a superseding :Differ <rev> closes a live log session, not just leaves it dangling",
        function()
            local History = require("differ.history")
            local root = fresh_repo()
            write(root .. "/z.lua", "z1\nz2\n")
            git(root, "add", "z.lua")
            git(root, "commit", "-q", "-am", "two files")
            write(root .. "/a.lua", "1x\nreturn x\n") -- a.lua: one hunk, unstaged
            write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, unstaged
            vim.cmd.edit(root .. "/a.lua")

            git_src.history({ path = root .. "/a.lua" }) -- :Differ log a.lua
            assert.is_not_nil(History.current())
            assert.is_true(History.current():is_open())

            -- :Differ HEAD (a rev arg, so opts.supersede applies) must close the live log
            -- session rather than leave its History.current() dangling alongside a fresh one
            git_src.panel({ rev = { "HEAD" }, open_first = true, supersede = true })
            assert.is_nil(History.current())
            local p = Panel.current()
            local v = view_in_origin(p)
            assert.are.equal("a.lua", v.model.path)

            -- a leftover History.current() used to make goto_hunk treat this unrelated rev
            -- diff as still inside a single-commit history session, so ]c at the boundary
            -- just notified "no next hunk" instead of flowing into the next file
            vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
            _G.notifs = {}
            v:goto_hunk("next")
            assert.are.equal("z.lua", v.model.path)
            assert.are.equal(0, #_G.notifs)
            p:close()
        end
    )

    it("a superseding bare :Differ also closes a live log session", function()
        local History = require("differ.history")
        local root = fresh_repo()
        write(root .. "/z.lua", "z1\nz2\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")
        write(root .. "/a.lua", "1x\nreturn x\n") -- a.lua: one hunk, unstaged
        write(root .. "/z.lua", "z1x\nz2\n") -- z.lua: one hunk, unstaged
        vim.cmd.edit(root .. "/a.lua")

        git_src.history({ path = root .. "/a.lua" }) -- :Differ log a.lua
        assert.is_not_nil(History.current())

        -- a bare `:Differ` (no rev) still passes opts.supersede = true from dispatch;
        -- it must close the live log session the same as a `:Differ <rev>` does
        git_src.panel({ rev = {}, open_first = true, supersede = true })
        assert.is_nil(History.current())
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        _G.notifs = {}
        v:goto_hunk("next")
        assert.are.equal("z.lua", v.model.path)
        assert.are.equal(0, #_G.notifs)
        p:close()
    end)

    it("]c flowing forward lands on the new file's first hunk, not line 1", function()
        -- z.lua mirrors a file with a long header before its first real change: 30
        -- lines of context, a small hunk, more context, then a second hunk near the
        -- end. a hunk-at-line-1 fixture can't tell "landed on the first hunk" apart
        -- from "cursor just carried over from wherever it was" -- this one can.
        local root = fresh_repo()
        local base = {}
        for i = 1, 30 do
            base[#base + 1] = "ctx" .. i
        end
        base[#base + 1] = "OLD_A"
        for i = 31, 60 do
            base[#base + 1] = "ctx" .. i
        end
        base[#base + 1] = "OLD_B"
        write(root .. "/z.lua", table.concat(base, "\n") .. "\n")
        git(root, "add", "z.lua")
        git(root, "commit", "-q", "-am", "two files")

        local changed = vim.deepcopy(base)
        changed[31] = "NEW_A"
        changed[#changed] = "NEW_B"
        write(root .. "/a.lua", "1x\n2\n") -- a.lua: one hunk near the top
        write(root .. "/z.lua", table.concat(changed, "\n") .. "\n") -- z.lua: two hunks
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)

        v:goto_hunk("next") -- past a.lua's only hunk: flow into z.lua
        assert.are.equal("z.lua", v.model.path)
        local first = v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]]
        assert.are.equal(1, first and first.hunk) -- z.lua's first hunk, not a leftover cursor row

        v:goto_hunk("next") -- z.lua's second hunk, not a skip out to a (nonexistent) next file
        assert.are.equal("z.lua", v.model.path)
        local second = v.columns[1].map.lines[vim.api.nvim_win_get_cursor(p.origin_win)[1]]
        assert.are.equal(2, second and second.hunk)
        p:close()
    end)

    it("binds s/u/S/U in the diff window for a worktree source, not a rev-pair", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local lhs = keymaps(view_in_origin(p).columns[1].bufnr)
        for _, k in ipairs({ "s", "u", "S", "U", "X" }) do
            assert.is_true(lhs[k])
        end
        p:close()

        git(root, "commit", "-q", "-am", "edit") -- now a clean worktree
        git_src.panel({ rev = "HEAD~1..HEAD", open_first = true })
        local p2 = Panel.current()
        local lhs2 = keymaps(view_in_origin(p2).columns[1].bufnr)
        assert.is_nil(lhs2["s"]) -- rev-pair sources aren't stageable
        assert.is_nil(lhs2["u"])
        assert.is_nil(lhs2["S"])
        assert.is_nil(lhs2["U"])
        assert.is_nil(lhs2["X"]) -- nor revertable: there's no worktree side to write
        p2:close()
    end)

    it("binds df only on a worktree-vs-base source, not a `<rev>↔worktree` open", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        -- default `:Differ` is HEAD↔worktree (uncommitted): df is bound
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        assert.is_true(keymaps(view_in_origin(p).columns[1].bufnr)["df"])
        p:close()

        -- commit so the worktree is clean, then `:Differ HEAD~1` is <rev>↔worktree:
        -- it folds in committed history, so edit-in-review must be off (df unbound)
        git(root, "commit", "-q", "-am", "edit")
        git_src.panel({ rev = "HEAD~1", open_first = true })
        local p2 = Panel.current()
        local v2 = view_in_origin(p2)
        assert.are.equal("WORKTREE", v2.model.new_rev) -- new side is the worktree...
        assert.are.equal("HEAD~1", v2.model.old_rev) -- ...but the base is an older rev
        assert.is_nil(keymaps(v2.columns[1].bufnr)["df"])
        assert.is_false(v2:_editable_source())
        p2:close()
    end)
end)

describe(":Differ panel <-> diff wiring", function()
    local Panel = require("differ.panel")

    it("opens with the cursor in the diff window, not the panel", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        assert.are.equal(p.origin_win, vim.api.nvim_get_current_win()) -- in the diff
        assert.are_not.equal(p.winid, vim.api.nvim_get_current_win())
        p:close()
    end)

    it("binds ]c/[c in the panel, driving the diff view's hunk nav", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n3\n4\n5\n6\n7\n8\n")
        git(root, "commit", "-q", "-am", "8 lines")
        write(root .. "/a.lua", "1x\n2\n3\n4\n5\n6\n7\n8x\n") -- two hunks
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()

        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.bufnr, "n")) do
            lhs[m.lhs] = true
        end
        assert.is_true(lhs["]c"])
        assert.is_true(lhs["[c"])

        -- from the panel, ]c moves the diff window's cursor to the next hunk
        vim.api.nvim_set_current_win(p.winid)
        vim.api.nvim_win_set_cursor(p.origin_win, { 1, 0 })
        require("differ").goto_hunk("next")
        assert.are.equal(9, vim.api.nvim_win_get_cursor(p.origin_win)[1]) -- second hunk
        p:close()
    end)

    it("gofile works from the panel, acting on the driven view", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        vim.api.nvim_set_current_win(p.winid) -- focus the panel
        assert.is_not_nil(require("differ").active_view())

        require("differ").jump_to_file()
        local cur = vim.api.nvim_get_current_buf()
        assert.are.equal("a.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur), ":t"))
        assert.are.equal("", vim.bo[cur].buftype) -- the real file
        assert.is_nil(Panel.current()) -- the whole session was torn down
    end)
end)

describe(":Differ (open_first)", function()
    local Panel = require("differ.panel")

    -- p:select returns focus to the panel, so the View lives in the origin window
    local function view_in_origin(p)
        vim.api.nvim_set_current_win(p.origin_win)
        return require("differ.view").current()
    end

    it("opens the panel and the first file's diff (DiffviewOpen-style)", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        assert.is_not_nil(p)
        local v = view_in_origin(p)
        assert.is_not_nil(v)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(V1, v.model.old_text) -- index (nothing staged) == HEAD
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text) -- worktree
        -- the default footer is the HEAD commit (a 40-char hex sha)
        assert.are.equal("Showing changes for:", p.lines[#p.lines - 1])
        local sha = p.lines[#p.lines]
        assert.are.equal(40, #sha)
        assert.is_truthy(sha:match("^%x+$"))
        p:close()
    end)

    it("populates gitsigns status vars on the diff buffer for the statusline", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- one changed line
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local buf = vim.api.nvim_win_get_buf(p.origin_win)
        local dict = vim.b[buf].gitsigns_status_dict
        assert.is_not_nil(dict)
        assert.are.equal(1, dict.changed) -- "1" -> "2" is a single changed line
        assert.are.equal(0, dict.added)
        assert.are.equal(0, dict.removed)
        assert.are.equal("main", vim.b[buf].gitsigns_head)
        p:close()
    end)

    it("resolves a merge-base (three-dot) against the working tree", function()
        local root = fresh_repo()
        -- diverge: branch off main, commit a change on the branch, then edit further
        git(root, "checkout", "-q", "-b", "feature")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "commit", "-q", "-am", "feature change")
        write(root .. "/a.lua", "local x = 3\nreturn x\n") -- uncommitted on top
        vim.cmd.edit(root .. "/a.lua")

        -- main... => merge-base(main, HEAD) [the init commit, V1] vs worktree [V3]
        git_src.panel({ rev = "main...", open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.is_not_nil(v)
        assert.are.equal(V1, v.model.old_text)
        assert.are.equal("local x = 3\nreturn x\n", v.model.new_text)
        assert.are.equal("main...", v.model.old_rev)
        p:close()
    end)

    it("]f from the diff window steps the panel selection, keeping focus in the diff", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged
        write(root .. "/z.lua", "local z = 9\n")
        git(root, "add", "z.lua") -- staged -> two files in the set
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        vim.api.nvim_set_current_win(p.origin_win) -- emulate cursor in the diff window
        local v = require("differ.view").current()
        local first = v.model.path

        v:step_file("next")
        -- focus stayed in the diff window (not bounced to the panel)
        assert.are.equal(p.origin_win, vim.api.nvim_get_current_win())
        -- and the one view re-sourced to a different file
        assert.are_not.equal(first, require("differ.view").current().model.path)
        p:close()
    end)

    it("]f / [f wrap past the ends of the file list", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- unstaged (sorts last)
        write(root .. "/z.lua", "local z = 9\n")
        git(root, "add", "z.lua") -- staged (sorts first)
        vim.cmd.edit(root .. "/a.lua") -- open on a.lua, the last file

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        vim.api.nvim_set_current_win(p.origin_win)
        local v = require("differ.view").current()
        assert.are.equal("a.lua", v.model.path)

        _G.notifs = {}
        v:step_file("next") -- ]f past the last file wraps to the first
        assert.are.equal("z.lua", require("differ.view").current().model.path)
        assert.are.equal("differ: wrapped to the first file", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)

        _G.notifs = {}
        v:step_file("prev") -- [f past the first wraps back to the last
        assert.are.equal("a.lua", require("differ.view").current().model.path)
        assert.are.equal("differ: wrapped to the last file", _G.notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, _G.notifs[1].level)
        p:close()
    end)

    it("git.close tears down the panel and the diff view it drives", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.is_true(p:is_open())
        assert.is_true(v:is_open())

        git_src.close()
        assert.is_nil(Panel.current()) -- panel gone
        assert.is_false(v:is_open()) -- on_close closed the driven view
    end)
end)

-- a panel and a history are tracked by independent singletons in their own tabs, so an
-- opener that only superseded its own kind left the other stacked underneath. `:Differ log`
-- over a live `:Differ base` panel then needed two `:Differ close`s (the first closed the
-- stale panel, the second the visible history)
describe(":Differ session supersession (cross-kind)", function()
    local Panel = require("differ.panel")
    local History = require("differ.history")

    it("`:Differ log` supersedes a live panel, so one git.close ends the session", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua") -- the origin buffer; supersede returns focus here so
        local ntabs = #vim.api.nvim_list_tabpages() -- range history resolves this repo by anchor

        git_src.panel({ rev = {}, open_first = true }) -- the base/worktree panel
        assert.is_not_nil(Panel.current())

        git_src.range_history({ range = "HEAD" }) -- `:Differ log` on top
        assert.is_nil(Panel.current()) -- superseded, not stacked
        assert.is_not_nil(History.current()) -- exactly the history remains
        assert.are.equal(ntabs + 1, #vim.api.nvim_list_tabpages()) -- one session tab, never two

        git_src.close() -- a single :Differ close ends it
        assert.is_nil(History.current())
        assert.is_nil(Panel.current())
        assert.are.equal(ntabs, #vim.api.nvim_list_tabpages()) -- session tab dropped
    end)

    it("`:Differ log <file>` also supersedes a live panel", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        assert.is_not_nil(Panel.current())

        git_src.history({ path = root .. "/a.lua" }) -- explicit path: repo resolves unambiguously
        assert.is_nil(Panel.current()) -- superseded
        assert.is_not_nil(History.current())

        git_src.close()
        assert.is_nil(History.current())
    end)
end)

-- :q on the diff window is the most natural way to leave a session, and it means the
-- window is already gone when the panel's on_close runs. the teardown has to happen
-- anyway, or every cycle strands a buffer holding a whole DiffModel, the armed
-- WinClosed autocmd, and the canonical differ:// name the next session wants
describe("git session teardown after :q on the diff", function()
    local function differ_bufs()
        local n = 0
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if
                vim.api.nvim_buf_is_valid(b)
                and vim.api.nvim_buf_get_name(b):find("differ://", 1, true)
            then
                n = n + 1
            end
        end
        return n
    end

    local function viewclose_autocmds()
        local n = 0
        for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "WinClosed" })) do
            if
                type(a.group_name) == "string" and a.group_name:find("differ.viewclose", 1, true)
            then
                n = n + 1
            end
        end
        return n
    end

    it("leaks no buffers or autocmds across repeated open/:q cycles", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "1\n2\n")
        git(root, "add", "a.lua")
        git(root, "commit", "-q", "-am", "seed")
        write(root .. "/a.lua", "1x\n2\n")
        vim.cmd.edit(root .. "/a.lua")

        local bufs_before, aus_before = differ_bufs(), viewclose_autocmds()

        for _ = 1, 3 do
            git_src.panel({ rev = {}, open_first = true })
            local v = require("differ.view").current()
            assert.is_not_nil(v)
            local win = v.columns[1].winid
            assert.is_true(vim.api.nvim_win_is_valid(win))

            -- the gesture: the window is gone before on_close runs. nvim_win_close
            -- rather than :quit, which would take headless nvim down with it
            vim.api.nvim_win_close(win, false)
            require("differ.git").close()
        end

        assert.are.equal(bufs_before, differ_bufs())
        assert.are.equal(aus_before, viewclose_autocmds())
    end)
end)

-- a change that diffs to no lines still opens a diff view (the session's anchor) on
-- a notice naming the reason, rather than refusing the selection and re-notifying
describe(":Differ panel (zero-hunk entries)", function()
    local Panel = require("differ.panel")

    local function open_only_entry(root)
        git_src.panel({ open_first = true })
        local p = assert(Panel.current())
        vim.api.nvim_set_current_win(p.origin_win)
        return p, require("differ.view").current()
    end

    it("opens a mode-only change on a notice naming both modes", function()
        local root = fresh_repo()
        git(root, "config", "core.fileMode", "true")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/a.lua", 493)) -- 0755
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_only_entry(root)
        assert.is_not_nil(v)
        assert.are.equal("Mode changed 100644 → 100755", v.model.notice)
        assert.are.same(
            { "Mode changed 100644 → 100755" },
            vim.api.nvim_buf_get_lines(v.columns[1].bufnr, 0, -1, false)
        )
        p:close()
    end)

    it("opens an empty untracked file on a notice", function()
        local root = fresh_repo()
        write(root .. "/empty.txt", "")
        vim.cmd.edit(root .. "/empty.txt")

        local p, v = open_only_entry(root)
        assert.is_not_nil(v)
        assert.are.equal("empty.txt", v.model.path)
        assert.are.equal("Empty file", v.model.notice)
        p:close()
    end)

    it("opens a final-newline-only change on a notice", function()
        local root = fresh_repo()
        write(root .. "/a.lua", V1:sub(1, -2)) -- same content, no trailing newline
        vim.cmd.edit(root .. "/a.lua")

        local p, v = open_only_entry(root)
        assert.is_not_nil(v)
        assert.are.equal("Final newline removed", v.model.notice)
        p:close()
    end)

    it("names a moved submodule pointer, which reads empty on both sides", function()
        local root = fresh_repo()
        -- the submodule's own repo lives outside root, so it adds no untracked entry
        local sub = vim.fn.tempname()
        vim.fn.mkdir(sub, "p")
        git(sub, "init", "-q")
        write(sub .. "/f", "one\n")
        git(sub, "add", "f")
        git(sub, "commit", "-q", "-m", "one")

        git(root, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "mod")
        git(root, "commit", "-q", "-m", "add submodule")
        write(root .. "/mod/f", "two\n") -- move the pointer: commit inside the submodule
        git(root .. "/mod", "commit", "-q", "-am", "two")
        vim.cmd.edit(root .. "/a.lua") -- put the session's origin inside this repo

        local p, v = open_only_entry(root)
        assert.is_not_nil(v)
        assert.are.equal("mod", v.model.path)
        -- `git show :mod` fails on a gitlink, so the model has no content either side
        assert.are.equal("", v.model.old_text)
        assert.are.equal("", v.model.new_text)
        assert.are.equal("Submodule commit changed", v.model.notice)
        p:close()
    end)

    it("still refuses a stale entry, so the list re-sources instead", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")
        git_src.panel({})
        local p = assert(Panel.current())

        -- commit the change behind the panel's back: its entry now diffs to nothing
        git(root, "commit", "-qam", "outside")
        -- on_select is what the panel calls on <CR>; false is "stale, re-source"
        assert.is_false(p.on_select({ path = "a.lua", status = "M", staged = false }))
        if Panel.current() then
            p:close() -- the refresh may have emptied the list and ended the session
        end
    end)
end)

-- a whole-file source (a new or deleted file, a binary one, a change with no lines
-- to show) stages as a unit. the keys act on the file rather than on the hunk under
-- the cursor, which is what used to send them stepping off to another file
describe(":Differ diff whole-file staging", function()
    local Panel = require("differ.panel")

    local function view_in_origin(p)
        vim.api.nvim_set_current_win(p.origin_win)
        return require("differ.view").current()
    end
    -- the mode git records for `path` in the index
    local function index_mode(root, path)
        return (git(root, "ls-files", "--stage", "--", path):match("^(%d+)"))
    end
    local function staged_entry(p, path)
        for _, m in ipairs(p.meta) do
            if m.kind == "file" and m.entry.path == path and m.entry.staged then
                return m.entry
            end
        end
    end

    it("stages a mode-only change with s instead of stepping to another file", function()
        local root = fresh_repo()
        git(root, "config", "core.fileMode", "true")
        write(root .. "/b.lua", "other\n") -- a second file, to catch a step away
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "two files")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/a.lua", 493))
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(0, #v.model.hunks) -- nothing to put a cursor on
        assert.is_true(v.staging.whole_file)
        assert.are.equal("100644", index_mode(root, "a.lua"))

        v:stage_hunk()

        assert.are.equal("100755", index_mode(root, "a.lua")) -- the mode really staged
        assert.is_not_nil(staged_entry(p, "a.lua"))
        assert.are.equal("a.lua", view_in_origin(p).model.path) -- never stepped away
        p:close()
    end)

    it("unstages a staged mode change with u, which needs its seeded staged state", function()
        local root = fresh_repo()
        git(root, "config", "core.fileMode", "true")
        assert((vim.uv or vim.loop).fs_chmod(root .. "/a.lua", 493))
        git(root, "add", "a.lua") -- stage the mode change: the only entry is staged
        vim.cmd.edit(root .. "/a.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("staged", v.staging.initial)
        assert.is_true(v.staged_hunks[1]) -- seeded with no hunk behind it
        assert.are.equal("100755", index_mode(root, "a.lua"))

        v:unstage_hunk()

        assert.are.equal("100644", index_mode(root, "a.lua"))
        p:close()
    end)

    it("stages a new file from the old column's filler rows in split layout", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\ntwo\n") -- untracked: a pure add
        write(root .. "/b.lua", "other\n") -- a second entry, to catch a step away
        vim.cmd.edit(root .. "/new.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.are.equal("new.lua", v.model.path)
        v:toggle_layout() -- -> split; the old column is all filler
        assert.are.equal(2, #v.columns)

        -- a pure add carries no old lines, so every old-column row is a meta row with
        -- no hunk on it: the cursor lookup finds nothing there
        vim.api.nvim_set_current_win(v.columns[1].winid)
        vim.api.nvim_win_set_cursor(v.columns[1].winid, { 1, 0 })
        assert.is_nil(v:_hunk_index_under_cursor())

        v:stage_hunk()

        assert.are.equal("one\ntwo\n", git(root, "show", ":new.lua"))
        assert.is_not_nil(staged_entry(p, "new.lua"))
        p:close()
    end)

    it("advertises the file, not the hunk, in the diff help", function()
        local root = fresh_repo()
        write(root .. "/new.lua", "one\n")
        vim.cmd.edit(root .. "/new.lua")

        git_src.panel({ rev = {}, open_first = true })
        local p = Panel.current()
        local v = view_in_origin(p)
        assert.is_true(v.staging.whole_file)
        v:show_help()
        local help_buf = vim.api.nvim_win_get_buf(0)
        local text = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("stage / unstage file", 1, true))
        assert.is_nil(text:find("stage / unstage hunk", 1, true))
        vim.api.nvim_win_close(0, true)
        p:close()
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
        assert.is_nil(n.msg:find("no changes for this source", 1, true))
    end)

    it("still reports a genuinely empty source at INFO", function()
        local root = fresh_repo() -- clean worktree: nothing to show, and no failure
        vim.cmd.edit(root .. "/a.lua")

        _G.notifs = {}
        assert.is_nil(git_src.panel({}))
        local n = last_notif()
        assert.are.equal("differ: no changes for this source", n.msg)
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
