# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
