---
name: ptp-dead-torrents
description: Remove PassThePopcorn torrents that PTP has DELETED (trumped/deduped) — torrent + data — from Deluge, using the PTP inbox "Torrent deleted" messages as the authoritative signal. Use when the user says there are new dead/deleted torrents in the PTP inbox to clean up, or asks to reclaim space from trumped PTP torrents still seeding in Deluge.
user-invocable: true
allowed-tools:
  - Bash
  - Read
---

# /ptp-dead-torrents — purge PTP-deleted torrents (+ data) from Deluge

## What this fixes

When a torrent you're seeding is trumped / deduped / removed on PassThePopcorn, PTP posts a
**"Torrent deleted: …"** message to your inbox and the torrent goes **unregistered** — it can never
earn ratio/BP again and can't be seeded, so its download-dir copy is dead weight on disk.

`deluge_cleanup.py` does **not** reclaim these on its own:
- Rule 1 deliberately keeps *complete PTP* torrents seeding (for BP/ratio), so it skips them.
- Rule 3 (tracker-error) removes the torrent but **keeps the data** when it's complete.

So a trumped, already-imported PTP release seeds forever and its file lingers. This skill uses the
**inbox as the authoritative "this torrent is gone" signal** and removes the matching Deluge torrents
**with their data**. Imported releases keep their media-library copy (a separate hardlink); only the
dead seeding copy is dropped.

## Environment

- SSH alias `synology` (user michael, passwordless sudo). Deluge is reachable only from the Synology
  itself at `http://localhost:8112/json` (it runs inside gluetun's netns).
- Secrets in `/volume2/docker-ssd/.env` (root-owned, world-readable): `PTP_COOKIE` (logged-in session
  cookie — the ApiUser/ApiKey API cannot read the inbox), `DELUGE_PASSWORD`.
- Script is deployed at `/volume2/docker-ssd/scripts/ptp_dead_torrents.py` and versioned in the
  `~/scripts` repo as `ptp_dead_torrents.py`. python3 3.8, `requests` only (no bs4) — stdlib parsing.
- Log: `/volume2/docker-ssd/logs/ptp_dead_torrents.log`.

## How it works

1. Fetch the PTP inbox with `PTP_COOKIE`, collect every `Torrent deleted: …` conversation.
2. Open each and parse the site log line — `Torrent <id> (… 'EXACT.RELEASE.NAME' (<size>) was deleted
   by <who> for the reason: <Trump|Dupe|…>`. The single-quoted string is the real release name and
   equals the Deluge torrent name (± a video extension).
3. Match those names against current Deluge torrents, **gated to PTP torrents only** (tracker domain
   contains `passthepopcorn.me`) so a same-named grab from another tracker is never touched. Match is
   extension-normalised and case-insensitive.
4. Remove each match from Deluge **with data**.

No Hit-and-Run guard is needed (unlike deluge_cleanup): a deleted torrent is gone from the tracker and
accrues no HnR. `DRY_RUN` defaults to **true** (this deletes data and is run by hand).

### Inbox read-state (MARK_READ, default on)

A "Torrent deleted" message is marked **read** only when its torrent was **actually removed from
Deluge** this run. That gives the inbox a clean meaning: **unread = not (yet) removed by this skill**
(already-gone / handled-elsewhere messages stay unread; ones we act on go read).

Implementation detail that matters: opening a conversation to parse its release name **marks it read
as a side effect** (a plain GET of `viewconv` does this) — and that happens even in a dry run. So the
script captures each message's original read state from the *listing* first, then after processing
**restores the original unread state** for every message it merely peeked at but didn't act on. Net
effect: a dry run is inbox-neutral, and only real removals leave a message read. Marking is via the
inbox masschange form: `POST inbox.php` with `action=masschange`, `actiontype=Mark read|Mark unread`,
`referrer=/inbox.php`, a fresh `AntiCsrfToken`, and one `messages[]=<convid>` per conversation.
Set `MARK_READ=false` to disable all inbox writes (leave read-state untouched).

## Run it

Always dry-run first, show the user what matched, then run live.

```bash
# 1. Sync the latest script from the repo to the Synology (safe to re-run every time):
ssh synology 'sudo cp /dev/stdin /volume2/docker-ssd/scripts/ptp_dead_torrents.py && sudo chmod 755 /volume2/docker-ssd/scripts/ptp_dead_torrents.py' < ~/scripts/ptp_dead_torrents.py

# 2. Dry run — lists DEAD/REMOVE (present in Deluge) vs ALREADY-GONE:
ssh synology 'ENV_FILE=/volume2/docker-ssd/.env DRY_RUN=true python3 /volume2/docker-ssd/scripts/ptp_dead_torrents.py'

# 3. Live — actually remove torrent + data (only after reviewing the dry run):
ssh synology 'ENV_FILE=/volume2/docker-ssd/.env DRY_RUN=false python3 /volume2/docker-ssd/scripts/ptp_dead_torrents.py'
```

Optional env: `INBOX_PAGES` (default 1 — page 1 covers months; raise only if very behind),
`PTP_TRACKER_DOMAIN`, `PTP_BASE`.

## Notes / gotchas

- **Matching key is the quoted release name**, not the message subject (the subject is PTP's
  pretty title like "Under the Fig Trees [2021] - H.264 / MKV / WEB / 720p"; the quoted name is the
  raw release `Under.the.Fig.Trees.2021.720p.AMZN.WEB-DL...-MADSKY`). Deluge single-file torrents add
  a video extension (`.mkv`) that `_norm()` strips before comparing.
- HTML entities: quotes render as `&#39;` — the conversation HTML is `html.unescape`d before regex.
- "ALREADY-GONE" is the normal state for most messages — deluge_cleanup's tracker-error rule usually
  removed the torrent already (it just left the data, or the release was incomplete so data went too).
  The ones this skill catches are typically **complete, imported PTP releases still seeding**.
- If a deletion message can't be parsed (`Could not parse deletion log`), it's skipped loudly rather
  than guessed — inspect that conversation by hand.
- If the run errors with "PTP session cookie rejected", re-capture `PTP_COOKIE` (same cookie
  ptp_ratio.py uses; see the `ptp-bonus-point-api` memory for how).
- This is on-demand, not a DSM cron task. If it should become scheduled later, add a root Task
  Scheduler entry mirroring the other scripts (`ENV_FILE=… DRY_RUN=false python3 …`).
