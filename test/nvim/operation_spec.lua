-- runs under headless nvim against throwaway repos stopped mid-operation: continue, skip
-- and abort run without a terminal and never open an editor

local git_src = require("differ.git")
local operation = require("differ.git.operation")
local merge = require("differ.merge")

local function git(cwd, ...)
    local args = { "git", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    return vim.system(args, { cwd = cwd, text = true }):wait()
end

local function git_ok(cwd, ...)
    local res = git(cwd, ...)
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

-- a repo where `feature` changes f.txt then g.txt and `main` changes both the other way,
-- so replaying feature's two commits stops twice. identity is repo config, since the
-- runner's own commits can't take `-c` flags
local function diverged_repo()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    git_ok(root, "config", "user.email", "t@t")
    git_ok(root, "config", "user.name", "t")
    git_ok(root, "config", "rerere.enabled", "false")
    write(root .. "/f.txt", "a\n")
    write(root .. "/g.txt", "a\n")
    git_ok(root, "add", ".")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", "feature\n")
    git_ok(root, "commit", "-q", "-am", "feature f", "--author=f <f@f>")
    write(root .. "/g.txt", "feature\n")
    git_ok(root, "commit", "-q", "-am", "feature g", "--author=f <f@f>")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/f.txt", "main\n")
    write(root .. "/g.txt", "main\n")
    git_ok(root, "commit", "-q", "-am", "main")
    return root
end

-- stopped on the first conflict of `op`; revert undoes feature's two commits on top of a
-- third that rewrites both files. `single` picks or reverts only the first commit, which
-- git runs without a sequencer
---@param op "merge"|"rebase"|"rebase-apply"|"am"|"cherry-pick"|"revert"
---@param single boolean|nil
local function stopped(op, single)
    local root = diverged_repo()
    if op == "merge" then
        git(root, "merge", "--no-edit", "feature") -- --no-edit isn't saved for the continue
    elseif op == "rebase" then
        git_ok(root, "checkout", "-q", "feature")
        git(root, "rebase", "main")
    elseif op == "rebase-apply" then
        git_ok(root, "checkout", "-q", "feature")
        git(root, "rebase", "--apply", "main")
    elseif op == "am" then
        local patch = root .. ".patch"
        write(patch, git_ok(root, "format-patch", "-2", "--stdout", "feature"))
        git(root, "am", "-3", patch)
    elseif op == "cherry-pick" then
        local picks = { "feature~1", "feature" }
        if single then
            picks = { "feature~1" }
        end
        git(root, "cherry-pick", unpack(picks))
    elseif op == "revert" then
        git_ok(root, "checkout", "-q", "feature")
        write(root .. "/f.txt", "later\n")
        write(root .. "/g.txt", "later\n")
        git_ok(root, "commit", "-q", "-am", "later")
        local reverts = { "HEAD~2", "HEAD~1" }
        if single then
            reverts = { "HEAD~2" }
        end
        git(root, "revert", "--no-edit", unpack(reverts))
    end
    assert(#git_src.conflicted(root) > 0, op .. " didn't stop on a conflict")
    return root
end

local function resolve_all(root)
    for _, path in ipairs(git_src.conflicted(root)) do
        write(root .. "/" .. path, "resolved\n")
        git_ok(root, "add", path)
    end
end

-- run the action and wait for its callback
local function run(root, action, opts)
    local result
    operation.run(root, assert(git_src.operation(root)), action, opts, function(ok, output)
        result = { ok = ok, output = output }
    end)
    assert(
        vim.wait(10000, function()
            return result ~= nil
        end),
        "the run never finished"
    )
    return result
end

local function subject(root)
    return vim.trim(git_ok(root, "log", "-1", "--format=%s"))
end

-- a gpg.program that records whether GPG_TTY names a terminal, then signs with junk after
-- `delay` seconds. returns the record's path
local function gpg_stub(root, delay)
    local record = vim.fn.tempname()
    local stub = vim.fn.tempname()
    write(
        stub,
        table.concat({
            "#!/bin/sh",
            "cat >/dev/null",
            ('if [ -c "$GPG_TTY" ]; then echo tty; else echo none; fi > %s'):format(
                vim.fn.shellescape(record)
            ),
            ("sleep %d"):format(delay or 0),
            "printf '\\n[GNUPG:] SIG_CREATED D 22 8 00 0 0\\n' >&2",
            "printf -- '-----BEGIN PGP SIGNATURE-----\\nstub\\n-----END PGP SIGNATURE-----\\n'",
        }, "\n")
    )
    vim.fn.setfperm(stub, "rwx------")
    git_ok(root, "config", "gpg.program", stub)
    return record
end

-- signing on through commit.gpgsign. returns the stub's record
local function signing(root, delay)
    git_ok(root, "config", "commit.gpgsign", "true")
    return gpg_stub(root, delay)
end

describe("git operation runner", function()
    local saved, marker

    -- an editor that leaves a trace, so a run that opened one shows
    before_each(function()
        marker = vim.fn.tempname()
        local script = vim.fn.tempname()
        write(script, ("#!/bin/sh\ntouch %s\n"):format(vim.fn.shellescape(marker)))
        vim.fn.setfperm(script, "rwx------")
        saved = { vim.env.GIT_EDITOR, vim.env.EDITOR, vim.env.VISUAL }
        vim.env.GIT_EDITOR, vim.env.EDITOR, vim.env.VISUAL = script, script, script
    end)

    after_each(function()
        vim.env.GIT_EDITOR, vim.env.EDITOR, vim.env.VISUAL = saved[1], saved[2], saved[3]
        assert.are.equal(0, vim.fn.filereadable(marker), "an editor was opened")
    end)

    it("continues a merge with git's prepared message", function()
        local root = stopped("merge")
        resolve_all(root)
        local res = run(root, "continue")
        assert.is_true(res.ok, res.output)
        assert.is_nil(git_src.operation(root))
        assert.are.equal("Merge branch 'feature'", subject(root))
        assert.are.equal(2, #vim.split(vim.trim(git_ok(root, "log", "-1", "--format=%p")), " "))
    end)

    for _, op in ipairs({ "rebase", "rebase-apply", "am", "cherry-pick", "revert" }) do
        it(op .. " continues to its next conflict, then finishes", function()
            local root = stopped(op)
            resolve_all(root)
            local res = run(root, "continue")
            assert.is_false(res.ok)
            assert.is_not_nil(git_src.operation(root))
            assert.are.same({ "g.txt" }, git_src.conflicted(root))
            resolve_all(root)
            res = run(root, "continue")
            assert.is_true(res.ok, res.output)
            assert.is_nil(git_src.operation(root))
        end)
    end

    for _, op in ipairs({ "merge", "rebase", "cherry-pick", "revert" }) do
        it(op .. " continues with an edited message", function()
            local root = stopped(op)
            resolve_all(root)
            assert.is_not_nil(operation.prepared_message(root, git_src.operation(root)))
            run(root, "continue", { message = "edited subject\n\n# a comment\nbody\n" })
            -- the sequence ops stop again on g.txt, after committing the edited first one
            assert.are.equal(
                "edited subject\n\nbody",
                vim.trim(git_ok(root, "log", "-1", "--format=%B"))
            )
            if op ~= "merge" then
                assert.are.same({ "g.txt" }, git_src.conflicted(root))
            end
        end)
    end

    it("keeps prepare-commit-msg's output in an edited merge message", function()
        local root = stopped("merge")
        resolve_all(root)
        local hook = root .. "/.git/hooks/prepare-commit-msg"
        write(hook, '#!/bin/sh\necho hooked >> "$1"\n')
        vim.fn.setfperm(hook, "rwx------")
        local res = run(root, "continue", { message = "edited\n" })
        assert.is_true(res.ok, res.output)
        assert.is_nil(git_src.operation(root))
        assert.are.equal("edited\nhooked", vim.trim(git_ok(root, "log", "-1", "--format=%B")))
        assert.are.equal(2, #vim.split(vim.trim(git_ok(root, "log", "-1", "--format=%p")), " "))
    end)

    for _, op in ipairs({ "rebase", "cherry-pick" }) do
        it("keeps the picked commit's author on an edited " .. op, function()
            local root = stopped(op)
            resolve_all(root)
            run(root, "continue", { message = "edited\n" })
            assert.are.equal("edited", subject(root))
            assert.are.equal("f@f", vim.trim(git_ok(root, "log", "-1", "--format=%ae")))
        end)
    end

    it("has no prepared message for am or an apply-backend rebase", function()
        assert.is_nil(operation.prepared_message(stopped("am"), "am"))
        assert.is_nil(operation.prepared_message(stopped("rebase-apply"), "rebase"))
    end)

    it("reports git's output when a continue fails", function()
        local root = stopped("merge")
        local res = run(root, "continue")
        assert.is_false(res.ok)
        assert.matches("conflict", res.output)
        assert.is_not_nil(git_src.operation(root))
    end)

    for _, op in ipairs({ "rebase", "am", "cherry-pick", "revert" }) do
        it("skips a " .. op .. " commit", function()
            local root = stopped(op)
            local res = run(root, "skip")
            assert.is_false(res.ok) -- the next commit stops too
            assert.are.same({ "g.txt" }, git_src.conflicted(root))
            assert.are.equal(op, git_src.operation(root))
        end)
    end

    for _, op in ipairs({ "merge", "rebase", "am", "cherry-pick", "revert" }) do
        it("aborts a " .. op, function()
            local root = stopped(op)
            -- a rebase stops detached on main; aborting goes back to feature
            local head = git_ok(root, "rev-parse", "HEAD")
            if op == "rebase" then
                head = git_ok(root, "rev-parse", "feature")
            end
            local res = run(root, "abort")
            assert.is_true(res.ok, res.output)
            assert.is_nil(git_src.operation(root))
            assert.are.equal(head, git_ok(root, "rev-parse", "HEAD"))
            assert.are.same({}, git_src.conflicted(root))
        end)
    end

    for _, op in ipairs({ "cherry-pick", "revert" }) do
        it("continues a single-commit " .. op, function()
            local root = stopped(op, true)
            assert.is_nil(vim.uv.fs_stat(root .. "/.git/sequencer"))
            resolve_all(root)
            local res = run(root, "continue")
            assert.is_true(res.ok, res.output)
            assert.is_nil(git_src.operation(root))
        end)

        it("continues a single-commit " .. op .. " with an edited message", function()
            local root = stopped(op, true)
            resolve_all(root)
            local res = run(root, "continue", { message = "edited\n" })
            assert.is_true(res.ok, res.output)
            assert.is_nil(git_src.operation(root))
            assert.are.equal("edited", subject(root))
        end)
    end

    it("stops before the --continue when the edited commit fails", function()
        local root = stopped("cherry-pick")
        resolve_all(root)
        local head = git_ok(root, "rev-parse", "HEAD")
        local hook = root .. "/.git/hooks/commit-msg"
        write(hook, "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
        vim.fn.setfperm(hook, "rwx------")
        local res = run(root, "continue", { message = "edited\n" })
        assert.is_false(res.ok)
        assert.matches("hook says no", res.output)
        assert.are.equal("cherry-pick", git_src.operation(root))
        assert.are.equal(head, git_ok(root, "rev-parse", "HEAD"))
    end)

    describe("with signing on", function()
        it("runs in a floating terminal that gpg can prompt on", function()
            local root = stopped("merge")
            resolve_all(root)
            local record = signing(root)
            local wins = #vim.api.nvim_list_wins()
            local result
            operation.run(root, "merge", "continue", nil, function(ok, output)
                result = { ok = ok, output = output }
            end)
            assert.are.equal(wins + 1, #vim.api.nvim_list_wins())
            assert.are.equal("terminal", vim.bo.buftype)
            assert(
                vim.wait(10000, function()
                    return result ~= nil
                end),
                "the run never finished"
            )
            assert.is_true(result.ok, result.output)
            assert.are.equal(wins, #vim.api.nvim_list_wins())
            assert.are.same({ "tty" }, vim.fn.readfile(record))
            assert.matches("gpgsig", git_ok(root, "cat-file", "-p", "HEAD"))
        end)

        it("hands back the float's output when git fails", function()
            local root = stopped("merge")
            signing(root)
            local res = run(root, "continue")
            assert.is_false(res.ok)
            assert.matches("conflict", res.output)
            assert.not_matches("Process exited", res.output)
        end)

        for _, close in ipairs({ "quit", "bdelete!" }) do
            it("stops git and still hands back when the float is closed with :" .. close, function()
                local root = stopped("merge")
                resolve_all(root)
                signing(root, 30)
                local wins = #vim.api.nvim_list_wins()
                local result
                operation.run(root, "merge", "continue", nil, function(ok, output)
                    result = { ok = ok, output = output }
                end)
                vim.cmd(close)
                assert(
                    vim.wait(5000, function()
                        return result ~= nil
                    end),
                    "the run never handed back"
                )
                assert.is_false(result.ok)
                assert.are.equal(wins, #vim.api.nvim_list_wins())
                assert.are.equal("merge", git_src.operation(root))
            end)
        end

        it("aborts in the background", function()
            local root = stopped("merge")
            signing(root)
            local wins = #vim.api.nvim_list_wins()
            local result
            operation.run(root, "merge", "abort", nil, function(ok, output)
                result = { ok = ok, output = output }
            end)
            assert.are.equal(wins, #vim.api.nvim_list_wins())
            assert(vim.wait(10000, function()
                return result ~= nil
            end))
            assert.is_true(result.ok, result.output)
        end)

        it("runs a rebase started with -S in the float", function()
            local root = diverged_repo()
            local record = gpg_stub(root)
            git_ok(root, "checkout", "-q", "feature")
            git(root, "rebase", "-S", "main")
            resolve_all(root)
            local result
            operation.run(root, "rebase", "continue", nil, function(ok, output)
                result = { ok = ok, output = output }
            end)
            assert.are.equal("terminal", vim.bo.buftype)
            assert(vim.wait(10000, function()
                return result ~= nil
            end))
            assert.are.same({ "tty" }, vim.fn.readfile(record))
        end)

        it("signs an edited commit of a cherry-pick range started with -S", function()
            local root = diverged_repo()
            gpg_stub(root)
            git(root, "cherry-pick", "-S", "feature~1", "feature")
            resolve_all(root)
            run(root, "continue", { message = "edited\n" })
            assert.are.equal("edited", subject(root))
            assert.matches("gpgsig", git_ok(root, "cat-file", "-p", "HEAD"))
        end)
    end)
end)

describe(":Differ continue", function()
    local command = require("differ.command")
    local continue = require("differ.merge.continue")
    local saved, shown, chosen

    -- stub the picker, choosing the entry labelled `chosen` (nil chooses nothing)
    before_each(function()
        saved = { select = vim.ui.select, confirm = vim.fn.confirm }
        _G.notifs, shown, chosen = {}, nil, nil
        vim.ui.select = function(items, opts, on_choice)
            shown = { prompt = opts.prompt, labels = vim.tbl_map(opts.format_item, items) }
            for _, item in ipairs(items) do
                if opts.format_item(item) == chosen then
                    return on_choice(item)
                end
            end
            on_choice(nil)
        end
    end)

    after_each(function()
        vim.ui.select, vim.fn.confirm = saved.select, saved.confirm
        if merge.current() then
            merge.close()
        end
        vim.cmd("silent! %bwipeout!")
    end)

    -- the command acts on the current file's repo
    local function in_repo(root)
        vim.cmd.edit(vim.fn.fnameescape(root .. "/f.txt"))
    end

    local function noted(pattern)
        for _, n in ipairs(_G.notifs) do
            if n.msg:find(pattern) then
                return n
            end
        end
    end

    -- the run is reported in the same callback that clears running()
    local function finished(root)
        assert(
            vim.wait(10000, function()
                return git_src.operation(root) == nil and not continue.running()
            end),
            "the operation never finished"
        )
    end

    it("says there's nothing in progress", function()
        in_repo(diverged_repo())
        command.dispatch({ "continue" })
        assert.is_nil(shown)
        assert.is_not_nil(noted("no merge, rebase, cherry%-pick, revert or am in progress"))
    end)

    local cases = {
        { "merge", { "continue", "continue and edit the message", "abort" } },
        { "rebase", { "continue", "continue and edit the message", "skip", "abort" } },
        { "am", { "continue", "skip", "abort" } },
        {
            "cherry-pick",
            { "continue", "continue and edit the message", "skip", "abort" },
        },
        { "revert", { "continue", "continue and edit the message", "skip", "abort" } },
    }
    for _, case in ipairs(cases) do
        it("offers " .. case[1] .. "'s options", function()
            in_repo(stopped(case[1]))
            command.dispatch({ "continue" })
            assert.are.equal(case[1] .. " options", shown.prompt)
            assert.are.same(case[2], shown.labels)
        end)
    end

    it("completes only while an operation is in progress", function()
        local root = stopped("merge")
        in_repo(root)
        assert.is_true(vim.tbl_contains(command.complete("", "Differ "), "continue"))
        git_ok(root, "merge", "--abort")
        assert.is_false(vim.tbl_contains(command.complete("", "Differ "), "continue"))
    end)

    it("refuses to continue with files still conflicted", function()
        local root = stopped("merge")
        in_repo(root)
        chosen = "continue"
        command.dispatch({ "continue" })
        assert.are.equal(vim.log.levels.WARN, noted("2 conflicted files left").level)
        assert.is_false(continue.running())
        assert.is_not_nil(git_src.operation(root))
    end)

    it("continues a merge", function()
        local root = stopped("merge")
        resolve_all(root)
        in_repo(root)
        chosen = "continue"
        command.dispatch({ "continue" })
        finished(root)
        assert.is_not_nil(noted("merge finished"))
    end)

    it("reports a rebase stopping again", function()
        local root = stopped("rebase")
        resolve_all(root)
        in_repo(root)
        chosen = "continue"
        command.dispatch({ "continue" })
        assert(vim.wait(10000, function()
            return noted("rebase stopped on 1 conflicted file") ~= nil
        end))
    end)

    it("continues with the message written in the edit buffer", function()
        local root = stopped("merge")
        resolve_all(root)
        in_repo(root)
        chosen = "continue and edit the message"
        command.dispatch({ "continue" })
        local buf = vim.api.nvim_get_current_buf()
        assert.are.equal("gitcommit", vim.bo[buf].filetype)
        assert.are.equal("Merge branch 'feature'", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "edited" })
        vim.cmd("write")
        finished(root)
        assert.are.equal("edited", subject(root))
        assert.is_false(vim.api.nvim_buf_is_valid(buf))
    end)

    it("leaves focus in the signing float after the edit buffer is written", function()
        local root = stopped("merge")
        resolve_all(root)
        signing(root)
        in_repo(root)
        chosen = "continue and edit the message"
        command.dispatch({ "continue" })
        local buf = vim.api.nvim_get_current_buf()
        vim.cmd("write")
        assert(
            vim.wait(1000, function()
                return vim.bo.buftype == "terminal"
            end),
            "focus never reached the float"
        )
        assert.is_false(vim.api.nvim_buf_is_valid(buf))
        finished(root)
    end)

    -- the edit buffer for the stopped operation, open on its prefilled message
    local function edit_buffer()
        chosen = "continue and edit the message"
        command.dispatch({ "continue" })
        local buf = vim.api.nvim_get_current_buf()
        assert.are.equal("gitcommit", vim.bo[buf].filetype)
        return buf
    end

    -- edit the message's subject and close the buffer unwritten
    local function draft(text)
        local buf = edit_buffer()
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
        vim.cmd("bwipeout!")
    end

    local function first_line(buf)
        return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    end

    describe("message draft", function()
        it("is kept when the edit buffer closes unwritten, and reopens", function()
            local root = stopped("merge")
            resolve_all(root)
            in_repo(root)
            draft("drafted")
            assert.is_false(continue.running())
            assert.is_not_nil(git_src.operation(root))
            assert.is_not_nil(noted("merge message draft kept"))
            assert.are.equal("drafted", first_line(edit_buffer()))
        end)

        it("isn't kept when the edit buffer closes unchanged", function()
            local root = stopped("merge")
            resolve_all(root)
            in_repo(root)
            edit_buffer()
            vim.cmd("bwipeout!")
            assert.is_nil(noted("draft kept"))
        end)

        it("is committed by a write, then cleared", function()
            local root = stopped("merge")
            resolve_all(root)
            in_repo(root)
            draft("drafted")
            edit_buffer()
            vim.cmd("write")
            finished(root)
            assert.are.equal("drafted", subject(root))
            git_ok(root, "reset", "-q", "--hard", "HEAD~1")
            git(root, "merge", "--no-edit", "feature")
            resolve_all(root)
            assert.are.equal("Merge branch 'feature'", first_line(edit_buffer()))
        end)

        it("is ignored by a plain continue", function()
            local root = stopped("merge")
            resolve_all(root)
            in_repo(root)
            draft("drafted")
            chosen = "continue"
            command.dispatch({ "continue" })
            finished(root)
            assert.are.equal("Merge branch 'feature'", subject(root))
        end)

        it("is cleared by an abort", function()
            local root = stopped("merge")
            resolve_all(root)
            in_repo(root)
            draft("drafted")
            chosen = "abort"
            vim.fn.confirm = function()
                return 1
            end
            command.dispatch({ "continue" })
            finished(root)
            git(root, "merge", "--no-edit", "feature")
            resolve_all(root)
            assert.are.equal("Merge branch 'feature'", first_line(edit_buffer()))
        end)

        it("isn't offered on the next stop of a rebase", function()
            local root = stopped("rebase")
            resolve_all(root)
            in_repo(root)
            draft("drafted")
            git(root, "-c", "core.editor=true", "rebase", "--continue")
            resolve_all(root)
            assert.are.equal("feature g", first_line(edit_buffer()))
        end)
    end)

    it("aborts once confirmed, and not otherwise", function()
        local root = stopped("merge")
        in_repo(root)
        chosen = "abort"
        vim.fn.confirm = function()
            return 2
        end
        command.dispatch({ "continue" })
        assert.is_false(continue.running())
        assert.is_not_nil(git_src.operation(root))
        vim.fn.confirm = function()
            return 1
        end
        command.dispatch({ "continue" })
        finished(root)
        assert.is_not_nil(noted("merge aborted"))
    end)

    describe("from the merge tool", function()
        -- a session on f.txt with its result resolved but unsaved
        local function session_on(root)
            in_repo(root)
            merge.open({})
            local s = assert(merge.current())
            vim.api.nvim_buf_set_lines(s.result_buf, 0, -1, false, { "resolved" })
            return s
        end

        local function outside_closes()
            return noted("outside the merge tool")
        end

        -- touch the git dir and wait for the session's watcher to handle it
        local function after_git_change(s, root)
            local files = require("differ.merge.files")
            local on_git_change, seen = files.on_git_change, false
            files.on_git_change = function(this)
                if this == s then
                    seen = true
                end
                return on_git_change(this)
            end
            git_ok(root, "config", "differ.test", "touched")
            local handled = vim.wait(3000, function()
                return seen
            end)
            files.on_git_change = on_git_change
            assert(handled, "the watcher never handled a change")
        end

        it("saves and stages the result, then closes once the merge finishes", function()
            local root = stopped("merge")
            session_on(root)
            write(root .. "/g.txt", "resolved\n")
            git_ok(root, "add", "g.txt")
            chosen = "continue"
            command.dispatch({ "continue" })
            finished(root)
            assert.is_nil(merge.current())
            assert.is_not_nil(noted("merge finished"))
            assert.is_nil(outside_closes())
        end)

        it("reopens on the conflict a rebase stops on next", function()
            local root = stopped("rebase")
            session_on(root)
            chosen = "continue"
            command.dispatch({ "continue" })
            assert(
                vim.wait(10000, function()
                    local s = merge.current()
                    return s ~= nil and s.path == "g.txt"
                end),
                "never reopened on g.txt"
            )
            local s = assert(merge.current())
            after_git_change(s, root)
            assert.are.equal(s, merge.current())
            assert.is_nil(outside_closes())
        end)

        it("closes after an abort", function()
            local root = stopped("rebase")
            session_on(root)
            chosen = "abort"
            vim.fn.confirm = function()
                return 1
            end
            command.dispatch({ "continue" })
            finished(root)
            assert.is_nil(merge.current())
            assert.is_nil(outside_closes())
        end)

        for _, case in ipairs({ { "merge", "abort" }, { "rebase", "skip" } }) do
            it("reads the saved result back after a " .. case[2], function()
                local root = stopped(case[1])
                local s = session_on(root)
                vim.api.nvim_buf_call(s.result_buf, function()
                    vim.cmd("silent write")
                end)
                chosen = case[2]
                vim.fn.confirm = function()
                    return 1
                end
                command.dispatch({ "continue" })
                local buf = vim.fn.bufnr(root .. "/f.txt")
                assert(
                    vim.wait(10000, function()
                        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "main"
                    end),
                    "the result kept the pre-" .. case[2] .. " text"
                )
            end)
        end

        it("stays open with git's error when a hook refuses the commit", function()
            local root = stopped("merge")
            local hook = root .. "/.git/hooks/commit-msg"
            write(hook, "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
            vim.fn.setfperm(hook, "rwx------")
            local s = session_on(root)
            write(root .. "/g.txt", "resolved\n")
            git_ok(root, "add", "g.txt")
            chosen = "continue"
            command.dispatch({ "continue" })
            assert(vim.wait(10000, function()
                return noted("hook says no") ~= nil
            end))
            assert.are.equal(vim.log.levels.ERROR, noted("hook says no").level)
            after_git_change(s, root)
            assert.are.equal(s, merge.current())
            assert.is_not_nil(git_src.operation(root))
        end)
    end)

    it("refuses a second run while the first is going", function()
        local root = stopped("merge")
        resolve_all(root)
        local hook = root .. "/.git/hooks/commit-msg"
        write(hook, "#!/bin/sh\nsleep 1\n")
        vim.fn.setfperm(hook, "rwx------")
        in_repo(root)
        chosen = "continue"
        command.dispatch({ "continue" })
        command.dispatch({ "continue" })
        local refused = noted("still running")
        assert.is_not_nil(refused)
        assert.are.equal(vim.log.levels.WARN, refused.level)
        finished(root)
        for _, n in ipairs(_G.notifs) do
            assert.are_not.equal(vim.log.levels.ERROR, n.level, n.msg)
        end
    end)

    it("opens the merge tool on new conflicts when run outside it", function()
        local root = stopped("rebase")
        resolve_all(root)
        in_repo(root)
        chosen = "continue"
        command.dispatch({ "continue" })
        assert(
            vim.wait(10000, function()
                local s = merge.current()
                return s ~= nil and s.path == "g.txt"
            end),
            "the merge tool never opened on g.txt"
        )
    end)
end)

describe("operation label", function()
    for _, case in ipairs({
        { "merge", "(merging) feature → main" },
        { "rebase", "(rebasing) feature onto main" },
        { "rebase-apply", "(rebasing) feature onto main" },
        { "am", "(applying patch 1/2) → main" },
        { "cherry-pick", "(cherry-picking) feature~1 → main" },
        { "revert", "(reverting) feature~2 → feature" },
    }) do
        it("names a stopped " .. case[1], function()
            assert.are.equal(case[2], git_src.operation_label(stopped(case[1])))
        end)
    end

    it("is nil with nothing in progress", function()
        assert.is_nil(git_src.operation_label(diverged_repo()))
    end)

    -- resolving the stopped commit and committing it by hand drops *_HEAD, not sequencer/
    for _, case in ipairs({
        { "cherry-pick", "(cherry-picking) → main" },
        { "revert", "(reverting) → feature" },
    }) do
        it("names a " .. case[1] .. " range left with only sequencer/", function()
            local root = stopped(case[1])
            resolve_all(root)
            git_ok(root, "commit", "-q", "--no-edit")
            assert.are.equal(case[1], git_src.operation(root))
            assert.are.equal(case[2], git_src.operation_label(root))
        end)
    end

    it("names each commit once", function()
        local root = stopped("merge")
        assert.are.equal("(merging) feature → main", git_src.operation_label(root))
        git_ok(root, "branch", "-m", "feature", "renamed")
        assert.are.equal("(merging) feature → main", git_src.operation_label(root))
    end)
end)

describe("local panel mid-operation", function()
    after_each(function()
        local p = require("differ.panel").current()
        if p then
            p:close()
        end
        vim.cmd("silent! %bwipeout!")
    end)

    local function operation_lines(p)
        local lines = {}
        for i, m in ipairs(p.meta) do
            if m.kind == "operation" or m.kind == "continue" then
                lines[#lines + 1] = p.lines[i]
            end
        end
        return lines
    end

    -- every conflict staged, plus an untracked file so the panel outlives the operation
    local function panel_on(root)
        resolve_all(root)
        write(root .. "/extra.txt", "extra\n")
        vim.cmd.edit(vim.fn.fnameescape(root .. "/f.txt"))
        git_src.panel({ rev = {} })
        return assert(require("differ.panel").current())
    end

    for _, action in ipairs({ "continue", "abort" }) do
        it("drops the operation lines after a " .. action, function()
            local root = stopped("merge")
            local p = panel_on(root)
            assert.are.same(
                { "(merging) feature → main", ":Differ continue" },
                operation_lines(p)
            )
            assert.is_true(run(root, action).ok)
            assert(
                vim.wait(5000, function()
                    return #operation_lines(p) == 0
                end),
                "the operation lines outlived the " .. action
            )
            assert.are.equal(vim.trim(git_ok(root, "rev-parse", "HEAD")), p.lines[#p.lines])
        end)
    end

    it("drops the operation lines after a rebase --quit", function()
        local root = stopped("rebase")
        local p = panel_on(root)
        assert.are.equal(2, #operation_lines(p))
        git_ok(root, "rebase", "--quit")
        assert(
            vim.wait(5000, function()
                return #operation_lines(p) == 0
            end),
            "the operation lines outlived the --quit"
        )
    end)
end)
