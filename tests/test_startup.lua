-- Run with --cmd before startup opens the PDF given on the command line: Neovim's
-- startup returns to the first window after the PDF is covered, and the page
-- view must take focus back. Exits non-zero on failure.
local api = vim.api
vim.opt.rtp:prepend(vim.fn.getcwd())
local kitty = require 'pdfview.kitty'
kitty.supported = function() return true end
kitty.cell_size = function() return { width = 10, height = 20 } end
kitty.show = function(png)
  os.remove(png)
  return 1
end
kitty.delete = function() end
require('pdfview').setup()
local deadline = vim.uv.now() + 15000
local function check()
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_config(win).hide then
    io.stdout:write 'Startup focus is in the page view\n'
    return vim.cmd 'qa!'
  end
  if vim.uv.now() > deadline then
    io.stderr:write(('focus stayed in window %d (%s)\n'):format(win, vim.inspect(api.nvim_win_get_config(win))))
    return vim.cmd 'cquit!'
  end
  vim.defer_fn(check, 50)
end
api.nvim_create_autocmd('VimEnter', { callback = function() vim.defer_fn(check, 500) end })
