#!/bin/bash
set -euo pipefail

BREWFILE="$(chezmoi source-path)/bootstrap/Brewfile"
brew bundle install --file="$BREWFILE" --no-lock
