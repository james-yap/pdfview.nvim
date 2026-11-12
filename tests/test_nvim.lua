-- Invoked by test_helper.py with a generated two-column document and optional Leap runtime.
local api = vim.api
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.PDFVIEW_LEAP_RTP then
  vim.opt.rtp:prepend(vim.env.PDFVIEW_LEAP_RTP)
  vim.cmd.runtime 'plugin/init.lua'
  vim.keymap.set({ 'n', 'x', 'o' }, 'f', '<Plug>(leap)')
end
vim.g.mapleader = ' '
vim.o.columns, vim.o.lines = 100, 35
vim.o.mouse, vim.o.incsearch, vim.o.hlsearch = 'a', true, true
local shows, errors, latest_png = 0, {}, nil
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
end
local kitty = require 'pdfview.kitty'
kitty.supported = function() return true end
kitty.cell_size = function() return { width = 10, height = 20 } end
kitty.show = function(png)
  local file = assert(io.open(png, 'rb'))
  latest_png = file:read '*a'
  file:close()
  shows = shows + 1
  os.remove(png)
  return shows
end
kitty.delete = function() end
local block_visual, visual_blocked = false, false
-- Match a plugin such as which-key waiting for input before later mode hooks run.
api.nvim_create_autocmd('ModeChanged', {
  callback = function()
    if not block_visual or vim.v.event.new_mode ~= 'V' then return end
    visual_blocked = true
    vim.fn.getcharstr()
    visual_blocked = false
  end,
})
local pdfview = require 'pdfview'
pdfview.setup()
local states
for i = 1, 100 do
  local name, value = debug.getupvalue(pdfview.setup, i)
  if name == 'states' then states = value; break end
