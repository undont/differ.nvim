# Troubleshooting

Working out what's wrong, and the edge cases in how differ interacts with lazy-loading and other plugins. It lives here rather than in the README so that stays a reference rather than a FAQ.

## PR review fails

`:checkhealth differ` is the first thing to run. It reports the Neovim floor and `termguicolors`, git, the options you passed to `setup()`, the resolved sidecar binary and whether it completes a handshake, and whether a GitHub token is available. A sidecar that died during the session is reported there too, with the last thing it wrote.

`:Differ sidecar` is the narrower diagnostic. It tells a sidecar that was never built (`make go-build`) apart from a protocol mismatch or a `gh` auth failure, and it's the only thing that reports which binary is actually running. A binary left stale by a missing update hook is the case it earns its keep on: the handshake only rejects one whose wire protocol has moved, so an otherwise-current sidecar fails later, as `unknown method` on the first call into something it doesn't have.

`:Differ sidecar stop` ends the supervised process; the next PR command starts a fresh one.

## Review threads look stale

The sidecar memoises review threads for the life of the process and flushes them only on your own mutations, so a comment posted while you have the PR open won't appear until `:Differ cache clear`. File blobs are keyed by commit sha and can't go stale, so clearing those only costs a refetch.

## An option is ignored

An option that doesn't name a real key, or that carries a value outside a closed set (`panel.position = "middle"`), is reported once at startup and again by `:checkhealth differ`. differ still starts, and the value it can't honour falls back to its default.

## Reading the sidecar log

The sidecar logs to its stderr, which differ keeps rather than lets through to your terminal, so `:checkhealth differ` is where it surfaces: what a process said before it died, and what a running one has said since. The tail also comes with the error when a request fails on a sidecar that has just died. Nothing there carries your token.

## `command_alias` and lazy-loading

`command_alias` is registered by `setup()`, so it can't trigger differ's own load. If you lazy-load on `cmd = "Differ"`, the first `:D` of a session errors with `E464` before differ has loaded (it prefix-matches the `Differ` load stub).

Either list the alias in `cmd` as well:

```lua
cmd = { "Differ", "D" },
```

or skip `command_alias` and use a cmdline abbrev, which expands before the plugin loads so the name lives in one place:

```lua
vim.cmd [[cnoreabbrev <expr> D (getcmdtype() == ':' && getcmdline() ==# 'D') ? 'Differ' : 'D']]
```

## which-key popups over differ buffers

differ's surfaces are scratch buffers (`buftype=nofile`) with their own filetypes (`differdiff` for the diff buffers, `differpanel`, `differhistory`), so no foreign `FileType <lang>` autocmds attach to them. Some which-key setups gate their trigger (re)registration on `buftype == ""`, or rebuild triggers in a way that briefly clears them globally (each `wk.add` calls `Buf.clear()`). In those setups the `<leader>` / `]` / `[` popups can fail to open over a scratch buffer during which-key's trigger suspension windows, even though the same keys work in a normal file.

This is a property of the which-key integration, not of differ. If you hit it, pin permanent buffer-local maps on differ buffers (a plain keymap isn't managed by the trigger system, so it can't be cleared). differ's buffers carry stable filetypes, so key off those:

```lua
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("differ-whichkey", { clear = true }),
  pattern = { "differdiff", "differpanel", "differhistory" },
  callback = function(ev)
    local wk = require("which-key")
    for _, key in ipairs({ " ", "]", "[" }) do
      vim.keymap.set("n", key, function() wk.show(key) end, { buffer = ev.buf })
    end
  end,
})
```

## Statusline requires under lazy-loading

Requiring any `differ.*` module from your statusline config makes lazy load the whole plugin at startup, which defeats a `cmd` lazy-load. That includes `require("differ.lualine")`. Read `vim.b.differ_filetype` directly instead: it never triggers a load, works whether or not differ is loaded, and is simply absent on every other buffer.

## Format-on-save over conflict markers

The merge result buffer is the real worktree file, so a format-on-save would otherwise run over the conflict markers. The merge tool sets `vim.b.disable_autoformat` (conform's opt-out) for the session, so honour that flag in your `format_on_save` gate if you format on save.

If a formatter reformats the markers anyway, differ notices on save, refuses to stage the file, and warns once that the flag isn't being honoured.

## render-markdown.nvim in the merge result

The merge result disables in-buffer markdown rendering for the session so the conflict markers aren't concealed as block-quotes, restoring it on close.
