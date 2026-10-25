-- Reproduce the user's LazyVim UI with isolated, pinned plugin snapshots.
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/lazy.nvim")
require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = "lazyvim.plugins.extras.coding.mini-snippets" },
    { "saghen/blink.cmp", opts = { fuzzy = { implementation = "lua" } } },
    { "nvim-treesitter/nvim-treesitter", build = false, opts = function(_, o) o.ensure_installed = {} o.auto_install = false end },
    { "mason-org/mason.nvim", build = false, opts = function(_, o) o.ensure_installed = {} end },
    { "folke/snacks.nvim", opts = { picker = { sources = {
      explorer = { hidden = true, ignored = true }, files = { hidden = true, ignored = true },
    } } } },
    { "christoomey/vim-tmux-navigator", lazy = false, keys = {
      { "<c-h>", "<cmd>TmuxNavigateLeft<cr>" }, { "<c-j>", "<cmd>TmuxNavigateDown<cr>" },
      { "<c-k>", "<cmd>TmuxNavigateUp<cr>" }, { "<c-l>", "<cmd>TmuxNavigateRight<cr>" },
    } },
  },
  checker = { enabled = false },
  change_detection = { enabled = false },
  defaults = { version = false },
})
