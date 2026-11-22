-- Invoked by test_html_helper.py with a writable local HTML document. The file is
-- one buffer that follows changes on disk and :e!, and :HtmlSource / :HtmlView
-- switch that same buffer between the source and the rendered view.
local api = vim.api
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd 'filetype on'
vim.o.columns, vim.o.lines = 80, 24
local kitty = require 'pdfview.kitty'
kitty.supported = function() return true end
kitty.cell_size = function() return { width = 18, height = 37 } end
kitty.show = function(path)
  os.remove(path)
  return 1
end
kitty.delete = function() end
local errors = {}
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
end
require('pdfview').setup()
local path = vim.env.PDFVIEW_TEST_HTML

local function write(body)
  local f = assert(io.open(path, 'w'))
  f:write('<!doctype html><title>t</title>' .. body)
  f:close()
end
local function fail(msg)
  io.stderr:write(msg .. '\n' .. table.concat(errors, '\n') .. '\n')
  vim.cmd 'cquit!'
end
local function check(cond, msg)
  if not cond then fail(msg) end
end
local function wait(label, pred)
  if not vim.wait(15000, function()
    local ok, res = pcall(pred)
    return ok and res
  end, 20) then fail(label .. ': timed out') end
end
local function viewing()
  local buf = api.nvim_get_current_buf()
  return vim.bo[buf].filetype == 'htmlview' and api.nvim_win_get_config(0).hide
end
local function first_line() return api.nvim_buf_get_lines(0, 0, 1, false)[1] end
local function listed() return #vim.fn.getbufinfo { buflisted = 1 } end

write '<h1>One</h1><p>first paragraph</p>'
vim.cmd.edit(vim.fn.fnameescape(path))
local buf = api.nvim_get_current_buf()
wait('open the rendered view', viewing)
check(first_line() == 'One', 'rendered text: ' .. vim.inspect(first_line()))
check(listed() == 1, 'one buffer per file, got ' .. listed())
check(vim.fn.resolve(api.nvim_buf_get_name(buf)) == vim.fn.resolve(path), 'the buffer is the file')

write '<h1>Two</h1><p>second paragraph</p><p>more paragraph</p>'
wait('reload after a change on disk', function() return first_line() == 'Two' end)

write '<h1>Three</h1><p>third paragraph</p>'
vim.cmd 'edit!'
check(first_line() == 'Three', ':e! reloads: ' .. vim.inspect(first_line()))
api.nvim_feedkeys('/paragraph\r', 'xt', false)
vim.wait(500)
check(#errors == 0, 'no errors after :e! and a search')

vim.cmd 'HtmlSource'
check(api.nvim_get_current_buf() == buf and listed() == 1, ':HtmlSource keeps the one buffer')
check(vim.bo[buf].filetype == 'html' and vim.bo[buf].buftype == '' and vim.bo[buf].modifiable, 'source is a normal HTML buffer')
check(api.nvim_buf_get_lines(buf, 0, -1, false)[1] == '<!doctype html><title>t</title><h1>Three</h1><p>third paragraph</p>', 'source text')
wait('the view closes', function() return not api.nvim_win_get_config(0).hide end)

api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved' })
vim.cmd 'HtmlView'
check(#errors == 1 and errors[1]:match 'E37', ':HtmlView refuses unsaved source: ' .. vim.inspect(errors))
check(vim.bo[buf].filetype == 'html', 'still the source after the refusal')
errors = {}
vim.cmd 'HtmlView!'
wait('back to the rendered view', viewing)
check(api.nvim_get_current_buf() == buf and first_line() == 'Three', ':HtmlView! drops the edit and renders the file')
check(#errors == 0, 'no errors')
io.stdout:write 'HTML reload passed\n'
vim.cmd 'qa!'
