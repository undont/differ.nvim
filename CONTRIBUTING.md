# Contributing

Thanks for considering a contribution to differ.nvim.

## Setup

- Neovim 0.12+, git on `PATH`
- For the Go sidecar: Go + make on `PATH`
- `make go-build` builds the sidecar into `bin/`. Rerun it after any change under `cmd/` or `internal/` and restart the sidecar process in your running nvim, otherwise you're testing against a stale binary

## Before opening a PR

```sh
make check       # lint + type-check + vet + full test suite (Lua + Go)
```

Or run pieces individually:

```sh
make test           # Lua (unit + headless-nvim) + Go tests
make lint           # luacheck + stylua --check + golangci-lint
make lua-typecheck  # lua_ls type-check over lua/ (pinned; fetched on first run)
make fmt            # format Lua and Go sources
make help           # full target list
```

The Lua type-check runs a version-pinned lua-language-server, downloaded into gitignored `.tools/` on first use (needs `curl` and network access, once). It covers `lua/` only and must be clean; CI enforces it. luacheck and lua_ls are independent and can disagree: a fix that satisfies one can trip the other, so run both before pushing.

Modules under `test/unit` must not touch any Neovim or `vim` API, at load or in the functions they test — that's what keeps them fast and dependency-free. Neovim-only behaviour (windows, extmarks, treesitter) belongs in `test/nvim` instead.

## Debugging the sidecar

`DIFFER_LOG_LEVEL` sets the sidecar's log level: `debug`, `info` (the default), `warn` or `error`. At `debug` it writes a line per request (method, duration, outcome) and a line per GitHub call (status, duration, remaining rate limit). The level is read when the process starts and the sidecar inherits Neovim's environment, so `DIFFER_LOG_LEVEL=debug nvim` covers a session; to turn it on without restarting, set `vim.env.DIFFER_LOG_LEVEL` then `:Differ sidecar stop`.

Its stderr is piped to the client, never to your terminal. `:checkhealth differ` shows the tail — of a process that died, and of one still running — and the tail also comes with the error when a request fails on a sidecar that has just died. The client keeps the last 200 lines per process, so a long `debug` trace loses its beginning; nothing writes it to disk. Tokens are never logged, by contract in `logx`'s package doc and asserted in the `github` tests.

## Docs

Each `doc/*.txt` is generated from a markdown source: `differ.txt` from `README.md`, `differ-recipes.txt` from `RECIPES.md`, `differ-troubleshooting.txt` from `TROUBLESHOOTING.md`. A change to any of them has to carry the regenerated vimdoc with it:

```sh
make vimdoc   # rewrites every doc/*.txt (needs pandoc 3.10.1 on PATH)
```

Commit the source and its generated doc together. CI regenerates and fails if what's committed doesn't match, so a readme change on its own turns the Vimdoc job red.

pandoc is pinned because its output shifts between releases, and `make vimdoc` refuses to run against any other version rather than producing a doc CI will reject. panvimdoc is pinned too, fetched into gitignored `.tools/` on first use like lua_ls. The recipe forces `LC_ALL=C`: the panvimdoc writer wraps with Lua patterns, whose `%s` class is locale-dependent, and a UTF-8 locale on BSD libc counts `0xa0` as whitespace and splits the no-break space pandoc emits after "e.g." into U+FFFD.

Regions fenced with `<!-- panvimdoc-ignore-start -->` / `<!-- panvimdoc-ignore-end -->` are left out of the vimdoc. In the readme that's the badges, the nav line and the demo, so `:h differ` opens on why it exists.

## UI changes

If your change touches anything visible (layout, highlights, panel, keymaps), rerun the demo recording and check it still looks right:

```sh
brew install vhs ffmpeg   # one-time
make demo                 # rebuilds fixtures, re-records .demo/demo.gif + .demo/demo.mp4
```

`.demo/demo.tape` is the script behind the README's gif; its header comment covers prereqs, quirks (panel-side assumptions, keycast HUD placement), and what each scene currently demonstrates. If your change adds behaviour worth showing off, consider extending the tape with a scene for it rather than just re-recording the existing one, and commit the regenerated `.demo/demo.gif`/`.demo/demo.mp4` alongside your change.

## Commits and PR titles

PR titles must start with one of `breaking`, `feat`, `add`, `update`, `fix`, `docs`, `chore`, `refactor`, `test` (enforced by CI). Match the existing `git log` style: lowercase after the prefix, imperative mood, no trailing full stop.

## Changelog

`CHANGELOG.md` is hand-maintained in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) style; the generated GitHub release notes come from commit messages and don't replace it. Land user-facing changes as terse bullets under `## [Unreleased]`, grouped into `### Added` / `### Changed` / `### Fixed`, and let the release rename that section to `## [x.y.z] — YYYY-MM-DD`.

CI enforces it for any PR whose title prefix cuts a release (`breaking`, `add`, `update`, `feat`, `fix`); `docs`, `chore`, `refactor` and `test` don't cut one on their own, so they're exempt. They still ride along in whatever release lands next, so add an entry anyway if such a PR changes something a user would notice. A release-bound change that genuinely warrants no entry can be labelled `no changelog` to skip the check.

## Opening a PR

`main` is protected, changes land via PR with CI green. Keep a PR scoped to one change; unrelated cleanup belongs in its own PR.

## Licence

By contributing, you agree your contributions are licensed under the project's [MIT licence](LICENCE).
