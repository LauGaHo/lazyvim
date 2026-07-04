local prefix = "<leader>c"

return {
  "barrettruth/live-server.nvim",
  ft = { "html" },
  cmd = { "LiveServerStart", "LiveServerStop", "LiveServerToggle" },
  keys = {
    {
      prefix .. "w",
      "<cmd>LiveServerStart<cr>",
      desc = "Start live server",
    },
    {
      prefix .. "W",
      "<cmd>LiveServerStop<cr>",
      desc = "Stop live server",
    },
  },
}
