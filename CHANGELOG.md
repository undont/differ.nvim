# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `:checkhealth differ` reports the Neovim floor, git, the options you passed to `setup()`, the sidecar binary and its handshake, and whether a GitHub token is available
- `DIFFER_LOG_LEVEL=debug` traces the sidecar: a line per request, and a line per GitHub call carrying its status and the rate limit you have left

### Fixed

- A sidecar that crashed reported only an exit code, discarding the Go logs and panic stack. Its last output now comes with the error, and `:checkhealth differ` keeps it
- An option that didn't name a real key, or carried a value outside a closed set like `panel.position = "middle"`, was accepted in silence. Those are now reported, and the value falls back to its default correctly

## [0.1.30] — 2026-08-12

### Added

- differ warns once when `termguicolors` is off, which is what leaves the diff rendering uncoloured
- The README documents `:Differ sidecar`, `:Differ cache clear`, `:Differ mergetool`, `:Differ gofile` and `:Differ edit`, including how to open the merge tool, and the `details` keymap default

### Fixed

- Installing asked for an exact Go patch release, so the build hook pulled down a second toolchain on machines that already had Go 1.26, and failed outright under a distro-packaged Go or `GOTOOLCHAIN=local`
- A sidecar protocol mismatch told you to run `:Differ build`, which is not a command. It now names `make go-build`

## [0.1.29] — 2026-08-11

- `gx` on a thread with more than 100 comments deleted the wrong one, which could be another author's published comment rather than your own draft. It now asks GitHub for the thread's newest comment instead of taking the last one it had read
- `gx` and `gp` on a line carrying more than one thread silently acted on the oldest, so you could delete from or reply to a thread you weren't reading. They now ask which one

## [0.1.28] — 2026-08-11

### Fixed

- Reverting a hunk with `X` could destroy a different hunk, or a hunk in another file, when anything changed the repo while the confirm prompt was up
- Discarding a file with `X` on the panel could delete it while leaving its staged copy in the index, if something staged it while the confirm prompt was up
- `:Differ pr owner/repo#n` from an unrelated checkout treated your own files as the pull request's: `df`/`de` opened and saved them under its name, and `:Differ pr checkout` fetched into your repo. Both now need the current directory to be a clone of that repo

## [0.1.27] — 2026-08-11

### Fixed

- The merge tool could splice a different conflict's ancestor into the file. Take-base looked the ancestor up by position in a map that reset whenever the number of conflict regions changed, which happens when you hand-resolve one or undo a resolve: the text landed silently, `:w` staged it, and it was committable with no warning. Only under git's default `merge.conflictStyle`, where differ has to recover the ancestor itself
- The merge tool wrote a doubled carriage return on CRLF files. Take-base's ancestor came from the raw stage blob, so its lines kept the CR the buffer had already stripped, and saving added a second one. The base pane rendered the stray `^M` too

## [0.1.26] — 2026-08-10

### Changed

- Neovim 0.12 is the minimum, documented and enforced at startup. Every diff uses `vim.text.diff`, which 0.10 and 0.11 don't have

### Fixed

- Review actions taken from the overview page (submit, discard, post, delete, resolve) reached GitHub but were ignored by the session, leaving a stale draft id, invisible comments, and conflicts reported nowhere
- `:Differ pr review` and `resume` dropped the draft when they answered before the diff had loaded, so `ga` posted live comments while the title said draft
- Switching pull requests mid-request mixed the two: a prefetch, a viewed toggle or a state transition could land on the wrong session
- Opening two pull requests in quick succession landed on whichever answered last, not the one asked for last
- A comment posted against whatever file the diff showed at submit time rather than the one it was written on, and closing the diff mid-compose raised an error
- A comment posted while the thread list was still loading stayed invisible for the rest of the session
- Outdated review threads stacked on line 1 and read as `path:0`; they now sit where they were written, marked outdated
- Thread, file and timeline pagination could loop until the token hit a rate limit; a sidecar request that never answers now fails after a minute
- Closing a diff with `:q` skipped teardown, leaking a buffer, its parsed diff and an autocmd each time
- `:Differ pr review resume` failed: the query behind it asked GitHub for a field that doesn't exist on a review comment, so it failed with an internal error, and opening a PR didn't adopt an existing draft either
- Opening a PR and going straight to the files bounced you back to the overview a moment later: the page's own render was still in flight and took the window back, closing the diff it found there

