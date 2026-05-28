return {
  {
    "nvim-neotest/neotest",
    dependencies = {
      "nvim-neotest/nvim-nio",
      "nvim-lua/plenary.nvim",
      "antoinemadec/FixCursorHold.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    config = function()
      require("neotest").setup({
        adapters = {
          require("neotest-python")({}),
        },
      })
    end,
    keys = {
      { "<leader>dm", "<cmd>lua require('neotest').run.run()<cr>", desc = "Test Method" },
      { "<leader>dM", "<cmd>lua require('neotest').run.run({strategy = 'dap'})<cr>", desc = "Test Method DAP" },
      { "<leader>df", "<cmd>lua require('neotest').run.run({vim.fn.expand('%')})<cr>", desc = "Test Class" },
      {
        "<leader>dF",
        "<cmd>lua require('neotest').run.run({vim.fn.expand('%'), strategy = 'dap'})<cr>",
        desc = "Test Class DAP",
      },
      { "<leader>dS", "<cmd>lua require('neotest').summary.toggle()<cr>", desc = "Test Summary" },
      { "<leader>dl", "<cmd>lua require('coverage').load(true)<cr>", desc = "Load Test Coverage" },
      { "<leader>dv", "<cmd>lua require('coverage').toggle()<cr>", desc = "Toggle Test Coverage" },
      { "<leader>de", "<cmd>lua require('neotest').output.open()<cr>", desc = "Toggle Test Output" },
      {
        "<leader>dE",
        "<cmd>lua require('neotest').output.open({ enter = true })<cr>",
        desc = "Toggle Test Output And Enter",
      },
    },
  },
  { "nvim-neotest/neotest-python" },
}
