---
name: tubesync-prioritize
description: Diagnose a stalled or crawling tubesync (Synology docker-ssd stack) and jump the actually-downloadable videos ahead of the cap-skipped metadata backlog, so channels finish in hours instead of days. Use when tubesync channels aren't progressing, downloads are crawling, or a newly added source isn't downloading anything.
user-invocable: true
allowed-tools:
  - Bash
  - Read
---

# /tubesync-prioritize — make tubesync download the real content first

## What this fixes

tubesync (`ghcr.io/meeb/tubesync`, in the Synology `docker-ssd` compose stack) must run a full
per-video metadata fetch (~35–60s each, YouTube-bound) before it can download a video. Crucially the
metadata step runs **even for videos the download cap will skip** — `download_media_metadata` only
short-circuits `manual_skip`, not cap `skip` (tasks.py:803). On a channel with a big back-catalog the
LIMIT queue fills with thousands of skip-bound fetches, and the handful of videos you actually want
sit behind them for days. Cap-skip itself is decided cheaply at index time from approximate
"X years ago" dates, so the skipped videos never needed those fetches. This skill schedules
high-priority tasks for just the downloadable videos so they run first.

## Environment

- SSH alias `synology` (user michael, passwordless sudo). Docker needs `sudo /usr/local/bin/docker`
  — it's not on root's PATH, so plain `docker`/`sudo docker` fails with "command not found".
- Postgres DB: `sudo /usr/local/bin/docker exec postgres psql -U mediastack -d tubesync -c "..."`.
- Run tubesync Django code: `sudo /usr/local/bin/docker exec [-i] tubesync python3 /app/manage.py shell`
  (reads Python from stdin, or use `-c`). It logs a "Using database connection" line to stdout — grep
  it out.
- Live huey queues are SQLite at `/config/tasks/huey_<queue>.db`; the one that matters is the LIMIT
  queue `huey_net_limited.db` (metadata + downloads).
- Full background lives in memory `tubesync.md`.

## 1. Diagnose

Per-channel state:

```sql
select s.name,
  count(*) filter (where m.downloaded) dl,
  count(*) filter (where not m.downloaded and not m.skip and m.can_download) ready,
  count(*) filter (where not m.downloaded and not m.skip and not m.can_download) needs_meta,
  count(*) filter (where m.skip) skipped
from sync_media m join sync_source s on m.source_id = s.uuid
group by s.name order by s.name;
```

- `ready` = metadata done, just needs the download.
- `needs_meta` = downloadable but needs a full metadata fetch first.
- `skipped` = cap-skipped, won't download — these clog the metadata queue.

Queue depth:
`sudo /usr/local/bin/docker exec tubesync sqlite3 /config/tasks/huey_net_limited.db 'select count(*) from task'`

If the queue depth ≫ (sum of `ready` + `needs_meta`), it's clogged with skip-bound fetches → prioritize.

## 2. Prioritize

Schedule high-priority (1000 — above the skip-bound 60–65) tasks for every not-downloaded, not-skip
video: a download for the `ready` ones, a metadata fetch for the rest. `media_post_save` auto-queues
the download once a metadata fetch flips `can_download` true.

```bash
ssh synology 'sudo /usr/local/bin/docker exec -i tubesync bash -s' <<'REMOTE'
cat > /tmp/prioritize.py <<'PYEOF'
from common.models import TaskHistory
from sync.tasks import download_media_metadata, download_media_file
from sync.models import Media
qs = Media.objects.filter(downloaded=False, skip=False, manual_skip=False)
n_meta = n_dl = 0
for m in qs.iterator():
    if m.can_download:
        TaskHistory.schedule(download_media_file, str(m.pk), priority=1000,
            remove_duplicates=True, vn_fmt='[priority] Downloading media for "{}"', vn_args=(m.name,))
        n_dl += 1
    else:
        TaskHistory.schedule(download_media_metadata, str(m.pk), priority=1000,
            remove_duplicates=True, vn_fmt='[priority] Metadata for: {}: "{}"', vn_args=(m.key, m.name))
        n_meta += 1
print("metadata scheduled:", n_meta, "| downloads scheduled:", n_dl)
PYEOF
python3 /app/manage.py shell < /tmp/prioritize.py 2>&1 | grep -vE 'using database connection|objects imported'
REMOTE
```

## 3. Verify

Give it a few minutes, then confirm previously-stuck channels start moving:

```bash
# which channels are being metadata-fetched now:
sudo /usr/local/bin/docker logs --since 4m tubesync 2>&1 \
  | grep -oE 'metadata for: [a-z]+' | sed -E 's/metadata for: //' | sort | uniq -c
```

Re-run the per-channel query — `ready`/`dl` should start climbing for the channels that were stuck.
The skip-bound fetches keep grinding harmlessly in the background; they don't affect what lands in
Jellyfin. Total finish ≈ (ready + needs_meta) ÷ throughput, where throughput is YouTube-bound at
~roughly 40–100 fetches/hour.

## Gotchas

- huey **does** honor priority here (1000 jumps ahead of 60–65). Confirm with, in `manage.py shell`:
  `import sync.tasks; from django_huey import get_queue; from collections import Counter;
   print(Counter(t.priority for t in get_queue('limited').pending()))`.
- Do **not** force a download via `download_media_file.call_local(...)` in a **root** `docker exec`
  shell — it writes cache/output files as root that the app user (1027) can't overwrite, and skips the
  worker signal that finalizes the download. If you must force one, use `docker exec -u 1027:100`.
- This does not make each fetch faster (that's YouTube-rate-bound, not CPU/RAM-bound) — it only stops
  the real content from waiting behind throwaway skip-bound work.
- If a single video is stuck (never progresses while others do), suspect a stale huey lock from a
  killed worker — clear with `lock_task('media:<uuid>', queue='database').clear()` and
  `lock_task('index_media:<uuid>', queue='filesystem').clear()` (see `tubesync.md`).
