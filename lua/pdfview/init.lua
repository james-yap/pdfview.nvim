-- pdfview.nvim: a read-only text buffer for vim motions (hjkl, /, leap,
-- visual) shown as the rendered pages: by default the pages cover the text
-- window and the text stays hidden (or, toggled, a page pane beside the text).
-- The view follows the cursor and tints the cursor line or visual selection.
-- Pages are drawn with the kitty graphics protocol (lua/pdfview/kitty.lua).
--
-- Text, geometry and annotations live in python/helper.py (PyMuPDF, run
-- through uv). Buffer lines are the helper's lines: one per PDF text line, in
-- content order, with a "── page N ──" line before each page.
--
-- Annotations (highlight/underline/strikeout + note text) are standard PDF
-- annotations. Edits stay in memory and mark the buffer modified: :w writes
-- them into the PDF (incremental save), :e! discards them. The PDF reloads
-- when it changes on disk, unless there are unsaved annotations; then :w is
-- refused because the in-memory document no longer matches the file.
local M = {}
local api, uv = vim.api, vim.uv
local kitty = require 'pdfview.kitty'

local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local HELPER = vim.fs.joinpath(ROOT, 'python', 'helper.py')
local NS = api.nvim_create_namespace 'pdfview'
local GROUP = api.nvim_create_augroup('pdfview', { clear = true })
-- Tints for the page view / snapshot (multiplied over the page, so ink stays dark).
local COLORS = { cursor = 0xDDEBFF, cursor_char = 0x8AB8FF, selection = 0xA8D1FF, search = 0xFFE07A }
local HL = { Highlight = 'PdfViewHighlight', Underline = 'PdfViewUnderline', StrikeOut = 'PdfViewStrikeOut', Squiggly = 'PdfViewSquiggly' }
local NOTE_TYPES = { Text = true, FreeText = true }

---@class pdfview.Config
M.config = {
  -- Buffer-local keys in PDF buffers; set any of them to false to skip it. A key
  -- can also be a list of keys.
  -- leap: keys that run pdfview's leap (targets everything the page view shows).
  -- nil: whatever you mapped to <Plug>(leap), in the same modes.
  keys = {
    prefix = '<leader>p',
    next_annotation = ']a',
    prev_annotation = '[a',
    next_page = { ']p', '<PageDown>' },
    prev_page = { '[p', '<PageUp>' },
    leap = nil,
    hover = 'K',
    undo = 'u',
    redo = '<C-r>',
  },
  -- 'page': the pages fill the PDF's window and the text is hidden; 'split': the
  -- text window plus a page pane to its right. <prefix>t toggles per buffer.
  view = 'page',
  -- Split mode pane width: a fraction (< 1) of the columns it shares with the text window,
  -- or a number of columns. Reapplied when the terminal is resized; <C-w> resizes otherwise stick.
  pane_width = 0.6,
  -- Where snapshots are written. nil: $TMPDIR/pdfview.
  snapshot_dir = nil, ---@type string?
}

---@type table<integer, table> per PDF buffer
local states = {}
local editor_focused = true

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = 'pdfview' }) end

-- Helper process -------------------------------------------------------------

local helper = { seq = 0, pending = {}, chunks = {}, stderr = '' }

local function dispatch(line)
  local msg = vim.json.decode(line, { luanil = { object = true, array = true } })
  local cb = helper.pending[msg.id]
  helper.pending[msg.id] = nil
  if cb then cb(msg.error, msg.result) end
end

