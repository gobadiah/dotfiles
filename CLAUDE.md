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
```

## Shell Configuration

`.zshrc` uses Powerlevel10k theme with Oh My Zsh. Active plugins: git, zsh-autosuggestions, kubectl, zsh-syntax-highlighting, zsh-completions, autojump, history-search-multi-word, uv.

`.zshenv` sets GOPATH, PYENV_ROOT, CDPATH, locale, Cargo, and sources `~/.zshenv.local` for secrets.

## Neovim

`dot_config/nvim/` is a full lazy.nvim setup. Python host points to `~/.pyenv/versions/neovim3`. Custom plugins live in `lua/plugins/`.
