#!/bin/bash
set -euo pipefail

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

clone_if_missing() {
  local dest="$1" url="$2"
  [[ -d "$dest" ]] || git clone --depth=1 "$url" "$dest"
}

clone_if_missing "$ZSH_CUSTOM/themes/powerlevel10k"        https://github.com/romkatv/powerlevel10k
clone_if_missing "$ZSH_CUSTOM/plugins/zsh-autosuggestions" https://github.com/zsh-users/zsh-autosuggestions
clone_if_missing "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" https://github.com/zsh-users/zsh-syntax-highlighting
clone_if_missing "$ZSH_CUSTOM/plugins/zsh-completions"     https://github.com/zsh-users/zsh-completions
clone_if_missing "$ZSH_CUSTOM/plugins/history-search-multi-word" https://github.com/zdharma-continuum/history-search-multi-word
