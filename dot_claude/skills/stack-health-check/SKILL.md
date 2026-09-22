---
name: stack-health-check
description: Monthly end-to-end health audit of the Synology docker-ssd media stack — containers, VPN/Deluge, the *arrs, autobrr/PTP, tubesync, Jellyfin playback & transcoding, Bazarr + AI subtitles, tracearr history continuity, scheduled jobs and the deployed script layer (repo-vs-NAS drift), backups and capacity. Use when the user asks for the monthly stack check, a stack health report, or "is everything still working".
user-invocable: true
allowed-tools:
  - Bash
  - Read
---

# /stack-health-check — monthly audit of the Synology media stack

Replaces the manual monthly click-through of every web UI. Run every section, collect the
verdicts, and finish with the report in [§14](#14-report-format). Every command below was
executed live on 2026-08-06 (§11's script-layer checks on 2026-08-07) and re-validated against
Jellyfin 12.1 and the json-file log pin on 2026-09-22; it returns what it claims to return.

**Rules of engagement**

- **Read-only.** Nothing here mutates state. Remediation is *proposed* in the report, never
  applied unprompted — the one exception is that you may re-run an idempotent diagnostic.
- **Read-only includes how you read.** Never open a live SQLite database read-write, even to
  `SELECT` (use `-readonly`/`mode=ro`, or query a copy), and never cut a `docker logs` stream
  short (§0). Both look like reads and both have caused multi-hour outages. The hard rules in
  `~/scripts/CLAUDE.md` apply to every command you improvise here.
- **Read a service's compose block before calling it down.** `profiles: [donotstart]` means it
  was parked on purpose.
- **Don't stop at the first failure.** A red section is a finding, not an abort. Run all 13.
- **Every verdict needs a number.** "Deluge looks fine" is not a verdict; "1898 torrents,
  0 in Error, 3 tracker errors, incoming connections OK" is.
- **Compare against [§15 baseline](#15-baseline-recorded-2026-09-22)**, not against your
  intuition. This stack is deliberately unusual in places.

---

## 0. Connection prelude

SSH alias `synology` (user `michael`, passwordless sudo). Two hard-won invariants:

- Use **`/usr/bin/ssh`** explicitly. The shell's `ssh` wrapper does iTerm profile switching and
  breaks non-interactive use.
- Docker is **`sudo /usr/local/bin/docker`**. It is not on root's PATH, so `sudo docker` fails
  with "command not found". This generalises: **both plain ssh and sudo give you only
  `/usr/bin:/bin:/usr/sbin:/sbin`**, so nothing in `/usr/local/bin` resolves — `docker`,
  `docker-compose`, `git`, `borg`, `tailscale`, `rclone`, `node`, `npm`, `rg`, `fd`, `bat`,
  `ffmpeg7`, `python3.12`. Always name them absolutely. `rsync`, `python3`, `sqlite3`, `curl`,
  `jq`, `ffmpeg` and the coreutils live in `/usr/bin` and are fine.
  Sudo has always been this way; **plain ssh lost `/usr/local/bin` in the DSM 7.4.1 upgrade on
  2026-09-13**, which silently broke every hourly borgmatic run (`borg serve` unresolvable →
  "Connection closed by remote host. Is borg working on the server?", exit 81).
  Scheduled tasks are unaffected — cron sets its own PATH in `/etc/crontab` which still includes
  `/usr/local/bin`, so the NAS scripts that call `docker` bare keep working. When auditing, do
  not "fix" those; they are only broken if you run them over ssh yourself.

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

**Never run `docker compose up -d <service>` without `--no-deps`.** Compose also recreates that
service's `depends_on` targets whenever their running config no longer matches the compose file —
and most containers here have been up for weeks, so they *don't* match. Recreating `tubesync` on
2026-08-06 therefore recreated **`postgres`**, which is the shared database for radarr, sonarr,
prowlarr, lidarr, bazarr, jellystat and tubesync. The tubesync step then errored, aborting the
run before postgres was started, so the whole stack lost its database and every *arr crashed with
`Non-recoverable failure, waiting for user intervention`. Recovery was `docker start postgres`
then `docker restart radarr sonarr prowlarr lidarr` — data was never at risk (postgres uses a
bind mount) but it was a real outage. Always:

```bash
/usr/bin/ssh synology 'cd /volume2/docker-ssd && sudo /usr/local/bin/docker compose up -d --no-deps <service>'
```

Compose changes go through `~/scripts/compose_deploy.sh` (`status` → `push`), never by editing
the NAS copy. Its validation is worth trusting — it caught a duplicate `stop_grace_period` key
that would have made the file unparseable.

**Know how much of the stack a bare `compose up` would churn**, because it is normally most of it:

```bash
/usr/bin/ssh synology 'cd /volume2/docker-ssd && sudo /usr/local/bin/docker compose up -d --dry-run 2>&1 | grep Recreate | grep -v Recreated'
```

Read-only, and the honest answer is usually alarming: **20 of 33 on 2026-08-06.** The dominant
cause is not config drift — it is that **watchtower leaves `com.docker.compose.image` pointing at
the pre-update image**. Watchtower recreates the container with the new image but copies the old
labels verbatim, so compose compares that stale label against the live image, sees a mismatch, and
wants to recreate. Every watchtower-updated container is permanently "stale" to compose thereafter.
Count them:

```bash
/usr/bin/ssh synology 'for c in $(sudo /usr/local/bin/docker ps --format "{{.Names}}"); do
  cur=$(sudo /usr/local/bin/docker inspect -f "{{.Image}}" $c | cut -c8-19)
  lbl=$(sudo /usr/local/bin/docker inspect -f "{{index .Config.Labels \"com.docker.compose.image\"}}" $c 2>/dev/null | cut -c8-19)
  [ -n "$lbl" ] && [ "$cur" != "$lbl" ] && echo "STALE $c"
done | wc -l'
```

This is **not itself a fault** — the containers are running the right images; only compose's
bookkeeping is stale. It matters solely because it makes any unscoped `compose up` a stack-wide
restart. Treat it as the reason to always scope with `--no-deps` and an explicit service name,
not as something to fix.

> **Decided 2026-08-06: keep watchtower and live with the drift.** The alternative — moving
> updates to a nightly `compose pull` + `compose up -d` so labels stay correct — was considered
> and rejected: it buys consistency at the cost of a new updater to maintain and a one-time
> stack-wide recreate, to fix bookkeeping that has no operational effect. Upstream
> ([containrrr/watchtower#339](https://github.com/containrrr/watchtower/issues/339)) is
> Abandoned/wontfix, and container labels are immutable, so there is no in-place repair.
> **Do not re-propose this each month** — report the count and move on.

Compose's expected hashes are printable, which separates this cause from real config drift:
`sudo docker compose config --hash="*"` vs each container's
`com.docker.compose.config-hash` label.

**Never cut a `docker logs` stream short — not with `| head`, not with `timeout`.** On a
container still using DSM's default `db` log driver, a client disconnecting mid-stream deadlocks
the driver: the app freezes on its next log line while `docker ps` says `Up (healthy)`, and only
a Container Manager restart clears it — which itself hangs and takes the **whole stack** down.
This took Jellyfin down for 7 h on 2026-09-22 (full story in `~/scripts/CLAUDE.md`, memory
`docker-db-logdriver-wedge`). `docker-compose.yaml` now pins `json-file` on every service, which
is immune, but a container keeps the driver it was *created* with. So: **let the stream finish
into a file, then filter the file.** `/volume1` is not writable by `michael`, so redirect under
`sudo sh -c` (and never stage in `/tmp` — it is RAM):

```bash
/usr/bin/ssh synology 'D=/usr/local/bin/docker; P=/volume1/probe-hc.log
sudo sh -c "$D logs --since 720h <container> > $P 2>&1"
sudo head -1 $P | cut -c1-160          # first line = how far back the log really reaches
sudo grep -ci <pattern> $P
sudo rm -f $P'
```

Every `docker logs` command in this document follows that shape. `| grep -c` straight off the
stream is safe in principle (grep reads to EOF), but anything followed by `head`, or wrapped in
`timeout`, is not — use the file form everywhere and there is nothing to remember. §1 lists which
containers are still on `db`; run nothing but the file form against those.

**`docker logs --since 720h` does not actually reach back 30 days.** Container logs start at the
last *recreation*, and watchtower recreates most containers weekly. Observed 2026-08-06:
autobrr's entire log began 2026-07-28, so a "last 30 days" query covered 9 days; on 2026-09-22,
after a stack restart, tubesync's log was 56 lines. Always read that first line (above) before
drawing a conclusion from a log-based count. If the window is short, say so in the report rather
than reporting the count as a 30-day figure. Anything needing true 30-day history must come from
a **database or a file log** under `/volume2/docker-ssd/logs/`, not from `docker logs`.

For a chatty container, reading the json log file directly is cheaper still — bounded by line
count:

```bash
/usr/bin/ssh synology 'lp=$(sudo /usr/local/bin/docker inspect -f "{{.LogPath}}" autobrr)
sudo -n sh -c "tail -n 4000 $lp" | grep -c "got message"'
```

**A glob inside a root-only directory silently expands to nothing — wrap it in `sudo sh -c`.**
`sudo -n ls /some/root-only-dir/*.gz` is expanded by *your* shell (running as `michael`) before
sudo ever runs, so if the directory is mode 0700 root the pattern matches nothing and `ls` is
handed a literal `*.gz`. The result is an empty listing and a count of **0**, which for a backup
check reads as "the backups are gone". Two directories here are like this —
`/volume2/docker-ssd/postgres-dumps/` and `tubesync/state/hat/`. Always:

```bash
/usr/bin/ssh synology 'sudo -n sh -c "ls -lat /volume2/docker-ssd/postgres-dumps/*.sql.gz | head -3"'
```

The same trap bites `rm`: a delete that looks like it succeeded may have removed nothing.

**NAS `python3` is 3.8.** f-strings cannot reuse the enclosing quote character
(`f"{d["key"]}"` is a `SyntaxError` there, though it is legal in 3.12+). Use `%`-formatting or
swap the inner quotes in any inline `python3 -c` on the NAS.

---

## 1. Container fleet

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker ps -a --format "{{.Names}}\t{{.Status}}" | sort'
/usr/bin/ssh synology 'sudo /usr/local/bin/docker inspect --format "{{.Name}} {{.RestartCount}} {{.State.Status}}" $(sudo /usr/local/bin/docker ps -aq) | awk "\$2>0"'
echo "--- containers NOT on json-file (db-driver deadlock risk, see §0) ---"
/usr/bin/ssh synology 'for c in $(sudo /usr/local/bin/docker ps -a --format "{{.Names}}"); do
  echo "$c $(sudo /usr/local/bin/docker inspect -f "{{.HostConfig.LogConfig.Type}}" $c)"; done | grep -v json-file'
```

**PASS**: 32 named containers, all `Up` and — for the ones that declare a healthcheck —
`(healthy)`. No `Exited`, no `Restarting`, restart counts 0. The log-driver check prints nothing.
A container listed there was created before the compose pin (2026-09-22) and never recreated:
recreate it with `compose up -d --no-deps <svc>`, and until then touch its logs only via the
file form in §0.

**Before reporting an `Exited` container, read its compose block.** A service parked on purpose
carries `profiles: [donotstart]` and a comment saying why; that is a decision, not a fault.
(jellystat was parked like this on 2026-09-05 and misreported as down on 2026-09-22; it has
since been retired.)

**A stack-wide uptime of ~1 h** (every container "Up About an hour") means Container Manager
restarted — usually recovery from a db-driver wedge. Expect that day's job logs and DSM task
statuses (§11) to carry fallout errors (connection refused / read timeouts on `localhost:<port>`)
clustered in the restart window; attribute them to the incident, not to each job.

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
/usr/bin/ssh synology 'D=/usr/local/bin/docker; P=/volume1/probe-hc.log
sudo sh -c "$D logs --since 720h autoheal > $P 2>&1"
sudo grep -ci restart $P; sudo grep -i restart $P | tail -6 | cut -c1-160; sudo rm -f $P'
```
0 restarts in 30 days = PASS. A non-zero count is not itself a failure but tells you which
container has been flapping — chase it.

## 2. Host capacity & load

```bash
/usr/bin/ssh synology 'df -h | grep -E "^Filesystem|cachedev"; free -h; uptime'
```

| Metric | PASS | WARN | FAIL |
|---|---|---|---|
| `/volume1` (37T media HDD) | < 88 % | 88–93 % | > 93 % |
| `/volume2` (1.8T SSD, docker) | < 60 % | 60–80 % | > 80 % |
| Swap used | < 5 G | 5–10 G | > 10 G |
| Load avg (CPU component) | < 3 | 3–5 | > 5 |

`/volume1` was 27T and held at ~90 % by `space_cleanup.py` until the September 2026 disk swap
grew it to **37T (61 % on 2026-09-22)**. The metric that matters is still the trend: it is only a
finding if usage is **climbing month over month**, which means the cleanup is losing ground.
Check §11 for whether space_cleanup ran.

Also confirm the RAID arrays are whole — `cat /proc/mdstat`: `md2` must read `[6/6] [UUUUUU]`
and `md4` `[3/3] [UUU]`. Any `_` in that string is a degraded array and outranks everything else
in the report.

Read the load from the DSM-specific tail of `uptime`: `[IO: …  CPU: …]`. The plain load average
on this box is inflated by IO wait and is not the thing to judge.

## 3. VPN (gluetun) and Deluge

Deluge shares gluetun's network namespace, so these are one subsystem.

```bash
/usr/bin/ssh synology 'D=/usr/local/bin/docker; P=/volume1/probe-hc.log
echo "--- public IP ---"; sudo $D exec gluetun wget -qO- https://ipinfo.io/json | tr -d "\n" | cut -c1-300; echo
sudo sh -c "$D logs --since 720h gluetun > $P 2>&1"
echo "--- forwarded/allowed port ---"; sudo grep -i "allowed input port" $P | tail -1
echo "--- errors 30d ---"; sudo grep -icE "error|i/o timeout" $P
sudo rm -f $P'
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
- **Every PTP torrent in Error simultaneously** → PTP Intermission (their downtime), not your
  DNS/VPN. **An Intermission can last two weeks** — the Jul 2026 one ran 2026-07-18 → 07-29, and
  assuming "maintenance = a few hours" is how a site-wide outage gets misfiled as three unrelated
  local faults (see §5). Memory `deluge-nightly-restart-ptp-intermission`.
- **Everything stalled, "skipping tracker announce (unreachable)", ~0 peers** → Deluge started
  before gluetun finished rebuilding the tunnel. Cure: stop then start deluge *after* the VPN
  settles. Memory `deluge-stale-tun0-bind`.
- Torrents stuck at 0 % with **zero trackers** → 1337x/itorrents DHT reconstruction; memory
  `prowlarr-1337x-trackerless`.

## 4. PTP account health

```bash
/usr/bin/ssh synology 'sudo -n tail -15 /volume2/docker-ssd/logs/ptp_ratio.log'
```

**PASS**: a run stamped within the last 24 h; `ratio` ≥ 2.0; `Leak … <= BP-credit earned …
covered, no alert`; the `PTP Freeleech → Deluge` filter state matches what the policy line
dictates (freeleech only under ratio 1.50 with BP at reserve, so normally disabled).

The ratio is expected to **drift down** now: the list backfill downloads ~10 films a day, paid for
in BP rather than upload (2.69 on 09-14 → 2.4969 on 09-22, down +96 GiB, while BP rose to
16.97M at ~188k/day). That is the design working. Judge it by the daily trend, one line per run:

```bash
/usr/bin/ssh synology 'sudo -n grep -E "PTP stats: ratio|BP/day=" /volume2/docker-ssd/logs/ptp_ratio.log | tail -60 | sed -E "s/\[INFO\] //" | cut -c1-130'
```

Escalate only if the ratio is on course to cross 2.0 **and** BP is not rising — at that point the
purchase step should be buying credit, and a `no upload purchase needed` line below 2.0 is a bug.

**Flag**: ratio trending *down* month over month, a `Leak … NOT covered` line, BP balance heading
toward the 5M reserve, or BP/day well under ~180k (the seed budget in `deluge_cleanup` Rule 5 trims
seeding to 8 TiB from 2026-09-14, expected to settle income ~180k/day). Since the 2026-09-13 rework
(memory `ptp-freeleech-rework`) list-sourced PTP grabs are the INTENDED, BP-funded intake (bucket
`list`), not a leak; the old leak notes `ptp-ratio-webhook-leak` / `ptp-ratio-search-rss-leak` are
history.

`tail -15` shows one run. **Also scan the whole window for stats-bar parse errors**, because a
run of them dates a PTP Intermission and explains §3 and §5 in one shot (see §5's table):

```bash
/usr/bin/ssh synology 'sudo -n grep -c "Could not parse the PTP stats bar" /volume2/docker-ssd/logs/ptp_ratio.log
sudo -n grep "Could not parse the PTP stats bar" /volume2/docker-ssd/logs/ptp_ratio.log | head -1
sudo -n grep "Could not parse the PTP stats bar" /volume2/docker-ssd/logs/ptp_ratio.log | tail -1'
```

One or two isolated days = transient. A contiguous run of them = PTP was down for that whole
period; report it as an outage window, not as a script fault, and expect the `up` figure either
side of it to be flat (Jul 2026: +3.18 GiB across 13 days, +43.31 GiB the day after recovery).

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
| 1 | PTP Freeleech → Radarr | **absent** — deleted in the 2026-09-13 rework. Its reappearance is a finding |
| 2 | PTP Freeleech → Deluge | disabled (§4's `ptp_ratio.py` toggles it) |
| 3 | PTP → Radarr | disabled |

With filter 1 gone and filter 2 normally disabled, **autobrr stores no new releases at all** —
the newest release sits at the last day filter 1 existed (2026-09-13) and stays there. That is
expected; the release-cadence table below is now only meaningful while filter 2 is enabled.
Film intake is Radarr import lists, visible in §6.

Lifetime push outcomes:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
curl -s -H "X-API-Token: $AUTOBRR_API_KEY" "http://localhost:7474/api/release/stats"; echo'
```

`push_error_count` is the lifetime count of a matched release's **action** failing. It is a
lifetime total that never resets, so **only the delta since last month means anything** — record
the number, don't react to its size.

**The two error paths mean very different things**, so break the count down before judging it:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
curl -s -m 30 -H "X-API-Token: $AUTOBRR_API_KEY" "http://localhost:7474/api/release?limit=500&push_status=PUSH_ERROR" | python3 -c "
import sys, json, collections
d = json.load(sys.stdin)[\"data\"]
byf=collections.Counter(); bym=collections.Counter(); act=collections.Counter(); err=collections.Counter()
for r in d:
    for a in (r.get(\"action_status\") or []):
        if a[\"status\"] != \"PUSH_ERROR\": continue
        byf[r[\"filter\"]] += 1; bym[r[\"timestamp\"][:7]] += 1
        act[a.get(\"action\",\"?\")+\"/\"+a.get(\"type\",\"?\")] += 1
        for x in (a.get(\"rejections\") or []): err[x[:110]] += 1
print(\"by filter:\", dict(byf)); print(\"by month:\", sorted(bym.items())); print(\"action:\", dict(act))
for m,n in err.most_common(6): print(n, m)
"'
```

- **Filter 1 (→ Radarr) and the `autobrr-webhook` container were RETIRED 2026-09-13** (memory
  `ptp-freeleech-rework`). If either reappears, someone re-created it — flag it. Intake is now
  Radarr import lists paced by `ptp_ratio.py` (10 searches/run while BP > 5M reserve); a run log
  line `Backfill PAUSED` or the "PTP bonus points at reserve" email is the new thing to chase.
- **`deluge/DELUGE_V2` errors on filter 2 (→ Deluge) are a missed grab, not a leak** — the
  torrent simply never downloaded. Nothing was over-downloaded, so the ratio is unaffected.

Baseline 2026-08-06: 282 lifetime, **all of them in June 2026, none since**. 276 were filter 2 /
Deluge (222 × `could not connect to client Deluge at host.docker.internal: EOF`) and only 6 were
filter 1, of which ~5 were `could not parse macro … .TorrentImdbId` on releases with no IMDb ID.
So the headline number is dominated by a healed June connectivity fault, not by the leak.

That connectivity is worth re-verifying directly, because filter 2 is normally **disabled** and
therefore never exercises the path — it would only fail once the ratio drops and `ptp_ratio.py`
re-enables it, i.e. exactly when you need it:

```bash
/usr/bin/ssh synology 'sudo /usr/local/bin/docker exec autobrr getent hosts host.docker.internal
sudo /usr/local/bin/docker exec autobrr sh -c "nc -z -w3 host.docker.internal 58846 && echo REACHABLE || echo UNREACHABLE"'
```
**PASS**: resolves to the `host-gateway` address (172.17.0.1, from autobrr's `extra_hosts`) and
port 58846 is `REACHABLE`.

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
echo "--- announces in the last 4000 log lines ---"
lp=$(sudo /usr/local/bin/docker inspect -f "{{.LogPath}}" autobrr)
sudo -n sh -c "tail -n 4000 $lp" | grep -c "got message"'
```

> Do **not** use `docker logs --since 1h autobrr | grep` here — the `db` log driver makes it slow
> enough to drop the ssh connection (see §0). Read the log file directly, as above.

`PassThePopcorn connected=True healthy=True`, `#ptp-announce monitoring=True`, and a healthy
announce count (**247 per 4000 lines on 2026-08-06**) = the feed is fine *now*. Zero-release days
are then usually a **freeleech drought** — normal and outside your control, PTP freeleech arrives
in waves.

**But rule out an Intermission before calling a long zero-run a drought.** The 2026-07-18 → 07-31
gap was originally recorded here as a drought; it was not. PTP was **down for about two weeks**
(Intermission), which is why nothing was announced. The tell is that a site-wide outage moves
three signals at once, and each one alone looks like a different local fault:

| Signal during Jul 18–29 | Looks like | Actually |
|---|---|---|
| autobrr: 0 releases | freeleech drought | nothing to announce |
| `ptp_ratio.log`: 12 × `Could not parse the PTP stats bar (page layout changed?)` | PTP changed their HTML | maintenance page, not the site |
| PTP upload credit: **+3.18 GiB in 13 days**, then +43.31 GiB the day after | seeding/announce fault (cf. `ptp-hnr-after-outage`) | no tracker to announce to |

Check `ptp_ratio.log` for a run of stats-bar parse errors covering the same dates — that is the
cheapest Intermission confirmation, and §4 reads that log anyway. Note the trap: **that
cross-check is itself broken during the outage**, so a silent `ptp_ratio` proves nothing; look for
the *errors*, not for health. Upload credit flatlining across the window is the corroborating
number.

Note the asymmetry: this proves the feed is healthy **now**, and — as far back as the log
reaches — that announces were arriving while zero releases matched. It cannot prove anything
about a zero run older than the container's last recreation (see §0). For 2026-07-18→31, only
Jul 28 onward was verifiable this way. Say which part you actually verified.

**Only escalate a zero run when** `connected=False`, `monitoring=False`, or the last-hour
announce count is 0 — *and* the Intermission check above came back clean. Otherwise it is the
IRC feed, and the filter is starved.

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
LIDARR_API_KEY=$(sudo -n sed -n "s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p" /volume2/docker-ssd/lidarr/config.xml)
for x in "radarr:7878:v3:$RADARR_API_KEY" "sonarr:8989:v3:$SONARR_API_KEY" "lidarr:8686:v1:$LIDARR_API_KEY" "prowlarr:9696:v1:$PROWLARR_API_KEY"; do
  n=${x%%:*}; rest=${x#*:}; p=${rest%%:*}; rest=${rest#*:}; v=${rest%%:*}; k=${rest#*:}
  echo "--- $n ---"; curl -s -H "X-Api-Key: $k" "http://localhost:$p/api/$v/health"; echo
done'
```

`[]` for all four = **PASS** (verified 2026-09-22). Lidarr has no key in `.env`; the command
reads it from its `config.xml`.

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
for r in d[\"records\"][:10]:
    print(\" \",r.get(\"status\"),r.get(\"trackedDownloadStatus\"),r.get(\"trackedDownloadState\"),(r.get(\"title\") or \"\")[:55], r.get(\"added\",\"\")[:16])
    for m in r.get(\"statusMessages\") or []: print(\"     \", m.get(\"messages\"))
"
done'
```

**Radarr PASS**: `downloadFolderImported` events on most days (import lists + the §4 backfill
land daily), queue near 0, and every `grabbed` followed by an import.

**Sonarr PASS**: activity clustered around actual show releases — **gaps of a week or more are
expected out of season and are not a finding.** Judge Sonarr by "did the shows I follow that
aired this month get imported", not by daily cadence. An occasional `downloadFailed` followed by
a successful re-grab is the system working (Radarr/Sonarr failed-redownload).

**`downloadFailed` with message `Manually marked as failed` on an episode that has not aired yet**
is `deluge_cleanup --arr-guard` rejecting a pre-air fake (memory `fake-mislabelled-episode-releases`)
— the guard working, not a fault. Check `airDateUtc` before reporting a failed episode grab
(2026-09-22: Slow Horses S06E02/E03 fakes, both caught before air).

A queue item `completed / warning / importBlocked` with *"release was matched to movie by ID.
Manual Import required"* is a one-click manual import in the Radarr UI; report it with its title
and `added` time, it will not clear on its own.

**Flag on either**: queue items stuck in `warning`/`error` `trackedDownloadStatus`, or a
`grabbed` with no matching import within ~24 h.

Prowlarr indexers:

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a;
echo "--- failing indexers ---"
curl -s -H "X-Api-Key: $PROWLARR_API_KEY" "http://localhost:9696/api/v1/indexerstatus"; echo
echo "--- 30d stats ---"
S=$(date -u -d "-30 days" +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -v-30d +%Y-%m-%dT00:00:00Z); E=$(date -u +%Y-%m-%dT00:00:00Z)
curl -s -m 30 -H "X-Api-Key: $PROWLARR_API_KEY" "http://localhost:9696/api/v1/indexerstats?startDate=$S&endDate=$E" | python3 -c "
import sys, json
rows = json.load(sys.stdin)[\"indexers\"]
print(\"%-20s %5s %5s %7s %8s %6s %6s\" % (\"indexer\",\"q\",\"fail\",\"rss\",\"rssfail\",\"grabs\",\"avgms\"))
for i in sorted(rows, key=lambda r: -r[\"numberOfQueries\"]):
    print(\"%-20s %5d %5d %7d %8d %6d %6d\" % (i[\"indexerName\"], i[\"numberOfQueries\"], i[\"numberOfFailedQueries\"], i[\"numberOfRssQueries\"], i[\"numberOfFailedRssQueries\"], i[\"numberOfGrabs\"], i[\"averageResponseTime\"]))
"'
```

`/indexerstatus` lists only indexers Prowlarr has **backed off**; each entry carries
`disabledTill` / `initialFailure`. **PASS** = empty, or one transient public tracker.

**Flag**: PassThePopcorn appearing there (that's the one that matters), any indexer with
`numberOfFailedQueries` > ~20 % of queries, `averageResponseTime` > ~5000 ms, or an
`initialFailure` more than a few days old — that indexer has been dead all month. Cloudflare-
gated indexers route through `flaresolverr`; if several fail at once, check that container.

## 7. Jellyfin — content freshness

> **Jellyfin 12 (12.1.0 since 2026-09-22) accepts only the `Authorization` header.**
> `X-Emby-Token` and `?api_key=` both return **401** — which reads as "Jellyfin is down" or,
> through `json.load`, as a `JSONDecodeError`. `/health` still answers 200 anonymously. Every
> deployed script already switched (`f5e8be8`); use the same header in every call here:
> `-H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\""`.

```bash
/usr/bin/ssh synology 'set -a; . /volume2/docker-ssd/.env; set +a; A="Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\""
echo "--- counts ---"; curl -s -H "$A" "http://localhost:8096/Items/Counts"; echo
for lib in "Movies:f137a2dd21bbc1b99aa5c0f6bf02a805" "Shows:a656b907eb3a73532e40e44b968d0225" "Youtube:e59b37148e0ff06f0d35b0c3c714e75c"; do
n=${lib%%:*}; id=${lib##*:}; echo "=== $n ==="
curl -s -H "$A" \
 "http://localhost:8096/Items?ParentId=$id&Recursive=true&IncludeItemTypes=Movie,Episode&SortBy=DateCreated&SortOrder=Descending&Limit=60&Fields=DateCreated" \
 | python3 -c "
import sys,json,collections,datetime
d=json.load(sys.stdin)
day=collections.Counter(i[\"DateCreated\"][:10] for i in d[\"Items\"])
newest=max(day); age=(datetime.date.today()-datetime.date.fromisoformat(newest)).days
print(\"newest:\", newest, \"(%dd ago)\" % age, \"| distinct days in last 60 items:\", len(day))
for i in d[\"Items\"][:5]: print(\" \", i[\"DateCreated\"][:16], i.get(\"SeriesName\",\"\"), i[\"Name\"][:50])
"; done'
```

**Take library sizes from `/Items/Counts`, not from `TotalRecordCount`.** In Jellyfin 12 the
`/Items?ParentId=…&Recursive=true` total is wrong — it returned 1649 for a movie library that
holds 3586 (2026-09-22) — and looks like a mass deletion. `MovieCount` should equal Radarr's
`hasFile` count (`/api/v3/movie`, sum of `hasFile`); a gap between the two is the real signal.

Per-library expectations — **these differ deliberately, do not apply one threshold to all**:

| Library | Expected cadence | WARN | FAIL |
|---|---|---|---|
| **Movies** (`MovieCount` ~3600) | near-daily; import lists + backfill land several/day | newest > 3 d old | newest > 7 d old |
| **Youtube** (~520 episodes) | almost every day (tubesync) | newest > 2 d old | newest > 4 d old |
| **Shows** (`EpisodeCount` ~4000) | bursty, follows airing seasons | — | only if §6 shows Sonarr imported episodes that Jellyfin does not have |

A falling `MovieCount` is normal when it tracks Radarr: `space_cleanup.py` deleted 938 films in
August 2026 (3941 → 3586). Only a Jellyfin count *below* Radarr's `hasFile` is a finding.

A Movies or Youtube stall with §5/§9 healthy means the **import/scan** side broke, not the
acquisition side — check the `jellyfin-nfo-refresh` job in §11 and Jellyfin's own errors in §8.

## 8. Jellyfin — playback, transcoding, library errors

**Any transcoding is a finding**, because this NAS cannot hardware-transcode and software
transcoding starves it enough to stall playback mid-episode.

> Until Jellyfin 12 the best evidence was the `FFmpeg.Transcode-*` session logs in
> `jellyfin/config/log/`. **Jellyfin 12 no longer leaves them there** — on 2026-09-22 the
> directory held zero `FFmpeg.*` files and only the last 3 days of `log_*.log` — so a
> `find … FFmpeg.Transcode-*` count of 0 proves nothing. tracearr is now the only source:

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

It has regressed once already: **2026-08-14 → 09-11, 4–22 % weekly**, every transcode (37/37)
from `Jellyfin Desktop` on Michaels MacBook Pro, then 0 % from 09-12 on. Report the first and
last transcode dates (`max(started_at) filter (where is_transcode)`) so a closed episode is not
re-reported as live.

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

Buffering complaints with `pct_tc` at 0 are **not** a server fault — that is CPL powerline link
saturation. Memories `jellyfin-buffering-cpl-saturation`, `lan-latency-wifi-scan-vs-cpl`.

Jellyfin's own error log — **only ~3 days are retained under Jellyfin 12**, so say "last 3 days"
in the report, not 30:

```bash
/usr/bin/ssh synology 'd=/volume2/docker-ssd/jellyfin/config/log
sudo -n ls $d | grep -E "^log_[0-9]+\.log$" | tr "\n" " "; echo
sudo -n sh -c "grep -ohE \"\[ERR\].{0,90}\" $d/log_2*.log" | sed "s/[0-9]\{2,\}//g" | sort | uniq -c | sort -rn | head -12'
```

Known-benign noise (report the counts, do not chase): `EpisodeNfoProvider: Image location`,
`ProviderManager: Error in metadata saver`, `SubtitleResolver: Error getting external streams`.
These come from tubesync NFOs and are cosmetic. New with 12.x: `LibraryManager: Error in
ItemAdded event handler` → `NullReferenceException at LibraryManager.CreateItems` (~30/day on
2026-09-22). Items still appear in the library, so it is cosmetic for now — record the daily
count and escalate only if new items stop showing up in §7.

**Genuinely bad, escalate**: `Error in Directory watcher` / `FileSystemWatcher` bursts — real-time
library monitoring dies silently and the whole library's watcher tears down. Root cause is the
Synology `@eaDir` permission trap; the fix (`group_add: "100"` on the jellyfin service) is already
applied, so a recurrence means it regressed. Memory `jellyfin-eadir-watcher`.

Sanity-check the injected web customisations (they break on Jellyfin updates). They are no longer
standalone `.js` files — they live inside the JS Injector plugin's config:

```bash
/usr/bin/ssh synology 'F=/volume2/docker-ssd/jellyfin/config/plugins/configurations/Jellyfin.Plugin.JavaScriptInjector.xml
sudo -n ls -l $F; sudo -n grep -oE "<(Name|Enabled)>[^<]*</(Name|Enabled)>" $F | paste - -'
```
**PASS**: four entries, all `<Enabled>true</Enabled>` — Recently Watched rows · Latest ungroup
(episodes) · Tag filter · Subtitle resync button. Present-and-enabled does not prove they
*render* on the new version; if a Jellyfin update landed this month, say so and suggest a look
at the home page. Memories `jellyfin-recently-watched`, `jellyfin-latest-ungroup`,
`jellyfin-tag-filter`, `jellyfin-subfix`, `jellyfin-injected-script-stale-cache`.

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
echo "--- queue guard (queue depths, auth, bgutil) ---"; sudo -n cat /volume2/docker-ssd/state/tubesync_queue_guard.json; echo
echo "--- guard log ---"; sudo -n tail -20 /volume2/docker-ssd/logs/tubesync_queue_guard.log'
```

> **Do not query the huey databases directly.** This section used to run
> `docker exec tubesync sqlite3 /config/tasks/huey_net_limited.db "select count(*) …"` — a
> **read-write open of a live SQLite database**, the exact pattern that broke Jellyfin for 5.5 h
> on 2026-09-19 (`~/scripts/CLAUDE.md`, memory `jellyfin-sqlite-shm-deleted`). And `-readonly`
> cannot be added: `sqlite3` in that image is a `python -m sqlite3` shim that rejects the flag.
> The guard already reads all four queues safely every hour — take the depths from
> `queues.<name>.depth` in its state file above.

**PASS**: every `queues.*.depth` 0 (or draining), `stall_passes` 0, `auth.status` `ok`.
`bgutil: repaired` after a container restart is normal — the guard reinstalls the PO-token
provider when the container comes back without it.

The guard runs hourly and reconciles tasks lost to a watchtower-killed container (stale huey lock
+ frozen "running" sentinel). Repeated recoveries in its log = the 4 a.m. image update is killing
in-flight downloads regularly. Memories `tubesync`, `tubesync-watchtower-killed-tasks`.

**Triage the container error count before reporting it.** ~800 matches per 30 days is the normal
floor, and it is almost entirely three known-benign categories:

```bash
/usr/bin/ssh synology 'D=/usr/local/bin/docker; P=/volume1/probe-hc.log
sudo sh -c "$D logs --since 720h tubesync > $P 2>&1"
echo "log starts: $(sudo head -1 $P | cut -c1-80)  ($(sudo wc -l < $P) lines)"
echo "error lines: $(sudo grep -icE "error|exception" $P)"
sudo grep -oiE "(error|exception)[^ ]*" $P | sort | uniq -c | sort -rn | head -8
sudo rm -f $P'
```

If the container was recreated recently the log is short (56 lines on 2026-09-22, after a stack
restart) — report the count as covering that window, not 30 days.

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

**Raising the memory limit cannot fix this** — that is why 2G → 4G did not help. The cleanup
working set is `high − low` = 9,000,000 rows regardless of the cap, so a bigger limit only moves
the failure later.

**Fixed permanently 2026-08-06** by bind-mounting a replacement s6 run script that passes
`--db-high-size 200000 --db-low-size 50000` and drops `--db-enable-archive` (repo:
`~/scripts/tubesync-hat-syslog-run` → `/volume2/docker-ssd/tubesync/s6_overrides/hat-syslog-server-run`).
Store now caps at ~59 MB with a plain daily DELETE. Verify it is still in force:

```bash
/usr/bin/ssh synology '
sudo /usr/local/bin/docker top tubesync -eo pid,args | grep hat-syslog
echo "--- override still matches the repo copy? ---"
sudo -n md5sum /volume2/docker-ssd/tubesync/s6_overrides/hat-syslog-server-run
echo "--- has upstream changed the script we shadow? ---"
sudo /usr/local/bin/docker run --rm --entrypoint cat ghcr.io/meeb/tubesync:latest \
  /etc/s6-overlay/s6-rc.d/hat-syslog-server/run 2>/dev/null | md5sum'
```

**PASS**: the running command shows both size flags and **no** `--db-enable-archive`; the deployed
md5 matches `md5 -q ~/scripts/tubesync-hat-syslog-run` (`d17cb919…` on 2026-09-22). The
*upstream* script read `6fe1c4282e3f40f6c8765a55a297ffa9` on 2026-09-22; if that changes, read
their new script — ours shadows it, so an upstream fix or restructure would be silently ignored.

Diagnostic tell if it ever regresses: `du -sh state/hat/` over a few hundred MB, or any
`syslog.db.NNNN` archive files at all (with `--db-enable-archive` dropped there should be none).

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
`gestdown` (Cloudflare → check `flaresolverr`). A single provider showing
`DownloadLimitExceeded` with a retry timer (`subdl`, 2026-09-22) is a daily quota, not an outage —
note it, don't escalate unless it persists across audits. Wanted counts around 1100–1500 movies /
~1900 episodes are the **expected steady state**, not a backlog to panic over: most of it is fr/ja that no
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

**PASS**: `done` growing month over month (803 on 2026-09-22, +381 in 30 days — a run writes
~16–20 files a day); `failures` around a dozen or fewer; the `providers` snapshot matches the 8
live providers from the Bazarr call above.

`FAILED …: claude exited 143` is SIGTERM — the run was killed from outside, almost always by a
Container Manager or stack restart that day. The DSM `Subtitles` task then shows `Error(1)`. It
is not a translation fault: the lock is an `fcntl.flock`, so it dies with the process, and the
next 08:00 run carries on where this one stopped.

**Flag**:
- `providers` snapshot **≠** live provider list → a provider was added or removed. The script
  auto-resets `provider_baseline` to now on an *addition* (so every language must fail a fresh
  all-provider sweep before being translated). Expect a temporary drop in output; that is
  correct, not broken.
- An old `subtitle_translate.lock` mtime means nothing on its own: the file is never deleted, its
  mtime is when the last run *started*, and the lock itself is an `flock` held only while the
  process lives. A run is dead-and-stuck only if `ps -eo pid,args | grep subtitle_translat[e]`
  shows a process **and** the log has not moved for hours **and** no `claude-cli` container is
  running.
- Rising `failures`. The recurring error shape is `sent 150 blocks, missing [...]` — the model
  dropped cues from a chunk. A few are normal (the script retries); a jump means the `[N]`-block
  protocol is degrading and `CHUNK_CUES` (150) may need lowering. Memory `subtitle-translate`.
- Auth: if the log shows the Claude CLI failing to start, `CLAUDE_CODE_OAUTH_TOKEN` in `.env` has
  expired.

Spot-check that the output is real, not truncated — `done` is keyed `movie:<radarrId>:<lang>`
and each value carries the written file's `path`; pick 2–3 recent ones (sort by `ts`) and verify
the `.fr.srt` / `.ja.srt` has a plausible cue count and actual target-language text:

```bash
/usr/bin/ssh synology 'sudo -n bash -c "f=\"<path from done>\"; ls -l \"\$f\"; grep -c \" --> \" \"\$f\"; sed -n \"1,12p\" \"\$f\""'
```
A file with far fewer cues than the English source, or one containing English text, is a bad
translation that Bazarr is now serving — report it with the specific title.

One more subtitle trap to verify has not regressed: Japanese subs showing up as **Hindi** in
Jellyfin (`.hi` SDH suffix collides with ISO `hi`). Bazarr's `hi_extension` must be `sdh`.
Memory `jellyfin-japanese-as-hindi-subs`.

## 11. Scheduled jobs and the script layer

`/volume2/docker-ssd/scripts/` is the automation layer — ~25 scripts deployed from the `~/scripts`
git repo, run by DSM Task Scheduler as root. **Three questions fail independently**, so ask all
three: **(a)** did each job run, and run cleanly · **(b)** is DSM still configured to run it ·
**(c)** is the code on the NAS the code in the repo.

### 11.1 Job logs — enumerate, never hard-code

```bash
/usr/bin/ssh synology 'cd /volume2/docker-ssd/logs
RE="^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:,.]+ +\[?(ERROR|CRITICAL)\]?( |$)"
SINCE=$(date -d "-30 days" +%F)                              # audit window, computed — nothing to edit
RETIRED=" ptp_bp_tracker ptp_ratio_filter mentour_season_fix radarr_list_filter postgres-backup "  # folded in / replaced
ONEOFF=" btrfs-balance media-cold-copy tubesync_target_schedule_pin "   # hand-run, no task, expected to go stale
NOW=$(date +%s)
for p in $(sudo -n sh -c "ls -1 /volume2/docker-ssd/logs/*.log" | sed "s|.*/||; s|\.log$||" \
           | grep -vE "^icloudpd-sync-[0-9]{8}$|^space_cleanup_needs_manual$"); do
  case "$RETIRED" in *" $p "*) tag="[retired]";; *) tag="";; esac
  case "$ONEOFF"  in *" $p "*) tag="[one-off]";; esac
  age=$(( (NOW - $(sudo -n stat -c %Y "$p.log")) / 3600 ))
  last=$(sudo -n stat -c %y "$p.log" | cut -c1-16)
  days=$(sudo -n grep -E "$RE" "$p.log" 2>/dev/null | cut -c1-10 | awk -v s="$SINCE" "\$1 >= s")
  n=$(printf "%s" "$days" | grep -c .)
  worst=$(printf "%s" "$days" | sort | uniq -c | sort -rn | head -1 | tr -s " ")
  printf "%-30s last=%s %5sh  errs=%-5s worst:%s %s\n" "$p" "$last" "$age" "$n" "${worst:- none}" "$tag"
done'
```

`[one-off]` logs were written by hand-run jobs from the September 2026 disk swap (a btrfs
rebalance, a `/volume1` cold copy that was deliberately interrupted, a one-time tubesync schedule
pin). They have no script in the repo and no DSM task; a stale age on them is correct.

Three traps this command exists to avoid:

1. It must anchor on the **log-level field**, not the word. `deluge_cleanup.log` is full of
   `[INFO] ERROR/RECHECK: …` lines — normal operation, since its whole job is reacting to
   erroring torrents. A naive `grep -c ERROR` reports ~1600 "errors" that are not errors.
2. It must be **scoped to the audit window** and **bucketed by day**. These logs span months, and
   the shape matters far more than the total: 772 errors sounds alarming, but 769 of them landed
   on a single day (2026-07-27) and the rest of the month is 0–3/day. **A spike day is one
   incident to investigate; a steady trickle is background noise.** Always read `worst:` before
   reacting to `errs=`.
3. It must **enumerate the log directory**, not walk a hard-coded list. The list this section
   used until 2026-08-07 named 15 jobs; there were 25 logs. Four live, actively-writing jobs —
   `cwa_ui_patch` · `kindle_calibre_metadata` · `kindle_koreader_status` ·
   `kindle_syncthing_unblock` — were therefore invisible to every audit, and a newly added script
   would have stayed invisible until someone remembered to edit the list. Enumerating inverts
   that: a job you don't recognise shows up as a row, and the only thing needing maintenance is
   the small `RETIRED` allowlist of logs left behind by merged-away scripts.

**A stale log is not automatically a dead job — check whether the script was folded into another
one first.** `radarr_list_filter.log` last moved 2026-06-25 and looks abandoned, but the script is
alive: `space_cleanup.py` `import radarr_list_filter as rlf` and runs its sweep inside the daily
05:00 task, logging to `space_cleanup.log` (`emailed 'NAS daily — list-filter N'`, last hit
2026-07-14). Its own log is a legacy artifact from before the fold, which is why it sits in
`RETIRED`. Confirm the same way before reporting any stale log as a failure:
`sudo -n grep -l <name> /volume2/docker-ssd/scripts/*.py`.

A spike in `deluge_cleanup` specifically (hundreds of `[ERROR] ERROR processing … ` in one run)
is the mass-error signature from §3 — PTP Intermission or a gluetun tunnel drop, which triggers
the script's own systemic-error self-restart. Confirm which, then move on; it is self-healing.

Expected cadence: `databases-backup` daily 03:00 (replaced `postgres-backup` on 2026-09-20 —
Postgres plus the SQLite dbs) · `ptp_ratio` daily 04:00 · `media-precious-sync` daily 04:00 ·
`icloudpd-sync` daily 04:30 · `space_cleanup` daily 05:00 · `jellyfin_cast_rollup` daily ~05:30 ·
`deluge_cleanup` daily 07:00 (plus `--arr-guard` passes every 15 min) · `disk_health_check` daily
07:15 · `ptp_dead_torrents` daily 07:30 · `mentour_rewatch` daily 08:00 · `subtitle_translate`
daily 08:00 (runs for hours) · `recsys` daily 09:00 ·
`jellyfin-nfo-refresh` (+ `youtube_episode_renumber` + `tubesync_members_only_sweep` +
`tubesync_queue_guard`) every 15 min · `container_crash_watcher` continuous ·
one "Kindle Read Sync" task hourly at :05 chaining five scripts
(`kindle_syncthing_unblock` → `kindle_read_sync` → `kindle_koreader_status` →
`kindle_calibre_metadata` → `cwa_ui_patch`) — so those five logs move together, and one of them
lagging the other four means that script is failing, not that the task stopped.
Event-driven or rare: `compose-reconcile`, `acl-guard` (watchdog; its log moves only when DSM
regenerates the reverse-proxy config).

**Flag**: a log whose `age` exceeds its cadence by a wide margin — the DSM task is disabled, or
the script errors before it can write. Cross-check against §11.2 (is a task still configured?)
and §11.3 (is anything still calling it?) before concluding it is dead.

### 11.2 DSM tasks — read the status, not just the state

The old one-liner (`grep -E "Name:|State:" | paste - -`) threw away the most useful field: DSM
records each task's **last exit status**. Parse the whole record instead:

```bash
/usr/bin/ssh synology 'sudo -n /usr/syno/bin/synoschedtask --get 2>&1 | python3 -c "
import sys, re
cur = {}; rows = []
for line in sys.stdin:
    m = re.match(r\"\s*([A-Za-z ]+):\s*(?:\[(.*)\]|(.*))\s*$\", line.rstrip())
    if not m: continue
    k = m.group(1).strip(); v = (m.group(2) if m.group(2) is not None else m.group(3)).strip()
    if k == \"User\" and cur: rows.append(cur); cur = {}
    cur[k] = v
if cur: rows.append(cur)
print(\"%-34s %-9s %-13s %s\" % (\"task\", \"state\", \"status\", \"command\"))
for r in rows:
    print(\"%-34s %-9s %-13s %s\" % (r.get(\"Name\",\"?\")[:34], r.get(\"State\",\"?\"),
                                    r.get(\"Status\",\"-\"), r.get(\"Command\",\"\")[:70]))
"'
```

**PASS**: every enabled script task `Success`. Expected `disabled`: `Personal videos`, `Docker`,
`PTP Archiver` (the last one also carries a stale `Error(1)` — it is disabled, so ignore it).
`Not Available` is normal for DSM's own built-in tasks (snapshots, updater, C2), which never
report a status.

Note the `Command` field is **truncated at 70 chars here and backslash-escaped** for DSM's own
tasks (`\/\u\s\r\/…`). Never grep it for a script name without `tr -d "\\\\"` first, and never
conclude "no task runs this script" from the truncated column — several tasks chain more than
one script (`jellyfin-nfo-refresh.sh` alone invokes three).

### 11.3 Script inventory — repo vs NAS

Nothing else in this document checks that the *code* on the NAS is the code in git. It has
already drifted once: `ptp_ratio.py` on the NAS was the Jun 25 build, missing repo commit
`fc28e48` (Jul 20, "skip run quietly when PTP is in Intermission") — so the graceful Intermission
handling §4 assumes is in place was **never actually deployed**. That is not cosmetic: PTP
Intermissions run for **weeks**, and the undeployed fix is the difference between 12 quiet skips
and the 12 `[ERROR]` days that made §4's log useless as the cross-check §5 was leaning on.
Nothing surfaced the drift for six weeks.

Run this from the **laptop** (it needs both sides):

```bash
cd ~/scripts && {
  for f in *.py *.sh; do printf "%s %s\n" "$(md5 -q "$f")" "$f"; done
  echo "--MARK--"
  /usr/bin/ssh synology 'sudo -n sh -c "cd /volume2/docker-ssd/scripts && md5sum *.py *.sh"' | awk '{print $1, $2}'
} | awk -v laptop="compose_deploy.sh linkcheck.sh podcast_ad_cut.py podcast_ad_deploy.py tubesync-ts-overrides.py" '
  /^--MARK--$/ {side=1; next}
  side==0 {l[$2]=$1; next}
  {n[$2]=$1}
  END {
    split(laptop, L, " "); for (i in L) ok[L[i]]=1
    for (f in l) if (!(f in n) && !(f in ok) && f !~ /_patch\.py$/) print "LOCAL-ONLY  ", f
    for (f in n) if (!(f in l))                                   print "NAS-ONLY    ", f, "(not in git — unbacked-up)"
    for (f in l) if ((f in n) && l[f] != n[f])                    print "DRIFT       ", f
  }' | sort
```

- **`DRIFT`** — the repo and the NAS disagree. Diff it and establish the direction before doing
  anything: `git -C ~/scripts log --oneline -3 -- <file>` against the NAS copy's mtime. A repo
  that is *ahead* means a fix was committed and never deployed; a NAS copy that is ahead means
  someone hot-fixed in place and it is not backed up. **`compose_deploy.sh` does not deploy
  scripts** — it only handles `docker-compose.yaml`. Scripts go over the base64 pipe, because
  `scp` to this host fails outright (memory `synology-script-deployment`):
  ```bash
  base64 -i ~/scripts/<f>.py | /usr/bin/ssh synology \
    'base64 -d > /tmp/<f>.py && sudo -n cp /tmp/<f>.py /volume2/docker-ssd/scripts/<f>.py'
  ```
  Then re-run the md5 block above to confirm. Deploying is a *change*, so propose it in the
  report rather than doing it — §11 is read-only like everything else here.
- **`NAS-ONLY`** — running code that exists nowhere in git. Pull it back into `~/scripts` and
  commit it. Baseline is now **empty**: the one instance, `subtitle_credit_sweep.py`, was
  committed 2026-08-07 (`de8cca4`). Note what it turned out to be, because the same judgement
  recurs — a **completed one-off migration**, not a job that stopped. It backfilled the AI-credit
  cue into subtitles written before `subtitle_translate.py` began inserting it inline
  (`AI_CREDIT`, `subtitle_translate.py:389`). Such a script belongs in git (it edited the live
  library; that edit needs a record) but must **not** be scheduled or given a log — that would
  present a finished migration as a running job and guarantee a false "stale log" finding every
  month afterwards. Commit it, mark it in the header, and let §11.3 list it as an expected orphan.
- **`LOCAL-ONLY`** — normally fine. The `laptop=` allowlist covers the scripts that run on the
  MacBook by design (`compose_deploy.sh`, `linkcheck.sh`, the `/podcast-ad-cut` pair
  `podcast_ad_cut.py` / `podcast_ad_deploy.py`), plus `tubesync-ts-overrides.py`, which *is*
  deployed but under another name — to `tubesync/settings_overrides/ts_overrides.py`; compare it
  by hand with `md5sum` there. `*_patch.py` covers the one-shot Kindle patches. Anything else
  appearing here is a script you wrote and never deployed. (Mac-side tools like `borg-backup.sh`
  now live in chezmoi, not here.)
- **`DRIFT` on `subtitle_credit_sweep.py` is expected** — the repo copy gained a header note
  after the one-off ran (`de8cca4`), and a finished migration is not worth redeploying.

Then the reachability question — is each deployed script actually invoked by *something*, either
a DSM task or another script?

```bash
/usr/bin/ssh synology 'D=/volume2/docker-ssd/scripts
sudo -n /usr/syno/bin/synoschedtask --get 2>&1 | tr -d "\\\\" > /tmp/_t.txt
for s in $(sudo -n sh -c "ls -1 $D/*.py $D/*.sh" | sed "s|.*/||"); do
  hit=$( { cat /tmp/_t.txt; sudo -n sh -c "grep -h . \$(ls $D/*.py $D/*.sh | grep -v /$s\$)"; } | grep -c "$s" )
  [ "$hit" -eq 0 ] && echo "ORPHAN $s"
done; rm -f /tmp/_t.txt'
```

**The `grep -v /$s$` is the whole trick** — without it every script matches its own name (in a
docstring, a log path, an `argparse` prog) and the check reports exactly one orphan and looks
like it passed. Note it also counts *module imports*, not just shell invocations, which is what
keeps `radarr_list_filter.py` correctly off the list (§11.1).

An `ORPHAN` is deployed code nothing calls. Baseline 2026-09-22 is **six, all expected**:
`tracearr_playback_audit.py` (run by hand / §13) · `tracearr_plex_backfill.py` (one-off
2016–2026 import) · `subtitle_credit_sweep.py` (one-off AI-credit backfill, see above) ·
`kindle_syncthing_relay.py` (a container entrypoint, not a scheduled job) ·
`jellyfin_nfo_pin.py` (hand-run fix for mis-identified movies, memory
`jellyfin-movie-misidentification`) · `jellyfin_task_triggers.py` (hand-run `--disable` /
`--restore` / `--status` of Jellyfin's library-scan tasks, used to park them during a RAID
rebuild). `ptp_dead_torrents.py` left the list when it got its own daily 07:30 task.

For `jellyfin_task_triggers.py` specifically, confirm the tasks are **not still parked** — a
forgotten `--disable` silently stops library scans, trickplay and intro detection:

```bash
/usr/bin/ssh synology 'sudo -n env ENV_FILE=/volume2/docker-ssd/.env python3 /volume2/docker-ssd/scripts/jellyfin_task_triggers.py --status 2>&1 | tail -9'
```
**PASS**: all six tasks show `1 trigger(s)` and `backup: none` (no parked state waiting to be
restored).

So a bare orphan is not a finding here. The finding to chase is the combination **orphan + a log
that used to move and stopped** — a job that silently died — or **orphan + `NAS-ONLY`**, which is
untracked code of unknown provenance.

Two specific logs worth reading rather than counting:

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
sudo -n sh -c "ls -lat /volume2/docker-ssd/postgres-dumps/*.sql.gz | head -5; echo dumps=\$(ls /volume2/docker-ssd/postgres-dumps/*.sql.gz | wc -l)"
echo "--- last run ---"; sudo -n tail -9 /volume2/docker-ssd/logs/databases-backup.log | cut -c1-160'
```

**PASS**: today's `dump-YYYYMMDD.sql.gz` present, ~170 MB, ~30 files retained, size **stable or
growing** — a sudden shrink means a database dropped out of `pg_dumpall`; and the
`databases-backup.log` run ends `=== finished, all databases backed up ===` with one `OK:` line
per SQLite db (jellyfin, introskipper, autobrr, tautulli, wizarr, calibre →
`sqlite-dumps/<db>-YYYYMMDD.db.gz`). This job replaced `postgres-backup.sh` on 2026-09-20, which
is why that log stops on 09-19. Background: memory `sqlite-backup-vs-snapshots`.

Expect a **one-time ~70 MB drop in the dump size** after 2026-09-22: the `jellystat` database
was dropped when jellystat was retired. A drop of that size in the following dump is that, not a
lost database. Its final standalone dump is archived at
`/volume2/docker-ssd/jellystat/jellystat-final-20260922.sql.gz`.

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
   Fix in **System Settings → General → Login Items & Extensions → Allow in the Background** —
   but **the entry is listed as `caffeinate`, not as anything resembling "borg"**. macOS derives
   the display name from the plist's `ProgramArguments[0]`, which here is `/usr/bin/caffeinate`
   (used to hold the Mac awake during the backup). It sits under "Unknown Developer" with no hint
   of what it does, which is exactly why it gets switched off by mistake and why searching the
   list for "borg" finds nothing. Confirm you have the right row — it is the only `caffeinate`
   entry, and the only `disallowed` one besides Canon's `CIJSULAgent`:
   ```bash
   sfltool dumpbtm 2>/dev/null | grep -E "^ +Name:|^ +Disposition:" | paste - - | grep -i caffeinate
   ```
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

The audit covers everything since 2026-06-03, so read its dates, not its total. Its "LOST plays"
count is dominated by one known artefact: **the same title "finished" roughly hourly by one
client** (FrancoisW / *Amélie* / MacBook-Air-de-Francois, 179 rows 2026-08-26 → 09-04) is a
forgotten paused player generating phantom sessions (memory `jellyfin-zombie-session-kill`), not
lost viewing. Bucket the rows by day (`grep -oE "^  2026-[0-9-]+" | sort | uniq -c`) and report
only the genuine ones inside the audit window — 3 since 09-05 on 2026-09-22.

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
| 1 | Containers | ✅ | 32 up, 0 restarts, 0 unhealthy, 0 on `db` log driver |
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

## 15. Baseline (recorded 2026-09-22)

Compare against this; if the stack has legitimately moved on, update these numbers. The first
baseline (2026-08-06) is kept below the table where a trend needs its "before" value.

| Signal | Value |
|---|---|
| Containers running | 32 (+ transient `claude-cli` one-shots). jellystat retired 2026-09-22 |
| Restart counts / exited | 0 / none. Log drivers: all `json-file` |
| `/volume1` · `/volume2` | **61 % of 37T** (was 90 % of 27T before the Sep 2026 disk swap) · 8 % of 1.8T |
| RAID | md2 `[6/6] [UUUUUU]` · md4 `[3/3] [UUU]` |
| Mem · swap · load | 4.8/31 Gi · 0.45/20 Gi · CPU 0.19 |
| VPN exit | NL, AS49453 Global Layer, 213.152.161.153 (the /24 rotates; the ASN is the check) |
| Deluge | 1524 torrents, **all Seeding**, 0 Error, 2 tracker-Error, incoming=1, tun0/tun0, port 55364 (seed budget trimmed it from 1898) |
| PTP | ratio 2.4969 (falling from 2.69 on 09-14 by design — list backfill), up 2990 / down 1198 GiB, **BP 16.97 M at 188.6k/day**, leak covered |
| autobrr filters | 1 **absent** (retired) · 2 disabled · 3 disabled. Newest stored release 2026-09-13 |
| autobrr lifetime | total 3774 · push_approved 3524 · push_error 282 (all June 2026, unchanged) · filter_rejected 0 |
| autobrr IRC | PTP connected+healthy, #ptp-announce monitored, 75 announces / 4000 log lines (log was ~1 h old) |
| Radarr / Sonarr / Lidarr / Prowlarr health | `[]` ×4 |
| Radarr history · queue | 11625 lifetime · 1 queued (manual-import block) |
| Sonarr history · queue | 4551 lifetime, last import 2026-09-21 · 0 queued |
| Prowlarr backed-off indexers | 0. Busiest: Nyaa 427 q, PTP-Freeleech 336, Torrent9 324 (4 fail), TPB 297 — all < 1.3 s |
| Jellyfin | 12.1.0. `/Items/Counts`: **Movies 3586** (= Radarr hasFile) · Episodes 4017 · Series 157 · Youtube lib 522 |
| Jellyfin errors (3 d) | 99 `ItemAdded` NullReference (new in 12.x) · 38 metadata saver · 19 SubtitleResolver · 0 watcher |
| tracearr weekly `pct_tc` | 0.9 → 3.9 → 5.4 → **18.6 → 11.3 → 22.2** → 11.6 → 0 → 0 (Aug 14–Sep 11 regression, MacBook Pro Desktop client; clean since 09-12) |
| tracearr 30 d | no zero days, 2–25 plays/day, 1–2 users · chunks 15 · 0 backfill rows |
| tracearr audit | 189 "lost" since June; 179 = the FrancoisW zombie player (08-26 → 09-04); 3 genuine since 09-05 |
| tubesync | 15 sources, 0 `ready`, 0 `needs_meta`, 3–4 downloads/day · guard queues all 0, auth ok, 22 cookies |
| tubesync memory | 947 MiB / 4 GiB (23 %), CPU 0.4 % · 0 kernel OOM kills |
| `state/hat/` | 63 MB, single `syslog.db`, no archives · override md5 `d17cb919…` = repo · upstream run md5 `6fe1c428…` |
| Laptop borg | ✅ `caffeinate` row `allowed`; hourly, last 2026-09-22 14:00 exit 0; NAS index 14:00 |
| chezmoi | status clean; last autocommit 2026-09-21 |
| Compose staleness | 1 of 32 (was 20 of 33 — the 09-22 Container Manager restart and json-file recreates reset most labels) |
| Bazarr | 7 Good + `subdl` quota-limited; wanted 1134 movies / 1910 episodes · `hi_extension=sdh` |
| AI subtitles | done 803 (+381 in 30 d), failures 11, 8-provider snapshot |
| Database dumps | `dump-20260922.sql.gz` 170 MB, 27 retained + 6 SQLite dumps (`databases-backup.sh`). Expect ~−70 MB once jellystat's db is gone |
| Scheduled-job errors (30 d) | all 0–4 except `subtitle_translate` 40 (worst 8 on 09-13; chunk-drop retries). 09-22 fallout from the CM restart: deluge_cleanup 4, recsys + Subtitles tasks `Error(1)` |
| Job logs enumerated | 31 basenames (excl. rotated `icloudpd-sync-*`): 5 `RETIRED`, 3 `one-off` |
| DSM tasks | 33 total; disabled: `Personal videos`, `Docker`, `PTP Archiver`, old `Synology C2` ×2, `Share [docker] Snapshot` |
| Scripts deployed | 30 in `/volume2/docker-ssd/scripts/` |
| Script drift | 1 `DRIFT`, expected (`subtitle_credit_sweep.py` header) · 0 `NAS-ONLY` · 3 `LOCAL-ONLY`, all allowlisted |
| Script orphans | 6, **all expected** (see §11.3) · Jellyfin scan tasks restored (`backup: none`) |

First baseline, 2026-08-06, for trend context: /volume1 90 % of 27T · Deluge 1898 torrents · PTP
ratio 2.4761, BP 8.86 M · Radarr 9486 lifetime · Jellyfin Movies 3941 · tracearr `pct_tc`
45.7 → 56.4 → 8.8 → 0.9 → 1.8 around the 2026-07-21 fix · AI subtitles 102 done · compose
staleness 20 of 33 · the **PTP Intermission 2026-07-18 → 07-29** (12 stats-bar parse errors,
+3.18 GiB upload in 13 days, autobrr silent; recovered on its own).

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
`postgres-mediastack-role` · `borg-backup-cpl-throttle` · `docker-db-logdriver-wedge` · `jellyfin-sqlite-shm-deleted` · `sqlite-backup-vs-snapshots` · `fake-mislabelled-episode-releases` · `jellyfin-zombie-session-kill` · `reverse-proxy-acl-guard` · `uptimerobot`