## [0.1.25] — 2026-08-10

### Fixed

- A failed GitHub request says what GitHub said. The status was mapped before the response body was read, leaving the branch that reads GitHub's own message unreachable: a rejected comment reported `422 Unprocessable Entity` where GitHub had named the line it was not part of, and an expired token reported `401 Unauthorized` rather than `Bad credentials`
- A secondary rate limit is reported as a rate limit rather than as a permissions problem. GitHub signals one with a 403 carrying only a message, no rate-limit headers and usually no `Retry-After`, so it read as a denied scope and sent you looking for a permission you already had. It is now recognised by that message, which the fix above is what makes readable
- A failing GitHub request no longer leaks its connection. The body was left unclosed on every non-2xx path, so each failure opened a fresh connection instead of reusing the pooled one. It bit hardest where failures arrive in bulk: a wall of 403s at a rate limit, or a repeated 401 on an expired token

## [0.1.24] — 2026-08-10

### Fixed

- A pull request's head branch name can no longer run commands on checkout. `:Differ pr checkout` handed it to `git fetch` as a positional argument, and git reads one beginning with `-` as an option rather than as a ref: a branch named `--upload-pack=<command>` had its value run through a shell. Branch names are now checked against git's own ref-name rules before any git call. A `--` separator is not the fix here, since it would turn the `checkout` that follows into a pathspec restore
- Staging a hunk at the end of a file with no trailing newline no longer corrupts the index. The `\ No newline at end of file` marker attaches to a line, and a zero-context hunk has none on the side that owns the terminator, so it was dropped: appending to such a file staged its last two lines merged into one, and `git apply` reported success. The hunk is widened by the line that owns the terminator, the way git's own diff does it, and deleting a file's tail is the mirror. Any file without a final newline was affected, which editors and generated files produce routinely
- `:Differ pr checkout` works on a pull request from a fork. A cross-repo PR's head branch lives on the contributor's own repository and never reaches `origin`, so fetching it by name failed outright with `couldn't find remote ref`. It falls back to `refs/pull/<number>/head`, the ref `origin` does publish for such a PR, and lands on a local branch named for the head ref. An existing local branch of that name is checked out as it stands rather than moved, so nothing on it is lost

## [0.1.23] — 2026-08-10

### Added

- `s` and `u` stage and unstage a deleted file from the diff view, by the same wholesale `git add` staging a new file already used; only the panel could do it before. `X` still restores the file rather than removing it

### Changed

- `s` and `u` walk the review by what is left to do rather than by position: on through the file, back round to whatever sits behind the cursor, then the next file holding anything on that side, cycling past the ends of the list and skipping files with nothing to do. Entering a file partway down used to strand every hunk above the cursor, with `s` reporting `no more hunks to stage` while plenty still was. `S` and `U` take the same walk

### Fixed

- Staging a hunk with an earlier one left unstaged puts it where it belongs. Only one side of a one-hunk patch's `@@` header was shifted onto the index, and git falls back to the other when the first has no lines to match on: a staged insertion landed at a worktree line number, and every later hunk in the file then failed against an index it no longer matched. Unstaging or reverting a pure deletion is the mirror, and applied cleanly in the wrong place rather than failing
- `:Differ` opens the unstaged side of a file changed on both sides. An `MM` file lists under Staged and Unstaged at once and the Staged row renders first, so opening from the file landed on the `HEAD`↔index diff and read the cursor's worktree line as an index line: it was context there, and the view snapped to whichever hunk happened to be nearest. It now takes the unstaged row, the only pair those line numbers belong to, and holds the exact line and column you were on
- The file panel keeps its cursor on its own file across a list rebuild. Rows were restored by line number, so an entry leaving the list above the cursor slid a neighbour into its place and silently moved the selection to a different file: `]f`/`[f` then stepped from the wrong one and the winbar counted it. Rows are anchored by identity now, following a file that moves between sections, and `i` no longer scatters the cursor when it reflows the list either
- Staging a file's last unstaged hunk moves the diff onto its staged side. The view stayed frozen on an index↔worktree pair that git no longer had anything in, until you navigated away and back; it follows the file across now, carrying the line you staged from rather than dropping you on the first hunk. Unstaging the last staged hunk still stays put, since that is what lets `s` re-stage it in place. Where a file's whole change is a single hunk this leaves you on the staged pair, so `X` there reverts the index and worktree together instead of refusing
- A staging op git refuses says so, rather than passing for one that worked. Staging, unstaging and `X`'s discard threw git's exit status away, so nothing distinguished a refused `git add` from a successful one: staging a new or deleted file from the diff marked the hunk and painted it staged over a change git never took. Discarding a staged add also stops short of deleting the file when the unstage before it fails, which used to leave the index holding an add for a file no longer on disk
- `s` and `u` carry on past a file that went clean under the session rather than stopping on it. Opening a file that was committed or checked out elsewhere refreshes the list and says so instead of showing a diff, but the walk counted that as having moved: it announced there was nothing left to stage while other files still held hunks, and `u` reached for the last hunk of a view that had not changed. The selection is dropped when its own file leaves the change set too, which is what made the next `s` report wrapping round a list it had not reached the end of

