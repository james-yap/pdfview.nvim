-- No which-key popups in PDF buffers: they hide the page and re-feed keys.
pcall(function()
  local opts = require('which-key.config').options
  opts.disable.ft = { 'pdfview', 'pdfview_page' }
end)

-- Keycast for README recordings only: typed keys appear in the middle of the
-- statusline. Started after the window has its final size and the PDF is open.
vim.defer_fn(function()
  local get = function(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
  local bar, accent = get 'StatusLine', get 'Title'
  local width = 40
  require('screenkey').setup {
    win_opts = {
      row = vim.o.lines - vim.o.cmdheight - 1,
      col = math.floor((vim.o.columns - width) / 2),
      relative = 'editor',
      anchor = 'NW',
      width = width,
      height = 1,
      border = 'none',
      style = 'minimal',
      focusable = false,
      noautocmd = true,
      zindex = 250,
    },
    hl_groups = {
      NormalFloat = { bg = bar.bg },
      Normal = { bg = bar.bg },
      ['screenkey.hl.key'] = { fg = accent.fg, bg = bar.bg, bold = true },
      ['screenkey.hl.map'] = { fg = accent.fg, bg = bar.bg, bold = true },
      ['screenkey.hl.sep'] = { fg = bar.bg, bg = bar.bg },
    },
    clear_after = 3,
    compress_after = 4,
    show_leader = true,
  }
  vim.cmd 'Screenkey toggle'
end, 2500)
