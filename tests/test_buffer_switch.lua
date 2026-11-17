-- Opens $PDFVIEW_TEST_PDF the way oil.nvim does (bufadd, then :buffer) from a
-- longer buffer with the cursor low down, so the window's '' mark lies past the
-- end of the PDF text. The page view must still render. Exits non-zero on failure.
local api = vim.api
vim.opt.rtp:prepend(vim.fn.getcwd())
local errors, shows = {}, 0
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
end
local kitty = require 'pdfview.kitty'
kitty.supported = function() return true end
kitty.cell_size = function() return { width = 10, height = 20 } end
kitty.show = function(png)
  os.remove(png)
  shows = shows + 1
  return shows
end
kitty.delete = function() end
require('pdfview').setup()
local pdf = vim.env.PDFVIEW_TEST_PDF
vim.cmd.enew()
local lines = {}
for i = 1, 50 do
  lines[i] = 'line ' .. i
end
api.nvim_buf_set_lines(0, 0, -1, false, lines)
api.nvim_win_set_cursor(0, { 50, 0 })
vim.cmd.buffer(vim.fn.bufadd(pdf))
vim.wait(15000, function() return shows > 0 or #errors > 0 end)
if #errors > 0 or shows == 0 then
  io.stderr:write(('shows %d, errors: %s\n'):format(shows, vim.inspect(errors)))
  vim.cmd 'cquit!'
end
io.stdout:write 'Page view rendered\n'
vim.cmd 'qa!'