## [0.1.22] — 2026-08-07

### Changed

- The word-level diff is faster on large hunks and long lines. Lines are tokenised once per pass rather than once per comparison, and the tokens shared at the head and tail of a pair are matched without reaching the LCS grid. A 1000-line rewrite renders in under a second where it took eleven, and a 50KB minified line in hundredths of one where it took ten

### Fixed

- A diff of a generated file no longer exhausts memory. Both word-diff grids stop at a million cells and fall back to whole-line highlighting; hand-written code never approaches that, but a regenerated JSON or CSV fixture can ask for billions
- `de` opens the file you asked for. The buffer lookup treated its path as a file-pattern rather than a literal, so `a[1].lua` would open `a1.lua`, silently, and only after the session had been torn down. The same lookup refreshes a buffer after a revert, where it checked the wrong one and left stale content on screen. Paths now match by name, symlinks included
- `:Differ sidecar stop` stops the sidecar. The binary traps `SIGTERM` only to cancel a context that its blocking read of stdin never observes, so the signal left the process running until nvim exited; it is now shut down by closing stdin. Stopping and immediately reissuing a request no longer strands a process either
- The cursor keeps its column when a diff opens, and when the worktree watcher re-sources it after a `:w`. It landed on the right line but at the start of it. The column is carried only where the landing is exact, since snapping to the nearest hunk moves you to a different line

## [0.1.21] — 2026-08-05

### Added

- `X` reverts the hunk under the cursor in the diff, the hunk-level counterpart to the panel's file-level discard. It confirms first, since unlike `s`/`u` it destroys the change rather than moving it between the index and the worktree: an unstaged hunk is dropped from the worktree, a staged one from the index and worktree together. Where a file's whole content is one hunk the confirm names the consequence instead of counting hunks, so reverting a new file says it deletes it and reverting a deleted file says it restores it. The frozen diff is spliced in place rather than re-read, so the cursor stays where the hunk was; when a revert leaves the file with no changes at all the panel moves you to the next one. Deleted files revert without gaining hunk staging, so `s`/`u` still refuse there

### Changed

- `context` defaults to the whole file rather than 10 lines, so a diff opens with no folds in it and reads as the file it came from. Folds were always created open, so nothing was ever hidden, but the fold markers still broke the file up on sight for no gain. The threshold is still there for anyone who wants it, through `context` in `setup()`, `:Differ context <n>`, or `d-`
- `d-` narrows away from whole-file context instead of doing nothing. There is no finite threshold to decrement from `math.huge`, so the first step down seeds 10 and narrows a line at a time after that; `d=` at whole-file stays a no-op, since there is nothing wider to reach
- An uncommitted session ends itself once its file list empties, rather than leaving an empty panel beside a diff of a file that is now clean. The change set can empty under you from either side: the last change reverted or discarded in differ, or a commit, checkout or stash from another pane. Either way the session closes and returns you to the tab you opened it from. Rev-pair sessions never reload their list, so they are untouched
- A hidden file panel (`dd`) keeps refreshing with the worktree. It is still a live session driving a visible diff, so refreshes now track whether the session exists rather than whether the sidebar is shown; a revert with the sidebar hidden hands the diff on to the next file instead of stranding it

### Fixed

