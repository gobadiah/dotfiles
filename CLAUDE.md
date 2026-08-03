# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal dotfiles managed with [chezmoi](https://www.chezmoi.io/). The source directory is `~/.local/share/chezmoi/` (this repo). Running `chezmoi apply` writes managed files to `$HOME`.

## Daily Commands

```bash
chezmoi edit ~/.zshrc                          # edit a file and apply
chezmoi add ~/.config/nvim/lua/plugins/foo.lua # track a new file
chezmoi add --recursive ~/.config/nvim         # track a directory tree
chezmoi diff                                   # preview what would change
chezmoi apply                                  # apply all pending changes
chezmoi update                                 # git pull + apply
chezmoi cd                                     # open shell in source dir
```

## File Naming Conventions

- `dot_` prefix → `.` in `$HOME` (e.g. `dot_zshrc` → `~/.zshrc`)
- `private_` prefix → `chmod 600` on the target
- `.tmpl` suffix → Go template, rendered before writing
- Files in `bootstrap/` are ignored by chezmoi apply (listed in `.chezmoiignore`) — they are run manually or at init time

## Secrets

`private_dot_zshenv.local.tmpl` reads all API keys from 1Password at `op://Personal/Dotfiles/*`. Running `chezmoi apply` calls `op` for each secret and writes `~/.zshenv.local` with `600` permissions. The keys themselves are never committed.

To update a secret: update it in 1Password, then run `chezmoi apply`.

## Autocommit and Drift

`~/.local/bin/chezmoi-autocommit` runs nightly at 23:00 via
`Library/LaunchAgents/com.gobadiah.chezmoi-autocommit.plist`. It runs `chezmoi re-add`,
then commits and pushes.

Because of that `re-add`, **the target wins**: edits made directly in `$HOME` are pulled back
into the source dir automatically. This is deliberate — edits in `$HOME` are the ones made
without thinking about chezmoi, whereas source edits are inert until `chezmoi apply`. The
consequence: a source edit left unapplied for a day will be reverted to match the live file.
Apply source edits promptly.

Templates are never re-added, so 1Password secrets are not baked into the repo. The `re-add`
is wrapped in `timeout 300` because rendering templates calls `op`, which would otherwise
block forever if 1Password is locked at 23:00. Paths inside the script are absolute —
launchd's PATH excludes `/opt/homebrew/bin`.

**The template exception is a trap.** Because templated targets are never re-added, editing one
directly in `$HOME` leaves a change that is never backed up *and* that `chezmoi apply` will
silently revert. This already happened once: `~/.config/borgmatic/config.yaml` had gained an
active `upload_rate_limit: 400` and a `large_files.txt` exclude that existed nowhere in the
source, so an `apply` would have removed borg's upload throttle and saturated the NAS uplink.
Edit templated targets with `chezmoi edit <target>` (which opens the `.tmpl`) followed by
`chezmoi apply`, never in `$HOME`. Persistent drift in `chezmoi status` is the warning sign.

The nightly run raises a macOS notification (same `osascript` helper as `scripts/borg-backup.sh`)
whenever it finds drift `re-add` could not capture, or when `re-add` itself fails or times out.
Both are cases where `$HOME` changes are silently not being backed up.

Machine-local *state* must be kept out of management, or `re-add` commits it nightly. See
`.chezmoiignore` for `.config/borg/security/`.

## Bootstrap (New Mac)

```bash
sh -c "$(curl -fsSL get.chezmoi.io)" -- init --apply gobadiah/dotfiles
op signin && chezmoi apply
```

Then run the bootstrap scripts in order:
```bash
bash ~/.local/share/chezmoi/bootstrap/run_once_01-homebrew.sh
bash ~/.local/share/chezmoi/bootstrap/run_once_02-brew-bundle.sh
bash ~/.local/share/chezmoi/bootstrap/run_once_03-oh-my-zsh.sh
bash ~/.local/share/chezmoi/bootstrap/run_once_04-omz-plugins.sh
bash ~/.local/share/chezmoi/bootstrap/run_once_05-pyenv.sh
bash ~/.local/share/chezmoi/bootstrap/run_once_06-fonts.sh
bash ~/.local/share/chezmoi/bootstrap/run_once_07-ruby.sh
bash ~/.local/share/chezmoi/bootstrap/run_once_08-iterm.sh   # run before launching iTerm2
```

## Shell Configuration

`.zshrc` uses Powerlevel10k theme with Oh My Zsh. Active plugins: git, zsh-autosuggestions, kubectl, zsh-syntax-highlighting, zsh-completions, autojump, history-search-multi-word, uv.

`.zshenv` sets GOPATH, PYENV_ROOT, CDPATH, locale, Cargo, and sources `~/.zshenv.local` for secrets.

## iTerm2 Activity Profiles

Color themes per activity live in `Library/private_Application Support/iTerm2/DynamicProfiles/activities.json`
(→ `~/Library/Application Support/iTerm2/DynamicProfiles/activities.json`). iTerm2 hot-reloads
that folder, so `chezmoi apply` is enough — no restart.

Three profiles (`Personal`, `Work`, `NAS`) share one Challenger Deep palette and inherit font
and keymap from the `Default` profile via `Dynamic Profile Parent Name`. Only the background,
tab color and badge differ, so only the *context* signal changes.

Switch with the `work` / `nas` / `perso` aliases in `.zshrc`, or by profile in `Cmd-O`.
`ssh` is wrapped to switch automatically for hosts listed in `ITERM_HOST_PROFILES`, and to
restore `ITERM_DEFAULT_PROFILE` on disconnect.

## iTerm2 Preferences Backup

`iterm/com.googlecode.iterm2.plist` is iTerm2's custom preferences folder, pointed directly at
this repo (Settings > General > Settings > "Load settings from a custom folder"). It is listed
in `.chezmoiignore`, so chezmoi never applies it to `$HOME` — iTerm reads and writes it in
place, and the autocommit agent picks up the changes.

**"Save changes" must be set to `Automatically`.** The previous setup at
`~/workspace/workstation.bak/files/iterm` (tracked in the `gobadiah/workstation` repo) was set
to `Manually`, so it only saved when "Save Now" was clicked — it silently went stale after
2021-11-21 and accumulated ~4.7 years of unsaved drift. That setting lives under a `NoSync*`
key, so it is itself never backed up and must be re-set by hand on a new machine.

What the custom folder covers: all genuine settings — profiles (colors, fonts, key bindings),
`GlobalKeyMap`, `PointerActions`, AI config, color presets. What it excludes: `NoSync*` UI
state, `Apple*`/`NS*` window geometry, `SU*` updater state, and the two pointer keys
(`PrefsCustomFolder`, `LoadPrefsFromCustomFolder`) — which is why `bootstrap/run_once_08-iterm.sh`
exists to seed those before iTerm's first launch.

`scripts/iterm-snapshot.sh` writes the same filtered snapshot on demand — a fallback if
"Save changes" ever reverts to Manually.

## Neovim

`dot_config/nvim/` is a full lazy.nvim setup. Python host points to `~/.pyenv/versions/neovim3`. Custom plugins live in `lua/plugins/`.