-- Replies can be hundreds of KB on one line, arriving in many small reads:
-- scan only the new chunk for newlines and join the pieces once per reply.
local function on_stdout(_, data)
  if not data then return end
  local start = 1
  while true do
    local nl = data:find('\n', start, true)
    if not nl then break end
    helper.chunks[#helper.chunks + 1] = data:sub(start, nl - 1)
    local line = table.concat(helper.chunks)
    helper.chunks = {}
    vim.schedule(function() dispatch(line) end)
    start = nl + 1
  end
  if start <= #data then helper.chunks[#helper.chunks + 1] = data:sub(start) end
end

local function start_helper()
  if helper.proc then return end
  if vim.fn.executable 'uv' ~= 1 then error('PDF viewer requires uv', 0) end
  helper.proc = vim.system({ 'uv', 'run', '--quiet', '--script', HELPER }, {
    stdin = true,
    stdout = on_stdout,
    stderr = function(_, data)
      if data then helper.stderr = (helper.stderr .. data):sub(-2000) end
    end,
  }, function(res)
    vim.schedule(function()
      helper.proc, helper.chunks = nil, {}
      local pending, err = helper.pending, ('PDF helper exited (%d): %s'):format(res.code, helper.stderr)
      helper.pending = {}
      for _, cb in pairs(pending) do
        cb(err)
      end
    end)
  end)
end

local function request(method, params, cb)
  start_helper()
  helper.seq = helper.seq + 1
  helper.pending[helper.seq] = cb
  helper.proc:write(vim.json.encode { id = helper.seq, method = method, params = params } .. '\n')
end

-- Synchronous request. The first call may wait for uv to install PyMuPDF.
local function call(method, params)
  local done, err, result
  request(method, params, function(e, r)
    done, err, result = true, e, r
  end)
  if not vim.wait(120000, function() return done end, 5) then error('PDF helper timed out: ' .. method, 0) end
  if err then error(err, 0) end
  return result
end

local function try_call(method, params)
  local ok, res = pcall(call, method, params)
  if not ok then notify(res, vim.log.levels.ERROR) end
  return ok and res or nil
end

-- Text geometry --------------------------------------------------------------

local function char_index(text, byte) return vim.str_utfindex(text, 'utf-32', math.min(byte, #text), false) end
local function byte_index(text, char) return vim.str_byteindex(text, 'utf-32', char, false) end

--- Absolute path with symlinks resolved (/tmp vs /private/tmp), for comparing write targets.
local function canonical(path)
  path = vim.fn.fnamemodify(path, ':p')
  return uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function stat_key(path)
  local s = uv.fs_stat(path)
  return s and table.concat({ s.ino, s.size, s.mtime.sec, s.mtime.nsec }, ':')
end

--- Visual selection of the current window as helper ranges {lnum, first char, last char}.
--- nil outside charwise/linewise visual mode; page headers are skipped.
local function selection(buf)
  local mode = vim.fn.mode()
  if mode ~= 'v' and mode ~= 'V' then return nil end
  local st, s, e = states[buf], vim.fn.getpos 'v', vim.fn.getpos '.'
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end
  local ranges = {}
  for lnum = s[2], e[2] do
    local text = st.lines[lnum]
    if not st.info[lnum][4] then
      local last = vim.str_utfindex(text, 'utf-32') - 1
      local cs = (mode == 'V' or lnum > s[2]) and 0 or char_index(text, s[3] - 1)
      local ce = (mode == 'V' or lnum < e[2]) and last or math.min(char_index(text, e[3] - 1), last)
      ranges[#ranges + 1] = { lnum, cs, ce }
    end
  end
  return #ranges > 0 and ranges or nil
end

local function ranges_page(st, ranges)
  local page = st.info[ranges[1][1]][1]
  for _, r in ipairs(ranges) do
    if st.info[r[1]][1] ~= page then return nil end
  end
  return page
end

-- Annotations in the text buffer ---------------------------------------------

local function set_hls()
  local dark = vim.o.background == 'dark'
  api.nvim_set_hl(0, 'PdfViewHighlight', { default = true, bg = dark and '#5c5017' or '#fff1a8' })
  api.nvim_set_hl(0, 'PdfViewUnderline', { default = true, underline = true, sp = '#e05252' })
  api.nvim_set_hl(0, 'PdfViewStrikeOut', { default = true, strikethrough = true })
  api.nvim_set_hl(0, 'PdfViewSquiggly', { default = true, undercurl = true, sp = '#e05252' })
  api.nvim_set_hl(0, 'PdfViewNote', { default = true, link = 'Comment' })
  api.nvim_set_hl(0, 'PdfViewPage', { default = true, link = 'StatusLine' })
end

local function decorate(buf)
  local st = states[buf]
  table.sort(st.annots, function(a, b) return a.anchor[1] < b.anchor[1] or (a.anchor[1] == b.anchor[1] and a.anchor[2] < b.anchor[2]) end)
  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, a in ipairs(st.annots) do
    for _, r in ipairs(a.ranges) do
      local text = st.lines[r[1]]
      api.nvim_buf_set_extmark(buf, NS, r[1] - 1, byte_index(text, r[2]), { end_col = byte_index(text, r[3] + 1), hl_group = HL[a.type] })
    end
    if a.contents ~= '' or NOTE_TYPES[a.type] then
      local last = a.ranges[#a.ranges]
      local lnum = last and last[1] or a.anchor[1]
      local first = vim.split(a.contents, '\n', { plain = true })[1]
      api.nvim_buf_set_extmark(buf, NS, lnum - 1, 0, { virt_text = { { '  ✎ ' .. first, 'PdfViewNote' } }, virt_text_pos = 'eol' })
    end
  end
end

-- Page view ------------------------------------------------------------------
--
-- The rendered pages are shown in one of two layouts (st.mode, toggled per buffer):
--   page:  a float (st.pane) covers the PDF buffer's window (st.host) and shows
--          the pages; focus sits in a hidden float on the same buffer (st.focus),
--          so the text and the terminal cursor are invisible while every key
--          still drives the text buffer.
--   split: the text window plus a page pane split to its right.
-- Either way the image is a cut of all pages stacked at the pane's width
-- ("doc pixels"), from st.top down, panned to follow the cursor.

local function pane_valid(st) return st.pane ~= nil and api.nvim_win_is_valid(st.pane.win) end

local function close_badge(st)
  if st.badge and api.nvim_win_is_valid(st.badge.win) then api.nvim_win_close(st.badge.win, true) end
  st.badge = nil
end

local function close_pane(st)
  if st.image then kitty.delete(st.image) end
  close_badge(st)
  -- After :bd the pane can be the last window; it cannot close, so it shows an empty buffer.
  if pane_valid(st) and not pcall(api.nvim_win_close, st.pane.win, true) then
    vim.wo[st.pane.win].winfixbuf = false
    api.nvim_win_call(st.pane.win, vim.cmd.enew)
  end
  st.pane, st.image, st.grid, st.view, st.render_key = nil, nil, nil, nil, nil
end

local function is_float(win) return api.nvim_win_get_config(win).relative ~= '' end

--- Whether the page view covers the PDF's window, with focus parked in its hidden float.
local function covered(st)
  return st.focus ~= nil and api.nvim_win_is_valid(st.focus) and st.host ~= nil and api.nvim_win_is_valid(st.host)
end

--- Make the covered window's statusline look active while its hidden float has focus.
local function host_active(st, active)
  if not (st.host and api.nvim_win_is_valid(st.host)) then return end
  local base = st.host_winhl or ''
  vim.wo[st.host][0].winhighlight = active and (base == '' and '' or base .. ',') .. 'StatusLineNC:StatusLine' or base
end

--- Remove the page view's floats, leaving the text window with the hidden float's cursor.
local function uncover(st)
  local focus, host = st.focus, st.host
  if not focus then return end
  -- Cleared first: the WinClosed handler ignores floats it no longer knows.
  st.focus = nil
  host_active(st, false)
  st.host = nil
  close_pane(st)
  if api.nvim_win_is_valid(focus) then
    if host and api.nvim_win_is_valid(host) and api.nvim_win_get_buf(host) == api.nvim_win_get_buf(focus) then
      api.nvim_win_set_cursor(host, api.nvim_win_get_cursor(focus))
      if api.nvim_get_current_win() == focus then api.nvim_set_current_win(host) end
    end
    pcall(api.nvim_win_close, focus, true)
  end
end

local unsupported_reported = false

local function can_show()
  local ok, reason = kitty.supported()
  if ok and not kitty.cell_size() then
    ok, reason = false, 'the terminal does not report its size in pixels'
  end
  if not ok and not unsupported_reported then
    unsupported_reported = true
    notify('No page view: ' .. reason, vim.log.levels.WARN)
  end
  return ok
end

local function new_pane_buf()
  local pbuf = api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = 'wipe'
  vim.bo[pbuf].filetype = 'pdfview_page'
  vim.bo[pbuf].modifiable = false
  return pbuf
end

-- :setlocal, so a buffer that later replaces the pane gets normal window options.
local PANE_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = 'no',
  cursorline = false,
  cursorcolumn = false,
  colorcolumn = '',
  foldcolumn = '0',
  statuscolumn = '',
  list = false,
  spell = false,
  wrap = false,
  winfixbuf = true,
}

local function set_pane_options(win)
  for option, value in pairs(PANE_OPTIONS) do
    vim.wo[win][0][option] = value
  end
end

local MIN_TEXT_WIDTH = 20

--- Pane columns out of `total`, the columns the text window and pane share (separator excluded).
local function pane_columns(total)
  local w = M.config.pane_width
  local cols = w < 1 and math.floor(total * w + 0.5) or math.floor(w)
  return math.max(1, math.min(cols, total - MIN_TEXT_WIDTH))
end

--- Split mode: a page pane to the right of the text window `win`.
local function open_pane(buf, win)
  local st = states[buf]
  if pane_valid(st) then return end
  local pbuf = new_pane_buf()
  local width = pane_columns(api.nvim_win_get_width(win) - 1)
  local pwin = api.nvim_open_win(pbuf, false, { split = 'right', win = win, width = width })
  set_pane_options(pwin)
  -- Keep the configured width through <C-w>= and other windows opening or closing.
  vim.wo[pwin][0].winfixwidth = true
  st.pane = { win = pwin, buf = pbuf }
end

--- Float config of the page image over `host`: below other floats (completion,
--- notifications), and mouse events go through to the host.
local function pane_float(host)
  local w, h = api.nvim_win_get_width(host), api.nvim_win_get_height(host)
  return { relative = 'win', win = host, row = 0, col = 0, width = w, height = h, focusable = false, mouse = false, zindex = 1 }
end

--- Float config of the hidden window holding focus over `host`.
local function focus_float(host)
  local w, h = api.nvim_win_get_width(host), api.nvim_win_get_height(host)
  return { relative = 'win', win = host, row = 0, col = 0, width = w, height = h, hide = true }
end

--- Page mode: cover the text window `host` with the pages and move focus into a
--- hidden float on the same buffer.
local function cover(buf, host)
  local st = states[buf]
  if covered(st) and st.host == host then return end
  uncover(st)
  close_pane(st)
  local pbuf = new_pane_buf()
  local pwin = api.nvim_open_win(pbuf, false, vim.tbl_extend('force', pane_float(host), { style = 'minimal', noautocmd = true }))
  set_pane_options(pwin)
  -- Opened from the host so it inherits the host's window options and jumplist.
  local focus = api.nvim_win_call(host, function() return api.nvim_open_win(buf, false, vim.tbl_extend('force', focus_float(host), { noautocmd = true })) end)
  api.nvim_win_set_cursor(focus, api.nvim_win_get_cursor(host))
  st.pane, st.host, st.focus, st.host_winhl = { win = pwin, buf = pbuf }, host, focus, vim.wo[host][0].winhighlight
  if api.nvim_get_current_win() == host then api.nvim_set_current_win(focus) end
  host_active(st, api.nvim_get_current_win() == focus)
end

--- The normal window showing `buf` that the page view belongs to, if any.
local function text_window(buf)
  local st = states[buf]
  if st.host and api.nvim_win_is_valid(st.host) and api.nvim_win_get_buf(st.host) == buf then return st.host end
  local cur = api.nvim_get_current_win()
  if api.nvim_win_get_buf(cur) == buf and not is_float(cur) then return cur end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if not is_float(win) then return win end
  end
end

--- The window whose cursor the page view follows.
local function cursor_window(buf)
  local st = states[buf]
  return covered(st) and st.focus or text_window(buf)
end

--- Show the pages for `buf` around its text window `win`, in the buffer's mode.
local function attach(buf, win)
  local st = states[buf]
  if not can_show() then return end
  if st.mode == 'page' then
    cover(buf, win)
  else
    open_pane(buf, win)
  end
end

--- Page tops, scales and heights in doc pixels for pages `width` pixels wide, `gap` apart.
local function layout(st, width, gap)
  local L = st.layout
  if L and L.width == width and L.gap == gap then return L end
  L = { width = width, gap = gap, tops = {}, scales = {}, heights = {} }
  local y = 0
  for i, page in ipairs(st.pages) do
    L.scales[i] = width / page[1]
    L.heights[i] = page[2] * L.scales[i]
    L.tops[i] = y
    y = y + L.heights[i] + gap
  end
  L.total = y - gap
  st.layout = L
  return L
end

--- Top and bottom of buffer line `lnum` in doc pixels; a page header sits at its page's top edge.
local function line_span(st, L, lnum)
  local info = st.info[lnum]
  local i = info[1] + 1
  if info[4] then return L.tops[i], L.tops[i] end
  return L.tops[i] + info[2] * L.scales[i], L.tops[i] + info[3] * L.scales[i]
end

--- Text lines (headers excluded) at least partly within doc pixels top..top+height, ascending.
local function lines_in(st, L, top, height)
  local lnums = {}
  for i = 1, #st.pages do
    if L.tops[i] < top + height and L.tops[i] + L.heights[i] > top then
      for lnum = st.headers[i] + 1, (st.headers[i + 1] or #st.lines + 1) - 1 do
        local a, b = line_span(st, L, lnum)
        if a < top + height and b > top then lnums[#lnums + 1] = lnum end
      end
    end
  end
  return lnums
end

--- Lines kept clear of the view's edges by this margin, like 'scrolloff'.
local function margin(height) return height * 0.1 end

--- New top that brings the line spanning a..b inside the margins: a small pan
--- when it is near the view, recentred when it is far.
local function follow(top, height, a, b)
  local m = margin(height)
  if a >= top + m and b <= top + height - m then return top end
  if b < top - height or a > top + 2 * height then return (a + b) / 2 - height * 0.4 end
  return a < top + m and a - m or b - height + m
end

local function clamp_top(L, height, top) return math.floor(math.max(0, math.min(L.total - height, top))) end

--- Width in pixels of the scrollbar the helper draws at the right edge of a view `width` pixels wide.
local function scrollbar_width(width) return math.max(12, math.floor(width / 60)) end

--- The view for the pane's current size: st.top, moved only when the cursor
--- line changes or the pane resizes.
--- The image is rendered at exactly cols x rows cells of terminal pixels.
local function view_for(buf, win)
  local st = states[buf]
  local cell = assert(kitty.cell_size())
  local cols = math.min(api.nvim_win_get_width(st.pane.win), kitty.max_cells)
  local rows = math.min(api.nvim_win_get_height(st.pane.win), kitty.max_cells)
  local width, height = math.floor(cols * cell.width), math.floor(rows * cell.height)
  local L = layout(st, width, math.floor(cell.height / 2))
  local lnum = api.nvim_win_get_cursor(win)[1]
  local a, b = line_span(st, L, lnum)
  local top = st.top
  if not top or st.top_width ~= width then
    top = (a + b) / 2 - height * 0.4
  elseif lnum ~= st.follow_lnum or height ~= st.top_height then
    -- Don't move the labels under the user's eyes while leap selects a target.
    if not st.leaping or a < top or b > top + height then top = follow(top, height, a, b) end
  end
  top = clamp_top(L, height, top)
  st.top, st.top_width, st.top_height, st.follow_lnum = top, width, height, lnum
  return { top = top, width = width, height = height, cols = cols, rows = rows, layout = L }
end

--- The 1-based page at doc pixel `y` (or the page before the gap it falls in).
local function page_at(L, y)
  local i = 1
  while L.tops[i + 1] and L.tops[i + 1] <= y do
    i = i + 1
  end
  return i
end

--- The "page/pages" badge in the pane's bottom-right corner, left of the
--- scrollbar: the page holding the cursor of `win`, or in pager mode, where
--- the cursor is not drawn, the page in the middle of the view.
local function update_badge(st, win, view)
  local text = st.pager and (' PAGER %d/%d '):format(page_at(view.layout, view.top + view.height / 2), #st.pages)
    or (' %d/%d '):format(st.info[api.nvim_win_get_cursor(win)[1]][1] + 1, #st.pages)
  local width = #text
  local config = {
    relative = 'win',
    win = st.pane.win,
    row = view.rows - 1,
    col = view.cols - math.ceil(scrollbar_width(view.width) / kitty.cell_size().width) - width,
    width = width,
    height = 1,
  }
  if config.col < 0 or config.row < 1 then return close_badge(st) end
  local b = st.badge
  if b and api.nvim_win_is_valid(b.win) then
    if b.config.row ~= config.row or b.config.col ~= config.col or b.config.width ~= width then api.nvim_win_set_config(b.win, config) end
  else
    local bbuf = api.nvim_create_buf(false, true)
    vim.bo[bbuf].bufhidden = 'wipe'
    local opts = { focusable = false, mouse = false, zindex = 2, style = 'minimal', noautocmd = true }
    b = { buf = bbuf, win = api.nvim_open_win(bbuf, false, vim.tbl_extend('force', config, opts)) }
    vim.wo[b.win].winhighlight = 'Normal:PdfViewPage'
    st.badge = b
  end
  b.config = config
  if b.text ~= text then
    api.nvim_buf_set_lines(b.buf, 0, -1, false, { text })
    b.text = text
  end
end

--- Matches of the search being typed (incsearch) or of the last search (while
--- 'hlsearch' shows it) on the lines `visible`, as helper ranges.
local function search_ranges(buf, visible)
  local st = states[buf]
  local pattern = st.incsearch
  if not pattern and vim.o.hlsearch and vim.v.hlsearch == 1 then pattern = vim.fn.getreg '/' end
  if not pattern or pattern == '' or #visible == 0 then return nil end
  -- matchbufline ignores 'smartcase' and assumes 'magic'; honour search options.
  local ic = vim.o.ignorecase and not (vim.o.smartcase and vim.fn.match(pattern, [[\u]]) >= 0)
  pattern = (ic and [[\c]] or [[\C]]) .. (vim.o.magic and [[\m]] or [[\M]]) .. pattern
  local ok, matches = pcall(vim.fn.matchbufline, buf, pattern, visible[1], visible[#visible])
  if not ok then return nil end
  local shown = {}
  for _, lnum in ipairs(visible) do
    shown[lnum] = true
  end
  local ranges = {}
  for _, m in ipairs(matches) do
    if shown[m.lnum] and m.text ~= '' then
      local text = st.lines[m.lnum]
      ranges[#ranges + 1] = { m.lnum, char_index(text, m.byteidx), char_index(text, m.byteidx + #m.text) - 1 }
    end
  end
  return #ranges > 0 and ranges or nil
end

--- Tints for the view: search matches, then the selection (visual mode in `win`)
--- or else the cursor line, then the character under the cursor (neither in pager mode).
local function marks_for(buf, win, view)
  local st = states[buf]
  local visible = lines_in(st, view.layout, view.top, view.height)
  local marks = {}
  local found = search_ranges(buf, visible)
  if found then marks[#marks + 1] = { ranges = found, color = COLORS.search } end
  local lnum, col = unpack(api.nvim_win_get_cursor(win))
  local ranges = win == api.nvim_get_current_win() and selection(buf)
  if ranges then
    local shown = {}
    for _, l in ipairs(visible) do
      shown[l] = true
    end
    ranges = vim.tbl_filter(function(r) return shown[r[1]] end, ranges)
    if #ranges > 0 then marks[#marks + 1] = { ranges = ranges, color = COLORS.selection } end
  end
  if st.info[lnum][4] or st.pager then return marks end
  local text = st.lines[lnum]
  if not ranges then marks[#marks + 1] = { ranges = { { lnum, 0, vim.str_utfindex(text, 'utf-32') - 1 } }, color = COLORS.cursor } end
  local ci = char_index(text, col)
  marks[#marks + 1] = {
    ranges = { { lnum, ci, ci } },
    color = COLORS.cursor_char,
    outline = not editor_focused or win ~= api.nvim_get_current_win(),
  }
  return marks
end

--- Point the pane at a freshly rendered PNG (the terminal deletes the file).
local function show(st, png, view)
  local pbuf, grid = st.pane.buf, view.cols .. 'x' .. view.rows
  local id = kitty.show(png, view.cols, view.rows)
  if st.grid ~= grid then
    vim.bo[pbuf].modifiable = true
    api.nvim_buf_set_lines(pbuf, 0, -1, false, kitty.placeholders(view.cols, view.rows))
    vim.bo[pbuf].modifiable = false
    st.grid = grid
  end
  api.nvim_buf_clear_namespace(pbuf, NS, 0, -1)
  api.nvim_buf_set_extmark(pbuf, NS, 0, 0, { end_row = view.rows, end_col = 0, strict = false, hl_group = kitty.hl(id) })
  -- Free the previous image only once the cells point at the new one, to avoid flicker.
  if st.image then
    vim.cmd.redraw()
    kitty.delete(st.image)
  end
  st.image = id
end

local render_id = 0

--- Render the pages for `buf`, following the cursor of `win`. At most one render
--- is in flight per buffer; requests arriving meanwhile collapse into one rerun.
local function render(buf, win)
  local st = states[buf]
  if not (st and win and pane_valid(st) and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf) then return end
  if st.busy then
    st.again = win
    return
  end
  local view = view_for(buf, win)
  update_badge(st, win, view)
  local marks = marks_for(buf, win, view)
  local key = vim.json.encode { view.top, view.width, view.height, marks, st.version }
  if key == st.render_key then return end
  st.view, st.render_key, st.busy = view, key, true
  render_id = render_id + 1
  -- kitty and Ghostty only accept temporary files named like this, in $TMPDIR.
  local png = vim.fs.joinpath(kitty.tmpdir(), ('tty-graphics-protocol-pdfview-%d-%d.png'):format(vim.fn.getpid(), render_id))
  local pane_buf = st.pane.buf
  local params = {
    key = buf,
    top = view.top,
    width = view.width,
    height = view.height,
    gap = view.layout.gap,
    marks = marks,
    scrollbar = scrollbar_width(view.width),
    out = png,
  }
  request('render', params, function(err)
    st.busy = false
    if err then
      st.render_key = nil
      os.remove(png)
      notify(err, vim.log.levels.ERROR)
    elseif states[buf] == st and pane_valid(st) and st.pane.buf == pane_buf then
      show(st, png, view)
    else
      os.remove(png)
    end
    local again = st.again
    st.again = nil
    if again and not err then render(buf, again) end
  end)
end

local function refresh(buf)
  vim.schedule(function()
    local win = states[buf] and text_window(buf)
    if not win then return end
    attach(buf, win)
    render(buf, cursor_window(buf))
  end)
end

--- Leave pager mode: put back the buffer's own mappings of the pager keys.
--- The caller repaints, if the view is still there.
local function leave_pager(buf)
  local st = states[buf]
  local saved = st.pager
  if not saved then return end
  st.pager = nil
  if not api.nvim_buf_is_valid(buf) then return end
  api.nvim_buf_call(buf, function()
    for lhs, map in pairs(saved) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
      if map then vim.fn.mapset(map) end
    end
  end)
end

--- Switch `buf` between page mode and split mode.
local function toggle(buf)
  local st = states[buf]
  leave_pager(buf)
  st.mode = st.mode == 'page' and 'split' or 'page'
  local win = text_window(buf)
  uncover(st)
  close_pane(st)
  if win then
    attach(buf, win)
    render(buf, cursor_window(buf))
  end
end

--- A file opened in the hidden float (:e, :bnext, a picker, <C-o>) moves to the
--- covered window, which then stops showing the pages.
local function hand_over(buf, focus)
  local st = states[buf]
  if not (st and st.focus == focus and covered(st)) then return end
  local host, other = st.host, api.nvim_win_get_buf(focus)
  if other == buf then return end
  local view = api.nvim_win_call(focus, vim.fn.winsaveview)
  -- Do the native buffer switch before dismantling the view: 'hidden' may be
  -- off and annotations unsaved. On refusal keep the PDF visible and editable.
  local ok, err = pcall(api.nvim_win_set_buf, host, other)
  if not ok then
    api.nvim_win_set_buf(focus, buf)
    api.nvim_win_set_cursor(focus, api.nvim_win_get_cursor(host))
    notify(err, vim.log.levels.ERROR)
    return
  end
  st.focus = nil
  host_active(st, false)
  st.host = nil
  close_pane(st)
  api.nvim_set_current_win(host)
  vim.fn.winrestview(view)
  pcall(api.nvim_win_close, focus, true)
end

--- The hidden float was closed (:q, :wq, :close, <C-w>c in it): close the covered
--- window too, or quit when it is the last one in the tab; cover it again if that
--- is refused or cancelled.
local function close_host(buf, host)
  local st = states[buf]
  if not st then return end
  host_active(st, false)
  st.host = nil
  close_pane(st)
  if not (host and api.nvim_win_is_valid(host) and api.nvim_win_get_buf(host) == buf) then return end
  api.nvim_set_current_win(host)
  local normal = vim.tbl_filter(function(w) return not is_float(w) end, api.nvim_tabpage_list_wins(0))
  local ok, err = pcall(vim.cmd, #normal == 1 and 'confirm quit' or 'confirm close')
  if not ok then notify(err, vim.log.levels.ERROR) end
  if api.nvim_win_is_valid(host) and api.nvim_win_get_buf(host) == buf then
    attach(buf, host)
    render(buf, cursor_window(buf))
  end
end

--- Cell (0-based row, col) of the pane over point (x, y) of 0-based `page`, or nil when off view.
local function cell_at(st, page, x, y)
  local v, cell = st.view, kitty.cell_size()
  if not (v and cell) then return end
  local L, i = v.layout, page + 1
  local row = math.floor((L.tops[i] + y * L.scales[i] - v.top) / cell.height)
  local col = math.floor(x * L.scales[i] / cell.width)
  if row >= 0 and row < v.rows and col >= 0 and col < v.cols then return row, col end
end

-- Scrolling and clicking in page mode -------------------------------------------

--- Scroll the view by `delta` doc pixels. Like Vim, the cursor stays on screen:
--- if it scrolled out, it moves to the first (scrolling down) or last line now in view.
local function scroll_by(buf, delta)
  local st = states[buf]
  local L, height, win = st.layout, st.top_height, st.focus
  st.top = clamp_top(L, height, st.top + delta)
  local m = margin(height)
  local lnum = api.nvim_win_get_cursor(win)[1]
  local a, b = line_span(st, L, lnum)
  if a < st.top + m or b > st.top + height - m then
    local best, best_y
    for _, l in ipairs(lines_in(st, L, st.top + m, height - 2 * m)) do
      local la, lb = line_span(st, L, l)
      local y = delta > 0 and la or -lb
      if la >= st.top + m and lb <= st.top + height - m and (not best or y < best_y) then
        best, best_y = l, y
      end
    end
    -- Column 0 keeps the cursor's column.
    if best then api.nvim_win_call(win, function() vim.fn.cursor(best, 0) end) end
  end
  st.follow_lnum = api.nvim_win_get_cursor(win)[1]
  render(buf, win)
end

--- zt / zz / zb: put the cursor line at the top (0), middle (0.5) or bottom (1) of the view.
local function align(buf, where)
  local st = states[buf]
  local L, height = st.layout, st.top_height
  local lnum = api.nvim_win_get_cursor(st.focus)[1]
  local a, b = line_span(st, L, lnum)
  local m = margin(height)
  local top = where == 0 and a - m or where == 1 and b - height + m or (a + b - height) / 2
  st.top, st.follow_lnum = clamp_top(L, height, top), lnum
  render(buf, st.focus)
end

--- ]p / [p: move the cursor to the first line of the page `count` pages after (dir 1)
--- or before (dir -1) the cursor's, and show that page from its top.
local function jump_page(buf, dir, count)
  local st = states[buf]
  local win = api.nvim_get_current_win()
  local page = st.info[api.nvim_win_get_cursor(win)[1]][1] + 1
  local target = math.max(1, math.min(#st.pages, page + dir * count))
  local header = st.headers[target]
  -- The page header when the page has no text.
  local lnum = header + 1 < (st.headers[target + 1] or #st.lines + 1) and header + 1 or header
  if st.layout and st.top_height and pane_valid(st) then
    st.top, st.follow_lnum = clamp_top(st.layout, st.top_height, st.layout.tops[target]), lnum
  end
  api.nvim_win_set_cursor(win, { lnum, 0 })
  render(buf, win)
end

--- H / M / L: move the cursor to the top (0), middle (0.5) or bottom (1) line in view.
local function screen_line(buf, where)
  local st = states[buf]
  local L, height = st.layout, st.top_height
  local m = margin(height)
  local target = st.top + m + where * (height - 2 * m)
  local best, best_d
  for _, l in ipairs(lines_in(st, L, st.top + m, height - 2 * m)) do
    local a, b = line_span(st, L, l)
    local d = math.abs((where == 0 and a or where == 1 and b or (a + b) / 2) - target)
    if not best or d < best_d then
      best, best_d = l, d
    end
  end
  if not best then return end
  vim.cmd "normal! m'"
  api.nvim_win_set_cursor(st.focus, { best, 0 })
end

-- Pager mode: like less or Vimium, keys pan the pages and the cursor is not
-- drawn (it still follows the view, so leaving resumes there). The pager keys
-- stand in for the buffer's own mappings of the same keys until it ends.

--- { keys, action(st), description } for pager mode in `buf`.
local function pager_keys(buf)
  local function rows(n) return n * kitty.cell_size().height end
  local function step() return rows(3 * vim.v.count1) end
  local function half(st) return vim.v.count > 0 and rows(vim.v.count) or st.top_height / 2 end
  local function screen(st) return (st.top_height - rows(2)) * vim.v.count1 end
  return {
    { { 'j', '<Down>', '<CR>' }, function() scroll_by(buf, step()) end, 'pan down' },
    { { 'k', '<Up>' }, function() scroll_by(buf, -step()) end, 'pan up' },
    { { 'd' }, function(st) scroll_by(buf, half(st)) end, 'pan down half a screen' },
    { { 'u' }, function(st) scroll_by(buf, -half(st)) end, 'pan up half a screen' },
    { { 'f', '<Space>' }, function(st) scroll_by(buf, screen(st)) end, 'pan down a screen' },
    { { 'b' }, function(st) scroll_by(buf, -screen(st)) end, 'pan up a screen' },
    { { 'gg' }, function(st) scroll_by(buf, -st.top) end, 'pan to the start' },
    { { 'G' }, function(st) scroll_by(buf, st.layout.total) end, 'pan to the end' },
    { { 'q', '<Esc>' }, function(st)
      leave_pager(buf)
      render(buf, st.focus)
    end, 'leave pager mode' },
  }
end

local function enter_pager(buf)
  local st = states[buf]
  if st.pager then return end
  if not (covered(st) and st.top and api.nvim_get_current_win() == st.focus) then
    return notify('Pager mode needs the full-window page view', vim.log.levels.WARN)
  end
  st.pager = {}
  for _, k in ipairs(pager_keys(buf)) do
    for _, lhs in ipairs(k[1]) do
      local saved = vim.fn.maparg(lhs, 'n', false, true)
      st.pager[lhs] = saved.buffer == 1 and saved or false
      vim.keymap.set('n', lhs, function()
        if covered(st) and api.nvim_get_current_win() == st.focus then return k[2](st) end
        -- The page view is gone (another window, :q, ...): end pager mode and do the key's usual thing.
        local count = vim.v.count > 0 and vim.v.count or ''
        leave_pager(buf)
        api.nvim_feedkeys(count .. vim.keycode(lhs), 'm', false)
      end, { buffer = buf, desc = 'PDF pager: ' .. k[3] })
    end
  end
  render(buf, st.focus)
end

--- Move the cursor to the character under a mouse click on the pages.
--- Returns false when the click was not on the pages.
local function click(buf)
  local st = states[buf]
  local pos = vim.fn.getmousepos()
  if not (st and st.view and pane_valid(st) and (pos.winid == st.pane.win or (covered(st) and pos.winid == st.host))) then return false end
  local cell, v = kitty.cell_size(), st.view
  if pos.winrow < 1 or pos.winrow > v.rows or pos.wincol < 1 or pos.wincol > v.cols then return false end
  local L = v.layout
  local y = v.top + (pos.winrow - 0.5) * cell.height
  local i = page_at(L, y)
  local s = L.scales[i]
  local hit = try_call('hit', { key = buf, page = i - 1, x = (pos.wincol - 0.5) * cell.width / s, y = (y - L.tops[i]) / s })
  local win = cursor_window(buf)
  if not win then return true end
  if vim.fn.mode():match '^[vV\22]' then vim.cmd 'normal! \27' end
  if api.nvim_get_current_win() ~= win then api.nvim_set_current_win(win) end
  local lnum = hit and hit[1] or st.headers[i]
  api.nvim_win_set_cursor(win, { lnum, hit and byte_index(st.lines[lnum], hit[2]) or 0 })
  return true
end

-- leap.nvim on the page view -----------------------------------------------------

local NS_LABELS = api.nvim_create_namespace 'pdfview.labels'

local function clear_labels()
  for _, st in pairs(states) do
    if pane_valid(st) then api.nvim_buf_clear_namespace(st.pane.buf, NS_LABELS, 0, -1) end
  end
end

--- Copy the labels leap is about to draw in PDF buffers onto their page panes,
--- in the cell over each target's first character.
local function mirror_labels(targets, first, last)
  local by_buf = {}
  for i = first or 1, last or #targets do
    local t = targets[i]
    local buf = t.wininfo and t.wininfo.bufnr
    local st = states[buf]
    local virt_text = t.beacon and t.beacon[2].virt_text
    if virt_text and t.pos and st and st.view and pane_valid(st) and not st.info[t.pos[1]][4] then
      local lnum = t.pos[1]
      by_buf[buf] = by_buf[buf] or {}
      table.insert(by_buf[buf], { lnum = lnum, char = char_index(st.lines[lnum], t.pos[2] - 1 + t.beacon[1]), virt_text = virt_text, box = t.beacon[1] == 0 and t.box })
    end
  end
  for buf, labels in pairs(by_buf) do
    local st = states[buf]
    local missing = vim.tbl_filter(function(l) return not l.box end, labels)
    local boxes = #missing == 0 and {} or try_call('char_boxes', { key = buf, chars = vim.tbl_map(function(l) return { l.lnum, l.char } end, missing) })
    if boxes then
      for i, l in ipairs(missing) do
        l.box = boxes[i]
      end
      for _, l in ipairs(labels) do
        local b = l.box
        local width = 0
        for _, chunk in ipairs(l.virt_text) do
          width = width + api.nvim_strwidth(chunk[1])
        end
        local row, col = cell_at(st, st.info[l.lnum][1], b[1], (b[2] + b[4]) / 2)
        if row then
          api.nvim_buf_set_extmark(st.pane.buf, NS_LABELS, row, 0, { virt_text = l.virt_text, virt_text_win_col = math.min(col, st.view.cols - width), strict = false })
        end
      end
    end
  end
end

-- leap's `on_beacons` hook (an experimental escape hatch in its README) sees
-- every target with its label right before leap draws it. Wrap any existing
-- hook rather than replace it; re-checked on every leap call in case the user
-- sets their own later.
local leap_hook
local function hook_leap()
  local ok, leap = pcall(require, 'leap')
  if not ok then return end
  -- rawget: leap's opts table recurses forever on unset keys.
  local defaults = leap.opts
  local prev = rawget(defaults, 'on_beacons')
  if leap_hook and prev == leap_hook then return end
  leap_hook = function(targets, first, last)
    if prev and prev(targets, first, last) == false then return false end
    mirror_labels(targets, first, last)
  end
  defaults.on_beacons = leap_hook
end

--- leap targets for every line the page view shows (not only the lines a text
--- window shows): reads the two pattern characters itself, matching like leap
--- does (case-insensitive, leap's equivalence classes, end of line as whitespace),
--- and orders the matches by distance from the cursor on the page.
local function leap_targets(buf, win)
  local st = states[buf]
  local class = {}
  for _, cls in ipairs(require('leap.opts').equivalence_classes or {}) do
    local chars = type(cls) == 'table' and cls or vim.fn.split(cls, [[\zs]])
    for _, c in ipairs(chars) do
      class[c] = chars[1]
    end
  end
  local function norm(c)
    c = vim.fn.tolower(c)
    return class[c] or c
  end
  return function()
    local in1 = vim.fn.getcharstr()
    if in1 == '\27' then return nil, '' end
    local in2 = vim.fn.getcharstr()
    if in2 == '\27' then return nil, '' end
    local c1, c2 = norm(in1), norm(in2)
    local v = st.view
    local cur = api.nvim_win_get_cursor(win)
    local targets, chars = {}, {}
    for _, lnum in ipairs(lines_in(st, v.layout, v.top, v.height)) do
      local text = st.lines[lnum]
      local line = vim.fn.split(text, [[\zs]])
      for i, c in ipairs(line) do
        local pos = { lnum, byte_index(text, i - 1) + 1 }
        if norm(c) == c1 and norm(line[i + 1] or '\n') == c2 and not (pos[1] == cur[1] and pos[2] == cur[2] + 1) then
          targets[#targets + 1] = { pos = pos }
          chars[#chars + 1] = { lnum, i - 1 }
        end
      end
    end
    if #targets == 0 then return nil, 'not found: ' .. in1 .. in2 end
    local info = st.info[cur[1]]
    if not info[4] then chars[#chars + 1] = { cur[1], char_index(st.lines[cur[1]], cur[2]) } end
    local boxes = try_call('char_boxes', { key = buf, chars = chars })
    if not boxes then return nil, '' end
    local L = v.layout
    local function point(page, box)
      local i = page + 1
      return box[1] * L.scales[i], L.tops[i] + (box[2] + box[4]) / 2 * L.scales[i]
    end
    local cx, cy
    if info[4] then
      cx, cy = 0, L.tops[info[1] + 1]
    else
      cx, cy = point(info[1], boxes[#boxes])
    end
    for i, t in ipairs(targets) do
      t.box = boxes[i]
      local x, y = point(st.info[t.pos[1]][1], t.box)
      t.dist = (x - cx) ^ 2 + (y - cy) ^ 2
    end
    targets = vim.tbl_filter(function(t)
      local row = cell_at(st, st.info[t.pos[1]][1], t.box[1], (t.box[2] + t.box[4]) / 2)
      return row ~= nil
    end, targets)
    table.sort(targets, function(a, b)
      if a.dist ~= b.dist then return a.dist < b.dist end
      return a.pos[1] < b.pos[1] or a.pos[1] == b.pos[1] and a.pos[2] < b.pos[2]
    end)
    return targets
  end
end

--- leap with the page view's targets; plain leap when there is no page view.
local function leap_on_page(buf)
  local st = states[buf]
  local win = api.nvim_get_current_win()
  local kwargs = { windows = { win }, inclusive = true }
  if st and st.view and pane_valid(st) then kwargs.targets = leap_targets(buf, win) end
  require('leap').leap(kwargs)
end

--- Keys mapped to leap's <Plug>(leap), per mode, or M.config.keys.leap in n/x/o.
local function leap_keys()
  local key = M.config.keys.leap
  if key == false then return {} end
  if type(key) == 'string' then return { { mode = { 'n', 'x', 'o' }, lhs = key } } end
  local found = {}
  for _, mode in ipairs { 'n', 'x', 'o' } do
    for _, m in ipairs(api.nvim_get_keymap(mode)) do
      if m.rhs == '<Plug>(leap)' then found[#found + 1] = { mode = mode, lhs = m.lhs } end
    end
  end
  return found
end

-- Annotation actions ---------------------------------------------------------

--- Only annotation state goes into this buffer; PDF text remains a motion index.
--- Neovim owns the undo tree, including counts and branches. Nothing is written
--- to disk for history, and reloading the PDF starts a fresh tree.
local function reset_history(st, buf, state)
  if st.history and api.nvim_buf_is_valid(st.history) then api.nvim_buf_delete(st.history, { force = true }) end
  local history = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(history, ('pdfview-history://%d'):format(buf))
  vim.bo[history].bufhidden = 'hide'
  vim.bo[history].swapfile = false
  vim.bo[history].undofile = false
  api.nvim_buf_call(history, function()
    vim.bo.undolevels = -1
    api.nvim_buf_set_lines(history, 0, -1, false, vim.split(state, '\n', { plain = true }))
    vim.bo.undolevels = vim.go.undolevels
  end)
  vim.bo[history].modified = false
  st.history, st.history_state, st.saved_state = history, state, state
end

local function record_state(st, state)
  if state == st.history_state then return end
  api.nvim_buf_call(st.history, function()
    api.nvim_buf_set_lines(st.history, 0, -1, false, vim.split(state, '\n', { plain = true }))
    -- Hidden buffers do not cross normal-mode command boundaries themselves.
    -- Close this undo block explicitly so counts work on the very next undo.
    vim.bo.undolevels = vim.bo.undolevels
  end)
  st.history_state = state
end

local function apply(buf, res, from_history)
  local st = states[buf]
  if res.page == nil then
    st.annots = res.annots
  else
    st.annots = vim.tbl_filter(function(a) return a.page ~= res.page end, st.annots)
    vim.list_extend(st.annots, res.annots)
  end
  if not from_history then record_state(st, res.state) end
  st.history_state = res.state
  vim.bo[buf].modified = res.state ~= st.saved_state
  vim.bo[st.history].modified = vim.bo[buf].modified
  st.version = st.version + 1
  decorate(buf)
  render(buf, cursor_window(buf))
  vim.cmd.redrawstatus()
end

local function undo_annotations(buf, redo, count)
  local st = states[buf]
  local moved
  local seq = api.nvim_buf_call(st.history, function()
    local before = vim.fn.undotree().seq_cur
    vim.cmd('silent normal! ' .. count .. (redo and vim.keycode '<C-r>' or 'u'))
    moved = vim.fn.undotree().seq_cur ~= before
    return before
  end)
  if not moved then return notify(redo and 'Already at newest annotation change' or 'Already at oldest annotation change') end
  local state = table.concat(api.nvim_buf_get_lines(st.history, 0, -1, false), '\n')
  if state == st.history_state then return end
  local res = try_call('restore', { key = buf, state = state })
  if not res then
    -- A failed restore must not move just the shadow buffer's history pointer.
    api.nvim_buf_call(st.history, function() vim.cmd('silent undo ' .. seq) end)
    return
  end
  apply(buf, res, true)
end

local function under_cursor(buf, notes_only)
  local st = states[buf]
  local lnum, col = unpack(api.nvim_win_get_cursor(0))
  local ci = char_index(st.lines[lnum], col)
  local best, best_len
  for _, a in ipairs(st.annots) do
    if not notes_only or a.contents:find('%S') then
      if #a.ranges == 0 then
        if a.anchor[1] == lnum and not best then
          best, best_len = a, math.huge
        end
      else
        for _, r in ipairs(a.ranges) do
          if r[1] == lnum and ci >= r[2] and ci <= r[3] and (not best_len or r[3] - r[2] < best_len) then
            best, best_len = a, r[3] - r[2]
          end
        end
      end
    end
  end
  return best
end

--- Native hover UI, with PDF note text instead of an LSP response.
local function hover_note(buf)
  local a = under_cursor(buf, true)
  if not a then return notify('No note under the cursor') end
  local st = states[buf]
  local view = st.view
  local nbuf, win = vim.lsp.util.open_floating_preview(vim.split(a.contents, '\n', { plain = true }), 'markdown', {
    focus_id = 'pdfview.note',
    border = 'rounded',
    title = ' ' .. a.type .. ' note ',
    max_width = math.max(1, math.min(70, view and view.cols - 4 or vim.o.columns - 4)),
    max_height = math.max(1, math.min(20, view and math.floor(view.rows / 2) or vim.o.lines - 4)),
  })
  -- The hidden text cursor does not line up with the rendered glyph. Anchor the
  -- hover to that glyph on the page instead, keeping the whole float in view.
  if covered(st) and pane_valid(st) and view then
    local lnum, col = unpack(api.nvim_win_get_cursor(st.focus))
    if not st.info[lnum][4] then
      local boxes = try_call('char_boxes', { key = buf, chars = { { lnum, char_index(st.lines[lnum], col) } } })
      if boxes then
        local box = boxes[1]
        local row, column = cell_at(st, st.info[lnum][1], box[1], box[4])
        if row then
          local width, height = api.nvim_win_get_width(win), api.nvim_win_get_height(win)
          row = row + height + 3 <= view.rows and row + 1 or math.max(0, row - height - 2)
          column = math.max(0, math.min(column, view.cols - width - 2))
          api.nvim_win_set_config(win, { relative = 'win', win = st.pane.win, row = row, col = column, anchor = 'NW' })
        end
      end
    end
  end
  for _, key in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', key, function() api.nvim_win_close(win, true) end, { buffer = nbuf, desc = 'Close PDF note preview' })
  end
end

local note_id = 0

local function edit_note(buf, annot)
  note_id = note_id + 1
  local nbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(nbuf, ('pdfview-note://%d'):format(note_id))
  vim.bo[nbuf].buftype = 'acwrite'
  vim.bo[nbuf].bufhidden = 'wipe'
  vim.bo[nbuf].filetype = 'markdown'
  api.nvim_buf_call(nbuf, function()
    vim.bo.undolevels = -1
    api.nvim_buf_set_lines(nbuf, 0, -1, false, vim.split(annot.contents, '\n', { plain = true }))
    vim.bo.undolevels = vim.go.undolevels
  end)
  vim.bo[nbuf].modified = false
  local win = api.nvim_open_win(nbuf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = math.min(70, vim.o.columns - 4),
    height = 8,
    border = 'rounded',
    title = (' %s note · :w save · q save+close '):format(annot.type),
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  local function save()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(nbuf, 0, -1, false), '\n'))
    local res = try_call('set_contents', { key = buf, page = annot.page, xref = annot.xref, contents = text })
    if not res then return false end
    vim.bo[nbuf].modified = false
    if api.nvim_buf_is_valid(buf) then apply(buf, res) end
    return true
  end
  api.nvim_create_autocmd('BufWriteCmd', { buffer = nbuf, callback = save })
  vim.keymap.set('n', 'q', function()
    if not vim.bo[nbuf].modified or save() then api.nvim_win_close(win, true) end
  end, { buffer = nbuf, desc = 'Save note and close' })
end

local function annotate(buf, kind, with_note)
  local st, ranges = states[buf], selection(buf)
  vim.cmd 'normal! \27'
  if not ranges then return notify('Select text with v or V first', vim.log.levels.WARN) end
  if not ranges_page(st, ranges) then return notify('Selection must stay on one page', vim.log.levels.WARN) end
  local res = try_call('annotate', { key = buf, kind = kind, ranges = ranges })
  if not res then return end
  apply(buf, res)
  if with_note then
    for _, a in ipairs(st.annots) do
      if a.xref == res.xref and a.page == res.page then return edit_note(buf, a) end
    end
  end
end

local function edit_under_cursor(buf)
  local a = under_cursor(buf)
  if not a then return notify('No annotation under the cursor', vim.log.levels.WARN) end
  edit_note(buf, a)
end

local function delete_under_cursor(buf)
  local a = under_cursor(buf)
  if not a then return notify('No annotation under the cursor', vim.log.levels.WARN) end
  local res = try_call('delete', { key = buf, page = a.page, xref = a.xref })
  if res then apply(buf, res) end
end

local function jump(buf, dir, count)
  local st = states[buf]
  local lnum, col = unpack(api.nvim_win_get_cursor(0))
  local target
  for _ = 1, count do
    local found
    for i = dir > 0 and 1 or #st.annots, dir > 0 and #st.annots or 1, dir do
      local a = st.annots[i]
      local l, c = a.anchor[1], byte_index(st.lines[a.anchor[1]], a.anchor[2])
      if (dir > 0 and (l > lnum or (l == lnum and c > col))) or (dir < 0 and (l < lnum or (l == lnum and c < col))) then
        found = { l, c }
        break
      end
    end
    if not found then break end
    target, lnum, col = found, found[1], found[2]
  end
  if not target then return notify(dir > 0 and 'No next annotation' or 'No previous annotation') end
  vim.cmd "normal! m'"
  api.nvim_win_set_cursor(0, target)
end

local function list(buf)
  local st = states[buf]
  if #st.annots == 0 then return notify 'No annotations' end
  local items = {}
  for _, a in ipairs(st.annots) do
    local excerpt = a.contents
    if excerpt == '' and a.ranges[1] then
      local r = a.ranges[1]
      local text = st.lines[r[1]]
      excerpt = text:sub(byte_index(text, r[2]) + 1, byte_index(text, r[3] + 1))
    end
    items[#items + 1] = {
      bufnr = buf,
      lnum = a.anchor[1],
      col = byte_index(st.lines[a.anchor[1]], a.anchor[2]) + 1,
      text = ('p%d [%s] %s'):format(a.page + 1, a.type, vim.split(excerpt, '\n', { plain = true })[1]),
    }
  end
  vim.fn.setqflist({}, ' ', { title = 'PDF annotations: ' .. vim.fs.basename(st.path), items = items })
  vim.cmd.copen()
end

-- Snapshot for agents --------------------------------------------------------

--- PNG of the visible stacked pages (the cursor's whole page without a view),
--- plus a caption with per-page clips, selection bounds and note texts.
local function snapshot(buf)
  local st, ranges = states[buf], selection(buf)
  if ranges and not ranges_page(st, ranges) then return notify('Selection must stay on one page', vim.log.levels.WARN) end
  if ranges then vim.cmd 'normal! \27' end
  local v = st.view
  local width, height, top, gap
  if v then
    width = math.max(v.width, 1600)
    local scale = width / v.width
    height, top, gap = math.floor(v.height * scale), v.top * scale, v.layout.gap * scale
  else
    width, gap = 1600, 0
    local L = layout(st, width, gap)
    local i = st.info[api.nvim_win_get_cursor(0)[1]][1] + 1
    top, height = L.tops[i], math.ceil(L.heights[i])
  end
  local dir = M.config.snapshot_dir or vim.fs.joinpath(kitty.tmpdir(), 'pdfview')
  vim.fn.mkdir(dir, 'p')
  local png = vim.fs.joinpath(dir, ('snap-%s-%03d.png'):format(os.date '%Y%m%d-%H%M%S', uv.now() % 1000))
  local params =
    { key = buf, width = width, height = height, top = top, gap = gap, ranges = ranges or {}, color = COLORS.selection, out = png }
  if not try_call('snapshot', params) then return end
  if vim.fn.has 'mac' ~= 1 then return notify('Saved snapshot ' .. png .. ' (clipboard copy is macOS-only)') end
  local res = vim.system({ 'osascript', '-e', ('set the clipboard to (read (POSIX file "%s") as «class PNGf»)'):format(png) }):wait()
  if res.code ~= 0 then return notify('Clipboard copy failed: ' .. res.stderr, vim.log.levels.ERROR) end
  notify('Copied snapshot ' .. png)
end

-- Buffer lifecycle -----------------------------------------------------------

local function unload(buf)
  local st = states[buf]
  if not st then return end
  leave_pager(buf)
  states[buf] = nil
  if st.poll then st.poll:close() end
  uncover(st)
  close_pane(st)
  if st.history and api.nvim_buf_is_valid(st.history) then api.nvim_buf_delete(st.history, { force = true }) end
  if helper.proc then request('close', { key = buf }, function() end) end
end

local load

--- Reload after the file settles: LaTeX and friends write PDFs in several steps.
local function on_disk_change(buf)
  local st = states[buf]
  local key = st and stat_key(st.path)
  if not key or key == st.stat then return end
  vim.defer_fn(function()
    if states[buf] ~= st or stat_key(st.path) ~= key then return end
    if vim.bo[buf].modified then
      if st.warned ~= key then
        st.warned = key
        notify(vim.fs.basename(st.path) .. ' changed on disk; :e! reloads it and drops unsaved annotations', vim.log.levels.WARN)
      end
      return
    end
    local ok, err = pcall(load, buf)
    if not ok then notify('Reload failed: ' .. err, vim.log.levels.WARN) end
  end, 300)
end

local function write(buf, target)
  local st = states[buf]
  target = canonical(target)
  if target ~= st.path then
    call('save', { key = buf, path = target })
    return
  end
  if stat_key(st.path) ~= st.stat then
    error(vim.fs.basename(st.path) .. ' changed on disk since it was loaded; :e! to reload (drops unsaved annotations)', 0)
  end
  call('save', { key = buf })
  st.stat = stat_key(st.path)
  st.saved_state = st.history_state
  vim.bo[st.history].modified = false
  vim.bo[buf].modified = false
  vim.cmd.redrawstatus()
end

local function setup_buffer(buf)
  local group = api.nvim_create_augroup('pdfview.' .. buf, { clear = true })
  local function au(events, fn) api.nvim_create_autocmd(events, { group = group, buffer = buf, callback = fn }) end
  au({ 'CursorMoved', 'ModeChanged' }, function()
    local st, win = states[buf], api.nvim_get_current_win()
    -- The covered window's statusline shows its own cursor: keep it with the hidden float's.
    if st and covered(st) and win == st.focus then api.nvim_win_set_cursor(st.host, api.nvim_win_get_cursor(win)) end
    render(buf, win)
  end)
  au('BufWinEnter', function() refresh(buf) end)
  au('BufWinLeave', function()
    vim.schedule(function()
      local st = states[buf]
      if not st then return end
      if st.host and not (covered(st) and api.nvim_win_get_buf(st.host) == buf) then uncover(st) end
      if not text_window(buf) then close_pane(st) end
    end)
  end)
  -- Split mode: close the pane first so :q in the last text window exits nvim.
  au('QuitPre', function()
    local st = states[buf]
    if st and not covered(st) and #vim.fn.win_findbuf(buf) == 1 then close_pane(st) end
  end)
  au('BufWriteCmd', function(ev) write(buf, ev.match) end)
  -- :e! unloads and immediately re-reads the buffer; only tear down for real unloads.
  au('BufUnload', function()
    vim.schedule(function()
      if not api.nvim_buf_is_loaded(buf) then unload(buf) end
    end)
  end)

  local keys = M.config.keys
  local function map(mode, lhs, fn, desc)
    for _, l in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
      if l then vim.keymap.set(mode, l, fn, { buffer = buf, desc = 'PDF: ' .. desc }) end
    end
  end
  local function prefixed(suffix) return keys.prefix and keys.prefix .. suffix end
  map({ 'n', 'x' }, prefixed 'y', function() snapshot(buf) end, 'copy snapshot for agent')
  map('x', prefixed 'h', function() annotate(buf, 'highlight') end, 'highlight selection')
  map('x', prefixed 'u', function() annotate(buf, 'underline') end, 'underline selection')
  map('x', prefixed 's', function() annotate(buf, 'strikeout') end, 'strike out selection')
  map('x', prefixed 'n', function() annotate(buf, 'highlight', true) end, 'highlight selection with note')
  map('n', prefixed 'n', function() edit_under_cursor(buf) end, 'edit note under cursor')
  map('n', prefixed 'd', function() delete_under_cursor(buf) end, 'delete annotation under cursor')
  map('n', prefixed 'l', function() list(buf) end, 'list annotations')
  map('n', prefixed 't', function() toggle(buf) end, 'toggle page view / text with page pane')
  map('n', prefixed 'p', function() enter_pager(buf) end, 'pager mode: keys pan the pages')
  map('n', keys.hover, function() hover_note(buf) end, 'show note under cursor')
  map('n', keys.undo, function() undo_annotations(buf, false, vim.v.count1) end, 'undo annotation change')
  map('n', keys.redo, function() undo_annotations(buf, true, vim.v.count1) end, 'redo annotation change')
  map('n', keys.next_annotation, function() jump(buf, 1, vim.v.count1) end, 'next annotation')
  map('n', keys.prev_annotation, function() jump(buf, -1, vim.v.count1) end, 'previous annotation')
  map({ 'n', 'x' }, keys.next_page, function() jump_page(buf, 1, vim.v.count1) end, 'next page')
  map({ 'n', 'x' }, keys.prev_page, function() jump_page(buf, -1, vim.v.count1) end, 'previous page')

  if pcall(require, 'leap') then
    for _, k in ipairs(leap_keys()) do
      map(k.mode, k.lhs, function() leap_on_page(buf) end, 'leap to anything on the page view')
    end
  end

  -- In page mode the text window is hidden, so scrolling, H/M/L and clicks act on
  -- the pages. Elsewhere (split mode, other windows, the mouse over another
  -- window) the keys do what they always do.
  local function page_map(lhs, fn, desc, mouse)
    map({ 'n', 'x' }, lhs, function()
      local st = states[buf]
      if st and covered(st) and st.top and api.nvim_get_current_win() == st.focus and (not mouse or vim.fn.getmousepos().winid == st.host) then
        return fn(st)
      end
      api.nvim_feedkeys((vim.v.count > 0 and vim.v.count or '') .. vim.keycode(lhs), 'n', false)
    end, desc)
  end
  local function rows(n) return n * kitty.cell_size().height end
  page_map('<C-e>', function() scroll_by(buf, rows(vim.v.count1)) end, 'scroll the page down')
  page_map('<C-y>', function() scroll_by(buf, -rows(vim.v.count1)) end, 'scroll the page up')
  page_map('<C-d>', function(st) scroll_by(buf, vim.v.count > 0 and rows(vim.v.count) or st.top_height / 2) end, 'scroll the page down half a screen')
  page_map('<C-u>', function(st) scroll_by(buf, -(vim.v.count > 0 and rows(vim.v.count) or st.top_height / 2)) end, 'scroll the page up half a screen')
  page_map('<C-f>', function(st) scroll_by(buf, (st.top_height - rows(2)) * vim.v.count1) end, 'scroll the page down a screen')
  page_map('<C-b>', function(st) scroll_by(buf, -(st.top_height - rows(2)) * vim.v.count1) end, 'scroll the page up a screen')
  page_map('<ScrollWheelDown>', function() scroll_by(buf, rows(3 * vim.v.count1)) end, 'scroll the page down', true)
  page_map('<ScrollWheelUp>', function() scroll_by(buf, -rows(3 * vim.v.count1)) end, 'scroll the page up', true)
  page_map('zt', function() align(buf, 0) end, 'cursor line to the top of the view')
  page_map('zz', function() align(buf, 0.5) end, 'cursor line to the middle of the view')
  page_map('zb', function() align(buf, 1) end, 'cursor line to the bottom of the view')
  page_map('H', function() screen_line(buf, 0) end, 'cursor to the top line in view')
  page_map('M', function() screen_line(buf, 0.5) end, 'cursor to the middle line in view')
  page_map('L', function() screen_line(buf, 1) end, 'cursor to the bottom line in view')
  page_map('<LeftDrag>', function() end, 'ignore drags on the page', true)
  map({ 'n', 'x' }, '<LeftMouse>', function()
    if not click(buf) then api.nvim_feedkeys(vim.keycode '<LeftMouse>', 'n', false) end
  end, 'move the cursor to the clicked character')
end

load = function(buf)
  local path = canonical(api.nvim_buf_get_name(buf))
  -- :e! keeps the buffer's mappings, and setup_buffer sets the usual ones again.
  if states[buf] then leave_pager(buf) end
  local res = call('open', { key = buf, path = path })
  local st = states[buf] or {}
  states[buf] = st
  st.path, st.lines, st.info, st.pages, st.annots = path, res.lines, res.info, res.pages, res.annots
  reset_history(st, buf, res.state)
  st.stat, st.warned, st.version = stat_key(path), nil, (st.version or 0) + 1
  st.mode, st.layout, st.headers = st.mode or M.config.view, nil, {}
  for lnum, info in ipairs(st.info) do
    if info[4] then st.headers[info[1] + 1] = lnum end
  end

  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
  end
  -- No swap file: the text is derived from the PDF, and a swap left by another
  -- nvim on the same PDF would otherwise raise E325 on the first set_lines.
  for option, value in pairs { swapfile = false, undolevels = -1, modifiable = true } do
    vim.bo[buf][option] = value
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, st.lines)
  for option, value in pairs { modifiable = false, modified = false, buftype = 'acwrite', filetype = 'pdfview' } do
    vim.bo[buf][option] = value
  end
  for win, view in pairs(views) do
    api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
  end

  decorate(buf)
  setup_buffer(buf)
  if not st.poll then
    st.poll = assert(uv.new_fs_poll())
    st.poll:start(path, 500, function()
      vim.schedule(function() on_disk_change(buf) end)
    end)
  end
  refresh(buf)
end

---@param opts? pdfview.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  set_hls()
  -- An earlier ModeChanged handler (notably which-key) can wait in getchar()
  -- before our handler runs. Scheduled input callbacks still run during that
  -- wait, so repaint after input as well as on native cursor/mode events.
  vim.on_key(function()
    local buf = api.nvim_get_current_buf()
    local st = states[buf]
    if not st or st.input_refresh_pending then return end
    st.input_refresh_pending = true
    vim.schedule(function()
      st.input_refresh_pending = nil
      if states[buf] == st and api.nvim_get_current_buf() == buf then render(buf, api.nvim_get_current_win()) end
    end)
  end, NS)
  api.nvim_create_autocmd('ColorScheme', { group = GROUP, callback = set_hls })
  api.nvim_create_autocmd('BufReadCmd', {
    group = GROUP,
    pattern = { '*.pdf', '*.PDF' },
    callback = function(ev)
      local ok, err = pcall(load, ev.buf)
      if not ok then notify('Cannot open ' .. ev.match .. ': ' .. err, vim.log.levels.ERROR) end
    end,
  })
  api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = GROUP,
    callback = function(ev)
      for buf, st in pairs(states) do
        if covered(st) then
          pcall(api.nvim_win_set_config, st.pane.win, pane_float(st.host))
          pcall(api.nvim_win_set_config, st.focus, focus_float(st.host))
          render(buf, st.focus)
        else
          local win = text_window(buf)
          if win and ev.event == 'VimResized' and pane_valid(st) then
            local total = api.nvim_win_get_width(win) + api.nvim_win_get_width(st.pane.win)
            api.nvim_win_set_width(st.pane.win, pane_columns(total))
          end
          if win then render(buf, win) end
        end
      end
    end,
  })
  -- Page mode keeps focus in the hidden float: entering the covered window (<C-w>
  -- motions, :cc and friends) passes on to it, with that window's cursor.
  api.nvim_create_autocmd('WinEnter', {
    group = GROUP,
    callback = function()
      local win = api.nvim_get_current_win()
      for buf, st in pairs(states) do
        if covered(st) then
          host_active(st, win == st.focus)
          if win == st.host then
            vim.schedule(function()
              if covered(st) and api.nvim_get_current_win() == st.host then
                api.nvim_win_set_cursor(st.focus, api.nvim_win_get_cursor(st.host))
                api.nvim_set_current_win(st.focus)
              end
            end)
          end
        end
        render(buf, cursor_window(buf))
      end
    end,
  })
  api.nvim_create_autocmd({ 'FocusLost', 'FocusGained' }, {
    group = GROUP,
    callback = function(ev)
      editor_focused = ev.event == 'FocusGained'
      for buf in pairs(states) do
        render(buf, cursor_window(buf))
      end
    end,
  })
  api.nvim_create_autocmd('BufEnter', {
    group = GROUP,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      for buf, st in pairs(states) do
        if st.focus == win and ev.buf ~= buf then
          vim.schedule(function() hand_over(buf, win) end)
        end
      end
    end,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = GROUP,
    callback = function(ev)
      local closed = tonumber(ev.match)
      for buf, st in pairs(states) do
        if closed == st.focus then
          st.focus = nil
          local host = st.host
          vim.schedule(function() close_host(buf, host) end)
        elseif closed == st.host then
          vim.schedule(function() uncover(st) end)
        end
      end
    end,
  })
  -- The hidden text window cannot show incsearch: highlight the matches on the
  -- pages and pan to the one the search would land on.
  api.nvim_create_autocmd('CmdlineChanged', {
    group = GROUP,
    pattern = { '/', '?' },
    callback = function()
      local buf = api.nvim_get_current_buf()
      local st = states[buf]
      if not (st and pane_valid(st)) then return end
      st.incsearch = vim.fn.getcmdline()
      -- Native incsearch updates the real cursor after CmdlineChanged returns.
      vim.schedule(function()
        if states[buf] == st and api.nvim_get_current_buf() == buf then render(buf, api.nvim_get_current_win()) end
      end)
    end,
  })
  api.nvim_create_autocmd('CmdlineLeave', {
    group = GROUP,
    pattern = { '/', '?' },
    callback = function()
      local buf = api.nvim_get_current_buf()
      local st = states[buf]
      if not (st and st.incsearch) then return end
      st.incsearch = nil
      -- After the search has moved the cursor (or not, when cancelled).
      vim.schedule(function()
        local win = states[buf] and cursor_window(buf)
        if win then render(buf, win) end
      end)
    end,
  })
  -- leap fires LeapRedraw before drawing each round of labels, and LeapLeave at the end.
  -- Leap can move the cursor and then keep waiting for keys (autojump to the first
  -- target, traversal), and CursorMoved only fires once it returns. Render on
  -- LeapRedraw so the pane follows; it also sets st.view before the labels are mirrored.
  api.nvim_create_autocmd('User', {
    group = GROUP,
    pattern = 'LeapEnter',
    callback = function()
      hook_leap()
      local st = states[api.nvim_get_current_buf()]
      if st then st.leaping = true end
    end,
  })
  api.nvim_create_autocmd('User', {
    group = GROUP,
    pattern = 'LeapRedraw',
    callback = function()
      clear_labels()
      render(api.nvim_get_current_buf(), api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd('User', {
    group = GROUP,
    pattern = 'LeapLeave',
    callback = function()
      clear_labels()
      local buf = api.nvim_get_current_buf()
      local st = states[buf]
      if st then
        st.leaping = nil
        render(buf, api.nvim_get_current_win())
      end
    end,
  })
  -- Free image data held by the terminal.
  api.nvim_create_autocmd('VimLeavePre', {
    group = GROUP,
    callback = function()
      for _, st in pairs(states) do
        if st.image then kitty.delete(st.image) end
      end
    end,
  })
end

return M
