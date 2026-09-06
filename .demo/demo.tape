# differ demo — produces .demo/demo.gif and .demo/demo.mp4 for the README.
#
# Prereqs:
#   brew install vhs ffmpeg
#   bash .demo/setup.sh      # builds the throwaway fixtures (also done by `make demo`)
#
# Run from the repo root:
#   make demo                # equivalent to: bash .demo/setup.sh && vhs .demo/demo.tape
#
# No network, no gh, no token, fully reproducible — the PR scene talks to the demo-only
# fixture sidecar (.demo/fake-sidecar, built by setup.sh), not GitHub. Drives the README's
# <leader>d*/<leader>p* launchers (leader is Space); a keycast HUD (bottom-right, from
# init.lua) shows the keys as they're pressed. Covers the multi-file diff, the s/s staging
# flow across files, panel repositioning, file-level staging, file history, layout toggle,
# the 3-way merge tool, and the GitHub PR review flow (list, overview with boxed code
# threads, enter the review at a thread, reply, resolve, the overview round-trip,
# comment, approve).
#
# NOTE: focus/nav steps assume the panel is on the RIGHT (Ctrl+W h -> diff, Ctrl+W l
# -> panel) and that `[f` lands back on palette.lua. The PR scene enters the review with
# `r` from the overview thread, which lands focus on the diff so `gp`/`gr`/`ga` land
# there. Watch one pass and nudge the sleeps; if the keycast HUD covers anything, move
# its anchor in .demo/init.lua.

Output .demo/demo.gif
Output .demo/demo.mp4

Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set Padding 0
Set FontSize 13
Set Width 1280
Set Height 760
Set Theme { "name": "Monokai", "background": "#272822", "foreground": "#f8f8f2", "cursor": "#f8f8f0", "selection": "#49483e", "black": "#272822", "red": "#f92672", "green": "#a6e22e", "yellow": "#f4bf75", "blue": "#66d9ef", "magenta": "#ae81ff", "cyan": "#a1efe4", "white": "#f8f8f2", "brightBlack": "#75715e", "brightRed": "#f92672", "brightGreen": "#a6e22e", "brightYellow": "#f4bf75", "brightBlue": "#66d9ef", "brightMagenta": "#ae81ff", "brightCyan": "#a1efe4", "brightWhite": "#f9f8f5" }
Set TypingSpeed 70ms
Set PlaybackSpeed 1.0

# ── Local diff over a multi-file change set ──────────────────
Hide
Type "cd .demo/fixture"
Enter
Type "clear"
Enter
Show
Sleep 1s

Type "nvim -u ../init.lua lua/palette.lua"
Enter
Sleep 2.2s

# Open the diff via the launcher (Space leader): panel on the right, stacked diff,
# both changed files in the panel. The keycast HUD shows the keys being pressed.
Space
Type "do"
Sleep 2.6s

# ── Reposition the panel: bottom, left, back to right ────────
Type ":Differ panel bottom"
Enter
Sleep 1.6s
Type ":Differ panel left"
Enter
Sleep 1.6s
Type ":Differ panel right"
Enter
Sleep 1.6s

# Focus the diff window (panel is on the right).
Ctrl+W
Type "h"
Sleep 700ms

# ── Side-by-side, then back to stacked (pure re-render) ──────
Space
Type "dl"
Sleep 2.4s
Space
Type "dl"
Sleep 2s

# ── The s/s staging flow ─────────────────────────────────────
# First s stages the hunk (stays put, mark shows); a second s advances; at the last
# hunk it steps into the next file. Repeated s walks the whole change set.
Type "s"
Sleep 1.7s
Type "s"
Sleep 1.5s
Type "s"
Sleep 1.7s
Type "s"
Sleep 1.7s
Type "s"
Sleep 1.9s

# ── File-level staging from the panel ────────────────────────
Type "]f"
Sleep 900ms
Ctrl+W
Type "l"
Sleep 900ms
Type "s"
Sleep 2s

# ── File history of palette.lua (it has commits) ─────────────
Ctrl+W
Type "h"
Sleep 600ms
Type "[f"
Sleep 1s
Type "de"
Sleep 2s

