---
name: ptp-dead-torrents
description: Reclaim disk from PassThePopcorn releases that PTP has DELETED (trumped/deduped), using the PTP inbox "Torrent deleted" messages as the authoritative signal. Removes the torrent + data from Deluge when it is still there, and — the usual case — sweeps the orphaned file deluge_cleanup left in the download dir when it already removed the torrent. Use when the user says there are new dead/deleted torrents in the PTP inbox to clean up, or asks to reclaim space from trumped PTP releases.
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
5. **Sweep orphaned data** for every ALREADY-GONE release (see below).

### The orphan sweep (why ALREADY-GONE is not "nothing to do")

Deluge can only delete data for a torrent it still holds. deluge_cleanup's tracker-error rule removes
a dead PTP torrent but **keeps the data** when the release is complete — so the release reports
ALREADY-GONE here while its file sits in the download dir forever. On 2026-09-01 that was **53.69 GiB
across 8 of 24 messages**, including all three most recent deletions.

So the ALREADY-GONE path now looks the release up in `DOWNLOAD_DIRS` (default
`/volume1/media/torrents/completed`) and removes what it finds. The log separates the two cases,
which are very different:

- **`st_nlink == 1`** — no hardlink anywhere else, so the bytes are genuinely reclaimed *and this was
  the only copy*. In practice these are superseded downloads: the trumping release is what Radarr
  actually imported, so the library keeps its own (different-inode) copy of the film.
- **`st_nlink > 1`** — the media library holds the *same inode*. Unlinking the download-dir name
  frees **nothing** and loses **nothing**; it just clears the dead entry.

Only the first kind counts toward "Space actually reclaimed". The sweep never runs against a live
torrent, refuses any path resolving outside `DOWNLOAD_DIRS`, and honours `DRY_RUN`. If an orphan
removal fails the message stays **unresolved**, hence unread. `SWEEP_ORPHANS=false` disables it.

No Hit-and-Run guard is needed (unlike deluge_cleanup): a deleted torrent is gone from the tracker and
accrues no HnR. `DRY_RUN` defaults to **true** (this deletes data and is run by hand).

### Inbox read-state (MARK_READ, default on)

A "Torrent deleted" message is marked **read** once it is **resolved** in a live run: its torrent was
**removed from Deluge** this run, **or confirmed already gone** (handled earlier by deluge_cleanup or
a previous run). That gives the inbox a clean meaning: **unread = not yet processed** — new unread
deletion messages really are new work. Only parse failures and removal errors stay unread.

Implementation detail that matters: opening a conversation to parse its release name **marks it read
as a side effect** (a plain GET of `viewconv` does this) — and that happens even in a dry run. So the
script captures each message's original read state from the *listing* first, then after processing
**restores the original unread state** for every unresolved message (and for everything in a dry
run). Net effect: a dry run is inbox-neutral, and a live run leaves resolved messages read. Marking is via the
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
`PTP_TRACKER_DOMAIN`, `PTP_BASE`, `DOWNLOAD_DIRS` (comma-separated, default
`/volume1/media/torrents/completed`), `SWEEP_ORPHANS` (default true).

## Notes / gotchas

- **Matching key is the quoted release name**, not the message subject (the subject is PTP's
  pretty title like "Under the Fig Trees [2021] - H.264 / MKV / WEB / 720p"; the quoted name is the
  raw release `Under.the.Fig.Trees.2021.720p.AMZN.WEB-DL...-MADSKY`). Deluge single-file torrents add
  a video extension (`.mkv`) that `_norm()` strips before comparing.
- HTML entities: quotes render as `&#39;` — the conversation HTML is `html.unescape`d before regex.
- "ALREADY-GONE" is the normal state for most messages — deluge_cleanup's tracker-error rule usually
  removed the torrent already. That is **not** the end of it: "it just left the data" is precisely the
  orphan case the sweep handles. A run reporting `Removed from Deluge: 0` can still reclaim tens of
  GiB. Before the sweep existed, an all-ALREADY-GONE summary read as "nothing to do" and silently hid
  53.69 GiB. The torrents removed *through Deluge* are typically complete, imported releases still
  seeding; the orphans are the ones deluge_cleanup already dropped.
- **Verify by inode, not by size or name**, when judging whether a download-dir file duplicates the
  library one. Vampire's Kiss had the *same apparent size* as its library copy but a different inode —
  a real 17.96 GiB duplicate, not a hardlink. `stat -c %i` settles it, and
  `sudo find /volume1/media/movies -inum <n>` finds the twin.
- If a deletion message can't be parsed (`Could not parse deletion log`), it's skipped loudly rather
  than guessed — inspect that conversation by hand.
- If the run errors with "PTP session cookie rejected", re-capture `PTP_COOKIE` (same cookie
  ptp_ratio.py uses; see the `ptp-bonus-point-api` memory for how).
## Scheduled since 2026-09-02

The routine sweep now runs itself: **DSM task 30 "PTP dead torrents", daily 07:30 as root**,
`ENV_FILE=/volume2/docker-ssd/.env DRY_RUN=false python3 …`, notify-on-error-only to
gobadiah@gmail.com. 07:30 is deliberately *after* `Deluge Cleanup` (task 3, 07:00), which is what
creates the orphan case — so each morning's orphans are swept the same day.

**The script exits non-zero when anything is left unresolved** (`errors` or `unparsed` > 0), which is
what makes DSM's notify-on-abnormal-termination meaningful. A cookie rejection raises and exits
non-zero too. Combined with the read-state logic, the inbox keeps its meaning without anyone reading
it: **unread = the cron could not resolve it**.

So invoke this skill for the *exceptional* cases, not the routine sweep:
- an error email arrived (cookie expired, removal error, `Could not parse deletion log`);
- unread "Torrent deleted" messages are still sitting in the inbox after a scheduled run;
- inode-level investigation of whether a download-dir file really duplicates the library one.

**`sudo synoschedtask --run id=N` is a silent no-op on this DSM** — it returns 0 and does nothing,
for *every* task (verified against task 22, which demonstrably runs daily at 04:00 from the identical
crontab line). Do not read a no-op manual trigger as a broken schedule; to test a task's command,
run the command itself by hand.
