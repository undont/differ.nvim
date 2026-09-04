# differ.nvim recipes

Snippets to copy and paste: launchers for the entry points (these are what I use in my setup), a statusline integration, and the highlight groups listed out in case you want to override.

## Launchers

```lua
{
  "undont/differ.nvim",
  build = "make go-build",
  cmd = { "Differ", "D" }, -- "D" matches command_alias below
  keys = {
    { '<leader>do', '<cmd>Differ<CR>',                        desc = "Diff: open (vs index)" },
    { "<leader>dt", "<cmd>Differ base<CR>",                   desc = "Diff: branch total (vs base)" },
    { "<leader>dh", "<cmd>Differ log<CR>",                    desc = "Diff: file history" },
    { "<leader>dp", "<cmd>Differ log origin/HEAD...HEAD<CR>", desc = "Diff: PR range (local, no API)" },
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

Once a session is open, `dc` / `dd` / `dl` close it and toggle the panel and layout, and `gS` / `gD` submit or discard a review without leaving the files. The rest of the PR verbs (`checks`, `checkout`, `ready`, `draft`, `close`, `reopen`, `merge`, `browser`, `url`) stay as `:Differ pr <verb>`.

If which-key's `<leader>` popup doesn't open over differ's buffers, that's a trigger-registration quirk on scratch buffers; check in [troubleshooting](TROUBLESHOOTING.md#which-key-popups-over-differ-buffers) (`:h differ-troubleshooting-which-key-popups-over-differ-buffers`) for a solution.

## Statusline

The diff buffers use a private `differdiff` filetype rather than the source file's, so any other `FileType <lang>` autocmds (LSP, linters, semantic tokens) in your setup don't attach to a throwaway `differ://` buffer. The source filetype is still read and stored in `b:differ_filetype`, so a statusline can still show the language.

For lualine, differ ships a drop-in for the stock `filetype` component, which shows the source filetype (with its devicon) on differ buffers and the native filetype everywhere else:

```lua
sections = { lualine_x = { require("differ.lualine").filetype } }
```

Any custom statusline can read the buffer var directly, lualine or not:

```lua
local function diff_filetype()
  local ft = vim.b.differ_filetype
  return (type(ft) == "string" and ft ~= "") and ft or vim.bo.filetype
end
```

Under a `cmd` lazy-load, prefer that over `require("differ.lualine")`; see [troubleshooting](TROUBLESHOOTING.md#statusline-requires-under-lazy-loading) (`:h differ-troubleshooting-statusline-requires-under-lazy-loading`).

## Highlight groups

Every group is defined with `default = true`, so a `:highlight` of your own wins and survives a colorscheme change. The palette is re-resolved on `ColorScheme`, so the defaults track your theme without a reload. Typing `:hi differ` and pressing `<Tab>` completes all highlights with their current values.

### Diff lines and words

| Group | Applies to |
|---|---|
| `differLineAdd` / `differLineDelete` | the quiet per-line tint on a changed line |
| `differWordAdd` / `differWordDelete` | the deeper same-hue patch on the changed words |
| `differCursorLine` | the cursor line over unchanged text (links `CursorLine`) |
| `differCursorLineAdd` / `differCursorLineDelete` | the cursor line over an added or deleted line |
| `differFiller` | split's padding row opposite an inserted or deleted block (links `NonText`) |

### Staging

| Group | Applies to |
|---|---|
| `differStagedLineAdd` / `differStagedLineDelete` | a staged line, dimmer than the live tint |
| `differStagedWordAdd` / `differStagedWordDelete` | the word patch inside a staged line |
| `differStagedLine` | a staged line with no add/delete kind (links `CursorLine`) |
| `differStagedSign` | the staged-hunk gutter glyph |

### File panel

| Group | Applies to |
|---|---|
| `differPanelHeader` / `differPanelRoot` / `differPanelHelp` | panel chrome (link `Title` / `Directory` / `Comment`) |
| `differPanelDir` / `differPanelContext` | a tree directory row, and the dimmed `·parent/` trailer in the name listing |
| `differPanelAdd` / `differPanelModify` / `differPanelDelete` | the status glyph, by kind |
| `differPanelRename` / `differPanelUnmerged` / `differPanelUntracked` | the status glyph, by kind |
| `differPanelCountAdd` / `differPanelCountDelete` | the per-file +/- counts |

### File history

| Group | Applies to |
|---|---|
| `differHistoryAuthor` | the author column on a commit row (links `Identifier`) |
| `differHistoryRef` | the ref decoration in branch-range mode (links `Special`) |

### Review threads

| Group | Applies to |
|---|---|
| `differThread` | an open thread's spine, rules and author |
| `differThreadResolved` / `differThreadResolvedTag` | a resolved thread, and its footer tag |
| `differThreadPending` | a thread carrying an unsubmitted draft |
| `differThreadMeta` / `differThreadBody` | the dim header line, and the comment text |
| `differThreadRange` | the diff lines a range comment covers |
| `differReviewDraft` | the pending-review badge in the diff winbar |

### PR overview

| Group | Applies to |
|---|---|
| `differOverviewTitle` / `differOverviewMeta` / `differOverviewBody` | the page's title, dim chrome and body (title links `Title`) |
| `differOverviewApproved` / `differOverviewChanges` | a review verdict, approved or changes-requested |
| `differOverviewAuthor` | the author's handle |
| `differOverviewDiffContext` | the unchanged rows of a code thread's inline hunk |

### Merge tool

| Group | Applies to |
|---|---|
| `differMergeOurs` / `differMergeTheirs` / `differMergeBase` | one conflict slab per side, in the result pane |
| `differMergeOursActive` / `differMergeTheirsActive` / `differMergeBaseActive` | the same, for the conflict under the cursor |
| `differMergeOursStrong` / `differMergeTheirsStrong` / `differMergeBaseStrong` | the conflicting lines in an input pane, over the rest of the file |
| `differMergeSignOurs` / `differMergeSignTheirs` / `differMergeSignBase` | the input-slab gutter sign |
| `differMergeConflict` | an unresolved block in the result |
| `differMergeMarker` | a raw conflict marker left in the buffer |
| `differMergeFlash` | the transient flash on lines a take-this produced |