- A staging key pressed in the file panel no longer tears down an in-progress hunk review in the diff. `s`/`u`/`S`/`U`/`X` write the index like their diff-window counterparts, but didn't re-baseline the change signature that tells differ which git movements are its own, so the watcher read the write back as an outside change and re-sourced the frozen diff: the in-place staged marks were lost and the diff collapsed to whichever side survived. Every list reload now records that state, whatever drove it
- The diff window no longer strands on a file that went clean outside differ while other changes remained. There was nothing to re-source it to, so it kept showing a diff of a file now identical to HEAD, and since it never moved on, no later refresh could recover it; it now hands over to the nearest surviving change, without stealing focus
- `R` in the panel re-sources the diff as well as the file list, matching what the watcher does. It's the manual counterpart, pressed because something changed outside differ, so reloading only the list left the diff stale
- A file discarded from the panel no longer leaves its own buffer showing the discarded content. Nvim doesn't reload a buffer on a window switch, so the stale text sat there until something forced a check; differ now runs a `checktime` on the file it rewrote, which leaves a buffer with unsaved edits alone
- The diff's `g?` lists the staging and revert keys per file rather than per session, so a file that can't stage by hunk no longer advertises `s`/`u`

## [0.1.20] — 2026-08-05

### Added

- A vimdoc: `doc/differ.txt`, generated from the README, so `:help differ` works
- In-buffer session keys, so the things you do inside a session no longer need a global launcher: `dc` ends it (routing to the merge, PR or local session), `dd` toggles the file panel, `dl` flips the layout. `dc` binds on the diff, panel and history; `dd` on the diff and panel; `dl` on the diff, the only surface that owns a layout
- `gS` and `gD` submit and discard a PR review from the diff or panel, so a review can be finished without leaving the files. Capitalised to keep the lowercase `g` family for thread and comment actions; each action's own prompt (the verdict picker, the discard confirm) is the guard

### Changed

- **Breaking:** the merge tool's drop-conflict key moves from `dx` to `<leader>cx`, so the whole choose family shares one prefix. Override `keymaps.choose_none` to keep `dx`
- **Breaking:** `q` no longer closes the merge tool. The result buffer is the real worktree file and stays editable, so `q` is left to native macro recording; `:Differ close` ends the session. `q` is now unbound on every differ surface except the PR overview, where it still drops back into the review
- `:Differ pr review` (and `r` on the overview) is start-or-resume: with a draft already pending it reattaches instead of refusing, and lands on the first file not yet marked viewed, since resuming asks what is left to review. On a thread row that anchor wins and the cursor stays there
- The panel and history cheatsheets are generated from the resolved keymaps rather than hardcoded, so `g?` shows your keys after a `keymaps` override. An action set to `false` drops its row instead of rendering `false`
- The documented launcher spec covers only the entry points that cannot be buffer-local (`:Differ`, `base`, `log`, `pr list`, `pr <n>`); everything else it used to bind now has an in-buffer key

### Fixed

- The file panel's `g?` lists the session's own maps (the PR viewed nav and review verbs), which bind through the extra-keymaps seam and were never shown

## [0.1.19] — 2026-08-04

### Added

- A `diff4` merge layout (`merge.layout = "diff4"`), adding a base column with the common ancestor above the result. `<leader>cb` takes base in either layout, so the layout is about seeing what you're taking, not being able to take it
- Base recovery under git's default `merge.conflictStyle`, which writes no base into the markers: differ re-merges the stages in diff3 style and maps those regions onto the worktree conflicts, so take-base works without `zdiff3`. Where the mapping can't be trusted the base pane says why (`no common ancestor` on add/add, `none for this conflict` otherwise) and take-base is refused rather than emptying the block

### Changed

- The merge tool's base column is a config preference (`merge.layout`) rather than a per-invocation argument: `:Differ mergetool diff3_mixed` is gone, and the sole argument to `mergetool` is always a path

## [0.1.18] — 2026-07-13

### Added

