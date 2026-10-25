# pty fixtures

raw streams git wrote to the float's pty, as `on_stdout` delivered them, for `util.text.printed` in `test/unit/util/text_spec.lua`

- re-captured with `capture.lua`, never hand-edited
- `.gitattributes` marks them `-text`, so line-ending conversion leaves their `\r` bytes alone
- the commits were made with a `prepare-commit-msg` hook that prefixes the subject with `[hook] `; the specs assert lines from these captures, so a re-capture from another repo updates those assertions to match

## recipes

each runs `capture.lua` with the given `GIT_EDITOR` in a repo left in the given state

- `cherry-pick-empty-again`: a cherry-pick range stopped on a pick that is empty once its conflict is resolved, after the continue that reported it empty. `GIT_EDITOR=true`, `git cherry-pick --continue`
- `rebase-multi-stop`: an interactive rebase stopped on a resolved and staged conflict, with a `reword` next and then a pick that conflicts again. `GIT_EDITOR=true`, `git rebase --continue`
- `editor-round`: a single cherry-pick stopped on a resolved and staged conflict. `GIT_EDITOR='sleep 1; true'`, `git cherry-pick --continue`
- `pinentry`: the same state as `editor-round` with `commit.gpgsign` on. `GIT_EDITOR=true`, `git -c gpg.program=$PWD/test/unit/fixtures/pty/pinentry-gpg.sh cherry-pick --continue`, then type any passphrase into pinentry
