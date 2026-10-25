#!/bin/sh
# gpg.program for capture.lua's pinentry fixture: asks through pinentry-curses on
# GPG_TTY, as gpg-agent does, then signs with junk
cat >/dev/null
printf 'OPTION ttyname=%s\nOPTION ttytype=xterm-256color\nSETDESC unlock the signing key\nGETPIN\nBYE\n' "$GPG_TTY" | pinentry-curses >/dev/null 2>&1
printf '\n[GNUPG:] SIG_CREATED D 22 8 00 0 0\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\nstub\n-----END PGP SIGNATURE-----\n'