- A PR overview page: the conversation timeline plus code threads rendered as boxed units (a left-spine box with a top-rule header, spine body rows, and a reply-count footer) that carry their diff hunk inline. The hunk tail is capped (keeping the `@@` header and an elision marker when trimmed), tinted with the diff's own +/- line colours, and treesitter-highlighted from the marker-stripped source rather than the page buffer. `]t`/`[t` hop between thread boxes
- Enter the review straight from an overview thread: `<CR>`, `e`, or `r` on a thread row open the review at that comment's file and line, landing on the comment with no file-stepping
- A review to overview round-trip: `go` pops from the review back to the overview, and `q` drops back into the review where you left off, restoring the stashed diff position and the overview's own cursor on the hop back
- `df` edits the real file in an in-review split on the pinned-blob diff; `de` opens a zoom tab to edit and returns to the review on close
- A floating keymap cheatsheet (`g?`) on the overview page, advertised by a `help: g?` header hint

### Fixed

- `:Differ log` now supersedes a live panel when it opens over one, instead of stacking a history session on top of it
- `q` on the overview dismisses the page only; `esc` no longer closes it (too easy to fumble). Window close on teardown is guarded so the kept window is spared the view-teardown buffer wipe
- The reused overview buffer is wiped on teardown so a stale `ctrl-o` jump can't resurface a dead page ("no PR url"); `ctrl-o` back onto the overview re-enters it live via a view `on_repurpose` hook
- Zoom-edit now looks up its buffer exactly and scopes its augroup per view, so a second zoom-edit can't attach to the wrong buffer

## [0.1.17] — 2026-07-09

### Changed

- Internal: a gated `lua_ls` type-check in CI, pinned and cleaned, with nilable session/rev/pcall types narrowed across the runtime (no behaviour change)

## [0.1.16] — 2026-07-08

### Fixed

- Content-bearing git reads are now byte-true instead of newline-normalised, so CRLF files stage and diff correctly; worktree-side reads run through git's own clean filter (eol conversion, text attrs, custom filters) so hunk staging compares against the bytes `git add` would store. Gated on a CR byte in non-binary content, leaving LF-only content untouched
- The checks panel replaces the deprecated `nvim_buf_add_highlight`

## [0.1.15] — 2026-07-05

### Changed

- Aligned PR notify wording and level: the checks float's "no url" case now warns, matching the other "no url to act on" guards, and the thread guards drop the redundant "review" qualifier ("no thread on this line"), matching the wording used elsewhere in the PR diff

## [0.1.14] — 2026-07-05

### Fixed

- `:Differ` and `:Differ <rev>` now also close a live `:Differ log`/history session when superseding, not just a live panel. Left dangling, the orphaned session made `goto_hunk` in an unrelated new diff view read its stale singleton and refuse to cross file boundaries on `]c`/`[c`
- Manually closing a fold with `zc`/`zm` now survives a context change (`d-`/`d=`): folds are keyed by the fixed hunk-boundary index they sit at, rather than their position in the fold list, so a closed fold's identity, and its closed state, no longer shifts when a neighbouring fold appears or disappears at the new context
- On `]c`/`[c` overflow in `:Differ log <range>`, hunk navigation now steps to the next/previous file within the current commit instead of just notifying and stopping; it still stops at the commit boundary itself, which stays `]f`/`[f`'s job
- `:Differ log` and `:Differ log <range>` are now idempotent like `:Differ <rev>`: reinvoking over a live session supersedes it (closes the old one, opens the new) instead of just closing it and dropping the new request on the floor
- History commit-edge, merge conflict-exhausted, and panel wrap-around navigation now notify explicitly instead of silently no-opping

## [0.1.13] — 2026-07-05

### Added

- `require("differ").goto_hunk(direction, opts)` takes an optional `opts.fallback`, run when hunk navigation would otherwise just notify at a first/last hunk or in-history commit boundary. Lets a caller extend that boundary behaviour, e.g. stepping to the next/previous file during a log/history session, without changing the default

## [0.1.12] — 2026-07-05

### Fixed

- Untracked files now count their real lines as additions in the panel's `--stat` totals and per-file `+N` counts, instead of a hardcoded `0/0`. An untracked file has no old side to diff against, so every line in it is genuinely an addition; binary content still counts as `0`, matching how binary tracked changes have always been reported

## [0.1.11] — 2026-07-04

### Fixed

- Untracked files no longer silently drop out of rev-pair diffs against the worktree (branch total `<a>...`, `:Differ <rev>`). `git diff` never lists them regardless of the refs passed to it, so the panel now unions in `git ls-files --others --exclude-standard` alongside the diffed set, with `?` status and 0/0 counts, matching the default view's Untracked section