end
local pdf = vim.env.PDFVIEW_TEST_PDF
vim.cmd.edit(vim.fn.fnameescape(pdf))
local buf = api.nvim_get_current_buf()
local function st() return states[buf] end
local function ready() return st() and st().view and not st().busy end
local function keys(s) api.nvim_feedkeys(vim.keycode(s), 't', false) end
local function cursor() return api.nvim_win_get_cursor(0) end
local function filled()
  local marks = vim.json.decode(st().render_key)[4]
  return not marks[#marks].outline
end
local function outline() return not filled() end
local steps = {}
local function step(name, action, done, check) steps[#steps + 1] = { name, action, done, check } end
local leap_shows
local function badge() return api.nvim_buf_get_lines(st().badge.buf, 0, -1, false)[1] end
local function cursor_drawn()
  for _, m in ipairs(vim.json.decode(st().render_key)[4]) do
    if m.color == 0xDDEBFF or m.color == 0x8AB8FF then return true end
  end
  return false
end
step('open hidden page view in pager mode', function() end, ready, function()
  assert(api.nvim_win_get_config(api.nvim_get_current_win()).hide)
  assert(api.nvim_win_get_width(st().pane.win) == api.nvim_win_get_width(st().host))
  assert(st().pager and badge() == ' 1/2 ' and not cursor_drawn(), badge())
end)
step('c enters cursor mode', function() keys('c') end,
  function() return ready() and not st().pager and badge() == ' CURSOR 1/2 ' end)
step('native j moves the invisible text cursor and PDF tint', function() keys('j') end,
  function() return ready() and cursor()[1] == 2 and filled() and cursor_drawn() end)
local visual_baseline, visual_cursor
step('linewise selection paints while an earlier mode callback waits for input', function()
  visual_baseline, visual_cursor = latest_png, cursor()
  block_visual = true
  keys('V')
end, function() return visual_blocked and ready() and latest_png ~= visual_baseline end, function()
  assert(vim.fn.mode() == 'V')
  assert(vim.deep_equal(cursor(), visual_cursor))
end)
step('release the earlier mode callback', function()
  block_visual = false
  keys('<Esc>')
end, function() return not visual_blocked and ready() end)
step('leaving linewise selection restores the normal image without movement', function() keys('<Esc>') end,
  function() return vim.fn.mode() == 'n' and ready() and latest_png == visual_baseline end,
  function() assert(vim.deep_equal(cursor(), visual_cursor)) end)
if vim.env.PDFVIEW_LEAP_RTP then
  step('Leap reaches right column beyond hidden viewport', function()
    leap_shows = shows
    assert(vim.fn.searchpos('xy', 'nW')[1] > vim.fn.line('w$'))
    keys('fxy')
  end, function() return ready() and shows > leap_shows and cursor()[1] > 40 end, function()
    assert(vim.fn.getline('.'):find('xy', 1, true))
    local ns = api.nvim_get_namespaces()['pdfview.labels']
    assert(#api.nvim_buf_get_extmarks(st().pane.buf, ns, 0, -1, {}) == 1)
  end)
  step('escape Leap without another movement', function() keys('<Esc>') end, function() return not st().leaping and ready() end)
  step('visual yank uses real text', function() keys('vly') end, function() return vim.fn.getreg('"') == 'xy' and ready() end)
end
local scroll_top
step('counted scrolling', function()
  scroll_top = st().top
  keys('3<C-e>')
end, function() return ready() and st().top == scroll_top + 60 end)
step('next page shows the second page from its top', function() keys(']p') end,
  function() return ready() and vim.fn.getline('.') == 'second page' end, function()
    assert(st().top == math.floor(st().layout.tops[2]))
    assert(badge() == ' CURSOR 2/2 ', badge())
  end)
step('[p inside a page returns to its top', function() keys('3<C-e>[p') end,
  function() return ready() and st().top == math.floor(st().layout.tops[2]) end,
  function() assert(badge() == ' CURSOR 2/2 ', badge()) end)
step('PageUp at a page top goes to the previous page', function() keys('<PageUp>') end,
  function() return ready() and st().top == 0 end, function() assert(badge() == ' CURSOR 1/2 ', badge()) end)
step('Esc returns to pager mode', function() keys('<Esc>') end,
  function() return ready() and st().pager and badge() == ' 1/2 ' and not cursor_drawn() end)
step('pager j pans three rows', function() keys('j') end, function() return ready() and st().top == 60 end)
step('pager u pans instead of undoing', function() keys('u') end, function() return ready() and st().top == 0 end)
step('v in pager mode starts a selection in cursor mode', function() keys('v') end,
  function() return ready() and vim.fn.mode() == 'v' and not st().pager end)
step('Esc ends the selection and stays in cursor mode', function() keys('<Esc>') end,
  function() return ready() and vim.fn.mode() == 'n' and not st().pager and filled() end, function()
    assert(vim.fn.maparg('u', 'n', false, true).desc == 'PDF: pager: pan up half a screen')
  end)
step('terminal focus lost makes cursor hollow', function() api.nvim_exec_autocmds('FocusLost', {}) end,
  function() return ready() and outline() end)
step('terminal focus gained restores filled cursor', function() api.nvim_exec_autocmds('FocusGained', {}) end,
  function() return ready() and filled() end)
step('incremental search renders native match', function() keys('/left 30') end,
  function() return ready() and vim.fn.getcmdtype() == '/' and vim.fn.getline('.'):find('left 30', 1, true) end)
step('accept search tints the match under the cursor apart from the rest', function() keys('<CR>') end,
  function() return ready() and vim.fn.getcmdtype() == '' end, function()
    local colors = {}
    for _, m in ipairs(vim.json.decode(st().render_key)[4]) do
      colors[m.color] = (colors[m.color] or 0) + #m.ranges
    end
    assert(colors[0xFF9F43] == 1, vim.inspect(colors))
  end)
local before_click
step('click another character on the page', function()
  before_click = cursor()
  local v = st().view
  -- A fixed point on the right column, away from the current left-column search result.
  local host_pos = api.nvim_win_get_position(st().host)
  api.nvim_input_mouse('left', 'press', '', 0, host_pos[1] + 8, host_pos[2] + 65)
  api.nvim_input_mouse('left', 'release', '', 0, host_pos[1] + 8, host_pos[2] + 65)
end, function() return ready() and cursor()[1] ~= before_click[1] end)
local plain
step('another window makes PDF cursor hollow', function() vim.cmd.vsplit(); vim.cmd.enew(); plain = api.nvim_get_current_win() end,
  function() return ready() and outline() end)
step('return to covered window restores hidden focus', function() api.nvim_set_current_win(st().host) end,
  function() return ready() and api.nvim_get_current_win() == st().focus and filled() end)
step('unsaved annotations prevent an invisible buffer switch', function()
  vim.bo[buf].modified = true
  vim.o.hidden = false
  vim.cmd.enew()
end, function() return api.nvim_get_current_buf() == buf and #errors > 0 and ready() end, function()
  assert(errors[#errors]:find('E37', 1, true))
  errors[#errors] = nil
  assert(vim.bo[buf].modified)
  assert(st().focus == api.nvim_get_current_win())
end)
step('edit! reloads the PDF without orphaning its view', function() vim.cmd.edit { bang = true } end,
  function() return ready() and not vim.bo[buf].modified and st().focus == api.nvim_get_current_win() end)
step('editing from hidden window hands file to normal window', function() vim.cmd.enew() end,
  function() return (not st() or not st().focus) and api.nvim_win_get_config(api.nvim_get_current_win()).relative == '' end,
  function()
    assert(api.nvim_get_current_buf() ~= buf)
    for _, win in ipairs(api.nvim_list_wins()) do
      assert(api.nvim_win_get_config(win).relative == '')
    end
  end)
step('returning to PDF rebuilds view', function() vim.cmd.buffer(buf) end,
  function() return ready() and st().focus == api.nvim_get_current_win() end)
step('closing PDF closes its normal window and floats', function() vim.cmd.quit() end,
  function() return not st() or not st().host and not st().pane end, function()
    assert(api.nvim_get_current_win() == plain)
    assert(#api.nvim_list_wins() == 1)
    assert(#errors == 0, table.concat(errors, '\n'))
  end)

local index = 0
local function fail(message)
  io.stderr:write(message .. '\n')
  vim.cmd 'cquit!'
end
local function next_step()
  index = index + 1
  local s = steps[index]
  if not s then
    io.stdout:write(('Passed %d headless interaction checks\n'):format(#steps))
    return vim.cmd 'qa!'
  end
  local ok, err = pcall(s[2])
  if not ok then return fail(s[1] .. ': ' .. err) end
  local deadline = vim.uv.now() + 15000
  local function check()
    local valid, done = pcall(s[3])
    if not valid then return fail(s[1] .. ': ' .. done) end
    if done then
      if s[4] then
        local good, why = pcall(s[4])
        if not good then return fail(s[1] .. ': ' .. why) end
      end
      return next_step()
    end
    if vim.uv.now() > deadline then return fail(s[1] .. ': timed out; ' .. table.concat(errors, '\n')) end
    vim.defer_fn(check, 20)
  end
  vim.defer_fn(check, 20)
end
next_step()
