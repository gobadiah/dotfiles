---
name: stack-health-check
description: Monthly end-to-end health audit of the Synology docker-ssd media stack — containers, VPN/Deluge, the *arrs, autobrr/PTP, tubesync, Jellyfin playback & transcoding, Bazarr + AI subtitles, tracearr history continuity, scheduled jobs, backups and capacity. Use when the user asks for the monthly stack check, a stack health report, or "is everything still working".
user-invocable: true
allowed-tools:
  - Bash
  - Read
---

# /stack-health-check — monthly audit of the Synology media stack

Replaces the manual monthly click-through of every web UI. Run every section, collect the
verdicts, and finish with the report in [§14](#14-report-format). Every command below was
executed live on 2026-08-06 and returns what it claims to return.

**Rules of engagement**

- **Read-only.** Nothing here mutates state. Remediation is *proposed* in the report, never
  applied unprompted — the one exception is that you may re-run an idempotent diagnostic.
- **Don't stop at the first failure.** A red section is a finding, not an abort. Run all 13.
- **Every verdict needs a number.** "Deluge looks fine" is not a verdict; "1898 torrents,
  0 in Error, 3 tracker errors, incoming connections OK" is.
- **Compare against [§15 baseline](#15-baseline-recorded-2026-08-06)**, not against your
  intuition. This stack is deliberately unusual in places.

---

## 0. Connection prelude

SSH alias `synology` (user `michael`, passwordless sudo). Two hard-won invariants:

- Use **`/usr/bin/ssh`** explicitly. The shell's `ssh` wrapper does iTerm profile switching and
  breaks non-interactive use.
- Docker is **`sudo /usr/local/bin/docker`**. It is not on root's PATH, so `sudo docker` fails
  with "command not found".

Secrets live in `/volume2/docker-ssd/.env` (root:root but **world-readable**, so no sudo needed
to source it):

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a; <command using $RADARR_API_KEY etc>'
```

Keys you will need: `JELLYFIN_API_KEY`, `RADARR_API_KEY`, `SONARR_API_KEY`, `PROWLARR_API_KEY`,
`BAZARR_API_KEY`, `AUTOBRR_API_KEY`, `DELUGE_PASSWORD`, `POSTGRES_PASSWORD`.

**Postgres/SQL: always pipe a heredoc, never `-c "…"`.** Nested quoting through ssh mangles
`interval '30 days'` into a syntax error every single time:

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker exec -i tracearr-db psql -U tracearr -d tracearr' <<'SQL'
select 1;
SQL
```

Databases: `postgres` container hosts `tubesync`, `bazarr`, and the *arr DBs (user `mediastack`);
`tracearr-db` is separate (user `tracearr`, db `tracearr`).

**`docker logs --since 720h` does not actually reach back 30 days.** Container logs start at the
last *recreation*, and watchtower recreates most containers weekly (§1). Observed 2026-08-06:
autobrr's entire log began 2026-07-28, so a "last 30 days" query covered 9 days. Always print the
first log line before drawing a conclusion from a log-based count:

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker logs --since 720h <container> 2>&1 | head -1 | cut -c1-160'
```

If the window is short, say so in the report rather than reporting the count as a 30-day figure.
Anything needing true 30-day history must come from a **database or a file log** under
`/volume2/docker-ssd/logs/`, not from `docker logs`.

Also: keep greps over container logs bounded (`| head`, `| tail`, a narrow `--since`). An
unbounded grep piping ~16 k lines back over ssh dropped the connection with a broken pipe.

---

## 1. Container fleet

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker ps -a --format "{{.Names}}\t{{.Status}}" | sort'
/usr/bin/ssh synology 'sudo /usr/local/bin/docker inspect --format "{{.Name}} {{.RestartCount}} {{.State.Status}}" $(sudo /usr/local/bin/docker ps -aq) | awk "\$2>0"'
```

**PASS**: 33 named containers, all `Up` and — for the ones that declare a healthcheck —
`(healthy)`. No `Exited`, no `Restarting`, restart counts 0.

**Flag**:
- Any container **absent entirely** rather than stopped → this is the watchtower remove-failure
  signature (see memory `watchtower-remove-failure`). Recreate via compose, don't `docker run`.
- `deluge` `Exited (128) "context canceled"` → just `sudo /usr/local/bin/docker start deluge`;
  gluetun stays the netns parent so a plain start re-attaches. See memory
  `synology-script-deployment`.
- Anything `(unhealthy)` for more than a couple of minutes — autoheal restarts on unhealthy, so
  a *persistently* unhealthy container means autoheal is also failing.

**Benign, do not report as a stray**: one or two randomly-named containers
(`musing_knuth`, `reverent_antonelli`, …) with a very short uptime. Those are the
`claude-cli` one-shots spawned by `subtitle_translate.py` (`docker run --rm -i … claude-cli`).
Confirm with `docker inspect -f '{{.Config.Image}}'` before dismissing.

Also check autoheal actually did nothing, rather than being asleep:

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker logs --since 720h autoheal 2>&1 | grep -ci restart'
```
0 restarts in 30 days = PASS. A non-zero count is not itself a failure but tells you which
container has been flapping — chase it.

## 2. Host capacity & load

```bash
/usr/bin/ssh synology 'df -h | grep -E "^Filesystem|cachedev"; free -h; uptime'
```

| Metric | PASS | WARN | FAIL |
|---|---|---|---|
| `/volume1` (27T media HDD) | < 88 % | 88–93 % | > 93 % |
| `/volume2` (1.8T SSD, docker) | < 60 % | 60–80 % | > 80 % |
| Swap used | < 5 G | 5–10 G | > 10 G |
| Load avg (CPU component) | < 3 | 3–5 | > 5 |

`/volume1` at 90 % is the *expected* steady state — `space_cleanup.py` runs nightly and holds it
there. It is only a finding if it is **climbing month over month**, which means the cleanup is
losing ground. Check §11 for whether space_cleanup ran.

Read the load from the DSM-specific tail of `uptime`: `[IO: …  CPU: …]`. The plain load average
on this box is inflated by IO wait and is not the thing to judge.

## 3. VPN (gluetun) and Deluge

Deluge shares gluetun's network namespace, so these are one subsystem.

```bash
/usr/bin/ssh synology '
echo "--- public IP ---"; sudo /usr/local/bin/docker exec gluetun wget -qO- https://ipinfo.io/json | head -c 300; echo
echo "--- forwarded/allowed port ---"; sudo /usr/local/bin/docker logs gluetun 2>&1 | grep -i "allowed input port" | tail -1
echo "--- errors 30d ---"; sudo /usr/local/bin/docker logs --since 720h gluetun 2>&1 | grep -icE "error|i/o timeout"'
```

**PASS**: public IP is the VPN exit (currently NL / AS49453 Global Layer — **not** the ISP), and
the "allowed input port" matches Deluge's `listen_ports` in the next check.

Then Deluge, via the **web JSON-RPC** (`http://localhost:8112/json`) — not the daemon:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a; python3 -' <<'PY'
import os, json, collections, requests
s = requests.Session(); U = "http://localhost:8112/json"
def rpc(m, p):
    d = s.post(U, json={"method": m, "params": p, "id": 1}, timeout=30).json()
    if d.get("error"): raise SystemExit(f"{m} -> {d['error']}")
    return d["result"]
print("login:", rpc("auth.login", [os.environ["DELUGE_PASSWORD"]]))
print("web.connected:", rpc("web.connected", []))
t = rpc("core.get_torrents_status", [{}, ["state","progress","tracker_status","label",
        "message","time_since_transfer","download_payload_rate","upload_payload_rate"]])
print("torrents:", len(t))
print("states:", collections.Counter(v["state"] for v in t.values()))
print("tracker heads:", collections.Counter((v.get("tracker_status") or "").split(":")[0][:40]
                                            for v in t.values()).most_common(8))
for k, v in list({k: v for k, v in t.items() if v["state"] == "Error"}.items())[:10]:
    print("  ERR", v.get("message"), "|", v.get("tracker_status"))
print("uploading now:", sum(1 for v in t.values() if v["upload_payload_rate"] > 0),
      "| downloading now:", sum(1 for v in t.values() if v["download_payload_rate"] > 0))
print("session:", json.dumps(rpc("core.get_session_status",
      [["payload_upload_rate","payload_download_rate","num_peers","has_incoming_connections"]])))
c = rpc("core.get_config", [])
print("listen_interface:", c.get("listen_interface"), "| outgoing:", c.get("outgoing_interface"),
      "| listen_ports:", c.get("listen_ports"))
PY
```

**Green all the way means all six of these:**

1. `web.connected: True`. If `False`, or if `core.*` calls return "Unknown method", `deluge-web`
   never auto-connected to the daemon — `web.conf`'s `default_daemon` is empty. See memory
   `deluge-web-daemon-disconnect`.
2. `has_incoming_connections: 1` — the forwarded port really is reachable. **`0` is the single
   most important red flag here**: it means unreachable-from-outside, ratio quietly dies.
3. `listen_interface` and `outgoing_interface` are both **`tun0`** (not empty, not `eth0`).
   An empty `listen_interface` caused the Aug-2026 announce-pool saturation and 29 HnRs — see
   memory `ptp-hnr-after-outage`.
4. `listen_ports` matches gluetun's "allowed input port" from the previous command.
5. States: overwhelmingly `Seeding`. **`Error` count should be 0.** A handful of
   `tracker_status: Error` (≤ ~5 of ~1900) is normal churn — dead public trackers.
6. Recent activity: `uploading now` > 0, or if 0, upload rate over the last day is non-zero.
   `downloading now: 0` is normal and not a finding — grabs are bursty.

**Mass-error patterns and what they actually mean** (do not misdiagnose these):
- **Every PTP torrent in Error simultaneously** → PTP Intermission (their scheduled downtime),
  not your DNS/VPN. Memory `deluge-nightly-restart-ptp-intermission`.
- **Everything stalled, "skipping tracker announce (unreachable)", ~0 peers** → Deluge started
  before gluetun finished rebuilding the tunnel. Cure: stop then start deluge *after* the VPN
  settles. Memory `deluge-stale-tun0-bind`.
- Torrents stuck at 0 % with **zero trackers** → 1337x/itorrents DHT reconstruction; memory
  `prowlarr-1337x-trackerless`.

## 4. PTP account health

```bash
/usr/bin/ssh synology 'sudo -n tail -15 /volume2/docker-ssd/logs/ptp_ratio.log'
```

**PASS**: a run stamped within the last 24 h; `ratio` ≥ 2.0 (currently ~2.48 and drifting up);
`Leak … <= BP-credit earned … covered, no alert`; the `PTP Freeleech → Deluge` filter state
matches what the ratio dictates (disabled while ratio > threshold).

**Flag**: ratio trending *down* month over month, or a `Leak … NOT covered` line. The two known
leak paths are documented in memories `ptp-ratio-webhook-leak` (fixed) and
`ptp-ratio-search-rss-leak` (knowingly left unplugged — the BP loop absorbs it while ratio > 2.0;
mention it only if the ratio is actually falling).

Also worth a glance: `logs/ptp_dead_torrents.log` — the trumped/deleted-torrent reaper.

## 5. autobrr → Radarr freeleech pipeline

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
curl -s -H "X-API-Token: $AUTOBRR_API_KEY" "http://localhost:7474/api/filters" \
 | python3 -c "import sys,json;[print(f[\"id\"], \"enabled=\"+str(f[\"enabled\"]), f[\"name\"]) for f in json.load(sys.stdin)]"'
```

Expected filter set (IDs are stable):
| ID | Name | Expected |
|---|---|---|
| 1 | PTP Freeleech → Radarr | **enabled** |
| 2 | PTP Freeleech → Deluge | disabled while ratio > 2.0 (§4 toggles it) |
| 3 | PTP → Radarr | disabled |

Lifetime push outcomes:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
curl -s -H "X-API-Token: $AUTOBRR_API_KEY" "http://localhost:7474/api/release/stats"; echo'
```

**Flag a rising `push_error_count`.** The webhook (`autobrr-webhook`, port 8787) is what adds the
movie to Radarr *and unmonitors it after the grab*. When it errors, the freeleech movie lands
**monitored**, and Radarr then upgrade-grabs the **non-freeleech** version — that is the original
ratio leak (memory `ptp-ratio-webhook-leak`). The lifetime counter includes errors from before
the fix, so what matters is the **delta since last month**, not the absolute number. Record it.

Then the actual throughput, day by day:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
curl -s -H "X-API-Token: $AUTOBRR_API_KEY" "http://localhost:7474/api/release?limit=1000" | python3 -c "
import sys,json,collections,datetime
d=json.load(sys.stdin)[\"data\"]
c=collections.Counter(r[\"timestamp\"][:10] for r in d)
st=collections.Counter(r[\"filter_status\"] for r in d)
ps=collections.Counter(a[\"status\"] for r in d for a in (r.get(\"action_status\") or []))
print(\"window:\", min(c), \"->\", max(c), \"| releases:\", len(d))
print(\"filter_status:\", dict(st), \"| push:\", dict(ps))
lo,hi = (datetime.date.fromisoformat(x) for x in (min(c), max(c)))
run=best=0
for i in range((hi-lo).days+1):
    day=str(lo+datetime.timedelta(days=i)); n=c.get(day,0)
    run = run+1 if n==0 else 0; best=max(best,run)
    print(day, n if n else \"-\")
print(\"longest zero run:\", best, \"days\")
"'
```

> **This instance stores only approved releases** — `/api/release/stats` shows
> `filter_rejected_count: 0` and `total_count == filtered_count`. So a day with zero rows means
> *nothing matched the freeleech filter*, **not** that autobrr was down. Do not report a zero run
> as an outage without the cross-check below.

**PASS**: releases on most days, and — critically — the IRC feed alive right now:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
curl -s -H "X-API-Token: $AUTOBRR_API_KEY" "http://localhost:7474/api/irc" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for n in (d if isinstance(d,list) else d.get(\"data\",[])):
    print(n.get(\"name\"), \"enabled=\",n.get(\"enabled\"), \"connected=\",n.get(\"connected\"), \"healthy=\",n.get(\"healthy\"))
    for c in n.get(\"channels\") or []: print(\"   #\", c.get(\"name\"), \"monitoring=\", c.get(\"monitoring\"))
"
echo "--- announces seen in the last hour ---"
sudo /usr/local/bin/docker logs --since 1h autobrr 2>&1 | grep -c "got message"'
```

`PassThePopcorn connected=True healthy=True`, `#ptp-announce monitoring=True`, and a non-zero
"got message" count = the feed is fine and any zero-release days were a genuine **freeleech
drought**, which is normal and outside your control. PTP freeleech arrives in waves.

Note the asymmetry: this proves the feed is healthy **now**, and — as far back as the log
reaches — that announces were arriving while zero releases matched. It cannot prove anything
about a zero run older than the container's last recreation (see §0). For 2026-07-18→31, only
Jul 28 onward was verifiable this way; Jul 18–27 rests on the ratio and Radarr cross-checks.
Say which part you actually verified.

**Only escalate a zero run when** `connected=False`, `monitoring=False`, or the last-hour
announce count is 0. Then it is the IRC feed, and the filter is starved.

Second cross-check for a long zero run — did Radarr keep grabbing anyway?

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
curl -s -H "X-Api-Key: $RADARR_API_KEY" "http://localhost:7878/api/v3/history?page=1&pageSize=500&sortKey=date&sortDirection=descending&eventType=1" | python3 -c "
import sys,json,collections
c=collections.Counter(r[\"date\"][:10] for r in json.load(sys.stdin)[\"records\"])
for k in sorted(c): print(k, c[k])
"'
```

Grabs continuing at 1–5/day through an autobrr-silent window are **not** freeleech — they come
from the IMDb import lists / RSS path, which is the knowingly-unplugged second leak (memory
`ptp-ratio-search-rss-leak`). That is tolerated while the PTP ratio stays above 2.0. Note it in
the report only if §4 shows the ratio falling.

> autobrr is reachable from the NAS **only** at `http://localhost:7474`. The public
> `https://autobrr.gobadiah.com` fails from the NAS itself (no NAT hairpin) but works from the
> laptop.

## 6. Radarr / Sonarr / Lidarr / Prowlarr

Health first — these endpoints return `[]` when clean:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
for x in "radarr:7878:v3:$RADARR_API_KEY" "sonarr:8989:v3:$SONARR_API_KEY" "lidarr:8686:v1:$LIDARR_API_KEY" "prowlarr:9696:v1:$PROWLARR_API_KEY"; do
  n=${x%%:*}; rest=${x#*:}; p=${rest%%:*}; rest=${rest#*:}; v=${rest%%:*}; k=${rest#*:}
  echo "--- $n ---"; curl -s -H "X-Api-Key: $k" "http://localhost:$p/api/$v/health"; echo
done'
```

`[]` for radarr/sonarr/prowlarr = **PASS** (verified 2026-08-06). Lidarr has no key in `.env`;
read it from its `config.xml` if you want it, or skip and say so.

Then activity and queues:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
for x in "radarr:7878:$RADARR_API_KEY" "sonarr:8989:$SONARR_API_KEY"; do
  n=${x%%:*}; p=$(echo $x|cut -d: -f2); k=$(echo $x|cut -d: -f3)
  echo "=== $n history ==="
  curl -s -H "X-Api-Key: $k" "http://localhost:$p/api/v3/history?page=1&pageSize=100&sortKey=date&sortDirection=descending" | python3 -c "
import sys,json,collections
d=json.load(sys.stdin); print(\"lifetime records:\", d[\"totalRecords\"])
ev=collections.Counter(r[\"eventType\"] for r in d[\"records\"])
day=collections.Counter(r[\"date\"][:10] for r in d[\"records\"])
print(\"last-100 events:\", dict(ev)); print(\"window:\", min(day), \"->\", max(day))
for r in d[\"records\"][:5]: print(\" \", r[\"date\"][:16], r[\"eventType\"], r[\"sourceTitle\"][:60])
"
  echo "=== $n queue ==="
  curl -s -H "X-Api-Key: $k" "http://localhost:$p/api/v3/queue?pageSize=100" | python3 -c "
import sys,json;d=json.load(sys.stdin);print(\"queued:\",d[\"totalRecords\"])
for r in d[\"records\"][:10]: print(\" \",r.get(\"status\"),r.get(\"trackedDownloadStatus\"),(r.get(\"title\") or \"\")[:55])
"
done'
```

**Radarr PASS**: `downloadFolderImported` events on most days (freeleech arrives daily),
queue near 0, and every `grabbed` followed by an import.

**Sonarr PASS**: activity clustered around actual show releases — **gaps of a week or more are
expected out of season and are not a finding.** Judge Sonarr by "did the shows I follow that
aired this month get imported", not by daily cadence. An occasional `downloadFailed` followed by
a successful re-grab is the system working (Radarr/Sonarr failed-redownload).

**Flag on either**: queue items stuck in `warning`/`error` `trackedDownloadStatus`, or a
`grabbed` with no matching import within ~24 h.

Prowlarr indexers:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
echo "--- failing indexers ---"
curl -s -H "X-Api-Key: $PROWLARR_API_KEY" "http://localhost:9696/api/v1/indexerstatus"; echo
echo "--- 30d stats ---"
S=$(date -u -d "-30 days" +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -v-30d +%Y-%m-%dT00:00:00Z); E=$(date -u +%Y-%m-%dT00:00:00Z)
curl -s -H "X-Api-Key: $PROWLARR_API_KEY" "http://localhost:9696/api/v1/indexerstats?startDate=$S&endDate=$E" | python3 -c "
import sys,json
for i in json.load(sys.stdin)[\"indexers\"]:
    q,fq = i[\"numberOfQueries\"], i[\"numberOfFailedQueries\"]
    r,fr = i[\"numberOfRssQueries\"], i[\"numberOfFailedRssQueries\"]
    print(f\"{i[\"indexerName\"]:<20} q={q:>5} fail={fq:>4} rss={r:>6} rssfail={fr:>5} grabs={i[\"numberOfGrabs\"]:>4} failgrabs={i[\"numberOfFailedGrabs\"]} avg={i[\"averageResponseTime\"]}ms\")
"'
```

`/indexerstatus` lists only indexers Prowlarr has **backed off**; each entry carries
`disabledTill` / `initialFailure`. **PASS** = empty, or one transient public tracker.

**Flag**: PassThePopcorn appearing there (that's the one that matters), any indexer with
`numberOfFailedQueries` > ~20 % of queries, `averageResponseTime` > ~5000 ms, or an
`initialFailure` more than a few days old — that indexer has been dead all month. Cloudflare-
gated indexers route through `flaresolverr`; if several fail at once, check that container.

## 7. Jellyfin — content freshness

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
for lib in "Movies:f137a2dd21bbc1b99aa5c0f6bf02a805" "Shows:a656b907eb3a73532e40e44b968d0225" "Youtube:e59b37148e0ff06f0d35b0c3c714e75c"; do
n=${lib%%:*}; id=${lib##*:}; echo "=== $n ==="
curl -s -H "X-Emby-Token: $JELLYFIN_API_KEY" \
 "http://localhost:8096/Items?ParentId=$id&Recursive=true&IncludeItemTypes=Movie,Episode&SortBy=DateCreated&SortOrder=Descending&Limit=60&Fields=DateCreated" \
 | python3 -c "
import sys,json,collections,datetime
d=json.load(sys.stdin); print(\"library total:\", d[\"TotalRecordCount\"])
day=collections.Counter(i[\"DateCreated\"][:10] for i in d[\"Items\"])
newest=max(day); age=(datetime.date.today()-datetime.date.fromisoformat(newest)).days
print(\"newest:\", newest, f\"({age}d ago)\", \"| distinct days in last 60 items:\", len(day))
for i in d[\"Items\"][:5]: print(\" \", i[\"DateCreated\"][:16], i.get(\"SeriesName\",\"\"), i[\"Name\"][:50])
"; done'
```

Per-library expectations — **these differ deliberately, do not apply one threshold to all**:

| Library | Expected cadence | WARN | FAIL |
|---|---|---|---|
| **Movies** (~3900) | near-daily; freeleech lands several/day | newest > 3 d old | newest > 7 d old |
| **Youtube** (~590) | almost every day (tubesync) | newest > 2 d old | newest > 4 d old |
| **Shows** (~3570) | bursty, follows airing seasons | — | only if §6 shows Sonarr imported episodes that Jellyfin does not have |

A Movies or Youtube stall with §5/§9 healthy means the **import/scan** side broke, not the
acquisition side — check the `jellyfin-nfo-refresh` job in §11 and Jellyfin's own errors in §8.

## 8. Jellyfin — playback, transcoding, library errors

The direct evidence, and the best signal in this whole document — ffmpeg session logs by kind:

```bash
/usr/bin/ssh synology 'd=/volume2/docker-ssd/jellyfin/config/log
for k in Transcode Remux DirectStream; do echo "$k: $(sudo -n find $d -name "FFmpeg.$k-*" -mtime -30 | wc -l)"; done'
```

**PASS**: `Transcode: 0`. Remux (container-swap, cheap) and DirectStream are fine and expected —
22 Remux sessions in 30 days is the current normal. **Any non-zero Transcode count is a
finding**, because this NAS cannot hardware-transcode and software transcoding starves it enough
to stall playback mid-episode.

Corroborate from the watch history, which also gives you the trend:

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker exec -i tracearr-db psql -U tracearr -d tracearr' <<'SQL'
select date_trunc('week', started_at)::date AS week,
       count(*) AS plays,
       count(*) filter (where is_transcode)               AS transcode,
       count(*) filter (where video_decision = 'transcode') AS video_tc,
       round(100.0 * count(*) filter (where is_transcode) / greatest(count(*),1), 1) AS pct_tc
from sessions
where started_at > now() - interval '90 days'
group by 1 order by 1;
SQL
```

**PASS**: `pct_tc` at or near 0. The fix landed **2026-07-21** — before that date the history
shows 40–60 % transcoding, and that older data is *not* a regression, it is the "before" half of
a known fix. Only weeks after 2026-07-21 are in scope.

**If transcoding has returned**, the cause is almost never the server. It is a **client-side
bitrate cap** forcing a needless transcode; the server's `RemoteClientBitrateLimit` is already 0.
Identify the offending client and fix the cap there:

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker exec -i tracearr-db psql -U tracearr -d tracearr' <<'SQL'
select product, player_name, platform, count(*) AS plays,
       count(*) filter (where is_transcode) AS tc,
       string_agg(distinct quality, ', ') AS qualities
from sessions
where started_at > now() - interval '30 days'
group by 1,2,3 order by tc desc, plays desc limit 15;
SQL
```
Full background: memory `jellyfin-transcode-cpu-starvation`.

Buffering complaints with `Transcode: 0` are **not** a server fault — that is CPL powerline link
saturation. Memories `jellyfin-buffering-cpl-saturation`, `lan-latency-wifi-scan-vs-cpl`.

Jellyfin's own error log, last 30 days:

```bash
/usr/bin/ssh synology 'd=/volume2/docker-ssd/jellyfin/config/log
sudo -n grep -ohE "\[ERR\].{0,90}" $d/log_2026*.log 2>/dev/null | sed "s/[0-9]\{2,\}//g" | sort | uniq -c | sort -rn | head -12'
```

Known-benign noise (report the counts, do not chase): `EpisodeNfoProvider: Image location`,
`ProviderManager: Error in metadata saver`, `SubtitleResolver: Error getting external streams`.
These come from tubesync NFOs and are cosmetic.

**Genuinely bad, escalate**: `Error in Directory watcher` / `FileSystemWatcher` bursts — real-time
library monitoring dies silently and the whole library's watcher tears down. Root cause is the
Synology `@eaDir` permission trap; the fix (`group_add: "100"` on the jellyfin service) is already
applied, so a recurrence means it regressed. Memory `jellyfin-eadir-watcher`.

Sanity-check the injected web customisations still load (they break on Jellyfin updates):

```bash
/usr/bin/ssh synology 'sudo -n grep -c "" /volume2/docker-ssd/jellyfin/config/jellyfin_recently_watched.js /volume2/docker-ssd/jellyfin/config/jellyfin_latest_ungroup.js 2>/dev/null'
```
Memories `jellyfin-recently-watched`, `jellyfin-latest-ungroup`. If the files moved, just note it.

## 9. tubesync

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker exec -i postgres psql -U mediastack -d tubesync' <<'SQL'
select date(download_date) AS d, count(*) AS n
from sync_media where download_date > now() - interval '30 days'
group by 1 order by 1;

select s.name,
       count(*) filter (where m.downloaded)                                            AS dl,
       count(*) filter (where not m.downloaded and not m.skip and m.can_download)       AS ready,
       count(*) filter (where not m.downloaded and not m.skip and not m.can_download)   AS needs_meta,
       max(m.download_date)::date                                                       AS last_dl
from sync_media m join sync_source s on m.source_id = s.uuid
group by 1 order by 5 nulls first;
SQL
```

**PASS**: downloads on most days of the month (bursty is fine — a 30-download day after a few
3–7 day ones is a channel catching up); `ready` = 0 everywhere; `needs_meta` small (< ~30) and
shrinking; every source's `last_dl` consistent with how often that channel actually publishes.

**Flag**:
- A source whose `last_dl` is > 30 days old **and** that publishes regularly → that source is
  stuck. `micode` / `mentourblackbox` / `pilot-debrief` are low-frequency by nature; don't
  report those without checking the channel.
- `ready` > 0 and not moving → downloads are queued but not running.
- `needs_meta` in the hundreds → metadata queue clogged with cap-skipped fetches. That is exactly
  what the **`/tubesync-prioritize`** skill fixes — recommend it rather than re-deriving it.

Queue and guard state:

```bash
/usr/bin/ssh synology '
echo "--- huey LIMIT queue depth ---"; sudo /usr/local/bin/docker exec tubesync sqlite3 /config/tasks/huey_net_limited.db "select count(*) from task"
echo "--- queue guard ---"; sudo -n cat /volume2/docker-ssd/state/tubesync_queue_guard.json; echo
echo "--- guard log ---"; sudo -n tail -20 /volume2/docker-ssd/logs/tubesync_queue_guard.log
echo "--- container errors 30d ---"; sudo /usr/local/bin/docker logs --since 720h tubesync 2>&1 | grep -icE "error|exception"'
```

The guard runs hourly and reconciles tasks lost to a watchtower-killed container (stale huey lock
+ frozen "running" sentinel). Repeated recoveries in its log = the 4 a.m. image update is killing
in-flight downloads regularly. Memories `tubesync`, `tubesync-watchtower-killed-tasks`.

**Triage the container error count before reporting it.** ~800 matches per 30 days is the normal
floor, and it is almost entirely three known-benign categories:

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker logs --since 720h tubesync 2>&1 | grep -oiE "(error|exception)[^ ]*" | sort | uniq -c | sort -rn | head -8'
```

| Pattern | Meaning | Action |
|---|---|---|
| `available to this channel's members on level:` | members-only video | none — `tubesync_members_only_sweep.py` auto-skips these |
| `waiting for errors: 429` | YouTube rate-limit backoff | none — expected, bgutil + cookies handle it |
| `errors.ForeignKeyViolation` | the `cleanup_old_media` upstream bug below | none |

Anything **outside** those three is worth reading. In particular a burst of yt-dlp signature /
`nsig` extraction failures means the `cookies.txt` or the `bgutil-provider` sidecar needs
attention (memory `tubesync`).

Known upstream bug, **do not re-diagnose**: `cleanup_old_media` never expires anything, because
`loaded_metadata` re-INSERTs a metadata row for the just-deleted media and rolls back every pass.
Memory `tubesync-cleanup-old-media-broken`.

### Memory — and the `hat-syslog-server` doom loop

```bash
/usr/bin/ssh synology '
sudo /usr/local/bin/docker inspect -f "started={{.State.StartedAt}} restarts={{.RestartCount}} OOMKilled={{.State.OOMKilled}} mem={{.HostConfig.Memory}}" tubesync
sudo /usr/local/bin/docker stats --no-stream tubesync
echo "--- top processes by RSS ---"
sudo /usr/local/bin/docker top tubesync -eo pid,rss,comm --sort=-rss | head -6
echo "--- hat syslog store (MUST stay small) ---"
sudo -n du -sh /volume2/docker-ssd/tubesync/state/hat/ 2>/dev/null
sudo -n ls /volume2/docker-ssd/tubesync/state/hat/ 2>/dev/null | wc -l
echo "--- kernel OOM kills ---"
sudo -n grep -c "Killed process" /var/log/kern.log 2>/dev/null'
```

`mem` must read `4294967296`. **`OOMKilled=true` is never just a stale flag — always chase it to
the process.** `docker top … --sort=-rss` names the culprit directly; `docker inspect` alone will
not.

**The known failure (found 2026-08-06, root-caused):** the image bundles a diagnostic syslog
collector started unconditionally by
`/etc/s6-overlay/s6-rc.d/hat-syslog-server/run`:

```
/usr/bin/python3 /usr/local/bin/hat-syslog-server --log-level INFO \
    --db-enable-archive --db-path /config/state/hat/syslog.db
```

Its SQLite DB grows without bound. Once it is big enough that opening it exceeds the container's
memory limit, startup OOMs **before** the archive step completes, s6 restarts it, and it loops
forever:

| Symptom | Observed value |
|---|---|
| `state/hat/syslog.db` | **2.9 GB** |
| Rotated `syslog.db.NNNN` archives | ~1100, one every 3 min, all 12 KB (empty — it never got that far) |
| `hat-syslog-server` RSS | 3.85 GiB of the container's 4 GiB (everything else totals < 30 MB) |
| Container | 98.6 % of limit, ~57 % CPU, 4 GB swap churned continuously |
| Onset | first archive `syslog.db.1` at 2026-08-04 17:34 |

**Raising the memory limit does not fix this** — that is why 2G → 4G did not help. The DB keeps
growing, so any fixed ceiling is crossed again later. The cure is to keep the store small:
delete `state/hat/syslog.db` and its archives (tubesync stops the loop and reclaims the space
immediately; the data is diagnostic logging, not tubesync state).

Diagnostic tell without touching the NAS filesystem: `du -sh state/hat/` over a few hundred MB,
or an archive count in the hundreds, means the loop is running or about to start.

**Downloads keep working while this loop runs**, just slowly — the huey workers survive. So a
tubesync that is "up, healthy, downloading a bit less than usual" can still be burning a CPU core
and 4 GB of swap. Check §2 host load together with this.

## 10. Bazarr and the AI-translated subtitles

Providers and backlog:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
echo "--- providers ---"; curl -s -H "X-API-KEY: $BAZARR_API_KEY" http://localhost:6767/api/providers; echo
echo "--- wanted movies ---"; curl -s -H "X-API-KEY: $BAZARR_API_KEY" "http://localhost:6767/api/movies/wanted?length=1" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\"total\"))"
echo "--- wanted episodes ---"; curl -s -H "X-API-KEY: $BAZARR_API_KEY" "http://localhost:6767/api/episodes/wanted?length=1" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\"total\"))"
echo "--- recent downloads ---"; curl -s -H "X-API-KEY: $BAZARR_API_KEY" "http://localhost:6767/api/movies/history?length=20" | python3 -c "
import sys,json,collections
d=json.load(sys.stdin)[\"data\"]
print(collections.Counter(r[\"provider\"] for r in d))
for r in d[:6]: print(\" \", r[\"parsed_timestamp\"], r[\"language\"][\"name\"], r[\"provider\"], r[\"score\"], r[\"title\"][:40])
"'
```

**PASS**: all 8 providers `"status": "Good"` with `"retry": "-"`; recent history shows subtitles
landing from more than one provider.

**Flag**: any provider not `Good` — especially `opensubtitlescom` (quota/auth) and `subf2m` /
`gestdown` (Cloudflare → check `flaresolverr`). Wanted counts around 1500 movies / 2000 episodes
are the **expected steady state**, not a backlog to panic over: most of it is fr/ja that no
provider has, which is precisely why the AI translator exists. Only a *sharp jump* matters.

Now the AI subtitle pipeline (`subtitle_translate.py`, Claude CLI on the NAS, fr + ja):

```bash
/usr/bin/ssh synology '
echo "--- state ---"; sudo -n python3 -c "
import json,itertools,time
d=json.load(open(\"/volume2/docker-ssd/state/subtitle_translate.json\"))
print(\"done:\",len(d[\"done\"]),\" failures:\",len(d[\"failures\"]))
print(\"providers snapshot:\",d[\"providers\"])
print(\"provider_baseline:\",d.get(\"provider_baseline\"))
rec=[v for v in d[\"done\"].values() if v[\"ts\"] > time.time()-30*86400]
print(\"produced in last 30d:\",len(rec))
for k,v in itertools.islice(d[\"failures\"].items(),8): print(\"  FAIL\",k,v[\"err\"])
"
echo "--- log tail ---"; sudo -n tail -15 /volume2/docker-ssd/logs/subtitle_translate.log
echo "--- lock age ---"; sudo -n stat -c "%y %n" /volume2/docker-ssd/state/subtitle_translate.lock 2>/dev/null'
```

**PASS**: `done` growing month over month (currently 102); ≥ ~20 new files in the last 30 days;
`failures` in single digits; the `providers` snapshot matches the 8 live providers from the
Bazarr call above.

**Flag**:
- `providers` snapshot **≠** live provider list → a provider was added or removed. The script
  auto-resets `provider_baseline` to now on an *addition* (so every language must fail a fresh
  all-provider sweep before being translated). Expect a temporary drop in output; that is
  correct, not broken.
- A stale `subtitle_translate.lock` (older than ~6 h) with no running `claude-cli` container →
  a run died holding the lock; every subsequent run is a no-op.
- Rising `failures`. The recurring error shape is `sent 150 blocks, missing [...]` — the model
  dropped cues from a chunk. A few are normal (the script retries); a jump means the `[N]`-block
  protocol is degrading and `CHUNK_CUES` (150) may need lowering. Memory `subtitle-translate`.
- Auth: if the log shows the Claude CLI failing to start, `CLAUDE_CODE_OAUTH_TOKEN` in `.env` has
  expired.

Spot-check that the output is real, not truncated — pick 2–3 recent paths from `done` and verify
the `.fr.srt` / `.ja.srt` has a plausible cue count and actual target-language text:

```bash
/usr/bin/ssh synology 'sudo -n bash -c "f=\"<path from done>\"; ls -l \"\$f\"; grep -c \" --> \" \"\$f\"; sed -n \"1,12p\" \"\$f\""'
```
A file with far fewer cues than the English source, or one containing English text, is a bad
translation that Bazarr is now serving — report it with the specific title.

One more subtitle trap to verify has not regressed: Japanese subs showing up as **Hindi** in
Jellyfin (`.hi` SDH suffix collides with ISO `hi`). Bazarr's `hi_extension` must be `sdh`.
Memory `jellyfin-japanese-as-hindi-subs`.

## 11. Scheduled jobs — the automation layer

DSM Task Scheduler runs these as root. Check both that each **ran recently** and that it ran
**cleanly** — the two failure modes are different.

```bash
/usr/bin/ssh synology 'cd /volume2/docker-ssd/logs
RE="^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:,.]+ +\[?(ERROR|CRITICAL)\]?( |$)"
MONTHS="^2026-0[78]"        # <-- widen/shift to the audit window
for f in deluge_cleanup ptp_ratio ptp_dead_torrents space_cleanup tubesync_queue_guard \
         tubesync_members_only_sweep recsys mentour_rewatch container_crash_watcher \
         jellyfin-nfo-refresh youtube_episode_renumber subtitle_translate kindle_read_sync \
         postgres-backup acl-guard; do
  [ -f "$f.log" ] || { printf "%-28s MISSING\n" "$f"; continue; }
  last=$(sudo -n stat -c %y "$f.log" | cut -c1-16)
  n=$(sudo -n grep -E "$RE" "$f.log" 2>/dev/null | grep -cE "$MONTHS")
  worst=$(sudo -n grep -E "$RE" "$f.log" 2>/dev/null | grep -oE "$MONTHS-[0-9]{2}" | sort | uniq -c | sort -rn | head -1 | tr -s " ")
  printf "%-28s last=%s  errs=%-5s worst:%s\n" "$f" "$last" "$n" "${worst:- none}"
done'
```

Two traps this regex exists to avoid — **do not simplify it to `grep -c ERROR`**:

1. It must anchor on the **log-level field**, not the word. `deluge_cleanup.log` is full of
   `[INFO] ERROR/RECHECK: …` lines — normal operation, since its whole job is reacting to
   erroring torrents. A naive grep reports ~1600 "errors" that are not errors.
2. It must be **scoped to the audit window** and **bucketed by day**. These logs span months, and
   the shape matters far more than the total: 772 errors sounds alarming, but 769 of them landed
   on a single day (2026-07-27) and the rest of the month is 0–3/day. **A spike day is one
   incident to investigate; a steady trickle is background noise.** Always read `worst:` before
   reacting to `errs=`.

A spike in `deluge_cleanup` specifically (hundreds of `[ERROR] ERROR processing … ` in one run)
is the mass-error signature from §3 — PTP Intermission or a gluetun tunnel drop, which triggers
the script's own systemic-error self-restart. Confirm which, then move on; it is self-healing.

Expected cadence: `deluge_cleanup` daily 07:00 · `ptp_ratio` daily 04:00 · `space_cleanup` daily
05:00 · `postgres-backup` daily 03:00 · `recsys` daily 09:00 · `mentour_rewatch` daily 08:00 ·
`jellyfin-nfo-refresh` (+ `youtube_episode_renumber` + `tubesync_members_only_sweep`) every 15 min ·
`tubesync_queue_guard` hourly · `container_crash_watcher` continuous · `icloudpd-sync` daily 04:30.

**Flag**: a log whose mtime is older than its cadence — the DSM task is disabled or erroring
before it can write. Cross-check:

```bash
/usr/bin/ssh synology 'sudo -n /usr/syno/bin/synoschedtask --get | grep -E "Name:|State:" | paste - -'
```
Expected `disabled`: `Personal videos`, `Docker`, `PTP Archiver`. Everything else `enabled`.

Two specific ones worth reading rather than counting:

```bash
/usr/bin/ssh synology 'echo "--- space_cleanup needs-manual ---"; sudo -n cat /volume2/docker-ssd/logs/space_cleanup_needs_manual.log
echo "--- crash watcher, last 20 ---"; sudo -n tail -20 /volume2/docker-ssd/logs/container_crash_watcher.log'
```
`container_crash_watcher` sends SES email on crash-only events; a quiet log is the good outcome.
`space_cleanup_needs_manual.log` is the queue of deletions the script refused to do itself —
worth surfacing in the report if non-empty.

iCloud photo archive (runs as `michael`, not root):

```bash
/usr/bin/ssh synology 'sudo -n tail -12 /volume2/docker-ssd/logs/icloudpd-sync-$(date +%Y%m%d).log 2>/dev/null || ls -t /volume2/docker-ssd/logs/icloudpd-sync-*.log | head -1'
```
A `421 → Two-factor authentication is required → EOFError` traceback is **not** necessarily a
real expiry — re-run the `--auth-only < /dev/null` verify first; it usually self-heals. Runbook in
the script header; memory `synology-script-deployment`.

## 12. Backups

```bash
/usr/bin/ssh synology '
echo "--- postgres dumps ---"; sudo -n ls -lat /volume2/docker-ssd/postgres-dumps/*.sql.gz | head -5
echo "--- dump count (expect ~30) ---"; sudo -n ls /volume2/docker-ssd/postgres-dumps/*.sql.gz | wc -l'
```

**PASS**: today's `dump-YYYYMMDD.sql.gz` present, ~175 MB, ~30 files retained, size **stable or
growing** — a sudden shrink means a database dropped out of `pg_dumpall`.

### Laptop → NAS borg backup

This runs **on the MacBook**, not the NAS, throttled to 400 KiB/s because the CPL uplink is only
~7 Mbit/s (memory `borg-backup-cpl-throttle`). It is the single easiest thing in this whole stack
to lose silently, because nothing alerts when it stops — **check all three of these**:

```bash
echo "--- 1. log freshness (the real detector) ---"
ls -la ~/Library/Logs/borg-backup.log; tail -20 ~/Library/Logs/borg-backup.log
echo "--- 2. is macOS ALLOWING it to run? ---"
sfltool dumpbtm 2>/dev/null | grep -A6 "Name: borg-backup" | grep -E "Disposition|Identifier"
sfltool dumpbtm 2>/dev/null | grep -A6 "Name: chezmoi-autocommit" | grep -E "Disposition|Identifier"
echo "--- 3. last write the NAS actually received ---"
/usr/bin/ssh synology 'sudo -n ls -lat /volume1/borg-backups/macbook | head -6'
```

1. **A log whose mtime is more than ~2 h old is a FAIL**, whatever its last line says. The log's
   mtime — not its contents — is the detector, because the failure mode is silence.
2. **`Disposition: [enabled, disallowed, notified]` is the FAIL.** A healthy agent reads
   `[enabled, allowed, notified]` — compare the two lines side by side; `chezmoi-autocommit` is
   the known-good reference. `disallowed` means macOS's Background Task Management is blocking
   it: the plist is still on disk, `launchctl` simply never fires it, and **nothing warns you**.
   This is what happened on 2026-08-04 — the agent was switched off as collateral of the
   login-items purge (memory `mac-startup-cleanup`), which had explicitly intended to *keep* it.
   Fix in **System Settings → General → Login Items & Extensions → Allow in the Background**;
   the entry appears under **"Unknown Developer"** because the plist has no signed parent, which
   is exactly why it looks like cruft and gets toggled off by mistake.
3. `/volume1/borg-backups/macbook` `index.*` / `hints.*` mtime = the last backup the NAS actually
   received. It should agree with the log.

> **Do not conclude "it's running" from `launchctl print` alone, and do not conclude "it's dead"
> from it either.** `StartCalendarInterval` agents are fired by UserEventAgent and are transient,
> so `launchctl list | grep borg` is empty *both* when healthy-between-runs and when blocked.
> The BTM disposition plus the log mtime are what actually distinguish the two.
> Note `/usr/bin/log` must be spelled out — in zsh, `log` is a builtin that shadows it and
> returns nothing with exit 0.

`NAS unreachable, skipping` lines are normal and expected — the laptop is often off the LAN, and
the job skips rather than failing. A *run* of them ending with a successful backup is healthy.
An unbroken run of them with **no** success in > 24 h means the NAS is not resolving from the
laptop — check Tailscale / the `synology` host alias before blaming borg.

Also confirm chezmoi drift is being captured (nightly 23:00 autocommit):

```bash
cd ~ && chezmoi status | head -20 && git -C ~/.local/share/chezmoi log --oneline -3
```
Persistent entries in `chezmoi status` are the warning sign described in `~/CLAUDE.md` — a
templated target edited in `$HOME` is never backed up *and* will be silently reverted by the
next `apply`.

## 13. tracearr — history continuity

Only the **last month** is in scope; do not go further back.

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker exec -i tracearr-db psql -U tracearr -d tracearr' <<'SQL'
with days as (
  select generate_series(current_date - 30, current_date, interval '1 day')::date AS d
)
select days.d,
       count(s.id)                                                       AS plays,
       count(*) filter (where s.session_key like 'plexdb-%')             AS plex_backfill,
       count(*) filter (where s.session_key like 'jfbackfill-%')         AS jf_backfill,
       count(distinct s.server_user_id)                                  AS users
from days left join sessions s on date_trunc('day', s.started_at)::date = days.d
group by 1 order by 1;
SQL
```

**PASS**: no run of ≥ 3 consecutive zero-play days that does not correspond to a real absence
(holiday, travel). Typical volume is 4–79 plays/day, 1–3 distinct users.

`plex_backfill` should be 0 in a recent window — that prefix marks the 2016–2026 Plex-era import
(memory `tracearr-plex-backfill`). A handful of `jf_backfill` rows is expected and fine: those are
rows repaired by `tracearr_playback_audit.py` (1–3/day appeared around 2026-07-30). A *sudden
surge* of them means the audit script is patching up a lot of missed plays, which is itself the
symptom described next.

**A gap here that you *know* was not an absence is the highest-value finding in this document**,
because it means plays are being watched but not recorded. The known cause: Jellyfin Desktop
3.0.0-dev sends `VolumeLevel` as a float, the server 400s every start/progress report, and the
session is never created — while the *stop* report still lands, so the library looks fine
(`Played=true`, `PlayCount=0`). Confirm with:

```bash
/usr/bin/ssh synology 'sudo -n python3 /volume2/docker-ssd/scripts/tracearr_playback_audit.py 2>&1 | tail -30' \
  || echo "audit script not deployed — run ~/scripts/tracearr_playback_audit.py locally"
```
Workaround is setting that client's volume to 100. Memory `tracearr-missing-plays-sse-plugin`.

Also confirm the History page still answers quickly — the hypertable over-chunking regression:

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker exec -i tracearr-db psql -U tracearr -d tracearr' <<'SQL'
select count(*) AS chunks from timescaledb_information.chunks where hypertable_name = 'sessions';
SQL
```
**PASS**: chunk count in the low tens (~14). Several hundred chunks means planning time, not
query time, blows up and the "All"-time History view 500s. Memory
`tracearr-hypertable-overchunking` has the `merge_chunks` recipe — and note it resets on some
tracearr updates, so this is worth re-checking monthly.

---

## 14. Report format

Produce a single markdown report. No preamble, no "I ran some checks".

```markdown
# Stack health — <YYYY-MM-DD>

**Verdict: <HEALTHY | DEGRADED | ACTION NEEDED>** — <one sentence>

## Needs attention
<numbered, most severe first. Each: what is wrong, the number that proves it,
the likely cause, and the proposed fix. Empty section = say "Nothing.">

## Watch list
<things trending the wrong way but not yet broken, with last month's number if known>

## Section results
| # | Area | Verdict | Key numbers |
|---|------|---------|-------------|
| 1 | Containers | ✅ | 33 up, 0 restarts, 0 unhealthy |
| … | | | |

## Notable this month
<new content volumes, ratio movement, anything that changed since last run>
```

Rules for the report:
- **Numbers, not adjectives**, in every row.
- If a check could not be run, say so explicitly and why — never infer a ✅ from silence.
- Do not repeat the known-benign items from §1/§8/§10 as problems. Fold them into a single
  "known benign noise unchanged" line.
- Recommend fixes; do not apply them. The one thing to offer proactively is re-running a
  named existing skill (`/tubesync-prioritize`, `/ptp-dead-torrents`) when its trigger condition
  is clearly met.

## 15. Baseline (recorded 2026-08-06)

Compare against this; if the stack has legitimately moved on, update these numbers.

| Signal | Value |
|---|---|
| Containers running | 33 (+ transient `claude-cli` one-shots) |
| Restart counts / exited | 0 / none |
| `/volume1` · `/volume2` | 90 % · 7 % |
| Mem · swap · load | 8.7/31 Gi · 2.7/20 Gi · CPU 1.75 |
| VPN exit | NL, AS49453 Global Layer, 213.152.161.54 |
| Deluge | 1898 torrents, **all Seeding**, 0 Error, 3 tracker-Error, incoming=1, tun0/tun0, port 55364 |
| PTP | ratio 2.4761, up 2463 GiB / down 995 GiB, BP 8.86 M, leak covered |
| autobrr filters | 1 enabled · 2 disabled · 3 disabled |
| autobrr lifetime | total 3033 · push_approved 2783 · **push_error 282** · filter_rejected 0 |
| autobrr cadence | 17–45/day Jun 20 → Jul 17, **zero Jul 18–31**, resumed Aug 1 (drought, IRC healthy) |
| Radarr / Sonarr / Prowlarr health | `[]` · `[]` · `[]` |
| Radarr history · queue | 9486 lifetime · 0 queued |
| Sonarr history | 3892 lifetime, last import 2026-08-03 |
| Prowlarr backed-off indexers | 1 (id 19, since 2026-07-28) |
| Jellyfin libraries | Movies 3941 · Shows 3571 · Youtube 592 |
| Jellyfin ffmpeg 30 d | **Transcode 0** · Remux 22 · DirectStream 0 |
| tracearr 30 d | no gaps, 4–79 plays/day, 1–3 users, transcodes ~0 since 2026-07-21 |
| tracearr weekly `pct_tc` | 45.7 → 56.4 → 8.8 → **0.9 → 1.8** (fix landed 2026-07-21) |
| tracearr `sessions` chunks | 15 |
| tubesync | 647 downloaded, 21 pending, 15 sources, 0 `ready`, 21 `needs_meta`, ~840 benign log "errors"/30 d |
| Laptop borg | **launchd agent NOT loaded; last backup 2026-08-04 11:00** (open finding) |
| Bazarr | 8 providers all Good; wanted 1538 movies / 1982 episodes |
| AI subtitles | done 102, failures 6, 8-provider baseline |
| postgres dump | `dump-20260806.sql.gz`, 176 MB, 03:00, 30 retained |
| Scheduled-job errors (Jul–Aug) | all 0–12 except `deluge_cleanup` 772 — **769 of them on 2026-07-27 alone** (one mass-error incident, self-healed) |
| DSM tasks | all enabled except `Personal videos`, `Docker`, `PTP Archiver` |

## 16. Related memories

Read these before diagnosing anything in their area — they exist so the same root cause is not
re-derived from scratch:

`synology-script-deployment` · `synology-docker-engine` · `watchtower-remove-failure` ·
`deluge-web-daemon-disconnect` · `deluge-stale-tun0-bind` · `deluge-nightly-restart-ptp-intermission` ·
`ptp-hnr-after-outage` · `ptp-ratio-webhook-leak` · `ptp-ratio-search-rss-leak` ·
`prowlarr-1337x-trackerless` · `arr-cap-chown-login` · `radarr-list-language-filter` ·
`jellyfin-transcode-cpu-starvation` · `jellyfin-eadir-watcher` · `jellyfin-buffering-cpl-saturation` ·
`jellyfin-japanese-as-hindi-subs` · `jellyfin-recently-watched` · `jellyfin-latest-ungroup` ·
`tubesync` · `tubesync-watchtower-killed-tasks` · `tubesync-cleanup-old-media-broken` ·
`subtitle-translate` · `bazarr-incomplete-english-subs` · `tracearr-missing-plays-sse-plugin` ·
`tracearr-hypertable-overchunking` · `tracearr-plex-backfill` · `space-cleanup-live-run` ·
`postgres-mediastack-role` · `borg-backup-cpl-throttle` · `reverse-proxy-acl-guard` · `uptimerobot`
