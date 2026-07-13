# differ.nvim

## Changelog

`CHANGELOG.md` is hand-maintained and nothing in CI enforces it; the release workflow only tags and uses GitHub's `--generate-notes`, so the file drifts silently if it isn't updated by hand.

- when pushing to or creating a PR, check `CHANGELOG.md` is reconciled: the branch's user-facing changes belong under `## [Unreleased]`, and every tagged release has its own dated section
- follow the existing Keep a Changelog style (`### Added`/`### Changed`/`### Fixed`, dated `## [x.y.z] — YYYY-MM-DD` headings, terse bullets with no trailing full stop)
