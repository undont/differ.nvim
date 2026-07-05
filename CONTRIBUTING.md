# Contributing

Thanks for considering a contribution to differ.nvim.

## Setup

- Neovim 0.10+, git on `PATH`
- For the Go sidecar: Go + make on `PATH`
- `make go-build` builds the sidecar into `bin/`. Rerun it after any change under `cmd/` or `internal/` and restart the sidecar process in your running nvim, otherwise you're testing against a stale binary

## Before opening a PR

```sh
make check       # lint + vet + full test suite (Lua + Go)
```

Or run pieces individually:

```sh
make test        # Lua (unit + headless-nvim) + Go tests
make lint        # luacheck + stylua --check + golangci-lint
make fmt         # format Lua and Go sources
make help        # full target list
```

Modules under `test/unit` must not touch any Neovim or `vim` API, at load or in the functions they test — that's what keeps them fast and dependency-free. Neovim-only behaviour (windows, extmarks, treesitter) belongs in `test/nvim` instead. See `docs/manual-testing.md` for the manual checklist covering what the automated suites don't reach.

## UI changes

If your change touches anything visible (layout, highlights, panel, keymaps), rerun the demo recording and check it still looks right:

```sh
brew install vhs ffmpeg   # one-time
make demo                 # rebuilds fixtures, re-records .demo/demo.gif + .demo/demo.mp4
```

`.demo/demo.tape` is the script behind the README's gif; its header comment covers prereqs, quirks (panel-side assumptions, keycast HUD placement), and what each scene currently demonstrates. If your change adds behaviour worth showing off, consider extending the tape with a scene for it rather than just re-recording the existing one, and commit the regenerated `.demo/demo.gif`/`.demo/demo.mp4` alongside your change.

## Commits and PR titles

PR titles must start with one of `breaking`, `feat`, `add`, `update`, `fix`, `docs`, `chore`, `refactor`, `test` (enforced by CI). Match the existing `git log` style: lowercase after the prefix, imperative mood, no trailing full stop.

## Opening a PR

`main` is protected, changes land via PR with CI green. Keep a PR scoped to one change; unrelated cleanup belongs in its own PR.

## Licence

By contributing, you agree your contributions are licensed under the project's [MIT licence](LICENCE).
