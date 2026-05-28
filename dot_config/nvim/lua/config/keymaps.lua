-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- First, remove the default LazyVim mapping for <leader>/
-- (which runs Telescope live_grep)
pcall(vim.keymap.del, "n", "<leader>/")

require("mini.comment").setup({
  mappings = {
    comment = "<Leader>/",
    comment_visual = "<Leader>/",
    comment_line = "<Leader>/",
  },
})
