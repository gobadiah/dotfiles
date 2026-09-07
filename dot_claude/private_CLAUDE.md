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
