<!-- panvimdoc-ignore-start -->

<div align="center">

# differ.nvim

**Your whole diff and review loop in one Neovim plugin: local diffs, file history, staging, PR review, and merge conflicts, all with the same UX.**

[![CI](https://img.shields.io/github/actions/workflow/status/undont/differ.nvim/ci.yml?branch=main&style=flat&logo=githubactions&logoColor=white&label=CI)](https://github.com/undont/differ.nvim/actions)
[![Release](https://img.shields.io/github/v/release/undont/differ.nvim?style=flat&logo=github&logoColor=white&label=Release&color=6366F1)](https://github.com/undont/differ.nvim/releases/latest)
[![Licence](https://img.shields.io/github/license/undont/differ.nvim?style=flat&label=licence&color=6366F1)](LICENCE)
[![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72?style=flat&logo=lua&logoColor=white)](https://www.lua.org)
[![Go](https://img.shields.io/badge/Go-1.26+-00ADD8?style=flat&logo=go&logoColor=white)](https://go.dev)
[![Neovim](https://img.shields.io/badge/Neovim-0.12+-57A143?style=flat&logo=neovim&logoColor=white)](https://neovim.io)
[![macOS](https://img.shields.io/badge/macOS-supported-6e7681?style=flat&logo=apple&logoColor=white)]()
[![Linux](https://img.shields.io/badge/Linux-supported-6e7681?style=flat&logo=linux&logoColor=white)]()

[Features](#features) · [Installation](#installation) · [Configuration](#configuration) · [Usage](#usage)

</div>

![differ demo](.demo/demo.gif)

---

You can already get most of this from existing plugins, just not all of it in one tool with the same feel. I wanted to see how feasible it would be, and what the result *could* feel like.

Everything runs through one renderer, so staging a hunk and replying to a review comment behave like the same tool, because they are. The default view is a stacked dual-rail layout: one scroll surface with old and new lines interleaved per hunk and both line numbers in the gutter. Side-by-side is a keystroke away from the same model. Word-level highlighting and Treesitter syntax are on by default.

The GitHub side runs in a separate process rather than the editor, so opening a PR or posting a review doesn't block on the API, and results are cached between calls.

---

<!-- panvimdoc-ignore-end -->

## Features

- Stacked dual-rail layout: one scroll surface, old and new interleaved
- Side-by-side layout from the same hunk model, toggled at runtime
- PR review in the diff: inline threads, drafts, resolve, viewed-state
- PR lifecycle: merge, checkout, ready/draft, close, and CI checks
- File panel with the changed-file tree, status icons, and +/- counts
- Hunk- and file-level staging from the diff or the panel
- File history for single files and branch ranges, commit by commit
- 3-way/4-way merge tool, resolved into the working-tree file
- Word-level highlighting and Treesitter syntax, both on by default
- Real buffer lines, so search, yank, and motions work as normal
- One diff engine (`vim.text.diff()`, histogram) shared by every source

---

## Requirements

- Neovim 0.12+ (`vim.text.diff` sets the floor; also uses `vim.system` and `vim.uv`)
- `termguicolors` on - nvim enables it itself on any terminal it detects as 24-bit capable, so this is usually already true; without it the diff, merge and thread highlights render uncoloured
- git on `PATH`
- A Treesitter parser for the languages you diff (optional)
- For PR review: Go + make on `PATH`, and `gh` authenticated
- Local diffs need none of the above beyond git

`:checkhealth differ` reports which of these are satisfied.

---

<!-- panvimdoc-ignore-start -->

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "undont/differ.nvim",
  build = "make go-build",
  config = function()
    require("differ").setup()
  end,
}
```

`setup()` is only needed to change defaults and register highlight groups eagerly. The `:Differ` command is registered on startup either way.

The `build` hook compiles the Go sidecar (used by PR review) on install and update. It needs Go and make on `PATH`; local diffs work without it, so you can drop the hook if you only want local diffing.

### vim.pack

Neovim 0.12+. `vim.pack` has no inline build key, so register a `PackChanged` hook (before `vim.pack.add`, so it also runs on first install):

```lua
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(ev)
    if ev.data.spec.name == "differ.nvim" and (ev.data.kind == "install" or ev.data.kind == "update") then
      vim.system({ "make", "go-build" }, { cwd = ev.data.path }):wait()
    end
  end,
})

vim.pack.add({ "https://github.com/undont/differ.nvim" })
require("differ").setup()
```

Pin a release with `{ src = "https://github.com/undont/differ.nvim", version = "v0.1.1" }`.

### Other managers

differ's only install step is building the Go sidecar, so point your manager's build / post-update hook at `make go-build`: pckr `run`, vim-plug `do`, or the equivalent.

---

<!-- panvimdoc-ignore-end -->

## Configuration

`setup()` merges over these defaults:

```lua
require("differ").setup({
  layout = "stacked",            -- "stacked" | "split", toggleable per-view
  context = math.huge,           -- fold threshold; math.huge = whole file, no folds
  wrap = true,                   -- soft-wrap long lines in the diff view
  diff_counter = true,           -- "hunk K/N" counter in the diff window's winbar
  cursorline_tint = true,        -- tint the cursor line by add/remove so the change
                                 -- kind reads under the cursor; false = plain neutral
  deep_diff = {
    enabled = true,
    granularity = "word",        -- "word" | "char"
    similarity_threshold = 0.5,  -- line-pairing cutoff for word-level diffing
  },
  comments = {                   -- pr review threads
    inline = true,
    collapsed = false,
  },
  panel = {                      -- file panel default placement/size; `:Differ panel`
                                 -- and the runtime Panel.current() setters override per-session
    position = "right",          -- "bottom" | "top" | "left" | "right"
    height = 9,                  -- top/bottom
    width = 35,                  -- left/right
    listing = "tree",            -- "tree" | "name"
    progress = true,             -- "file K/N" position meter in the panel winbar
  },
  history = {                    -- log/history sidebar default placement/size
    position = "bottom",
    height = 10,                 -- top/bottom
    width = 40,                  -- left/right
  },
  merge = {                      -- merge tool pane layout; no per-invocation override
    layout = "default",          -- "default" (ours | theirs) | "diff4" (adds base)
  },
  keymaps = {                    -- one flat action -> lhs table, shared across the diff,
    -- a value is a string, a list of strings, or false to disable. override globally
    -- here, or scope to one surface via a diff/panel/history/merge = {...} subtable
    next_hunk = "]c",            -- diff, panel, history
    prev_hunk = "[c",
    next_file = "]f",            -- diff; panel/history step the selection
    prev_file = "[f",
    first_file = "gg",           -- panel/history: jump to the first/last file or commit
    last_file = "G",
    next_section = "]]",         -- panel: sections (Staged/Unstaged); history: commits
    prev_section = "[[",
    scroll_down = "f",           -- shadows native f/b; set false to restore
    scroll_up = "b",
    select = { "<CR>", "o" },    -- diff, pr overview, panel, history
    details = "K",               -- history: float the full commit message
    help = "g?",                 -- diff, pr overview, panel, history
    toggle_listing = "i",        -- panel: toggle tree / name
    close_node = "c",            -- panel: collapse the dir under the cursor; history: the commit
    close_all = "C",             -- panel/history: collapse every dir / commit
    open_all = "O",              -- panel/history: expand every dir / commit
    stage = "s", unstage = "u",  -- diff (hunk-level), panel (file-level)
    stage_all = "S", unstage_all = "U",
    more_context = "d=", less_context = "d-",  -- diff
    edit_file = "df",            -- diff: edit-in-review; pr diff: worktree split beside the pinned diff
    goto_file = "de",            -- diff: open the real file and end the session; pr diff: zoom-edit in a tab instead
    discard = "X",               -- diff (revert a hunk), panel (discard a file)
    refresh = "R",               -- panel
    toggle_fold = "za",          -- history (range mode)
    close = "dc",                -- diff/panel/history: end the session
    toggle_panel = "dd",         -- diff/panel: hide/show the file panel sidebar
    toggle_layout = "dl",        -- diff: flip stacked / split
    -- pr review (pr diff + panel)
    toggle_viewed = "<Tab>",     -- pr panel: flip the github viewed checkbox
    next_unviewed = "]u", prev_unviewed = "[u",  -- pr panel + diff
    next_thread = "]t", prev_thread = "[t",      -- pr diff
    comment = "ga",              -- pr diff: comment on the line (normal) or selection (visual)
    reply = "gp",                -- pr diff: reply to the thread under the cursor
    delete_comment = "gx",       -- pr diff: delete the latest comment of the thread
    toggle_thread = "gc",        -- pr diff: collapse/expand the thread under the cursor
    resolve_thread = "gr",       -- pr diff: resolve/unresolve the thread under the cursor
    overview = "go",             -- pr diff + panel: back to the PR overview home
    review_submit = "gS",        -- pr: submit the pending review
    review_discard = "gD",       -- pr: discard the pending review and its drafts
    -- merge tool, bound on the result buffer
    next_conflict = "]x", prev_conflict = "[x",
    choose_ours = "<leader>co", choose_theirs = "<leader>ct", choose_base = "<leader>cb",
    choose_all = "<leader>ca",   -- take both (ours then theirs)
    choose_none = "<leader>cx",  -- drop the conflict region
  },
  relative_dates = false,        -- "3 days ago" instead of YYYY-MM-DD wherever a date shows
  base = nil,                    -- base branch for `base`/`log base`; nil auto-detects origin/HEAD
  sidecar_bin = nil,             -- override the go sidecar path
  command_alias = nil,           -- extra :command(s) routing to :Differ, e.g. "D" or { "D", "Df" }
})
```

---

## Usage

`:Differ [revspec]` opens the file panel over the changed files for a resolved source, landing on the file you ran it from, or on the first file in the list when that file isn't one of them. The grammar mirrors git:

| Command | Diffs |
|---|---|
| `:Differ` | `HEAD` vs worktree (all uncommitted) |
| `:Differ <rev>` | `<rev>` vs worktree |
| `:Differ <a>..<b>` | `<a>` vs `<b>` (two-dot) |
| `:Differ <a>...<b>` | merge-base(`<a>`, `<b>`) vs `<b>` |
| `:Differ <a>...` | merge-base vs worktree (branch total) |
| `:Differ <a> <b>` | `<a>` vs `<b>` |

Any source with worktree on the new side (the first three rows above) also lists untracked files: `git diff` can't see them no matter what refs you pass it, so differ unions in `git ls-files --others --exclude-standard` to fill the gap. They show with a `?` status and their line count as the addition count (0 for binary content), same as the default panel's Untracked section.

### Runtime controls

These re-render the active view only. No refetch, no re-diff, and the state is local to that view.

| Command | Effect |
|---|---|
| `:Differ layout [stacked\|split]` | Set layout; no argument flips it |
| `:Differ context <n>` | Set the fold threshold around hunks |
| `:Differ context full` | Show the whole file, no folds (the default) |
| `:Differ context +` / `-` | Widen / narrow the threshold by one |
| `:Differ panel [left\|right\|top\|bottom]` | Reposition the live panel or history sidebar |

`context` defaults to the whole file, so no folds are created at all and a diff reads as the file it came from. Set it to a number to fold the long unchanged runs away instead: every line is in the buffer either way (search, yank, and motions all work), and `context` only decides where a native fold forms once an unchanged run exceeds it either side of a hunk. Folds are created open, not closed, so nothing is hidden until you close one yourself (`zc`/`za`/`zM`). `d-` narrows out of whole-file the same way, landing on a threshold of 10 and stepping down a line at a time from there; `d=` has nothing wider to reach, so it does nothing.

Set `command_alias` in `setup()` to register a shorter name for the same command, e.g. `command_alias = "D"` gives `:D HEAD~1`, `:D log`. Names must start with an uppercase letter (enforced by vim, not by me). If you lazy-load on `cmd`, list the alias there too (`cmd = { "Differ", "D" }`); see [troubleshooting](TROUBLESHOOTING.md#command_alias-and-lazy-loading) for why.

### Session and sidecar commands

| Command | Effect |
|---|---|
| `:Differ mergetool [path]` | Open the [merge tool](#merge-tool) on a conflicted file; no argument takes the current file, else the only conflicted one, else a picker |
| `:Differ edit` | Edit the real file in a transient split at the cursor's mapped line, keeping the session; `:w` re-sources the diff. The `df` key |
| `:Differ gofile` | Open the real file at the cursor's mapped line and end the session. The `de` key |
| `:Differ sidecar` | Smoke-check the Go sidecar: start it, round-trip a handshake, and report the binary and protocol version |
| `:Differ sidecar stop` | Stop the supervised sidecar; the next PR command starts a fresh one |
| `:Differ cache clear` | Flush the sidecar's in-process caches (file blobs and PR review threads) |

`:Differ sidecar` is the diagnostic to reach for when PR review doesn't work. It tells a sidecar that was never built (`make go-build`) apart from a protocol mismatch or a `gh` auth failure, and it's the only thing that reports which binary is actually running.

`:Differ cache clear` is worth knowing about because the sidecar memoises review threads for the life of the process and flushes them only on your own mutations, so a colleague's comment posted while you have the PR open won't show up until you clear it. File blobs are keyed by commit sha and can't go stale, so clearing those only costs a refetch.

### Diagnostics

`:checkhealth differ` is the first thing to run when something doesn't work. It reports the Neovim floor and `termguicolors`, git, the options you passed to `setup()`, the resolved sidecar binary and whether it completes a handshake, and whether a GitHub token is available. A sidecar that died during the session is reported there too, with the last thing it wrote.

An option that doesn't name a real key, or that carries a value outside a closed set (`panel.position = "middle"`), is reported once at startup and again by `:checkhealth`. differ still starts, and the value it can't honour falls back to its default.

The sidecar logs to its stderr, which differ keeps rather than lets through to your terminal, so `:checkhealth differ` is where it surfaces: what a process said before it died, and what a running one has said since. The tail also comes with the error when a request fails on a sidecar that has just died. Nothing there carries your token.

### Keymaps

Buffer-local, scoped to each surface. All configurable via `keymaps` in `setup()`.

#### Diff

The stacked / split view.

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous hunk |
| `]f` / `[f` | Next / previous file |
| `f` / `b` | Scroll a quarter page down / up |
| `s` / `u` | Stage / unstage the hunk |
| `S` / `U` | Stage / unstage all |
| `X` | Revert the hunk under the cursor (confirms first) |
| `d=` / `d-` | More / less context |
| `df` | Edit-in-review (uncommitted diffs) |
| `de` | Open the real file and end the session |
| `dd` | Toggle the file panel |
| `dl` | Toggle the layout (stacked / split) |
| `dc` | Close the session |
| `go` | PR review only: back to the [PR overview](#pr-overview) |


`X` reverts the hunk entirely, so it confirms first. Reverting a new file deletes it, reverting a deleted one brings it back.

An uncommitted session tracks the worktree, so its file list can empty while you work - the last change reverted, or a commit made in another pane. When it does there is nothing left to review, so the session ends on its own and drops you back in the tab you opened it from. Rev-pair sessions (`:Differ main...HEAD`) diff fixed revisions and never empty.

#### Panel

The file list.

| Key | Action |
|---|---|
| `<CR>` / `o` | Open the file under the cursor |
| `]f` / `[f` | Next / previous file |
| `gg` / `G` | Move cursor to first / last file |
| `]]` / `[[` | Next / previous section |
| `]c` / `[c` | Next / previous hunk |
| `i` | Toggle tree / name listing |
| `c` / `C` / `O` | Collapse node / collapse all / expand all |
| `s` / `u` / `S` / `U` | Stage / unstage file, or all |
| `X` | Discard changes |
| `R` | Refresh the list and the diff against git |
| `dd` | Toggle the file panel |
| `dc` | Close the session |
| `g?` | Help |

#### History

Log / range mode.

| Key | Action |
|---|---|
| `<CR>` / `o` | Show the commit, or toggle fold in range mode |
| `]f` / `[f` | Next / previous file, or commit in file mode |
| `]]` / `[[` | Next / previous commit |
| `gg` / `G` | First / last commit |
| `za` | Toggle fold (range mode) |
| `c` | Collapse the commit under the cursor (range mode) |
| `O` / `C` | Expand / collapse every commit (range mode) |
| `K` | Commit details |
| `dc` | Close the session |
| `g?` | Help |

#### PR review

On top of the diff + panel keys.

| Key | Action |
|---|---|
| `<Tab>` | Toggle the GitHub "viewed" checkbox (panel) |
| `]u` / `[u` | Next / previous unviewed file |
| `]t` / `[t` | Next / previous review thread |
| `ga` | Comment on the line / selection |
| `gp` | Reply to the thread under the cursor |
| `gx` | Delete the latest comment in the thread |
| `gc` | Collapse / expand the thread |
| `gr` | Resolve / unresolve the thread |
| `go` | Back to the [PR overview](#pr-overview) |
| `df` | Edit the real file in a split beside the (pinned) diff, keeping the review |
| `de` | Zoom-edit the real file full-screen in its own tab; `:q` returns to the review |
| `gS` | Submit the review (pick a verdict, then write a summary) |
| `gD` | Discard the review and its draft comments (confirms) |

`df`/`de` edit the worktree file on disk, not the reviewed blob, so keep your checkout on the PR's head branch (`:Differ pr checkout`) or the two can drift; differ warns once a session if they don't match. Both verbs, and `:Differ pr checkout` itself, need the current directory to be a clone of the PR's own repo - either side of a fork counts. Reviewing another repo's PR from your own checkout is read-only.

#### PR overview

`:Differ pr <n>`'s landing page, a read-only summary + timeline.

| Key | Action |
|---|---|
| `e` / `r` | Enter the review / enter and start or resume one; on a thread row, at that comment's file |
| `<CR>` | On a thread row: jump into the review at that comment; elsewhere: open the PR in the browser |
| `]t` / `[t` | Next / previous thread |
| `gx` | Open the PR in the browser |
| `q` | Back into the review when one is in progress (closing the page window ends the session) |
| `g?` | Help |

`r` is start-or-resume: with a draft already pending it reattaches rather than refusing, and lands on the first file you haven't marked viewed - resuming asks what's left to review, not what you last said. On a thread row that anchor wins and the cursor stays there. Entering the review adopts any pending draft automatically, so commenting is in draft mode from the start either way; `:Differ pr review resume` does the same from cold.

Code-comment threads render as a contained box (GitHub's outline, differ's left-spine style) with the diff hunk they anchor to inline: the tail of the hunk, capped, `⋯` when trimmed, `+`/`-` lines carrying the diff's own tints and the code treesitter-highlighted when a parser is installed. Plain PR comments and review verdicts stay flat page text, which is how you tell them apart at a glance.

#### Merge tool

`:Differ mergetool [path]` opens it: with no argument it takes the current file when that's one of the conflicted ones, else the only conflicted file in the tree, else it offers a picker over them. A bare `:Differ` lands here too whenever the tree has conflicts, on the same target - mid-merge the thing you want is to resolve, not to diff. Only the no-argument form reroutes; `:Differ <rev>` still opens that diff. Keys are bound on the result buffer.

| Key | Action |
|---|---|
| `]x` / `[x` | Next / previous conflict |
| `<leader>co` / `ct` / `cb` | Take ours / theirs / base |
| `<leader>ca` | Take both (ours then theirs) |
| `<leader>cx` | Drop the conflict region |
| `:Differ close` | Close the merge tool |
| `g?` | Help |

The result buffer is the real file and stays editable, so the conflict keys sit behind `<leader>` rather than shadowing live operators, and `q` is left to native macro recording.

`merge.layout` picks the panes: `default` shows ours and theirs over the result, `diff4` adds a base column with the common ancestor. `<leader>cb` takes base in either layout, so `diff4` is about seeing what you're taking, not being able to take it.

You don't need `merge.conflictStyle = zdiff3` for that. Git's default style leaves no base in the conflict markers, so differ works it out from the merge stages instead. Where it can't, the base pane's winbar says so: `no common ancestor` when the file was added on both branches, `none for this conflict` when a conflict couldn't be matched up. Taking base is refused in those cases rather than emptying the block.

The result buffer is the real worktree file, so `:w` writes it and stages it once the markers are gone, then opens the next conflicted file; when none remain the session reports done and closes. Use `:Differ close` to stop after the current file.

Because it's a real file, the merge tool sets `vim.b.disable_autoformat` (conform's opt-out) for the session so a format-on-save doesn't run over the conflict markers; honour that flag in your `format_on_save` gate. See [troubleshooting](TROUBLESHOOTING.md#format-on-save-over-conflict-markers) for what happens if a formatter ignores it, and for the render-markdown.nvim interaction.

### Launchers

differ ships no global launchers - only the in-view buffer maps above and the optional `command_alias`. Everything you do *inside* a session already has a key, so a launcher only earns its place for the handful of entry points you reach from an ordinary file, where no differ buffer exists yet to bind to. These are the ones I drive it with; lift them wholesale or trim to taste.

<details>
<summary><b>lazy.nvim spec with <code>&lt;leader&gt;d*</code> / <code>&lt;leader&gt;p*</code> launchers</b></summary>

```lua
{
  "undont/differ.nvim",
  build = "make go-build",
  cmd = { "Differ", "D" }, -- "D" matches command_alias below; see note above
  keys = {
    -- local diff / history
    { '<leader>do', '<cmd>Differ<CR>',                        desc = "Diff: open (vs index)" },
    { "<leader>dt", "<cmd>Differ base<CR>",                   desc = "Diff: branch total (vs base)" },
    { "<leader>dh", "<cmd>Differ log<CR>",                    desc = "Diff: file history" },
    { "<leader>dp", "<cmd>Differ log origin/HEAD...HEAD<CR>", desc = "Diff: PR range (local, no API)" },
    -- pr review (sidecar + github)
    { "<leader>pl", "<cmd>Differ pr list<CR>",                desc = "PR: list" },
    {
      "<leader>po",
      function()
        vim.ui.input({ prompt = "PR number: " }, function(input)
          if input and input ~= "" then vim.cmd("Differ pr " .. input) end
        end)
      end,
      desc = "PR: open by number",
    },
  },
  config = function()
    require("differ").setup({ command_alias = "D" })
  end,
}
```

Once a session is open, `dc` / `dd` / `dl` close it and toggle the panel and layout, and `gS` / `gD` submit or discard a review without leaving the files. The rest of the PR verbs (`checks`, `checkout`, `ready`, `draft`, `close`, `merge`, `browser`, `url`) stay as `:Differ pr <verb>` - once-per-PR actions that don't earn a keymap.

</details>

If which-key's `<leader>` popup doesn't open over differ's buffers, that's a trigger-registration quirk on scratch buffers, not a differ bug; [troubleshooting](TROUBLESHOOTING.md#which-key-popups-over-differ-buffers) has the workaround.

### Statusline

The diff buffers use a private `differdiff` filetype rather than the source file's, so foreign `FileType <lang>` autocmds (LSP, linters, semantic tokens) don't attach to a throwaway `differ://` buffer. The source filetype is stashed in `b:differ_filetype`, so a statusline can still show the language.

For lualine, differ ships a drop-in for the stock `filetype` component, which shows the source filetype (with its devicon) on differ buffers and the native filetype everywhere else:

```lua
sections = { lualine_x = { require("differ.lualine").filetype } }
```

Any custom statusline can read the buffer var directly, lualine or not (it's simply absent on every other buffer):

```lua
local function diff_filetype()
  local ft = vim.b.differ_filetype
  return (type(ft) == "string" and ft ~= "") and ft or vim.bo.filetype
end
```

Under a `cmd` lazy-load, prefer that over `require("differ.lualine")`, which loads the whole plugin at startup; see [troubleshooting](TROUBLESHOOTING.md#statusline-requires-under-lazy-loading).

### Lua API

```lua
-- Same as :Differ, for binding keys:
require("differ").open("main...")

-- Render any old/new text pair directly:
require("differ").diff({
  path = "lua/foo.lua",
  old_text = old,
  new_text = new,
  old_rev = "HEAD",
  new_rev = "WORKTREE",
})

-- Open (or toggle) the file panel over a rev spec; opts are runtime, not
-- setup config: position, listing ("tree"|"name"), height, width:
require("differ").panel({ rev = "main...", position = "left" })

-- Single-file history (opts.path defaults to the current buffer):
require("differ").file_history({ path = "lua/foo.lua" })

-- Branch-range history, driving commit -> file -> diff:
require("differ").range_history({ range = "origin/HEAD...HEAD" })

-- Open the PR frontend, jumping straight to a PR number:
require("differ").pr_open({ number = 42 })

-- Hunk nav with a fallback for the first/last hunk (or an in-history
-- commit boundary), e.g. to step to the next/previous file:
require("differ").goto_hunk("next", {
  fallback = function(direction)
    return require("differ").active_view():step_file(direction)
  end,
})
```

---

<!-- panvimdoc-ignore-start -->

## Licence

[MIT](LICENCE)

<!-- panvimdoc-ignore-end -->
