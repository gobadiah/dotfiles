#!/bin/bash
set -euo pipefail

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

PYTHON3=$(pyenv install --list | grep -E "^  3\.[0-9]+\.[0-9]+$" | tail -1 | tr -d ' ')

if ! pyenv versions --bare | grep -qx "$PYTHON3"; then
  pyenv install "$PYTHON3"
fi

if ! pyenv versions --bare | grep -qx "neovim3"; then
  pyenv virtualenv "$PYTHON3" neovim3
fi

PYENV_VERSION=neovim3 pip install --quiet pynvim
