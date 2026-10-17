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
        git(root, "revert", unpack(reverts))
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

-- start the action; the returned function gives its result once it has finished
local function start(root, action, accept)
    local result
    operation.run(root, assert(git_src.operation(root)), action, function(ok, output)
        result = { ok = ok, output = output }
    end, accept)
    return function()
        return result
    end
end

local function finished(res)
    assert(
        vim.wait(10000, function()
            return res() ~= nil
        end),
        "the run never finished"
    )
    return res()
end

-- the commit message buffer git's editor opened, or nil once the run is over without one
local function message_buffer(res)
    local buf
    vim.wait(10000, function()
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(b):match("COMMIT_EDITMSG$") then
                buf = b
            end
        end
        return buf ~= nil or res() ~= nil
    end)
    return buf
end

-- replace the message with `lines` when given, write, and close
local function reply(buf, lines)
    if lines then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
    vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
end

-- answer git's next message prompt
local function answer(res, lines)
    local buf = message_buffer(res)
    assert(buf, "git never asked for a message: " .. vim.inspect(res()))
    reply(buf, lines)
end

-- run the action, answering every message prompt with `lines`, and wait for it
local function run(root, action, lines)
    local res = start(root, action)
    local buf = message_buffer(res)
    while buf do
        reply(buf, lines)
        buf = message_buffer(res)
    end
    return finished(res)
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

    -- an interactive rebase stopped on feature's first commit (`first`, default pick), with
    -- `second` (default pick) then `verb` on later commits that apply cleanly
    local function todo_rebase(verb, first, second)
        local root = diverged_repo()
        git_ok(root, "checkout", "-q", "feature")
        write(root .. "/h.txt", "h\n")
        git_ok(root, "add", "h.txt")
        git_ok(root, "commit", "-q", "-m", "feature h")
        write(root .. "/i.txt", "i\n")
        git_ok(root, "add", "i.txt")
        git_ok(root, "commit", "-q", "-m", "feature i")
        local function sha(rev)
            return vim.trim(git_ok(root, "rev-parse", rev))
        end
        local todo = vim.fn.tempname()
        write(
            todo,
            ("%s %s\n%s %s\n%s %s\n"):format(
                first or "pick",
                sha("feature~3"),
                second or "pick",
                sha("feature~1"),
                verb,
                sha("feature")
            )
        )
        local editor = vim.fn.tempname()
        write(editor, ('#!/bin/sh\ncp %s "$1"\n'):format(vim.fn.shellescape(todo)))
        vim.fn.setfperm(editor, "rwx------")
        git(root, "-c", "sequence.editor=" .. editor, "rebase", "-i", "main")
        assert.are.same({ "f.txt" }, git_src.conflicted(root))
        return root
    end

    for _, case in ipairs({ { "reword", "reworded" }, { "squash", "squashed" } }) do
        it("opens the message of a later " .. case[1] .. " in the todo", function()
            local root = todo_rebase(case[1])
            resolve_all(root)
            local res = start(root, "continue")
            answer(res) -- the stop on f.txt
            answer(res, { case[2] })
            assert.is_true(finished(res).ok, res().output)
            assert.is_nil(git_src.operation(root))
            assert.are.equal(case[2], subject(root))
        end)
    end

    local edited = { "edited subject", "", "# a comment", "body" }

    for _, op in ipairs({ "merge", "rebase", "cherry-pick", "revert" }) do
        it(op .. " commits the message written in the editor", function()
            local root = stopped(op)
            resolve_all(root)
            run(root, "continue", edited)
            -- the sequence ops stop again on g.txt, after committing the edited first one
            assert.are.equal(
                "edited subject\n\nbody",
                vim.trim(git_ok(root, "log", "-1", "--format=%B"))
            )
            if op ~= "merge" then
                assert.are.same({ "g.txt" }, git_src.conflicted(root))
            end
        end)

        it("leaves a " .. op .. " stopped when the message is emptied", function()
            local root = stopped(op)
            resolve_all(root)
            local head = git_ok(root, "rev-parse", "HEAD")
            local res = run(root, "continue", {})
            assert.is_false(res.ok)
            assert.matches("empty commit message", res.output)
            assert.are.equal(op, git_src.operation(root))
            assert.are.equal(head, git_ok(root, "rev-parse", "HEAD"))
        end)
    end

    it("commits git's message when the edited message closes unwritten", function()
        local root = stopped("merge")
        resolve_all(root)
        local res = start(root, "continue")
        local buf = assert(message_buffer(res), "git never asked for a message")
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unwritten" })
        vim.api.nvim_buf_delete(buf, { force = true })
        assert.is_true(finished(res).ok, res().output)
        assert.are.equal("Merge branch 'feature'", subject(root))
    end)

    it("names the commit message in the float's title while it shows", function()
        local root = stopped("merge")
        resolve_all(root)
        local res = start(root, "continue")
        local buf = assert(message_buffer(res), "git never asked for a message")
        local win = vim.fn.bufwinid(buf)
        assert.are.same(
            { { " git merge · commit message " } },
            vim.api.nvim_win_get_config(win).title
        )
        assert.are.equal("", vim.wo[win].winbar)
        local back
        local group = vim.api.nvim_create_augroup("differ_test_title", {})
        vim.api.nvim_create_autocmd("BufWinEnter", {
            group = group,
            callback = function(args)
                if vim.bo[args.buf].buftype == "terminal" then
                    back = vim.api.nvim_win_get_config(vim.fn.bufwinid(args.buf)).title
                end
            end,
        })
        reply(buf)
        assert.is_true(finished(res).ok, res().output)
        vim.api.nvim_del_augroup_by_id(group)
        assert.are.same({ { " git merge " } }, back)
    end)

    it("commits the stopped commit's message unasked when accepting it", function()
        local root = stopped("merge")
        resolve_all(root)
        local res = start(root, "continue", true)
        assert.is_nil(message_buffer(res))
        assert.is_true(finished(res).ok, res().output)
        assert.are.equal("Merge branch 'feature'", subject(root))
    end)

    it("still asks for a later reword when accepting the stopped message", function()
        local root = todo_rebase("reword")
        resolve_all(root)
        local res = start(root, "continue", true)
        answer(res, { "reworded" })
        assert.is_true(finished(res).ok, res().output)
        assert.are.equal("reworded", subject(root))
        assert.are.equal("feature f", vim.trim(git_ok(root, "log", "-1", "--format=%s", "HEAD~2")))
    end)

    for _, case in ipairs({ { "reword", "reworded" }, { "squash", "squashed" } }) do
        it("still asks for a " .. case[1] .. " after an edit stop when accepting", function()
            local root = todo_rebase(case[1], "pick", "edit")
            resolve_all(root)
            assert.is_true(finished(start(root, "continue", true)).ok)
            assert.are.equal("rebase", git_src.operation(root))
            local res = start(root, "continue", true)
            answer(res, { case[2] })
            assert.is_true(finished(res).ok, res().output)
            assert.are.equal(case[2], subject(root))
        end)
    end

    it("asks for the message of a reword that stopped on a conflict when accepting", function()
        local root = todo_rebase("pick", "reword")
        resolve_all(root)
        local res = start(root, "continue", true)
        answer(res, { "reworded" })
        assert.is_true(finished(res).ok, res().output)
        assert.are.equal("reworded", vim.trim(git_ok(root, "log", "-1", "--format=%s", "HEAD~2")))
    end)

    -- a --rebase-merges rebase stopped on a conflicting `merge` todo line, `flag` being
    -- -C, -c or nil
    local function merges_rebase(flag)
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git_ok(root, "init", "-q", "-b", "main")
        git_ok(root, "config", "user.email", "t@t")
        git_ok(root, "config", "user.name", "t")
        git_ok(root, "config", "rerere.enabled", "false")
        write(root .. "/f.txt", "a\n")
        git_ok(root, "add", ".")
        git_ok(root, "commit", "-q", "-m", "base")
        git_ok(root, "checkout", "-q", "-b", "side")
        write(root .. "/f.txt", "side\n")
        git_ok(root, "commit", "-q", "-am", "side")
        git_ok(root, "checkout", "-q", "main")
        write(root .. "/f.txt", "main\n")
        git_ok(root, "commit", "-q", "-am", "main f")
        git(root, "merge", "-q", "side")
        write(root .. "/f.txt", "merged\n")
        git_ok(root, "commit", "-q", "-am", "merge side")
        git_ok(root, "checkout", "-q", "-b", "onto", "HEAD~2")
        write(root .. "/g.txt", "onto\n")
        git_ok(root, "add", "g.txt")
        git_ok(root, "commit", "-q", "-m", "onto")
        git_ok(root, "checkout", "-q", "main")
        local function sha(rev)
            return vim.trim(git_ok(root, "rev-parse", rev))
        end
        local merge = "merge side-label"
        if flag then
            merge = ("merge %s %s side-label"):format(flag, sha("main"))
        end
        local todo = vim.fn.tempname()
        write(
            todo,
            ("label onto\nreset onto\npick %s\nlabel side-label\nreset onto\npick %s\n%s\n"):format(
                sha("side"),
                sha("main~1"),
                merge
            )
        )
        local editor = vim.fn.tempname()
        write(editor, ('#!/bin/sh\ncp %s "$1"\n'):format(vim.fn.shellescape(todo)))
        vim.fn.setfperm(editor, "rwx------")
        git(
            root,
            "-c",
            "sequence.editor=" .. editor,
            "-c",
            "core.editor=true",
            "rebase",
            "-i",
            "--rebase-merges",
            "onto"
        )
        assert.are.same({ "f.txt" }, git_src.conflicted(root))
        resolve_all(root)
        return root
    end

    it("accepts a conflicting merge -C's message", function()
        local res = start(merges_rebase("-C"), "continue", true)
        assert.is_nil(message_buffer(res))
        assert.is_true(finished(res).ok, res().output)
    end)

    for _, flag in ipairs({ "-c", false }) do
        local name = flag and ("merge " .. flag) or "bare merge"
        it("asks for a conflicting " .. name .. "'s message when accepting", function()
            local res = start(merges_rebase(flag or nil), "continue", true)
            answer(res)
            assert.is_true(finished(res).ok, res().output)
        end)
    end

    it("shows prepare-commit-msg's output in the message", function()
        local root = stopped("merge")
        resolve_all(root)
        local hook = root .. "/.git/hooks/prepare-commit-msg"
        write(hook, '#!/bin/sh\necho hooked >> "$1"\n')
        vim.fn.setfperm(hook, "rwx------")
        local res = start(root, "continue")
        local buf = assert(message_buffer(res), "git never asked for a message")
        assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "hooked"))
        reply(buf)
        assert.is_true(finished(res).ok, res().output)
        assert.matches("\nhooked$", vim.trim(git_ok(root, "log", "-1", "--format=%B")))
        assert.are.equal(2, #vim.split(vim.trim(git_ok(root, "log", "-1", "--format=%p")), " "))
    end)

    for _, op in ipairs({ "rebase", "cherry-pick" }) do
        it("keeps the picked commit's author on an edited " .. op, function()
            local root = stopped(op)
            resolve_all(root)
            run(root, "continue", { "edited" })
            assert.are.equal("edited", subject(root))
            assert.are.equal("f@f", vim.trim(git_ok(root, "log", "-1", "--format=%ae")))
        end)
    end

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
            local res = run(root, "continue", { "edited" })
            assert.is_true(res.ok, res.output)
            assert.is_nil(git_src.operation(root))
            assert.are.equal("edited", subject(root))
        end)
    end

    it("leaves the operation stopped when a hook refuses the commit", function()
        local root = stopped("cherry-pick")
        resolve_all(root)
        local head = git_ok(root, "rev-parse", "HEAD")
        local hook = root .. "/.git/hooks/commit-msg"
        write(hook, "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
        vim.fn.setfperm(hook, "rwx------")
        local res = run(root, "continue")
        assert.is_false(res.ok)
        assert.matches("hook says no", res.output)
        assert.are.equal("cherry-pick", git_src.operation(root))
        assert.are.equal(head, git_ok(root, "rev-parse", "HEAD"))
    end)

    describe("with signing on", function()
        -- wait for the float to show git's terminal again
        local function terminal_shown()
            assert(
                vim.wait(5000, function()
                    return vim.bo.buftype == "terminal"
                end),
                "the terminal float never came back"
            )
        end

        it("runs in a floating terminal that gpg can prompt on", function()
            local root = stopped("merge")
            resolve_all(root)
            local record = signing(root)
            local wins = #vim.api.nvim_list_wins()
            local res = start(root, "continue")
            assert.are.equal(wins + 1, #vim.api.nvim_list_wins())
            assert.are.equal("terminal", vim.bo.buftype)
            answer(res, { "signed" })
            assert.is_true(finished(res).ok, res().output)
            assert.are.equal(wins, #vim.api.nvim_list_wins())
            assert.are.same({ "tty" }, vim.fn.readfile(record))
            assert.matches("gpgsig", git_ok(root, "cat-file", "-p", "HEAD"))
            assert.are.equal("signed", subject(root))
        end)

        for _, close in ipairs({ "wq", "write | bdelete" }) do
            it("opens the message in the float and comes back after :" .. close, function()
                local root = stopped("merge")
                resolve_all(root)
                signing(root, 30)
                local res = start(root, "continue")
                local buf = assert(message_buffer(res), "git never asked for a message")
                local win = vim.api.nvim_get_current_win()
                assert.are.equal(buf, vim.api.nvim_win_get_buf(win))
                assert.are_not.equal("", vim.api.nvim_win_get_config(win).relative)
                vim.cmd("silent " .. close)
                terminal_shown()
                assert.are_not.equal("", vim.api.nvim_win_get_config(0).relative)
                vim.cmd("bdelete!")
                assert.is_false(finished(res).ok)
            end)
        end

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
                local res = start(root, "continue")
                answer(res)
                terminal_shown()
                vim.cmd(close)
                assert.is_false(finished(res).ok)
                assert.are.equal(wins, #vim.api.nvim_list_wins())
                assert.are.equal("merge", git_src.operation(root))
            end)
        end

        it("aborts in the background", function()
            local root = stopped("merge")
            signing(root)
            local wins = #vim.api.nvim_list_wins()
            local res = start(root, "abort")
            assert.are.equal(wins, #vim.api.nvim_list_wins())
            assert.is_true(finished(res).ok, res().output)
        end)

        it("runs a rebase started with -S in the float", function()
            local root = diverged_repo()
            local record = gpg_stub(root)
            git_ok(root, "checkout", "-q", "feature")
            git(root, "rebase", "-S", "main")
            resolve_all(root)
            local res = start(root, "continue")
            assert.are.equal("terminal", vim.bo.buftype)
            answer(res)
            finished(res)
            assert.are.same({ "tty" }, vim.fn.readfile(record))
        end)
    end)
end)

describe(":Differ continue", function()
    local command = require("differ.command")
    local continue = require("differ.merge.continue")
    local saved, shown, chosen

    -- stub the picker, choosing the entry labelled `chosen` (nil chooses nothing), and
    -- commit every message git asks for as it stands
    before_each(function()
        vim.api.nvim_create_autocmd("BufWinEnter", {
            group = vim.api.nvim_create_augroup("differ_test_messages", {}),
            pattern = "*/COMMIT_EDITMSG",
            callback = function(ev)
                vim.schedule(function()
                    reply(ev.buf)
                end)
            end,
        })
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
        vim.api.nvim_del_augroup_by_name("differ_test_messages")
        vim.ui.select, vim.fn.confirm = saved.select, saved.confirm
        if merge.current() then
            merge.close()
        end
        vim.cmd("silent! %bwipeout!")
    end)

    -- :Differ continue, then the picker's choice, which runs on the next loop
    local function continue_cmd()
        command.dispatch({ "continue" })
        local flushed = false
        vim.schedule(function()
            flushed = true
        end)
        vim.wait(1000, function()
            return flushed
        end)
    end

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
        continue_cmd()
        assert.is_nil(shown)
        assert.is_not_nil(noted("no merge, rebase, cherry%-pick, revert or am in progress"))
    end)

    local edit = "continue and edit the message"
    local cases = {
        { "merge", { "continue", edit, "abort" } },
        { "rebase", { "continue", edit, "skip", "abort" } },
        { "am", { "continue", "skip", "abort" } },
        { "cherry-pick", { "continue", edit, "skip", "abort" } },
        { "revert", { "continue", edit, "skip", "abort" } },
    }
    for _, case in ipairs(cases) do
        it("offers " .. case[1] .. "'s options", function()
            in_repo(stopped(case[1]))
            continue_cmd()
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
        continue_cmd()
        assert.are.equal(vim.log.levels.WARN, noted("2 conflicted files left").level)
        assert.is_false(continue.running())
        assert.is_not_nil(git_src.operation(root))
    end)

    it("continues a merge", function()
        local root = stopped("merge")
        resolve_all(root)
        in_repo(root)
        chosen = "continue"
        continue_cmd()
        finished(root)
        assert.is_not_nil(noted("merge finished"))
    end)

    it("reports a rebase stopping again", function()
        local root = stopped("rebase")
        resolve_all(root)
        in_repo(root)
        chosen = "continue"
        continue_cmd()
        assert(vim.wait(10000, function()
            return noted("rebase stopped on 1 conflicted file") ~= nil
        end))
    end)

    for _, case in ipairs({
        { "abort", "merge", "merge aborted" },
        { "skip", "rebase", "rebase stopped on 1 conflicted file" },
    }) do
        it(case[1] .. "s once confirmed, and not otherwise", function()
            local root = stopped(case[2])
            in_repo(root)
            local head = git_ok(root, "rev-parse", "HEAD")
            local conflicted = git_src.conflicted(root)
            chosen = case[1]
            vim.fn.confirm = function()
                return 2
            end
            continue_cmd()
            assert.is_false(continue.running())
            assert.are.equal(head, git_ok(root, "rev-parse", "HEAD"))
            assert.are.same(conflicted, git_src.conflicted(root))
            vim.fn.confirm = function()
                return 1
            end
            continue_cmd()
            assert(vim.wait(10000, function()
                return noted(case[3]) ~= nil
            end))
        end)
    end

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
            continue_cmd()
            finished(root)
            assert.is_nil(merge.current())
            assert.is_not_nil(noted("merge finished"))
            assert.is_nil(outside_closes())
        end)

        it("reopens on the conflict a rebase stops on next", function()
            local root = stopped("rebase")
            session_on(root)
            chosen = "continue"
            continue_cmd()
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
            continue_cmd()
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
                continue_cmd()
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
            continue_cmd()
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
        continue_cmd()
        continue_cmd()
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
        continue_cmd()
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