# ── A live edit, reflected straight away: theme.lua already carries one
# unstaged hunk and nothing staged, so reopening the diff lands right on it --
# the new line just joins the existing change, no staged/unstaged twin to dodge.
Type ":e lua/theme.lua"
Enter
Sleep 1s
Type ":10"
Enter
Type "o"
Type `M.accent2 = "#ff79c6"`
Escape
Type ":w"
Enter
Sleep 2s
Space
Type "do"
Sleep 2.6s
Type "de"
Sleep 1.2s

# back to palette.lua for its commit history
Type ":e lua/palette.lua"
Enter
Sleep 800ms
Space
Type "dh"
Sleep 2.6s
# Step to the previous commit and read its change.
Type "]f"
Sleep 3s

# Back to the shell.
Type ":qa!"
Enter
Sleep 800ms

# ── 3-way merge tool: an unresolved conflict ─────────────────
Hide
Type "cd ../fixture-merge"
Enter
Type "clear"
Enter
Show
Sleep 600ms

Type "nvim -u ../init.lua config.lua"
Enter
Sleep 2s

# The merge tool: ours / theirs across the top, the real result file full-width below.
Space
Type "do"
Enter
Sleep 2.8s

# First conflict — take ours (leader is Space).
Type "]x"
Sleep 1.5s
Space
Type "co"
Sleep 2s

# Second conflict — take theirs.
Type "]x"
Sleep 1.5s
Space
Type "ct"
Sleep 2s

# Write the resolved file; once marker-free it auto-stages.
Type ":w"
Enter
Sleep 1.8s

Type ":qa!"
Enter
Sleep 800ms

# ── GitHub PR review over the fixture sidecar (offline) ──────────
# The PR frontend talks to .demo/fake-sidecar, not GitHub: no network, no gh, no token.
# fixture-pr's `origin` resolves to acme/widgets, and the sidecar serves a canned PR #42
# ("add dracula theme") that already carries a review thread from a third user (octocat).
Hide
Type "cd ../fixture-pr"
Enter
Type "clear"
Enter
Show
Sleep 600ms

Type "nvim -u ../init.lua lua/theme.lua"
Enter
Sleep 2s

# List the open PRs (from the sidecar) and pick #42. It lands on the overview: title,
# body, green CI checks, the conversation timeline (octocat's note + review), and code
# threads rendered as boxed units that carry their diff hunk inline.
Space
Type "pl"
Sleep 1.8s
Type "1"
Sleep 2.4s

# Hop to octocat's boxed thread (]t) and read it.
Type "]t"
Sleep 2.4s

# r enters and starts the review at that thread's file and line, landing straight on
# octocat's comment in theme.lua with no file-stepping. New comments compose as drafts
# until submitted; the cursor peek expands the thread inline (it collapses when the cursor
# leaves), so the cursor stays on the line through the reply.
Type "r"
Sleep 2.8s

# Reply to it — the compose split opens in insert mode; Ctrl+S submits. the cursor stays
# on the line, so the peek now shows both comments inline: octocat's and the reply.
Type "gp"
Sleep 1s
Type "good call, pulling it from the palette now"
Sleep 800ms
Ctrl+S
Sleep 3.4s

# Resolve the thread now that it's addressed.
Type "gr"
Sleep 2.2s

# Pop back to the overview (go) to see the thread now reading resolved, then q drops
# straight back into the review where we left off (the stashed diff position restores).
Type "go"
Sleep 2.2s
Type "q"
Sleep 1.8s

# Add a fresh comment of our own: step to a changed line and comment on it.
Type "]c"
Sleep 1s
Type "ga"
Sleep 1s
Type "dracula's a good default, let's ship it"
Sleep 800ms
Ctrl+S
Sleep 2.4s

# Submit the review as Approve (Space pm; the event picker: 2 = APPROVE), with a summary.
Space
Type "pm"
Sleep 1.4s
Type "2"
Sleep 1.2s
Type "nice work, the palette refactor reads cleanly"
Sleep 800ms
Ctrl+S
Sleep 2.6s

Type ":qa!"
Enter
Sleep 800ms
