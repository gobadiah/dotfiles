#!/bin/bash
set -euo pipefail

eval "$(rbenv init -)"

LATEST=$(rbenv install --list 2>/dev/null | grep -E "^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+$" | tail -1 | tr -d ' ')

if ! rbenv versions --bare | grep -qx "$LATEST"; then
  RUBY_CONFIGURE_OPTS="--with-openssl-dir=$(brew --prefix openssl@3)" rbenv install "$LATEST"
  rbenv global "$LATEST"
fi

gem install neovim --no-document 2>/dev/null || true
