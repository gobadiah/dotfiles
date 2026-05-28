#!/bin/bash
set -euo pipefail

FONTS_DIR="$HOME/Library/Fonts"

# MesloLGS NF — required by powerlevel10k
if ! ls "$FONTS_DIR" | grep -q "MesloLGS"; then
  BASE="https://github.com/romkatv/powerlevel10k-media/raw/master"
  for font in \
    "MesloLGS%20NF%20Regular.ttf" \
    "MesloLGS%20NF%20Bold.ttf" \
    "MesloLGS%20NF%20Italic.ttf" \
    "MesloLGS%20NF%20Bold%20Italic.ttf"; do
    curl -fsSL "$BASE/$font" -o "$FONTS_DIR/${font//%20/ }"
  done
fi
