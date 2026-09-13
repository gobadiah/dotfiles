- When using the terraform MCP always use the Gobadiah organization, never ubbleai
## Synology NAS (host `synology`)

- **Never use plain `scp`** — it fails with `subsystem request failed on channel 0`.
  DSM gates the SFTP subsystem above sshd (it *is* declared in `/etc/ssh/sshd_config`,
  but Control Panel → File Services → FTP → SFTP is off), so editing sshd_config
  won't help. Don't re-diagnose this each time.
  Use instead, in order of preference:
  - `/usr/bin/rsync -av synology:'/remote/path' ~/dest/`   (rsync 3.1.2 is on the NAS)
  - `/usr/bin/scp -O ...`                                   (legacy SCP protocol)
  - `/usr/bin/ssh synology 'cat "/remote/file"' > local`    (single small file)
- If `ssh` ever fails with `ssh:4: division by zero`, that shell predates the
  2026-09-07 fix to the iTerm profile wrapper in `.zshrc` (it looked up a
  non-associative `ITERM_HOST_PROFILES`, so zsh evaluated the subscript as
  arithmetic and any arg with a `/` became a division). Fall back to
  `/usr/bin/ssh`; new shells are fine.
- Media lives under `/volume1/media/` (`series/`, `torrents/completed/`).
  User `michael` is in `administrators` and has passwordless `sudo`; DSM's `syno*`
  tools are NOT on sudo's PATH — call them by full path (`/usr/syno/bin/...`).
- **PATH over ssh and under sudo is only `/usr/bin:/bin:/usr/sbin:/sbin`.** Anything
  in `/usr/local/bin` therefore does NOT resolve — that includes `docker`,
  `docker-compose`, `git`, `borg`, `tailscale`, `rclone`, `node`, `npm`, `rg`, `fd`,
  `ffmpeg7`, `python3.12`. Call them by absolute path (`/usr/local/bin/docker ps`).
  `rsync`, `python3`, `sqlite3`, `curl`, `jq`, `ffmpeg` and the coreutils are in
  `/usr/bin` and are fine.
  **Scheduled tasks are NOT affected**: cron sets its own PATH in `/etc/crontab`
  (`…:/usr/syno/bin:/usr/local/sbin:/usr/local/bin`), so the ~20 NAS scripts that
  call `docker` bare keep working. The exposure is only interactive/scripted ssh
  from the Mac.
  Noticed 2026-09-13 after the DSM 7.4.1 upgrade, which broke every hourly borgmatic
  run — `borg serve` stopped resolving and borg reported the misleading
  "Connection closed by remote host. Is borg working on the server?" with exit 81.
  Fixed with `remote_path: /usr/local/bin/borg` in the borgmatic config.
