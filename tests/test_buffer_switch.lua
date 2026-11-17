-- Opens $PDFVIEW_TEST_PDF the way oil.nvim does (bufadd, then :buffer) from a
-- longer buffer with the cursor low down, so the window's '' mark lies past the
-- end of the PDF text. The page view must still render. Then opens a buffer in a
-- new tab page from the page view, as vim.pack.update shows its confirmation, and
-- closes it again: no errors, and focus returns to the page view.
-- Exits non-zero on failure.
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
local function fail(msg)
  io.stderr:write(msg .. '\n')
  vim.cmd 'cquit!'
end
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
if #errors > 0 or shows == 0 then fail(('shows %d, errors: %s'):format(shows, vim.inspect(errors))) end

local confirm = api.nvim_create_buf(true, true)
local ok, err = pcall(vim.cmd.sbuffer, { confirm, mods = { tab = vim.fn.tabpagenr() } })
if not ok then fail('opening a tab from the page view: ' .. err) end
if api.nvim_get_current_buf() ~= confirm then fail 'the new tab does not show the requested buffer' end
-- Keys typed in the other tab run the input hook.
api.nvim_feedkeys('j', 'x', false)
vim.wait(200)
api.nvim_buf_delete(confirm, { force = true })
vim.wait(200)
if #errors > 0 then fail('errors: ' .. vim.inspect(errors)) end
if #api.nvim_list_tabpages() ~= 1 or not api.nvim_win_get_config(0).hide then fail 'focus did not return to the page view' end
io.stdout:write 'Page view rendered\n'
vim.cmd 'qa!'
