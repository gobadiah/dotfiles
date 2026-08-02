#!/bin/bash
set -euo pipefail

# Point iTerm2 at the preferences kept in this repo.
#
# Must run BEFORE iTerm2 is launched for the first time on a new machine:
# these two keys cannot live in the backed-up plist itself (iTerm can't read
# the folder until it knows where the folder is), so they are seeded here.
#
# If iTerm2 is already running, quit it first — it rewrites its preferences
# from memory on quit and would clobber these writes.

PREFS_DIR="$HOME/.local/share/chezmoi/iterm"

if [ ! -f "$PREFS_DIR/com.googlecode.iterm2.plist" ]; then
  echo "no prefs at $PREFS_DIR — is the chezmoi repo cloned?" >&2
  exit 1
fi

# ps rather than pgrep: pgrep does not reliably report the iTerm2 process that
# is an ancestor of the running shell. grep -c rather than -q: under `pipefail`,
# -q exits on the first match and ps dies of SIGPIPE, failing the pipeline.
iterm_running=$(ps -axo comm= | grep -c "iTerm\.app/Contents/MacOS/iTerm2" || true)
if [ "$iterm_running" -gt 0 ]; then
  echo "iTerm2 is running; quit it and re-run this script." >&2
  exit 1
fi

defaults write com.googlecode.iterm2 PrefsCustomFolder -string "$PREFS_DIR"
defaults write com.googlecode.iterm2 LoadPrefsFromCustomFolder -bool true

echo "iTerm2 will load preferences from $PREFS_DIR"
echo "After launching it, set Settings > General > Settings >"
echo "  'Save changes' to 'Automatically' so the repo stays current."
