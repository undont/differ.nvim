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
-- third that rewrites both files
---@param op "merge"|"rebase"|"rebase-apply"|"am"|"cherry-pick"|"revert"
local function stopped(op)
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
        git(root, "cherry-pick", "feature~1", "feature")
    elseif op == "revert" then
        git_ok(root, "checkout", "-q", "feature")
        write(root .. "/f.txt", "later\n")
        write(root .. "/g.txt", "later\n")
        git_ok(root, "commit", "-q", "-am", "later")
        git(root, "revert", "--no-edit", "HEAD~2", "HEAD~1")
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

    it("keeps the picked commit's author on an edited cherry-pick", function()
        local root = stopped("cherry-pick")
        resolve_all(root)
        run(root, "continue", { message = "edited\n" })
        assert.are.equal(
            vim.trim(git_ok(root, "log", "-1", "--format=%ae", "feature~1")),
            vim.trim(git_ok(root, "log", "-1", "--format=%ae"))
        )
    end)

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

    it("skips a rebase commit", function()
        local root = stopped("rebase")
        local res = run(root, "skip")
        assert.is_false(res.ok) -- the next commit stops too
        assert.are.same({ "g.txt" }, git_src.conflicted(root))
    end)

    it("aborts a merge", function()
        local root = stopped("merge")
        local head = git_ok(root, "rev-parse", "main")
        local res = run(root, "abort")
        assert.is_true(res.ok, res.output)
        assert.is_nil(git_src.operation(root))
        assert.are.equal(head, git_ok(root, "rev-parse", "HEAD"))
    end)
end)

describe(":Differ continue", function()
    local command = require("differ.command")
    local saved, notes, shown, chosen

    -- stub the picker, choosing the entry labelled `chosen` (nil chooses nothing)
    before_each(function()
        saved = { select = vim.ui.select, notify = vim.notify, confirm = vim.fn.confirm }
        notes, shown, chosen = {}, nil, nil
        vim.notify = function(msg, level)
            notes[#notes + 1] = { msg = msg, level = level }
        end
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
        vim.ui.select, vim.notify, vim.fn.confirm = saved.select, saved.notify, saved.confirm
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
        for _, n in ipairs(notes) do
            if n.msg:find(pattern) then
                return n
            end
        end
    end

    local function finished(root)
        assert(
            vim.wait(10000, function()
                return git_src.operation(root) == nil
            end),
            "the operation never finished"
        )
        vim.wait(100) -- the scheduled report
    end

    it("says there's nothing in progress", function()
        in_repo(diverged_repo())
        command.dispatch({ "continue" })
        assert.is_nil(shown)
        assert.is_not_nil(noted("no merge, rebase, cherry%-pick, revert or am in progress"))
    end)

    local cases = {
        { "merge", { "continue", "continue and edit the message", "abort", "cancel" } },
        { "rebase", { "continue", "continue and edit the message", "skip", "abort", "cancel" } },
        { "am", { "continue", "skip", "abort", "cancel" } },
        {
            "cherry-pick",
            { "continue", "continue and edit the message", "skip", "abort", "cancel" },
        },
        { "revert", { "continue", "continue and edit the message", "skip", "abort", "cancel" } },
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
        vim.wait(200)
        assert.are.equal(vim.log.levels.WARN, noted("2 conflicted files left").level)
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

    it("leaves the operation alone when the edit buffer closes unwritten", function()
        local root = stopped("merge")
        resolve_all(root)
        in_repo(root)
        chosen = "continue and edit the message"
        command.dispatch({ "continue" })
        vim.cmd("bwipeout!")
        vim.wait(200)
        assert.is_not_nil(git_src.operation(root))
    end)

    it("aborts once confirmed, and not otherwise", function()
        local root = stopped("merge")
        in_repo(root)
        chosen = "abort"
        vim.fn.confirm = function()
            return 2
        end
        command.dispatch({ "continue" })
        vim.wait(200)
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
            vim.wait(300) -- a late watcher fire must not close the new session
            assert.is_not_nil(merge.current())
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
            vim.wait(300)
            assert.are.equal(s, merge.current())
            assert.is_not_nil(git_src.operation(root))
        end)
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
