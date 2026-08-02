#!/bin/bash
set -uo pipefail

LOG_FILE="$HOME/Library/Logs/borg-backup.log"
exec >>"$LOG_FILE" 2>&1

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null
}

echo ""
echo "=============================="
echo "$(date): Starting backup"

# 1. Cleanup any stuck previous run
EXISTING=$(pgrep -f "borgmatic" || true)
if [ -n "$EXISTING" ]; then
  echo "Killing previous borgmatic process(es): $EXISTING"
  pkill -f borgmatic 2>/dev/null || true
  sleep 5
  pkill -9 -f borgmatic 2>/dev/null || true
  pkill -9 -f "borg create" 2>/dev/null || true
  # If we had to kill a stuck one, notify
  notify "Borg Backup" "Cleaned up stuck previous run before starting"
fi

# 2. NAS reachability check
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes synology 'exit 0' 2>/dev/null; then
  echo "$(date): NAS unreachable, skipping"

  # Track consecutive failures
  STATE_FILE="$HOME/Library/Logs/borg-backup-skipped-count"
  COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  COUNT=$((COUNT + 1))
  echo "$COUNT" >"$STATE_FILE"

  # Notify if we've skipped 3+ runs in a row (NAS-down sustained)
  if [ "$COUNT" -ge 3 ]; then
    notify "Borg Backup Issue" "NAS unreachable for $COUNT consecutive runs"
  fi

  exit 0
fi

# Reset the skipped counter
rm -f "$HOME/Library/Logs/borg-backup-skipped-count"

# 2b. Skip oversized Downloads files.
# The CPL (powerline) link to the NAS can't sustain multi-GB uploads
# without saturating and taking the internet down with it. Borg has no
# size-based exclude, so we pre-scan Downloads and write the paths of any
# files >= threshold into a borg exclude file (exact-path "pf:" prefix,
# safe for names with spaces/globs). Regenerated every run.
LARGE_EXCLUDE="$HOME/.config/borgmatic/excludes/large_files.txt"
SIZE_THRESHOLD="${BORG_SKIP_LARGER_THAN:-500M}"   # override via env; find(1) units (M/G)
: >"$LARGE_EXCLUDE"
skipped_count=0
skipped_list=""
while IFS= read -r -d '' f; do
  printf 'pf:%s\n' "$f" >>"$LARGE_EXCLUDE"
  skipped_count=$((skipped_count + 1))
  skipped_list="$skipped_list  $(du -h "$f" | cut -f1)  $(basename "$f")
"
done < <(find "$HOME/Downloads" -type f -size +"$SIZE_THRESHOLD" -print0 2>/dev/null)
if [ "$skipped_count" -gt 0 ]; then
  echo "Skipping $skipped_count Downloads file(s) >= $SIZE_THRESHOLD:"
  printf '%s' "$skipped_list"
  notify "Borg Backup" "Skipping $skipped_count large file(s) in Downloads (>= $SIZE_THRESHOLD)"
fi

# 3. Run backup
timeout -s KILL 3600 /opt/homebrew/bin/borgmatic --verbosity 0

EXIT_CODE=$?
echo "$(date): Backup ended with exit code $EXIT_CODE"

# 4. Notify based on exit code
case $EXIT_CODE in
0)
  # Success - quiet
  ;;
124)
  notify "Borg Backup Timeout" "Backup hit 1 hour timeout - check logs"
  ;;
*)
  notify "Borg Backup Failed" "Exit code $EXIT_CODE - check logs"
  ;;
esac

exit $EXIT_CODE