## [0.1.10] — 2026-06-30

### Added

- A dashed filler row fills the empty side of a split-layout hunk (an inserted/deleted block with nothing on the opposite side), so it reads as "no line here" instead of a blank void, matching the native vimdiff look
- Diff buffers now carry a private `differdiff` filetype instead of the source file's, so foreign `FileType <lang>` autocmds (LSP, linters, semantic tokens) never attach to a throwaway `differ://` buffer. The source filetype is stashed in `b:differ_filetype`; `differ.lualine` ships a drop-in for lualine's filetype component that reads it (with a devicon), falling back to the native filetype everywhere else

### Fixed

- Jumping to the real file (`de`) a second time no longer throws `E37` when that buffer is already current and has unsaved changes; it switches to the already-loaded buffer instead of forcing a disk reload

## [0.1.9] — 2026-06-28

### Fixed

- Opening a modified binary file (e.g. a changed gif/mp4) no longer crashes the editor. Its content was read as raw bytes, split on stray `0x0a` bytes into pathological pseudo-lines, and fed through the O(n·m) word-diff pairing, exhausting memory until nvim was killed. Binary content is now detected (a NUL byte in the first 8kb, git's own heuristic) and the diff is skipped: the renderers show a "Binary file not shown" placeholder, the git frontend still opens the entry despite zero hunks, and the winbar reads "binary"

## [0.1.8] — 2026-06-28

### Added

- The merge tool advances through conflicts on `:w`: once a file's markers are gone it stages and opens the next conflicted file, reporting done and closing (back on the invoking tab) once none remain. `:Differ close` stops after the current file
- The merge result buffer disables in-buffer markdown rendering (render-markdown.nvim) for the session, since a `.md` result was otherwise read as prose and the conflict marker runs concealed as nested block-quotes; restored on close
- Panel `gg`/`G` now just move the cursor to the first/last visitable file row without opening it (`<CR>`/`o` opens the row under the cursor)
- Log panel commit-aware navigation: `]]`/`[[` step between commit headers, `gg`/`G` jump to the first/last commit, `O`/`C`/`c` expand/collapse commits, none of which open a diff on landing
- Bare `:Differ log` with no real file in the current buffer now shows the full HEAD history instead of warning
- `:Differ panel` toggles the sidebar in place; a bare `:Differ` re-opens it
- The panel footer shows `diff --stat` totals and fits the file-name column to the longest name

## [0.1.7] — 2026-06-24

### Added

- `:Differ panel <pos>` repositions a live `:Differ log` sidebar in place instead of spawning a second, overlapping session; a bare `:Differ panel` over a live log session is now a no-op + notify rather than opening a worktree diff on top of it
- A dedicated `history` config table (`position`/`height`/`width`, defaulting to the bottom edge) that the log openers read
- The hunk-counter marker in the diff winbar renders the nerd-font git-diff glyph when `nvim-web-devicons` is present, falling back to the plain diamond otherwise
- `:Differ log` reworked: defaults to the bottom strip (the wide sha/date/author/subject row fits on one line there); left/right positions render two lines per commit instead, clipping at the window edge with no ellipsis. `K` floats the full commit message plus author/date/hash
- `:Differ` (the worktree-status panel) now lands on the first unstaged file rather than the first changed file, skipping a Staged section with nothing left to review; falls back to the first visitable file when everything is staged

### Fixed

- Refuse to stage a file when a formatter has reindented its conflict markers: a `BufWritePost` check detects an indented `<<<<<<<`/`>>>>>>>` region and bails out of the `git add` with a one-time warning, guarding against the column-0 parser silently reading zero conflicts
- Hunk staging no longer corrupts the patch when applied after an earlier staged deletion. `patch.hunk` shifted both `@@` starts by the staged-hunk offset; under `--unidiff-zero` git relocates a single zero-context hunk by content and reads only one side's start, so a net-negative offset could drive the unused side below zero and git would reject the patch as corrupt. Now only the located side shifts per direction, leaving the other at its frozen, always-non-negative line number

## [0.1.6] — 2026-06-24

### Added

- Staged hunks now paint as a dimmed deep diff (same-hue add/delete line and word spans, well under the live weights) instead of a flat muted background, so a staged hunk still shows what changed while reading as set aside. The cursor-line tint stays lifted above the staged fill so the focused line still lights up, and repaints after a stage/unstage toggle

### Fixed

- Opening a diff (or single-file `:Differ log`) on the file you're already in now lands the cursor on the exact line you were on, instead of snapping to the nearest hunk's top. A cursor on unchanged context still falls back to the first hunk. For history, only the first commit shown holds the line; later commit steps land on the first hunk since older content no longer maps to it

## [0.1.5] — 2026-06-23

### Added

- A `g?` keymap cheatsheet on the merge result buffer, matching the panel, history, and diff views
- `cursorline_tint` config option (default on): the cursor line now paints in a stronger shade of its own add/delete colour instead of a neutral overlay, so the change kind reads under the cursor

### Changed

- The diff view now opens directly on the first hunk rather than one line above it, since the cursor-line tint keeps the hunk's colour visible under the cursor

### Fixed

- The merge result buffer widens `timeoutlen` to a 1s floor while focused (restored on leave/close) so the multi-key conflict chords (`<leader>co`/`ct`/`cb`/`ca`, `dx`) don't drop under a short global `timeoutlen`
- The merge result buffer opts out of format-on-save (`vim.b.disable_autoformat`) for the session, since a formatter running on `:w` could choke on or mangle unresolved conflict markers

## [0.1.4] — 2026-06-23

### Fixed

- Panel fold state is now scoped per section rather than shared globally by bare directory path, so a directory name present in two sections (e.g. an untracked `src/` and an unstaged `src/`) no longer collapses both from a single toggle. The cursor is also re-anchored to the toggled directory row after re-render instead of being restored by absolute line number, which could land it in the footer once rows above it disappeared

## [0.1.3] — 2026-06-23

### Added

- Floating keymap cheatsheet (`g?`) on the diff window and the in-review edit window, alongside the panel and history surfaces that already had it. The cheatsheet rows come from the live keymaps, so a configured `lhs` shows correctly, and it lists only the keys actually bound for the active source (staging, edit-in-review, and the session's extra maps such as the PR unviewed nav and thread/comment verbs)
- File-targeted diff verbs from the panel: `de` (go to the real file) and `df` (edit the real file in review) act on the file row under the cursor, opening it first so they operate on it rather than the last-shown diff
- The float help renderer extracted to a shared `differ.ui.help` module reused by the panel, history, and diff surfaces, with a configurable title and one blank row of padding above and below the keymap rows

### Changed

- The staging-review navigation now notifies at the change-set boundary instead of stopping silently. `s`/`u` past the last/first hunk and `S`/`U` past the last/first file echo "no more hunks/files to stage/unstage" when there is nowhere left to step. `step`, `goto_file`, and `step_file` now return whether they actually moved, which the hunk-nav and review callers key off (replacing the old before/after path comparison)
- The diff view now opens one line above the first hunk so the hunk is visible with a line of context, rather than landing directly on it

## [0.1.2] — 2026-06-23

### Added

- Directory and section staging in the panel: `s` / `u` / `X` act on a directory row (every file beneath it, scoped to its section) and on a section-header row (every file in that section). The header case is the only group target when a section's files share a deep prefix the tree strips to a subtitle, leaving no directory row. `S` / `U` stay global
- Panel navigation keymaps: `gg` / `G` jump to the first / last file; `]]` / `[[` step between sections

### Changed

- Pure renames now open instead of reporting "no changes". A rename (`R`/`C` with no content edit) diffs to zero hunks, so selecting one previously never opened; the view now opens for renames and renders the moved file. Initial open (`:Differ`) and edge jumps (`[[` / `]]`) skip content-less renames and land on the first file with a real diff, while untracked files (zero numstat counts but full content) are still visited
- Renamed the GitHub owner to `undont` across the repo, badges, and plugin spec; old paths redirect for a while so existing clones keep working
- Updated the licence copyright holder to `undont`
- Refreshed the README keymaps and added a vhs demo recording

## [0.1.1] — 2026-06-20

### Added

- `command_alias` config (default `nil`): a string or list of strings (e.g. `"D"` or `{ "D", "Df" }`) that registers extra ex-commands routing to the same dispatcher as `:Differ`, so `:D HEAD~1` or `:D log` work. Completion is name-agnostic (keyed off token position), so aliases get full subcommand and rev completion. An invalid name (Vim requires an uppercase-leading user-command name) warns via `vim.notify` rather than aborting setup

## [0.1.0] — 2026-06-20

Initial release. One renderer drives local diffs, file history, staging, PR review, and merge conflicts, so every surface behaves like the same tool.

### Diff engine & rendering

- Stacked dual-rail layout: one scroll surface with old and new lines interleaved per hunk and both line numbers in the gutter via `statuscolumn`
- Side-by-side layout from the same hunk model, switchable at runtime as a pure re-render
- Word-level intra-hunk highlighting rendered as a same-hue background block, with whitespace-only spans dropped and order-aware similarity pairing for word-diff lines
- Treesitter syntax on by default, so a diff reads like source rather than a grey block
- Real buffer lines for code, so search, yank, and motions work; the hunk model is canonical and the buffer is a projection of it
- One diff engine (`vim.diff()`, histogram) shared by every source
- Split rows aligned by similarity, so a mid-hunk insertion opens filler in place
- A full-width cursor-line overlay painted above the diff backgrounds; configurable context expansion (more / less context)

### Command grammar & sessions

- `:Differ [revspec]` with a git-mirroring grammar: bare (`HEAD` vs worktree), `<rev>`, two-dot `<a>..<b>`, three-dot `<a>...<b>` (merge-base), `<a>...` (branch total vs worktree), and `<a> <b>`
- `:Differ base` and `:Differ log base` shortcuts
- `:Differ <rev>` is idempotent: re-opening reopens over a live session
- HEAD re-read per source build, so a branch switch updates the statusline label
- Sessions end when the diff, panel, or compose window is navigated away

### File panel & staging

- Persistent sidebar with the changed-file tree, status icons, +/- counts, and tree / name listing modes
- Hunk-level and file-level staging, with the panel staging at file level and the diff view at hunk level
- Readable at depth: pinned diffstat, name truncation, deep-prefix subtitle, and fold operations
- Panel sidebar toggles in place instead of ending the session; the diffstat stays next to the tree on full-width top/bottom panels
- The diff cursor holds near its hunk across an external refresh

### Edit in review

- Edit the diffed file in place and write it back, with the diff cursor's column carried to the real file on `de` / `df`
- Editing in review is blocked on `<rev>` versus worktree opens (where there is no single writable file)

### File history

- File history for single files and branch ranges, walked commit-by-commit, each step a diff through the same engine
- Concurrent blob fetches and pinned-sha fast paths (pinned shas skip PR refs)

### PR review (Go sidecar)

- A supervised Go sidecar owns the GitHub API: stdio framing, a hello handshake, and restart-backoff supervision, so opening a PR or posting a review doesn't block the editor and results are cached between calls
- PR picker, typed client, and file navigation
- Inline review-thread overlay with thread/comment gestures: `gc` collapse, `]t` / `[t` thread nav, `gr` resolve, and a split-layout peek float showing comment times; the resolved tag sits on the footer rule in green and the peek float hides when focus leaves the diff columns
- Review-authoring loop: pending-review drafts, commenting, submit / discard, delete-comment, and immediate posting that honours the one-pending-review rule; the active draft state shows in the diff winbar
- Per-file viewed-state: `<Tab>` toggle, `]u` / `[u` nav, and neighbour prefetch
- CI checks view and PR lifecycle verbs (merge, checkout, ready / draft, close), grouped by what they act on
- An ISO-8601 timestamp parser for the timeline; a minimal PR overview page and timeline

### 3-way merge tool

- Reads merge-conflict stages and parses conflict markers into a 3-way model, carrying the `|||||||` / `=======` lines and ref labels through the parse
- Lays out the base / ours / theirs columns through the n-column renderer with conflict navigation, locating each side's slab and folding the unchanged spans
- Resolves conflicts in place and writes / stages on save; per-side colour, input sync, and raw editable markers
- Bare `:Differ` routes to the merge tool mid-conflict; result-buffer diagnostics are cleared rather than merely hidden

### Security

- Server-side `expected_head` TOCTOU guard on mutating PR actions

### Tooling & release

- Prefix-driven auto-tagging and release notes, a PR-title check, and version stamping via ldflags
- Build-on-install sidecar via the `make go-build` build hook (no prebuilt binaries)
