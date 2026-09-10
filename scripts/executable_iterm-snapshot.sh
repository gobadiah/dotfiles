#!/usr/bin/env bash
# Snapshot iTerm2 preferences into the chezmoi repo.
#
# Normally unnecessary: iTerm writes this file itself whenever "Save changes"
# is set to Automatically (Settings > General > Settings). Keep this as a
# fallback for when that setting is Manually, or to seed the folder initially.
#
# Mirrors iTerm's own export filter: genuine settings only, no machine state.
set -euo pipefail

DEST="${1:-$(chezmoi source-path)/iterm}"
PLIST="$DEST/com.googlecode.iterm2.plist"

mkdir -p "$DEST"

defaults export com.googlecode.iterm2 - | python3 -c '
import io, plistlib, sys

# Excluded because iTerm excludes them, and for the same reason: none of it is
# a setting. NoSync* is ephemeral UI state; Apple*/NS* are AppKit-injected
# defaults and window geometry; SU* is Sparkle updater state; the two pointer
# keys must stay machine-local or the custom folder cannot bootstrap itself.
PREFIXES = ("NoSync", "Apple", "NS", "SU", "UKCrash")
EXACT = {"LoadPrefsFromCustomFolder", "PrefsCustomFolder", "iTerm Version"}

src = plistlib.load(io.BytesIO(sys.stdin.buffer.read()))
kept = {
    k: v for k, v in src.items()
    if k not in EXACT and not k.startswith(PREFIXES)
}
dropped = len(src) - len(kept)
plistlib.dump(kept, sys.stdout.buffer, sort_keys=True)
print(f"kept {len(kept)} settings keys, dropped {dropped} machine-state keys",
      file=sys.stderr)
' > "$PLIST.tmp"

mv "$PLIST.tmp" "$PLIST"
echo "wrote $PLIST"
