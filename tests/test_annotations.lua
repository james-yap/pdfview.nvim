-- Headless interaction scenario for annotation preview, annotation undo/redo and the
-- unsaved-change statusline flag. Invoked with the real helper and a generated fixture:
--   PDFVIEW_TEST_PDF: page 1 reads 'alpha beta gamma' with a Highlight over 'alpha'
--   (custom colour and opacity) carrying the note 'existing note'; page 2 reads 'second page'.
-- Only kitty graphics are stubbed. Everything is driven through the mapped keys and observed through
-- public buffers, windows, options, the quickfix list, the file on disk and the rendered PNG.
local api = vim.api
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = ' '
vim.o.columns, vim.o.lines = 100, 35

local errors, notices = {}, {}
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = msg else notices[#notices + 1] = msg end
end

-- A mini.statusline-like provider: one expression for every window, a different look for the
-- active and the inactive one, both showing the modified flag between markers.
function _G.PdfviewTestStatusline()
  local active = vim.g.actual_curwin ~= nil and tonumber(vim.g.actual_curwin) == tonumber(vim.g.statusline_winid)
  return (active and '%#StatusLine#' or '%#StatusLineNC#') .. '%F<%m>%='
end
vim.o.laststatus = 2
vim.o.statusline = '%{%v:lua.PdfviewTestStatusline()%}'

-- Only the terminal protocol is replaced; the PNG is kept so renders can be compared.
local shows, latest = 0, nil
local kitty = require 'pdfview.kitty'
kitty.supported = function() return true end
kitty.cell_size = function() return { width = 10, height = 20 } end
kitty.show = function(png)
  shows = shows + 1
  local f = assert(io.open(png, 'rb'))
  latest = f:read '*a'
  f:close()
  os.remove(png)
  return shows
end
kitty.delete = function() end

local pdfview = require 'pdfview'
pdfview.setup()
local states
for i = 1, 100 do
  local name, value = debug.getupvalue(pdfview.setup, i)
  if name == 'states' then states = value; break end
end
assert(states, 'cannot find the plugin state table')

local pdf = vim.env.PDFVIEW_TEST_PDF
assert(pdf and pdf ~= '', 'PDFVIEW_TEST_PDF is not set')
vim.cmd.edit(vim.fn.fnameescape(pdf))
local buf = api.nvim_get_current_buf()
local function st() return states[buf] end
local function ready() return st() and st().view and not st().busy end
local function keys(s) api.nvim_feedkeys(vim.keycode(s), 't', false) end
local function cur() return api.nvim_get_current_win() end
local function cursor() return api.nvim_win_get_cursor(0) end

-- Keys plus a signal that the typeahead was consumed (SafeState only fires with none pending).
local synced = false
local function keys_sync(s)
  synced = false
  api.nvim_create_autocmd('SafeState', { once = true, callback = function() synced = true end })
  keys(s)
end

local function disk()
  local s = assert(vim.uv.fs_stat(pdf))
  return ('%d:%d.%d'):format(s.size, s.mtime.sec, s.mtime.nsec)
end

-- Statusline as displayed: the effective expression of the window, evaluated for that window.
local function status_of(win)
  local expr = vim.wo[win].statusline
  if expr == '' then expr = vim.go.statusline end
  return api.nvim_eval_statusline(expr, { winid = win }).str
end
local function flag(win) return status_of(win):match '<(.-)>' end

--- The normal (non-float) window that shows the PDF text buffer.
local function visible()
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if api.nvim_win_get_config(w).relative == '' then return w end
  end
end

--- Floating windows that are neither the page view nor its hidden focus window.
local function floats()
  local out = {}
  for _, w in ipairs(api.nvim_list_wins()) do
    local pane, badge = st() and st().pane, st() and st().badge
    if api.nvim_win_get_config(w).relative ~= '' and w ~= st().focus and not (pane and pane.win == w) and not (badge and badge.win == w) then out[#out + 1] = w end
  end
  return out
end

local host_win, plain, plain_buf, base, disk_key, lnum
local function options()
  return {
    global = vim.go.statusline,
    laststatus = vim.go.laststatus,
    host = vim.wo[host_win].statusline,
    plain = vim.wo[plain].statusline,
  }
end

--- Everything that must hold in every state: the buffer's modified flag, the statusline shown
--- for the visible PDF window, untouched statusline options, and a PDF file that only :w changes.
local function check_state(dirty)
  assert(vim.bo[buf].modified == dirty, ('buffer modified is %s, expected %s'):format(vim.bo[buf].modified, dirty))
  local win = visible()
  assert(win == host_win, 'the PDF is not shown in its window')
  local f = flag(win)
  assert((f:find('+', 1, true) ~= nil) == dirty, ('visible statusline flag is %q, expected dirty=%s'):format(f, dirty))
  assert(flag(plain) == '[+]', 'the unrelated window statusline changed: ' .. status_of(plain))
  assert(vim.deep_equal(options(), base), 'statusline options changed: ' .. vim.inspect(options()))
  assert(disk() == disk_key, 'the PDF on disk changed')
  local focus = st().focus
  if focus and cur() == focus then assert(api.nvim_win_get_config(focus).hide, 'focus window is not hidden') end
end

local function at_alpha() return cursor()[1] == lnum and cursor()[2] == 0 end

local steps = {}
local function step(name, action, done, check, slow) steps[#steps + 1] = { name, action, done, check, slow } end

-- Annotations as the user lists them: one quickfix entry each, ending with note or excerpt.
-- The list window shrinks the PDF window, so a following step closes it and waits for the
-- full-size page to be rendered again before anything else is compared.
local qf_mark, qf_was_open, host_height, mark
local function annotations(name, expected, dirty)
  step(name, function()
    vim.fn.setqflist({}, 'f')
    qf_mark = #notices
    keys ' pl'
  end, function()
    return ready() and (vim.fn.getqflist({ winid = 0 }).winid ~= 0 or #notices > qf_mark)
  end, function()
    local texts = {}
    for _, item in ipairs(vim.fn.getqflist()) do texts[#texts + 1] = item.text end
    assert(#texts == #expected, ('annotations %s, expected %s'):format(vim.inspect(texts), vim.inspect(expected)))
    local left = vim.deepcopy(texts)
    for _, e in ipairs(expected) do
      local found
      for i, t in ipairs(left) do
        if t:sub(-#e) == e then found = i; break end
      end
      assert(found, ('no annotation ending with %q in %s'):format(e, vim.inspect(texts)))
      table.remove(left, found)
    end
    check_state(dirty)
  end)
  step(name .. ' (list closed)', function()
    qf_was_open = vim.fn.getqflist({ winid = 0 }).winid ~= 0
    mark = shows
    if qf_was_open then vim.cmd.cclose() end
    if cur() ~= st().focus then api.nvim_set_current_win(st().focus) end
  end, function()
    return ready() and cur() == st().focus
      and (not qf_was_open or (shows > mark and api.nvim_win_get_height(host_win) == host_height
        and api.nvim_win_get_height(st().pane.win) == host_height))
  end, function() check_state(dirty) end)
end


--- An undo/redo/edit key sequence in the PDF with the state it must leave behind.
local function change(name, seq, dirty, opts)
  opts = opts or {}
  step(name, function()
    mark = shows
    keys_sync(seq)
  end, function()
    return synced and ready() and vim.bo[buf].modified == dirty and (opts.image == false or shows > mark) and at_alpha()
  end, function()
    check_state(dirty)
    if opts.check then opts.check() end
  end)
end

local png = {}

local function note_text(win)
  return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), '\n')
end

local hover
-- K opens a read-only preview without taking focus; a second K focuses that same window.
local function hover_cycle(label, close, text_ok)
  step('K previews the note (' .. label .. ')', function() keys 'K' end, function() return #floats() == 1 end, function()
    hover = floats()[1]
    local hbuf = api.nvim_win_get_buf(hover)
    assert(hbuf ~= buf, 'the preview shows the PDF text buffer')
    assert(not vim.bo[hbuf].modifiable or vim.bo[hbuf].readonly, 'the preview is editable')
    assert(text_ok(note_text(hover)), 'preview text: ' .. vim.inspect(note_text(hover)))
    assert(cur() == st().focus, 'the preview took focus on the first K')
    assert(at_alpha(), 'K moved the PDF cursor')
    check_state(false)
  end)
  step('repeated K focuses the existing preview (' .. label .. ')', function() keys 'K' end,
    function() return cur() == hover end, function()
      local now = floats()
      assert(#now == 1 and now[1] == hover, 'repeated K opened another float: ' .. vim.inspect(now))
      assert(not vim.bo[api.nvim_win_get_buf(hover)].modifiable or vim.bo[api.nvim_win_get_buf(hover)].readonly, 'focused preview is editable')
      check_state(false)
    end)
  step(close .. ' closes the preview (' .. label .. ')', function() keys(close) end,
    function() return not api.nvim_win_is_valid(hover) and cur() == st().focus and ready() end, function()
      assert(#floats() == 0, 'floats left: ' .. vim.inspect(floats()))
      assert(at_alpha())
      check_state(false)
    end)
end

local note_win, note_buf

--- Whether the note reading `text` is marked as Typst.
local function is_typst(text)
  for _, a in ipairs(st().annots) do
    if a.contents == text then return a.typst end
  end
  error('no note reads ' .. vim.inspect(text))
end

--- The note editor is current: Typst source beside its preview, two floats.
local function editing() return #floats() == 2 and vim.bo[api.nvim_get_current_buf()].filetype == 'typst' end

-- Scenario ---------------------------------------------------------------------------------------

step('opens the hidden page view over the PDF window', function() end, ready, function()
  assert(api.nvim_win_get_config(cur()).hide, 'focus is not in the hidden window')
  host_win = st().host
  assert(host_win and visible() == host_win)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find('alpha beta gamma', 1, true) then lnum = i; break end
  end
  assert(lnum, 'fixture text not found: ' .. vim.inspect(lines))
  assert(lines[lnum]:sub(1, 5) == 'alpha', 'alpha does not start its line')
  assert(vim.tbl_contains(lines, 'second page') or table.concat(lines, '\n'):find('second page', 1, true), 'second page missing')
  disk_key = disk()
  assert(not vim.bo[buf].modified)
end, true)

step('c enters cursor mode for annotating', function() keys 'c' end, function() return ready() and not st().pager end)

step('adds an unrelated modified window with its own statusline', function()
  mark = shows
  plain_buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(plain_buf, 0, -1, false, { 'scratch' })
  plain = api.nvim_open_win(plain_buf, false, { split = 'right', win = host_win })
  vim.wo[plain].statusline = '<%m>%t'
end, function()
  return ready() and shows > mark and api.nvim_win_get_width(st().pane.win) == api.nvim_win_get_width(host_win)
end, function()
  assert(cur() == st().focus)
  base = options()
  host_height = api.nvim_win_get_height(host_win)
  check_state(false)
end)

step('moves onto the annotated word', function()
  mark = shows
  keys(lnum .. 'G0')
end, function()
  return ready() and at_alpha() and shows > mark
end, function()
  png.base = latest
  check_state(false)
end)

hover_cycle('q', 'q', function(t) return t:find('existing note', 1, true) and not t:find('edited', 1, true) end)
hover_cycle('Esc', '<Esc>', function(t) return t:find('existing note', 1, true) and not t:find('edited', 1, true) end)

step('<leader>pn opens the imported plain note in the Typst editor', function() keys ' pn' end, editing, function()
    note_win = cur()
    note_buf = api.nvim_win_get_buf(note_win)
    assert(note_buf ~= buf)
    assert(vim.bo[note_buf].modifiable)
    assert(note_text(note_win) == 'existing note', vim.inspect(note_text(note_win)))
    assert(not is_typst 'existing note', 'a note from another viewer was read as Typst')
    check_state(false)
  end)
step('typing in the note does not touch the PDF', function() keys 'A edited<Esc>' end,
  function() return note_text(note_win) == 'existing note edited' end, function()
    check_state(false)
  end)
step('writing the note saves it into the PDF state', function() keys ':w<CR>' end,
  function() return not vim.bo[note_buf].modified and vim.bo[buf].modified end, function()
    -- The hidden float is not current, yet the visible PDF window shows the flag.
    check_state(true)
    assert(is_typst 'existing note edited', 'a note written by pdfview is not marked Typst')
  end)
step('q closes the saved note', function() keys 'q' end,
  function() return not api.nvim_win_is_valid(note_win) and cur() == st().focus and ready() end, function()
    assert(#floats() == 0)
    check_state(true)
  end)
annotations('lists the edited note', { 'existing note edited' }, true)

step(':w writes the PDF and clears the flag', function() keys ':w<CR>' end,
  function() return not vim.bo[buf].modified and ready() end, function()
    assert(disk() ~= disk_key, 'the PDF file was not written')
    disk_key = disk()
    check_state(false)
  end)

step('<leader>pn reopens the saved note', function() keys ' pn' end, editing, function()
    note_win = cur()
    note_buf = api.nvim_win_get_buf(note_win)
    assert(note_text(note_win) == 'existing note edited', vim.inspect(note_text(note_win)))
    check_state(false)
  end)
step('note text is typed', function() keys 'A more<Esc>' end,
  function() return note_text(note_win) == 'existing note edited more' end, function() check_state(false) end)
step('u in the note undoes note text, not the annotation state', function() keys 'u' end,
  function() return note_text(note_win) == 'existing note edited' and not vim.bo[note_buf].modified end, function()
    check_state(false)
    assert(cur() == note_win)
  end)
step('undo cannot erase the note text loaded from the PDF', function() keys_sync 'u' end,
  function() return synced end, function()
    assert(note_text(note_win) == 'existing note edited')
    assert(not vim.bo[note_buf].modified)
    check_state(false)
  end)
step('q closes the unchanged note without saving', function() keys 'q' end,
  function() return not api.nvim_win_is_valid(note_win) and cur() == st().focus and ready() end, function()
    check_state(false)
  end)
annotations('annotation state is untouched by note typing', { 'existing note edited' }, false)

change('u after :w returns to the unsaved older state', 'u', true, {
  image = false,
  check = function() assert(latest == png.base, 'undo did not restore the original page as rendered') end,
})
annotations('undone note is listed', { 'existing note' }, true)
step('undo also drops the Typst mark', function() end, function() return true end, function()
  assert(not is_typst 'existing note', 'undo kept the Typst mark on the plain note')
end)
change('Ctrl-R after :w returns to the saved state', '<C-r>', false, { image = false })
annotations('redone note is listed', { 'existing note edited' }, false)

change('visual <leader>ph adds a highlight', '0wwve ph0', true, {
  check = function()
    png.added = latest
    assert(png.added ~= png.base, 'highlighting did not change the rendered page')
  end,
})
annotations('new highlight is listed', { 'existing note edited', 'gamma' }, true)
change('<leader>pd deletes the imported highlight', ' pd', true, {
  check = function()
    png.deleted = latest
    assert(png.deleted ~= png.base and png.deleted ~= png.added, 'deleting did not change the rendered page')
  end,
})
annotations('only the new highlight remains', { 'gamma' }, true)

change('3u undoes three annotation changes at once', '3u', true, {
  check = function()
    assert(latest == png.base, 'undo did not restore the imported highlight exactly as rendered')
  end,
})
annotations('original note is back', { 'existing note' }, true)
change('Ctrl-R reaches the saved state again', '<C-r>', false, { image = false })
change('2<C-r> redoes two changes at once', '2<C-r>', true, {
  check = function() assert(latest == png.deleted, 'redo did not reproduce the deleted state as rendered') end,
})
annotations('redone deletion is listed', { 'gamma' }, true)
change('2u returns to the saved state', '2u', false)
annotations('saved state is listed again', { 'existing note edited' }, false)

change('a new edit starts a branch', ' pd', true, { check = function() png.branch = latest end })
annotations('branch has no annotations', {}, true)
change('Ctrl-R has nothing to redo on the new branch', '<C-r>', true, {
  image = false,
  check = function() assert(latest == png.branch, 'redo changed the page on the new branch') end,
})
annotations('still no annotations after the redo', {}, true)
change('u leaves the branch', 'u', false)
change('Ctrl-R follows the new branch, not the dropped redo', '<C-r>', true)
annotations('branch redo lists no annotations', {}, true)

step(':e! reloads the PDF from disk', function()
  mark = shows
  vim.cmd.edit { bang = true }
end, function()
  return ready() and not vim.bo[buf].modified and st().focus == cur() and shows > mark
end, function() check_state(false) end)
annotations('reloaded PDF lists the saved annotations', { 'existing note edited' }, false)
change('u after :e! has no history left', 'u', false, { image = false })
annotations('state after u is the reloaded one', { 'existing note edited' }, false)
change('Ctrl-R after :e! has no history left', '<C-r>', false, { image = false })
annotations('state after Ctrl-R is the reloaded one', { 'existing note edited' }, false)

change('creates a temporary gamma highlight', '0wwve ph0', true)
change('deleting it returns to the saved annotation state', '0ww pd0', false)
change('creates a different highlight', '0wve ph0', true)
change('3u returns across a repeated state', '3u', false)
local repeat_notices
step('counted redo can land on an identical state without a false boundary message', function()
  repeat_notices = #notices
  keys_sync '2<C-r>'
end, function() return synced and ready() end, function()
  assert(#notices == repeat_notices, 'redo incorrectly reported a history boundary')
  assert(at_alpha())
  check_state(false)
end)
change('redo continues past the identical state', '<C-r>', true)
change('undo the last highlight returns to the saved state', 'u', false)

-- Typst rendering: an editor beside a live preview, compile errors as diagnostics, a rendered hover.
local typst_win, typst_buf, preview_buf
local function preview_drawn()
  local line = api.nvim_buf_get_lines(preview_buf, 0, 1, false)[1] or ''
  return line:sub(1, 4) == vim.fn.nr2char(0x10EEEE)
end
step('visual <leader>pn opens the note editor beside its preview', function() keys '0wwve pn' end, editing, function()
    typst_win, typst_buf = cur(), api.nvim_get_current_buf()
    local other = floats()[1] == typst_win and floats()[2] or floats()[1]
    preview_buf = api.nvim_win_get_buf(other)
    assert(not api.nvim_win_get_config(other).focusable, 'the preview takes focus')
    local e, p = api.nvim_win_get_position(typst_win), api.nvim_win_get_position(other)
    assert(e[1] == p[1] and e[2] < p[2], 'a wide screen does not put the preview to the right: ' .. vim.inspect { e, p })
    local created = vim.tbl_filter(function(a) return a.contents == '' end, st().annots)
    assert(#created == 1 and not created[1].typst, 'the new highlight is not an empty, unmarked one: ' .. vim.inspect(st().annots))
  end)
step('typing renders the preview', function()
  mark = shows
  keys 'i$ x^2 $<Esc>'
end, function() return shows > mark and preview_drawn() end, function()
  assert(#vim.diagnostic.get(typst_buf) == 0, vim.inspect(vim.diagnostic.get(typst_buf)))
end)
step('a compile error is a diagnostic on its line', function() keys 'o#foo(<Esc>' end,
  function() return #vim.diagnostic.get(typst_buf) > 0 end, function()
    assert(vim.diagnostic.get(typst_buf)[1].lnum == 1, vim.inspect(vim.diagnostic.get(typst_buf)))
    assert(preview_drawn(), 'the last good preview was dropped')
  end)
step('fixing it clears the diagnostic', function()
  mark = shows
  keys 'dd'
end, function() return #vim.diagnostic.get(typst_buf) == 0 and shows > mark end)
step('q saves the Typst note and closes both windows', function() keys 'q' end,
  function() return #floats() == 0 and cur() == st().focus and ready() end, function()
    assert(vim.bo[buf].modified)
  end)
annotations('the Typst note is listed', { 'existing note edited', '$ x^2 $' }, true)
step('the new note is marked Typst', function() end, function() return true end, function()
  assert(is_typst '$ x^2 $')
end)
step('K shows the Typst note rendered', function() keys '0wwK' end, function() return #floats() == 1 end, function()
  local line = api.nvim_buf_get_lines(api.nvim_win_get_buf(floats()[1]), 0, 1, false)[1]
  assert(line:sub(1, 4) == vim.fn.nr2char(0x10EEEE), 'the hover is not the rendered image: ' .. vim.inspect(line))
end)
step('moving the cursor dismisses it', function() keys '0' end, function() return #floats() == 0 and at_alpha() end)
change('2u removes the Typst note', '2u', false)

step('opening another buffer detaches the page view', function() vim.cmd.enew() end,
  function() return (not st() or not st().focus) and api.nvim_win_get_config(cur()).relative == '' end, function()
    assert(vim.wo[host_win].statusline == base.host, 'host statusline changed on detach')
    assert(vim.go.statusline == base.global)
    assert(vim.wo[plain].statusline == base.plain)
  end)
step('returning to the PDF shows the page view again', function() vim.cmd.buffer(buf) end,
  function() return ready() and st().focus == cur() end, function()
    check_state(false)
    assert(#errors == 0, table.concat(errors, '\n'))
  end)

-- Driver -----------------------------------------------------------------------------------------

vim.v.errmsg = ''
local index = 0
local function fail(message)
  io.stderr:write(('%s\nnotifications: %s\nerrors: %s\n'):format(message, vim.inspect(notices), vim.inspect(errors)))
  vim.cmd 'cquit!'
end
local function next_step()
  index = index + 1
  local s = steps[index]
  if not s then
    io.stdout:write(('Passed %d headless annotation checks\n'):format(#steps))
    return vim.cmd 'qa!'
  end
  local ok, err = pcall(s[2])
  if not ok then return fail(s[1] .. ': ' .. err) end
  local deadline = vim.uv.now() + (s[5] and 60000 or 20000)
  local function check()
    local valid, done = pcall(s[3])
    if not valid then return fail(s[1] .. ': ' .. done) end
    if done then
      if s[4] then
        local good, why = pcall(s[4])
        if not good then return fail(s[1] .. ': ' .. why) end
      end
      if #errors > 0 or vim.v.errmsg ~= '' then
        return fail(s[1] .. ': error reported: ' .. table.concat(errors, '\n') .. vim.v.errmsg)
      end
      return next_step()
    end
    if vim.uv.now() > deadline then return fail(s[1] .. ': timed out') end
    vim.defer_fn(check, 20)
  end
  vim.defer_fn(check, 20)
end
next_step()
