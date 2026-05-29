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
