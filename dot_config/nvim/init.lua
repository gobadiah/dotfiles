-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")

-- disable perl
vim.g.loaded_perl_provider = 0

-- python
vim.g.python3_host_prog = "/Users/michaeljourno/.pyenv/versions/neovim3/bin/python"
