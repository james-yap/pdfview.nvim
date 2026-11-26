-- pdfview.nvim: a read-only text buffer for vim motions (hjkl, /, leap,
-- visual) shown as the rendered pages: the pages cover the PDF's window and
-- the text stays hidden. The view follows the cursor and tints the cursor line
-- or visual selection. Pages are drawn with the kitty graphics protocol
-- (lua/pdfview/kitty.lua); other terminals are refused.
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
--
-- Local HTML files open the same way: python/html_helper.py lays them out in
-- Chromium, and the buffer holds the page's text. :HtmlSource and :HtmlView
-- switch that buffer between the HTML source and the rendered view.
local M = {}
local api, uv = vim.api, vim.uv
local kitty = require 'pdfview.kitty'
local html = require 'pdfview.html'
local transport = require 'pdfview.helper'

local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local render
local helper = transport.new(vim.fs.joinpath(ROOT, 'python', 'helper.py'), 'PDF')
local browser = transport.new(vim.fs.joinpath(ROOT, 'python', 'html_helper.py'), 'HTML')
local request, call = helper.request, helper.call
local NS = api.nvim_create_namespace 'pdfview'
local GROUP = api.nvim_create_augroup('pdfview', { clear = true })
-- Tints for the page view / snapshot (multiplied over the page, so ink stays dark).
local COLORS = { cursor = 0xDDEBFF, cursor_char = 0x8AB8FF, selection = 0xA8D1FF, search = 0xFFE07A, cur_search = 0xFF9F43 }
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
    next_page = { ']p', '<C-j>', '<PageDown>' },
    prev_page = { '[p', '<C-k>', '<PageUp>' },
    leap = nil,
    hover = 'K',
    undo = 'u',
    redo = '<C-r>',
  },
  -- Where snapshots are written. nil: $TMPDIR/pdfview.
  snapshot_dir = nil, ---@type string?
  -- Size of rendered Typst notes; 1 makes their text about as large as the terminal's.
  -- A note still shrinks to fit its window.
  typst_scale = 1.2,
}

---@type table<integer, table> per document buffer
local states = {}
local editor_focused = true

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = 'pdfview' }) end

local function try_call(method, params)
  local source = states[params.key] and states[params.key].html and browser or helper
  local ok, res = pcall(source.call, method, params)
  if not ok then notify(res, vim.log.levels.ERROR) end
  return ok and res or nil
end

-- Text geometry --------------------------------------------------------------

local function char_index(text, byte) return vim.str_utfindex(text, 'utf-32', math.min(byte, #text), false) end
local function byte_index(text, char) return vim.str_byteindex(text, 'utf-32', char, false) end

local function is_header(st, lnum) return not st.html and st.info[lnum][4] end

--- Absolute path with symlinks resolved (/tmp vs /private/tmp), for comparing write targets.
local function canonical(path)
  path = vim.fn.fnamemodify(path, ':p')
  return uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function stat_key(path)
  local s = uv.fs_stat(path)
  return s and table.concat({ s.ino, s.size, s.mtime.sec, s.mtime.nsec }, ':')
end

local function is_html_path(path) return path:lower():match '%.html?$' ~= nil end

--- Set the text of document buffer `buf` to `lines`, rewriting only the lines
--- that changed so the others keep their marks.
local function set_text(buf, lines)
  if #lines == 0 then lines[1] = '' end
  local old = api.nvim_buf_get_lines(buf, 0, -1, false)
  local first = 1
  while first <= #old and old[first] == lines[first] do first = first + 1 end
  vim.bo[buf].modifiable = true
  if first <= #old or first <= #lines then
    local last, stop = #old, #lines
    while last >= first and stop >= first and old[last] == lines[stop] do
      last, stop = last - 1, stop - 1
    end
    api.nvim_buf_set_lines(buf, first - 1, last, false, vim.list_slice(lines, first, stop))
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function html_selection(st, mode)
  local ranges = {}
  for _, pair in ipairs(vim.fn.getregionpos(vim.fn.getpos 'v', vim.fn.getpos '.', { type = mode })) do
    local s, e = unpack(pair)
    local lnum = s[2]
    local text = st.lines[lnum]
    if #text > 0 then
      local cs = char_index(text, math.max(0, s[3] - 1))
      local ce = math.min(char_index(text, math.max(0, e[3] - 1)), vim.str_utfindex(text, 'utf-32') - 1)
      if cs <= ce then ranges[#ranges + 1] = { lnum, cs, ce } end
    end
  end
  return #ranges > 0 and ranges or nil
end

--- Visual selection of the current window as helper ranges {lnum, first char, last char}.
--- nil outside charwise/linewise visual mode; page headers are skipped.
local function selection(buf)
  local mode = vim.fn.mode()
  if states[buf].html and mode:match '^[vV\22]$' then return html_selection(states[buf], mode) end
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
-- A float (st.pane) covers the PDF buffer's window (st.host) and shows the
-- pages; focus sits in a hidden float on the same buffer (st.focus), so the
-- text and the terminal cursor are invisible while every key still drives the
-- text buffer. Other windows on the buffer show its text as usual.
-- The image is a cut of all pages stacked at the pane's width ("doc pixels"),
-- from st.top down, panned to follow the hidden float's cursor.

local function pane_valid(st) return st.pane ~= nil and api.nvim_win_is_valid(st.pane.win) end

local function close_badge(st)
  if st.badge and api.nvim_win_is_valid(st.badge.win) then api.nvim_win_close(st.badge.win, true) end
  st.badge = nil
end

local function close_pane(st)
  if st.image then kitty.delete(st.image) end
  close_badge(st)
  if pane_valid(st) then pcall(api.nvim_win_close, st.pane.win, true) end
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

local function new_pane_buf()
  local pbuf = api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = 'wipe'
  vim.bo[pbuf].filetype = 'pdfview_page'
  vim.bo[pbuf].modifiable = false
  return pbuf
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

--- Cover the text window `host` with the pages and move focus into a hidden
--- float on the same buffer.
local function cover(buf, host)
  local st = states[buf]
  if not (covered(st) and st.host == host) then
    uncover(st)
    close_pane(st)
    local pbuf = new_pane_buf()
    local pwin = api.nvim_open_win(pbuf, false, vim.tbl_extend('force', pane_float(host), { style = 'minimal', noautocmd = true }))
    vim.wo[pwin][0].wrap = false
    -- Opened from the host so it inherits the host's window options and jumplist.
    local focus = api.nvim_win_call(host, function() return api.nvim_open_win(buf, false, vim.tbl_extend('force', focus_float(host), { noautocmd = true })) end)
    api.nvim_win_set_cursor(focus, api.nvim_win_get_cursor(host))
    st.pane, st.host, st.focus, st.host_winhl = { win = pwin, buf = pbuf }, host, focus, vim.wo[host][0].winhighlight
  end
  -- Also when already covered: at startup, Neovim returns to the first window
  -- without autocommands after the PDF has been covered.
  if api.nvim_get_current_win() == host then
    api.nvim_win_set_cursor(st.focus, api.nvim_win_get_cursor(host))
    api.nvim_set_current_win(st.focus)
  end
  host_active(st, api.nvim_get_current_win() == st.focus)
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
  if st.html then return html.visible(L, top, height) end
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

local function html_scrollbar_width(width)
  local bar = scrollbar_width(width)
  return width >= 2 * bar and bar or 0
end

--- Identifies the jumplist of `win`: it changes on every jump (marks, '', <C-o>, n, ...).
local function jumplist_key(win)
  local list, idx = unpack(vim.fn.getjumplist(win))
  local last = list[#list] or {}
  return ('%d:%d:%d:%d'):format(idx, #list, last.lnum or 0, last.col or 0)
end

local function pane_size(win)
  local cell = assert(kitty.cell_size())
  local cols = math.min(api.nvim_win_get_width(win), kitty.max_cells)
  local rows = math.min(api.nvim_win_get_height(win), kitty.max_cells)
  return math.floor(cols * cell.width), math.floor(rows * cell.height), cols, rows
end

local function html_pane_size(win)
  local width, height, cols, rows = pane_size(win)
  -- The tty reports backing pixels, not display points. Estimate the browser
  -- density from the font's cell height: a normal 20px cell is about 40px at 2x.
  -- Quarter steps follow terminal zoom smoothly while keeping CSS pixel grids
  -- aligned to whole backing pixels every 4 CSS pixels.
  local scale = math.max(1, math.floor(kitty.cell_size().height / 5 + 0.5) / 4)
  local bar_width = html_scrollbar_width(width)
  return { width = width - bar_width, height = height, scale = scale }, cols, rows, bar_width
end

local function cursor_span(st, L, lnum, col)
  if not st.html then return line_span(st, L, lnum) end
  local r = html.fragment(L, lnum, char_index(st.lines[lnum], col))
  return r[3], r[4]
end

local function html_view(st, width, height, cols, rows, content_width)
  local lnum, col = unpack(api.nvim_win_get_cursor(st.focus))
  local L, top = st.layout, st.top
  if L.spans and (lnum ~= st.follow_lnum or col ~= st.follow_col) then
    local a, b = cursor_span(st, L, lnum, col)
    if not st.leaping or a < top or b > top + height then top = follow(top, height, a, b) end
    st.html_anchor = nil
  end
  top = clamp_top(L, height, top)
  st.left = math.floor(math.max(0, math.min(L.wide - content_width, st.left)))
  st.top, st.follow_lnum, st.follow_col = top, lnum, col
  return { top = top, left = st.left, width = width, height = height, cols = cols, rows = rows, layout = L }
end

--- The view for the pane's current size: st.top, moved only when the cursor
--- line changes or the pane resizes.
--- A jump to a line out of view restores the view that line was last seen in
--- from a jump or a mark (st.views), so marks and the jumplist return to the
--- exact view; other moves scroll just enough to show the line.
--- The image is rendered at exactly cols x rows cells of terminal pixels.
local function view_for(st)
  local width, height, cols, rows = pane_size(st.pane.win)
  local L = layout(st, width, math.floor(kitty.cell_size().height / 2))
  local lnum = api.nvim_win_get_cursor(st.focus)[1]
  local a, b = line_span(st, L, lnum)
  local top = st.top
  local jumps = jumplist_key(st.focus)
  if not top or st.top_width ~= width then
    top = (a + b) / 2 - height * 0.4
  elseif lnum ~= st.follow_lnum or height ~= st.top_height or jumps ~= st.jumps then
    local jumped = jumps ~= st.jumps
    if jumped and st.follow_lnum then st.views[st.follow_lnum] = (line_span(st, L, st.follow_lnum) - top) / width end
    local saved = st.views[lnum]
    if jumped and saved and (a < top or b > top + height) then
      top = a - saved * width
    -- Don't move the labels under the user's eyes while leap selects a target.
    elseif not st.leaping or a < top or b > top + height then
      top = follow(top, height, a, b)
    end
  end
  top = clamp_top(L, height, top)
  st.top, st.top_width, st.top_height, st.follow_lnum, st.jumps = top, width, height, lnum, jumps
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
--- scrollbar, for the page in the middle of the view.
local function update_badge(st, view)
  local text
  if st.html then
    text = st.pager and ' HTML ' or ' HTML CURSOR '
  else
    local page = page_at(view.layout, view.top + view.height / 2)
    text = (st.pager and ' %d/%d ' or ' CURSOR %d/%d '):format(page, #st.pages)
  end
  local width = #text
  local config = {
    relative = 'win',
    win = st.pane.win,
    row = view.rows - 1,
    col = view.cols - math.ceil((view.bar_width or scrollbar_width(view.width)) / kitty.cell_size().width) - width,
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

--- The search being typed (incsearch) or the last search (while 'hlsearch' shows
--- it), for matchbufline, which ignores 'smartcase' and assumes 'magic'; nil: none.
local function search_pattern(st)
  local pattern = st.incsearch
  if not pattern and vim.o.hlsearch and vim.v.hlsearch == 1 then pattern = vim.fn.getreg '/' end
  if not pattern or pattern == '' then return nil end
  local ic = vim.o.ignorecase and not (vim.o.smartcase and vim.fn.match(pattern, [[\u]]) >= 0)
  return (ic and [[\c]] or [[\C]]) .. (vim.o.magic and [[\m]] or [[\M]]) .. pattern
end

--- Matches of the search on the lines `visible`, as helper ranges: the match under
--- the cursor (like CurSearch, so it stands out in pager mode too), and the rest.
local function search_ranges(buf, visible, lnum, col)
  local st = states[buf]
  local pattern = search_pattern(st)
  if not pattern or #visible == 0 then return nil, nil end
  local ok, matches = pcall(vim.fn.matchbufline, buf, pattern, visible[1], visible[#visible])
  if not ok then return nil, nil end
  local shown = {}
  for _, lnum in ipairs(visible) do
    shown[lnum] = true
  end
  local ranges, current = {}, nil
  for _, m in ipairs(matches) do
    if shown[m.lnum] and m.text ~= '' then
      local text = st.lines[m.lnum]
      local range = { m.lnum, char_index(text, m.byteidx), char_index(text, m.byteidx + #m.text) - 1 }
      if m.lnum == lnum and col >= m.byteidx and col < m.byteidx + #m.text then
        current = { range }
      else
        ranges[#ranges + 1] = range
      end
    end
  end
  return #ranges > 0 and ranges or nil, current
end

--- Tints for the view: search matches, then the selection (visual mode in the
--- hidden float) or else the cursor line, then the character under the cursor
--- (neither in pager mode).
local function marks_for(buf, view)
  local st = states[buf]
  local win = st.focus
  local visible = lines_in(st, view.layout, view.top, view.height)
  local marks = {}
  local lnum, col = unpack(api.nvim_win_get_cursor(win))
  local found, current = search_ranges(buf, visible, lnum, col)
  if found then marks[#marks + 1] = { ranges = found, color = COLORS.search } end
  if current then marks[#marks + 1] = { ranges = current, color = COLORS.cur_search } end
  local ranges = win == api.nvim_get_current_win() and selection(buf)
  if ranges then
    local shown = {}
    for _, l in ipairs(visible) do
      shown[l] = true
    end
    ranges = vim.tbl_filter(function(r) return shown[r[1]] end, ranges)
    if #ranges > 0 then marks[#marks + 1] = { ranges = ranges, color = COLORS.selection } end
  end
  if is_header(st, lnum) or st.pager then return marks end
  local text = st.lines[lnum]
  if st.html and #text == 0 then return marks end
  local ci = char_index(text, col)
  if not ranges then
    local first, last = 0, vim.str_utfindex(text, 'utf-32') - 1
    if st.html then
      local fragment = html.fragment(view.layout, lnum, ci)
      first, last = fragment[1], fragment[2] - 1
    end
    marks[#marks + 1] = { ranges = { { lnum, first, last } }, color = COLORS.cursor }
  end
  marks[#marks + 1] = {
    ranges = { { lnum, ci, ci } },
    color = COLORS.cursor_char,
    outline = not editor_focused or win ~= api.nvim_get_current_win(),
  }
  return marks
end

--- What the scrollbar marks besides annotations: every line matching the search,
--- marks a-z and ' (where '' returns to), and the cursor line (not in pager mode).
local function scrollbar_for(buf, width)
  local st = states[buf]
  local bar = { width = width, marks = {} }
  local pattern = search_pattern(st)
  if pattern and (st.search_lines or {}).pattern ~= pattern then
    local ok, matches = pcall(vim.fn.matchbufline, buf, pattern, 1, '$')
    local lines = {}
    for _, m in ipairs(ok and matches or {}) do
      if lines[#lines] ~= m.lnum then lines[#lines + 1] = m.lnum end
    end
    st.search_lines = { pattern = pattern, lines = lines }
  end
  bar.search = pattern and st.search_lines.lines or nil
  -- '' is the window's previous-context mark, which Vim keeps across buffers: after
  -- :buffer from another file (as oil.nvim opens files) it holds that file's line,
  -- shifted by the PDF's text being set below it, so it can lie past the end.
  local last = api.nvim_buf_line_count(buf)
  local function add(name, lnum)
    if lnum >= 1 and lnum <= last then bar.marks[#bar.marks + 1] = { name, lnum } end
  end
  for _, m in ipairs(vim.fn.getmarklist(buf)) do
    if m.mark:match "^'[a-z]$" then add(m.mark:sub(2), m.pos[2]) end
  end
  add("'", api.nvim_win_call(st.focus, function() return vim.fn.line "''" end))
  if not st.pager then bar.cursor = api.nvim_win_get_cursor(st.focus)[1] end
  return bar
end

--- Point the pane at a freshly rendered frame (raw RGB when `view` has pixel
--- dimensions, else PNG; the terminal deletes the file).
--- While the pane keeps its size, each frame replaces its image in
--- place, so its cells stay as they are and Nvim has nothing to redraw. A new size
--- needs a new image: Ghostty keeps showing nothing for a replaced image placed at
--- another size.
local function show(st, frame, view)
  local pbuf, grid = st.pane.buf, view.cols .. 'x' .. view.rows
  local reuse = st.grid == grid and st.image or nil
  local size = view.width and { view.width, view.height } or nil
  local id = kitty.show(frame, view.cols, view.rows, { size = size, id = reuse })
  if st.grid ~= grid then
    vim.bo[pbuf].modifiable = true
    api.nvim_buf_set_lines(pbuf, 0, -1, false, kitty.placeholders(view.cols, view.rows))
    vim.bo[pbuf].modifiable = false
    st.grid = grid
  end
  if id == st.image then return end
  api.nvim_buf_clear_namespace(pbuf, NS, 0, -1)
  api.nvim_buf_set_extmark(pbuf, NS, 0, 0, { end_row = view.rows, end_col = 0, strict = false, hl_group = kitty.hl(id) })
  -- Free a previous image only once the cells point at the new one, to avoid flicker.
  if st.image then
    vim.cmd.redraw()
    kitty.delete(st.image)
  end
  st.image = id
end

-- Frame timings while $PDFVIEW_PROFILE is set (docs/benchmarking.md): ms per stage.
local profile = { frames = {} }
local PROFILE_FRAMES = 1000

local function ms_since(t) return (uv.hrtime() - t) / 1e6 end

local render_id = 0

local function html_cursor_at(st, y, edge)
  local lnum, char = html.nearest(st.layout, y, edge)
  if lnum then api.nvim_win_set_cursor(st.focus, { lnum, byte_index(st.lines[lnum], char) }) end
  st.follow_lnum, st.follow_col = unpack(api.nvim_win_get_cursor(st.focus))
end

local function html_geometry(buf, st)
  if st.html_resizing or st.html_measuring then return false end
  local layout = st.layout
  if layout.spans then return true end
  st.html_measuring = true
  local spans = try_call('geometry', { key = buf })
  st.html_measuring = nil
  if not spans or states[buf] ~= st or layout ~= st.layout then return false end
  html.set_spans(layout, spans)
  return true
end

local function html_anchor(buf, st)
  if not html_geometry(buf, st) or not covered(st) then return false end
  if st.html_anchor then
    html_cursor_at(st, st.top + margin(st.top_height), 0)
    st.html_anchor = nil
  end
  return true
end

local function html_mark_name(mark)
  if mark == "'" or mark == '`' then return "'" end
  if mark:match '^[a-zA-Z]$' then return mark end
end

local function html_mark_view(st)
  local lnum, col = unpack(api.nvim_win_get_cursor(st.focus))
  local y = cursor_span(st, st.layout, lnum, col)
  -- Anchor to the wrapped fragment so the view still follows the mark after reflow.
  return { lnum = lnum, col = col, offset = st.top - math.floor(y), left = st.left }
end

local function jump_to_html_mark(buf, key)
  local count, mark = vim.v.count, vim.fn.getcharstr()
  local st, name = states[buf], html_mark_name(mark)
  local pos = name and vim.fn.getpos("'" .. name)
  if not (pos and pos[2] ~= 0 and (pos[1] == 0 or pos[1] == buf)
      and st and covered(st) and api.nvim_get_current_win() == st.focus and html_anchor(buf, st)) then
    api.nvim_feedkeys((count > 0 and count or '') .. key .. mark, 'ni', false)
    return
  end
  local saved, origin = st.mark_views[name], html_mark_view(st)
  vim.cmd.normal { key .. mark, bang = true }
  st.mark_views["'"] = origin
  -- Match the native mark, not the post-jump cursor: 'a goes to first nonblank,
  -- which may be in a different wrap fragment than the one marked with ma.
  if saved and saved.lnum == pos[2] and saved.col == pos[3] - 1 then
    local y = cursor_span(st, st.layout, saved.lnum, saved.col)
    st.top, st.left = math.floor(y) + saved.offset, saved.left
    st.follow_lnum, st.follow_col = unpack(api.nvim_win_get_cursor(st.focus))
  end
  render(buf)
end

local function render_html(buf, st)
  if st.html_measuring then return end
  local viewport, cols, rows, bar_width = html_pane_size(st.pane.win)
  local content_width, height = viewport.width, viewport.height
  local width = content_width + bar_width
  local pane_buf = st.pane.buf
  local function current()
    return states[buf] == st and covered(st) and pane_valid(st) and st.pane.buf == pane_buf
  end
  local function finish(err)
    st.busy = false
    local again = st.again
    st.again = nil
    if err then notify(err, vim.log.levels.ERROR) end
    return states[buf] == st and not err and again
  end
  local resized = st.html_width ~= content_width or st.top_height ~= height or st.html_scale ~= viewport.scale
  if resized then
    st.busy, st.html_resizing = true, true
    viewport.key = buf
    browser.request('layout', viewport, function(err, res)
      st.html_resizing = nil
      finish(err)
      if err or states[buf] ~= st or not api.nvim_buf_is_loaded(buf) then return end
      set_text(buf, res.lines)
      st.lines, st.layout, st.search_lines = res.lines, res, nil
      st.html_width, st.top_height, st.html_scale = content_width, height, viewport.scale
      st.render_key, st.view = nil, nil
      if not st.pager then st.follow_lnum = nil end
      render(buf)
    end)
    return
  end

  local lnum, col = unpack(api.nvim_win_get_cursor(st.focus))
  local moved = lnum ~= st.follow_lnum or col ~= st.follow_col
  local search_active = search_pattern(st)
  local text_needed = not st.pager or search_active or moved
  if text_needed and not html_geometry(buf, st) then return end
  if not current() then return end
  if not st.pager and st.html_anchor and not moved then html_anchor(buf, st) end
  local view = html_view(st, width, height, cols, rows, content_width)
  view.bar_width = bar_width
  update_badge(st, view)
  local marks = (not st.pager or search_active) and marks_for(buf, view) or {}
  local bar = bar_width > 0 and scrollbar_for(buf, bar_width) or nil
  local search = bar and bar.search and st.search_lines.pattern
  local key = vim.json.encode { view.top, view.left, width, marks, bar and bar.marks, bar and bar.cursor, search, st.layout.spans ~= nil }
  if key == st.render_key then return end
  st.render_key, st.busy = key, true
  render_id = render_id + 1
  local path = vim.fs.joinpath(kitty.tmpdir(), ('tty-graphics-protocol-htmlview-%d-%d.rgb'):format(vim.fn.getpid(), render_id))
  local params = { key = buf, top = view.top, left = view.left, marks = marks, scrollbar = bar, out = path }
  browser.request('render', params, function(err)
    if not err and current() and view.layout == st.layout then
      st.view = view
      show(st, path, view)
    else
      os.remove(path)
      st.render_key = nil
    end
    if finish(err) then render(buf) end
  end)
end

--- Render the pages for `buf`, following the cursor of its hidden float. At most
--- one render is in flight per buffer; requests arriving meanwhile collapse into one rerun.
--- A page view in another tab page waits: entering that tab (WinEnter) renders it.
render = function(buf)
  local st = states[buf]
  if not (st and covered(st) and pane_valid(st) and api.nvim_win_get_buf(st.focus) == buf) then return end
  if api.nvim_win_get_tabpage(st.focus) ~= api.nvim_get_current_tabpage() then return end
  if st.busy then
    st.again = true
    return
  end
  -- v, V and <C-v> in pager mode start a selection in cursor mode. Checked here, as
  -- render also runs from the input hook while another ModeChanged handler waits.
  if st.pager and api.nvim_get_current_win() == st.focus and api.nvim_get_mode().mode:match '^[vV\22]' then st.pager = false end
  if st.html then return render_html(buf, st) end
  local t0 = uv.hrtime()
  local view = view_for(st)
  update_badge(st, view)
  local marks, bar = marks_for(buf, view), scrollbar_for(buf, scrollbar_width(view.width))
  -- Every key typed comes through here: the search matches enter the key as their
  -- pattern, as encoding thousands of matching lines each time would cost more.
  local search = bar.search and st.search_lines.pattern
  local key = vim.json.encode { view.top, view.width, view.height, marks, bar.width, bar.marks, bar.cursor, search, st.version }
  if key == st.render_key then return end
  st.view, st.render_key, st.busy = view, key, true
  render_id = render_id + 1
  -- kitty and Ghostty only accept temporary files named like this, in $TMPDIR.
  local frame = vim.fs.joinpath(kitty.tmpdir(), ('tty-graphics-protocol-pdfview-%d-%d.rgb'):format(vim.fn.getpid(), render_id))
  local pane_buf = st.pane.buf
  local profiling = (vim.env.PDFVIEW_PROFILE or '') ~= ''
  local params = {
    key = buf,
    top = view.top,
    width = view.width,
    height = view.height,
    gap = view.layout.gap,
    marks = marks,
    scrollbar = bar,
    out = frame,
    profile = profiling or nil,
  }
  local prepare, t1 = ms_since(t0), uv.hrtime()
  request('render', params, function(err, res)
    local t2 = uv.hrtime()
    st.busy = false
    if err then
      st.render_key = nil
      os.remove(frame)
      notify(err, vim.log.levels.ERROR)
    elseif states[buf] == st and pane_valid(st) and st.pane.buf == pane_buf then
      show(st, frame, view)
    else
      os.remove(frame)
    end
    if profiling and res and res.profile then
      local p = res.profile
      local helper_ms = (t2 - t1) / 1e6
      table.insert(profile.frames, {
        prepare = prepare,
        pages = p.pages,
        scrollbar = p.scrollbar,
        write = p.write,
        ipc = helper_ms - p.pages - p.scrollbar - p.write,
        show = ms_since(t2),
        total = ms_since(t0),
        rasterized = p.rasterized,
      })
      if #profile.frames > PROFILE_FRAMES then table.remove(profile.frames, 1) end
    end
    local again = st.again
    st.again = nil
    if again and not err then render(buf) end
  end)
end

local function refresh(buf)
  vim.schedule(function()
    local win = states[buf] and text_window(buf)
    if not win then return end
    cover(buf, win)
    render(buf)
  end)
end

--- Switch the page view between pager mode (`on`: keys pan the pages, the
--- cursor is not drawn) and cursor mode (vim motions, selections, annotations).
local function set_pager(buf, on)
  local st = states[buf]
  if st.pager == on then return end
  if not on and st.html and not html_anchor(buf, st) then return end
  st.pager = on
  render(buf)
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
    cover(buf, host)
    render(buf)
  end
end

local function doc_point(st, view, page, box)
  local y = (box[2] + box[4]) / 2
  if st.html then return box[1] - view.left, y end
  local i, L = page + 1, view.layout
  return box[1] * L.scales[i], L.tops[i] + y * L.scales[i]
end

--- Cell of the pane over a text box in either renderer's coordinates.
local function cell_at(st, page, box)
  local v, cell = st.view, kitty.cell_size()
  if not (v and cell) then return end
  local x, y = doc_point(st, v, page, box)
  local row = math.floor((y - v.top) / cell.height)
  local col = math.floor(x / cell.width)
  if row >= 0 and row < v.rows and col >= 0 and col < v.cols then return row, col end
end

-- Scrolling and clicking ---------------------------------------------------------

--- Scroll the view by `delta` doc pixels. Like Vim, the cursor stays on screen:
--- if it scrolled out, it moves to the first (scrolling down) or last line now in view.
--- In pager mode it moves to the top line in view, or without text in view to
--- the header of the page in the middle, so each view has its own cursor line:
--- marks and the jumplist can then tell views apart (view_for).
local function scroll_by(buf, delta)
  local st = states[buf]
  if st.html and not st.pager and not html_geometry(buf, st) then return end
  local L, height, win = st.layout, st.top_height, st.focus
  local top = clamp_top(L, height, st.top + delta)
  local moved = top ~= st.top
  st.top = top
  if st.html and st.pager then
    if moved then st.html_anchor = true end
    render(buf)
    return
  end
  local m = margin(height)
  local lnum, col = unpack(api.nvim_win_get_cursor(win))
  local a, b = cursor_span(st, L, lnum, col)
  if st.html then
    if a < st.top + m or b > st.top + height - m then
      local edge = delta > 0 and 0 or 1
      html_cursor_at(st, st.top + (edge == 0 and m or height - m), edge)
    end
    render(buf)
    return
  end
  if st.pager or a < st.top + m or b > st.top + height - m then
    local best, best_y
    for _, l in ipairs(lines_in(st, L, st.top + m, height - 2 * m)) do
      local la, lb = line_span(st, L, l)
      local y = (st.pager or delta > 0) and la or -lb
      if la >= st.top + m and lb <= st.top + height - m and (not best or y < best_y) then
        best, best_y = l, y
      end
    end
    if st.pager and not best then best = st.headers[page_at(L, st.top + height / 2)] end
    -- Column 0 keeps the cursor's column.
    if best and best ~= lnum then api.nvim_win_call(win, function() vim.fn.cursor(best, 0) end) end
  end
  st.follow_lnum = api.nvim_win_get_cursor(win)[1]
  render(buf)
end

--- zt / zz / zb: put the cursor line at the top (0), middle (0.5) or bottom (1) of the view.
local function align(buf, where)
  local st = states[buf]
  if st.html and not html_anchor(buf, st) then return end
  local L, height = st.layout, st.top_height
  local lnum, col = unpack(api.nvim_win_get_cursor(st.focus))
  local a, b = cursor_span(st, L, lnum, col)
  local m = margin(height)
  local top = where == 0 and a - m or where == 1 and b - height + m or (a + b - height) / 2
  st.top, st.follow_lnum = clamp_top(L, height, top), lnum
  render(buf)
end

--- ]p / [p: scroll so the page `count` pages after (dir 1) or before (dir -1)
--- the one in the middle of the view starts at the top. [p first goes back to
--- the top of that page when the view starts inside it.
local function jump_page(buf, dir, count)
  local st = states[buf]
  local L = st.layout
  local page = page_at(L, st.top + st.top_height / 2)
  if dir < 0 and st.top > L.tops[page] then count = count - 1 end
  local target = math.max(1, math.min(#st.pages, page + dir * count))
  scroll_by(buf, L.tops[target] - st.top)
end

--- H / M / L: move the cursor to the top (0), middle (0.5) or bottom (1) line in view.
local function screen_line(buf, where)
  local st = states[buf]
  local L, height = st.layout, st.top_height
  local m = margin(height)
  local target = st.top + m + where * (height - 2 * m)
  if st.html then
    if not html_geometry(buf, st) then return end
    st.html_anchor = nil
    vim.cmd "normal! m'"
    html_cursor_at(st, target, where)
    render(buf)
    return
  end
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


--- Move the cursor to the character under a mouse click on the pages.
--- Returns false when the click was not on the pages.
local function click(buf)
  local st = states[buf]
  local pos = vim.fn.getmousepos()
  if not (st and st.view and covered(st) and pos.winid == st.host) then return false end
  local cell, v = kitty.cell_size(), st.view
  if pos.winrow < 1 or pos.winrow > v.rows or pos.wincol < 1 or pos.wincol > v.cols then return false end
  local L = v.layout
  local y = v.top + (pos.winrow - 0.5) * cell.height
  local i = page_at(L, y)
  local s = L.scales[i]
  local hit = try_call('hit', { key = buf, page = i - 1, x = (pos.wincol - 0.5) * cell.width / s, y = (y - L.tops[i]) / s })
  local win = st.focus
  if vim.fn.mode():match '^[vV\22]' then vim.cmd 'normal! \27' end
  if api.nvim_get_current_win() ~= win then api.nvim_set_current_win(win) end
  local lnum = hit and hit[1] or st.headers[i]
  api.nvim_win_set_cursor(win, { lnum, hit and byte_index(st.lines[lnum], hit[2]) or 0 })
  set_pager(buf, false)
  return true
end

-- leap.nvim on the page view -----------------------------------------------------

local NS_LABELS = api.nvim_create_namespace 'pdfview.labels'

local function clear_labels()
  for _, st in pairs(states) do
    if pane_valid(st) then api.nvim_buf_clear_namespace(st.pane.buf, NS_LABELS, 0, -1) end
  end
end

--- Copy the labels Leap is about to draw in text buffers onto their image panes,
--- in the cell over each target's first character.
local function mirror_labels(targets, first, last)
  local by_buf = {}
  for i = first or 1, last or #targets do
    local t = targets[i]
    local buf = t.wininfo and t.wininfo.bufnr
    local st = states[buf]
    local virt_text = t.beacon and t.beacon[2].virt_text
    if virt_text and t.pos and st and st.view and pane_valid(st) and st.lines[t.pos[1]] and not is_header(st, t.pos[1]) then
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
        local page = not st.html and st.info[l.lnum][1]
        local row, col
        if b then row, col = cell_at(st, page, b) end
        local width = 0
        for _, chunk in ipairs(l.virt_text) do
          width = width + api.nvim_strwidth(chunk[1])
        end
        if width > st.view.cols then row = nil end
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
  -- Empty lists, never nil: leap evaluates `targets() or targets`, so nil would
  -- hand it the function itself. It also drops the message (shows "no targets").
  return function()
    local in1 = vim.fn.getcharstr()
    if in1 == '\27' then return {}, '' end
    local in2 = vim.fn.getcharstr()
    if in2 == '\27' then return {}, '' end
    local c1, c2 = norm(in1), norm(in2)
    local v = st.view
    if st.html and (not v or v.layout ~= st.layout or not html_geometry(buf, st)) then return {}, '' end
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
    if #targets == 0 then return {}, 'not found: ' .. in1 .. in2 end
    local info = not st.html and st.info[cur[1]]
    if not is_header(st, cur[1]) then chars[#chars + 1] = { cur[1], char_index(st.lines[cur[1]], cur[2]) } end
    local boxes = try_call('char_boxes', { key = buf, chars = chars })
    if not boxes or (st.html and st.layout ~= v.layout) then return {}, '' end
    local cx, cy = 0, v.top
    if info and info[4] then
      cy = v.layout.tops[info[1] + 1]
    elseif boxes[#chars] then
      cx, cy = doc_point(st, v, info and info[1], boxes[#chars])
    end
    local visible = {}
    for i, t in ipairs(targets) do
      local box, page = boxes[i], not st.html and st.info[t.pos[1]][1]
      if box and cell_at(st, page, box) then
        local x, y = doc_point(st, v, page, box)
        t.box, t.dist = box, (x - cx) ^ 2 + (y - cy) ^ 2
        visible[#visible + 1] = t
      end
    end
    targets = visible
    table.sort(targets, function(a, b)
      if a.dist ~= b.dist then return a.dist < b.dist end
      return a.pos[1] < b.pos[1] or a.pos[1] == b.pos[1] and a.pos[2] < b.pos[2]
    end)
    return targets
  end
end

--- leap with the page view's targets from the hidden float; plain leap elsewhere.
--- Starting it on the page view enters cursor mode.
local function leap_on_page(buf)
  local st = states[buf]
  local win = api.nvim_get_current_win()
  local kwargs = { windows = { win }, inclusive = true }
  if st and st.view and covered(st) and win == st.focus then
    set_pager(buf, false)
    if st.html and st.pager then return end
    kwargs.targets = leap_targets(buf, win)
  end
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
  render(buf)
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

--- Foreground and background (nil: the terminal's own) of floating windows, for images in them.
local function float_colors()
  local float, normal = api.nvim_get_hl(0, { name = 'NormalFloat', link = false }), api.nvim_get_hl(0, { name = 'Normal', link = false })
  return float.fg or normal.fg or (vim.o.background == 'dark' and 0xFFFFFF or 0x000000), float.bg or normal.bg
end

local typst_id = 0

--- Helper params rendering Typst `source` into at most cols x rows cells of a float.
local function typst_params(source, cols, rows)
  typst_id = typst_id + 1
  local cell, fg, bg = kitty.cell_size(), float_colors()
  return {
    source = source,
    color = fg,
    background = bg,
    cell = { cell.width, cell.height },
    cols = cols,
    rows = rows,
    scale = M.config.typst_scale,
    out = vim.fs.joinpath(kitty.tmpdir(), ('tty-graphics-protocol-pdfview-%d-typst-%d.png'):format(vim.fn.getpid(), typst_id)),
  }
end

--- Native hover UI, with PDF note text instead of an LSP response. A Typst note
--- shows rendered, or as its source if it does not compile.
local function hover_note(buf)
  local a = under_cursor(buf, true)
  if not a then return notify('No note under the cursor') end
  -- A second K focuses the open preview, as LSP hover does.
  local open = vim.b[buf].lsp_floating_preview
  if open and api.nvim_win_is_valid(open) and vim.w[open]['pdfview.note'] then return api.nvim_set_current_win(open) end
  local st = states[buf]
  local view = st.view
  local max_width = math.max(1, math.min(70, view and view.cols - 4 or vim.o.columns - 4))
  local max_height = math.max(1, math.min(20, view and math.floor(view.rows / 2) or vim.o.lines - 4))
  local lines, syntax, image = vim.split(a.contents, '\n', { plain = true }), 'markdown', nil
  if a.typst then
    syntax = 'typst'
    local p = typst_params(a.contents, max_width, max_height)
    local ok, res = pcall(call, 'typst', p)
    if ok and res.cols then
      image = kitty.show(p.out, res.cols, res.rows)
      lines, syntax = kitty.placeholders(res.cols, res.rows), nil
    end
  end
  local nbuf, win = vim.lsp.util.open_floating_preview(lines, syntax, {
    focus_id = 'pdfview.note',
    border = 'rounded',
    title = (' %s note '):format(a.typst and 'Typst' or a.type),
    max_width = max_width,
    max_height = max_height,
  })
  if image then
    api.nvim_buf_set_extmark(nbuf, NS, 0, 0, { end_row = #lines, end_col = 0, strict = false, hl_group = kitty.hl(image) })
    api.nvim_create_autocmd('BufWipeout', { buffer = nbuf, once = true, callback = function() kitty.delete(image) end })
  end
  -- The hidden text cursor does not line up with the rendered glyph. Anchor the
  -- hover to that glyph on the page instead, keeping the whole float in view.
  if view and covered(st) and api.nvim_get_current_win() == st.focus then
    local lnum, col = unpack(api.nvim_win_get_cursor(st.focus))
    if not st.info[lnum][4] then
      local boxes = try_call('char_boxes', { key = buf, chars = { { lnum, char_index(st.lines[lnum], col) } } })
      if boxes then
        local box = boxes[1]
        local row, column = cell_at(st, st.info[lnum][1], { box[1], box[4], box[3], box[4] })
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

--- Float configs of a Typst note's editor and preview, as one box centered on the
--- screen: side by side when it is wider than tall in pixels, else stacked.
local function typst_layout()
  local cell = kitty.cell_size()
  local cols, rows = math.floor(vim.o.columns * 0.9), math.floor((vim.o.lines - 2) * 0.85)
  local top, left = math.floor((vim.o.lines - 2 - rows) / 2), math.floor((vim.o.columns - cols) / 2)
  local function pane(row, col, width, height)
    return { relative = 'editor', row = row, col = col, width = math.max(1, width - 2), height = math.max(1, height - 2) }
  end
  if cols * cell.width >= rows * cell.height then
    local w = math.floor(cols / 2)
    return pane(top, left, w, rows), pane(top, left + w, cols - w, rows)
  end
  local h = math.floor(rows / 2)
  return pane(top, left, cols, h), pane(top + h, left, cols, rows - h)
end

local typst_ns = api.nvim_create_namespace 'pdfview.typst'

--- Open the editor window on Typst note buffer `nbuf` beside a preview that
--- re-renders on every change; compile errors become diagnostics. Returns the editor window.
local function open_typst_editor(nbuf)
  local editor, preview = typst_layout()
  local style = { style = 'minimal', border = 'rounded', title_pos = 'center' }
  local win = api.nvim_open_win(
    nbuf,
    true,
    vim.tbl_extend('force', editor, style, { title = ' Typst note ', footer = ' :w save · q save and close ', footer_pos = 'center' })
  )
  -- Shaped like a page view's state, so show() can draw into it.
  local ed = { pane = { buf = api.nvim_create_buf(false, true) } }
  vim.bo[ed.pane.buf].bufhidden = 'wipe'
  ed.pane.win = api.nvim_open_win(ed.pane.buf, false, vim.tbl_extend('force', preview, style, { title = ' preview ', focusable = false }))

  -- At most one render in flight; changes meanwhile collapse into one rerun.
  local function refresh()
    if ed.busy then
      ed.again = true
      return
    end
    ed.busy = true
    local source = table.concat(api.nvim_buf_get_lines(nbuf, 0, -1, false), '\n')
    local p = typst_params(source, api.nvim_win_get_width(ed.pane.win), api.nvim_win_get_height(ed.pane.win))
    request('typst', p, function(err, res)
      ed.busy = false
      if not api.nvim_win_is_valid(ed.pane.win) then return os.remove(p.out) end
      if err then
        vim.diagnostic.set(typst_ns, nbuf, { { lnum = 0, col = 0, message = err, source = 'pdfview' } })
      elseif res.diagnostics then
        vim.diagnostic.set(typst_ns, nbuf, vim.tbl_map(function(d)
          return { lnum = d.lnum - 1, col = d.col - 1, message = d.message, severity = vim.diagnostic.severity.ERROR, source = 'typst' }
        end, res.diagnostics))
      else
        vim.diagnostic.reset(typst_ns, nbuf)
        show(ed, p.out, { cols = res.cols, rows = res.rows })
      end
      if ed.again then
        ed.again = nil
        refresh()
      end
    end)
  end

  local group = api.nvim_create_augroup('pdfview.typst.' .. nbuf, { clear = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, buffer = nbuf, callback = refresh })
  api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      local e, p = typst_layout()
      api.nvim_win_set_config(win, e)
      api.nvim_win_set_config(ed.pane.win, p)
      refresh()
    end,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    callback = function()
      api.nvim_del_augroup_by_id(group)
      if api.nvim_win_is_valid(ed.pane.win) then api.nvim_win_close(ed.pane.win, true) end
      if ed.image then kitty.delete(ed.image) end
    end,
  })
  refresh()
  return win
end

--- Edit the note of `annot` as Typst; saving makes it a Typst note even if another
--- viewer wrote it as plain text.
local function edit_note(buf, annot)
  note_id = note_id + 1
  local nbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(nbuf, ('pdfview-note://%d'):format(note_id))
  vim.bo[nbuf].buftype = 'acwrite'
  vim.bo[nbuf].bufhidden = 'wipe'
  vim.bo[nbuf].filetype = 'typst'
  api.nvim_buf_call(nbuf, function()
    vim.bo.undolevels = -1
    api.nvim_buf_set_lines(nbuf, 0, -1, false, vim.split(annot.contents, '\n', { plain = true }))
    vim.bo.undolevels = vim.go.undolevels
  end)
  vim.bo[nbuf].modified = false
  local win = open_typst_editor(nbuf)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
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

local function html_snapshot(st, v, ranges, lnum, col)
  local text, caption = st.lines[lnum], ''
  local params = { top = v.top, left = v.left, ranges = ranges, color = COLORS.selection }
  if ranges then
    local excerpt, remaining = {}, 300
    for i, r in ipairs(ranges) do
      local line, first, last = st.lines[r[1]], r[2], r[3]
      local count = math.min(last - first + 1, remaining)
      if count > 0 then excerpt[i] = line:sub(byte_index(line, first) + 1, byte_index(line, first + count)) end
      remaining = remaining - count
      if remaining <= 0 then
        if i < #ranges or first + count <= last then excerpt[#excerpt + 1] = '…' end
        break
      end
      remaining = remaining - 1 -- newline between buffer lines
    end
    caption = '\nSelected text:\n' .. table.concat(excerpt, '\n')
  elseif not st.pager and #text > 0 then
    local ci = char_index(text, col)
    local first = byte_index(text, math.max(0, ci - 30))
    local start, stop = byte_index(text, ci), byte_index(text, ci + 1)
    local last = byte_index(text, ci + 31)
    caption = '\nCursor: ' .. (first > 0 and '…' or '') .. text:sub(first + 1, start) .. '[' .. text:sub(start + 1, stop) .. ']'
      .. text:sub(stop + 1, last) .. (last < #text and '…' or '')
    params.cursor = { lnum, ci }
  end
  params.caption = caption
  return params
end

--- PNG of the visible view with context for an agent. Return to pager mode.
local function snapshot(buf)
  local st, ranges = states[buf], selection(buf)
  local v = st.view
  if not v or (st.html and (st.html_resizing or v.layout ~= st.layout)) then return notify('No view to snapshot', vim.log.levels.WARN) end
  if not st.html and ranges and not ranges_page(st, ranges) then return notify('Selection must stay on one page', vim.log.levels.WARN) end
  local dir = M.config.snapshot_dir or vim.fs.joinpath(kitty.tmpdir(), 'pdfview')
  vim.fn.mkdir(dir, 'p')
  local png = vim.fs.joinpath(dir, ('snap-%s-%03d.png'):format(os.date '%Y%m%d-%H%M%S', uv.now() % 1000))
  local lnum, col = unpack(api.nvim_win_get_cursor(st.focus))
  local params
  if st.html then
    params = html_snapshot(st, v, ranges, lnum, col)
  else
    local width = math.max(v.width, 1600)
    local scale = width / v.width
    params = {
      width = width,
      height = math.floor(v.height * scale),
      top = v.top * scale,
      gap = v.layout.gap * scale,
      ranges = ranges or {},
      color = COLORS.selection,
      cursor = not (ranges or st.pager or st.info[lnum][4]) and { lnum, char_index(st.lines[lnum], col) } or nil,
    }
  end
  params.key, params.out = buf, png
  if ranges then vim.cmd 'normal! \27' end
  if not try_call('snapshot', params) then return end
  set_pager(buf, true)
  if vim.fn.has 'mac' ~= 1 then return notify('Saved snapshot ' .. vim.fs.basename(png) .. ' to snapshot_dir') end
  local res = vim.system({ 'osascript', '-e', 'on run argv', '-e', 'set the clipboard to (read (POSIX file (item 1 of argv)) as «class PNGf»)', '-e', 'end run', png }):wait()
  if res.code ~= 0 then return notify('Clipboard copy failed: ' .. res.stderr, vim.log.levels.ERROR) end
  notify 'Copied snapshot to clipboard'
end

-- Buffer lifecycle -----------------------------------------------------------

--- Stop showing `buf` as a document: drop its state, page view, keys and
--- autocommands, and release it in the helper.
local function unload(buf)
  local st = states[buf]
  if not st then return end
  states[buf] = nil
  if st.poll then st.poll:close() end
  pcall(api.nvim_del_augroup_by_name, 'pdfview.' .. buf)
  if api.nvim_buf_is_loaded(buf) then
    for _, m in ipairs(st.maps or {}) do
      pcall(vim.keymap.del, m[1], m[2], { buffer = buf })
    end
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end
  -- Called from BufReadCmd, where closing the current (hidden) window is unsafe.
  vim.schedule(function()
    uncover(st)
    close_pane(st)
  end)
  if st.history and api.nvim_buf_is_valid(st.history) then api.nvim_buf_delete(st.history, { force = true }) end
  local source = st.html and browser or helper
  if source.proc then source.request('close', { key = buf }, function() end) end
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
  local st = states[buf]
  local is_html = st.html
  st.maps = {}
  local group = api.nvim_create_augroup('pdfview.' .. buf, { clear = true })
  local function au(events, fn) api.nvim_create_autocmd(events, { group = group, buffer = buf, callback = fn }) end
  au({ 'CursorMoved', 'ModeChanged' }, function()
    local st, win = states[buf], api.nvim_get_current_win()
    -- The covered window's statusline shows its own cursor: keep it with the hidden float's.
    if st and covered(st) and win == st.focus then api.nvim_win_set_cursor(st.host, api.nvim_win_get_cursor(win)) end
    render(buf)
  end)
  au('BufWinEnter', function() refresh(buf) end)
  au('BufWinLeave', function()
    vim.schedule(function()
      local st = states[buf]
      if st and st.host and not (covered(st) and api.nvim_win_get_buf(st.host) == buf) then uncover(st) end
    end)
  end)
  if not is_html then au('BufWriteCmd', function(ev) write(buf, ev.match) end) end
  -- :e! unloads and immediately re-reads the buffer; only tear down for real unloads.
  au('BufUnload', function()
    vim.schedule(function()
      if not api.nvim_buf_is_loaded(buf) then unload(buf) end
    end)
  end)

  local keys = M.config.keys
  -- Normal-mode actions by key, for keys that pan in pager mode (u: undo).
  local own = {}
  local function map(mode, lhs, fn, desc)
    for _, l in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
      if l then
        vim.keymap.set(mode, l, fn, { buffer = buf, desc = (is_html and 'HTML: ' or 'PDF: ') .. desc })
        st.maps[#st.maps + 1] = { mode, l }
        if mode == 'n' then own[l] = fn end
      end
    end
  end
  local function prefixed(suffix) return keys.prefix and keys.prefix .. suffix end
  map({ 'n', 'x' }, prefixed 'y', function() snapshot(buf) end, 'copy snapshot for agent')
  -- Keep Vim's mark, and remember the rendered view in which it was set.
  map('n', 'm', function()
    local mark = vim.fn.getcharstr()
    local st = states[buf]
    if st and covered(st) and api.nvim_get_current_win() == st.focus then
      if st.html then
        local name = html_mark_name(mark)
        if not html_anchor(buf, st) then return end
        if name then st.mark_views[name] = html_mark_view(st) end
      elseif st.view then
        local lnum = api.nvim_win_get_cursor(st.focus)[1]
        st.views[lnum] = (line_span(st, st.layout, lnum) - st.top) / st.top_width
      end
    end
    pcall(vim.cmd.normal, { 'm' .. mark, bang = true })
  end, 'set a mark that also remembers the page view')
  if not is_html then
    map('x', prefixed 'h', function() annotate(buf, 'highlight') end, 'highlight selection')
    map('x', prefixed 'u', function() annotate(buf, 'underline') end, 'underline selection')
    map('x', prefixed 's', function() annotate(buf, 'strikeout') end, 'strike out selection')
    map('x', prefixed 'n', function() annotate(buf, 'highlight', true) end, 'highlight selection with note')
    map('n', prefixed 'n', function() edit_under_cursor(buf) end, 'edit note under cursor')
    map('n', prefixed 'd', function() delete_under_cursor(buf) end, 'delete annotation under cursor')
    map('n', prefixed 'l', function() list(buf) end, 'list annotations')
    map('n', keys.hover, function() hover_note(buf) end, 'show note under cursor')
    map('n', keys.undo, function() undo_annotations(buf, false, vim.v.count1) end, 'undo annotation change')
    map('n', keys.redo, function() undo_annotations(buf, true, vim.v.count1) end, 'redo annotation change')
    map('n', keys.next_annotation, function() jump(buf, 1, vim.v.count1) end, 'next annotation')
    map('n', keys.prev_annotation, function() jump(buf, -1, vim.v.count1) end, 'previous annotation')
  end

  if pcall(require, 'leap') then
    for _, k in ipairs(leap_keys()) do
      map(k.mode, k.lhs, function() leap_on_page(buf) end, 'leap to anything on the page view')
    end
  end

  -- The text window is hidden, so scrolling, page jumps, H/M/L and clicks act on
  -- the pages, and in pager mode (`pager` set) more keys pan them. Elsewhere
  -- (other windows on the buffer, the mouse over another window, cursor mode
  -- for pager keys) the keys do what they did before: the action mapped above,
  -- or the native key.
  local function page_map(lhs, fn, desc, opts)
    opts = opts or {}
    for _, l in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
      local before = own[l]
      map(opts.pager and 'n' or { 'n', 'x' }, l, function()
        local st = states[buf]
        if
          st
          and covered(st)
          and st.top
          and api.nvim_get_current_win() == st.focus
          and (not opts.mouse or vim.fn.getmousepos().winid == st.host)
          and (not opts.pager or st.pager)
        then
          return fn(st)
        end
        if before then return before() end
        api.nvim_feedkeys((vim.v.count > 0 and vim.v.count or '') .. vim.keycode(l), 'n', false)
      end, desc)
    end
  end
  local function rows(n) return n * kitty.cell_size().height end
  page_map('<C-e>', function() scroll_by(buf, rows(vim.v.count1)) end, 'scroll the page down')
  page_map('<C-y>', function() scroll_by(buf, -rows(vim.v.count1)) end, 'scroll the page up')
  page_map('<C-d>', function(st) scroll_by(buf, vim.v.count > 0 and rows(vim.v.count) or st.top_height / 2) end, 'scroll the page down half a screen')
  page_map('<C-u>', function(st) scroll_by(buf, -(vim.v.count > 0 and rows(vim.v.count) or st.top_height / 2)) end, 'scroll the page up half a screen')
  page_map('<C-f>', function(st) scroll_by(buf, (st.top_height - rows(2)) * vim.v.count1) end, 'scroll the page down a screen')
  page_map('<C-b>', function(st) scroll_by(buf, -(st.top_height - rows(2)) * vim.v.count1) end, 'scroll the page up a screen')
  page_map('zt', function() align(buf, 0) end, 'cursor line to the top of the view')
  page_map('zz', function() align(buf, 0.5) end, 'cursor line to the middle of the view')
  page_map('zb', function() align(buf, 1) end, 'cursor line to the bottom of the view')
  page_map('H', function() screen_line(buf, 0) end, 'cursor to the top line in view')
  page_map('M', function() screen_line(buf, 0.5) end, 'cursor to the middle line in view')
  page_map('L', function() screen_line(buf, 1) end, 'cursor to the bottom line in view')
  local pager = { pager = true }
  local function half(st) return vim.v.count > 0 and rows(vim.v.count) or st.top_height / 2 end
  page_map({ 'j', '<Down>', '<CR>' }, function() scroll_by(buf, rows(3 * vim.v.count1)) end, 'pager: pan down', pager)
  page_map({ 'k', '<Up>' }, function() scroll_by(buf, -rows(3 * vim.v.count1)) end, 'pager: pan up', pager)
  page_map('d', function(st) scroll_by(buf, half(st)) end, 'pager: pan down half a screen', pager)
  page_map('u', function(st) scroll_by(buf, -half(st)) end, 'pager: pan up half a screen', pager)
  page_map('gg', function(st) scroll_by(buf, -st.top) end, 'pager: pan to the start', pager)
  page_map('G', function(st) scroll_by(buf, st.layout.total) end, 'pager: pan to the end', pager)
  page_map('c', function() set_pager(buf, false) end, 'pager: cursor mode', pager)
  page_map('<ScrollWheelDown>', function() scroll_by(buf, rows(3 * vim.v.count1)) end, 'scroll the page down', { mouse = true })
  page_map('<ScrollWheelUp>', function() scroll_by(buf, -rows(3 * vim.v.count1)) end, 'scroll the page up', { mouse = true })
  if is_html then
    local function pan(st, dir)
      st.left = st.left + dir * 3 * vim.v.count1 * kitty.cell_size().width
      render(buf)
    end
    page_map('<ScrollWheelRight>', function(st) pan(st, 1) end, 'pan the document right', { mouse = true })
    page_map('<ScrollWheelLeft>', function(st) pan(st, -1) end, 'pan the document left', { mouse = true })
    page_map('<LeftMouse>', function() end, 'ignore clicks on the document', { mouse = true })
    page_map('<LeftDrag>', function() end, 'ignore drags on the document', { mouse = true })
    for _, key in ipairs { "'", '`' } do
      map('n', key, function() jump_to_html_mark(buf, key) end, 'jump to a mark and restore its view')
    end
    -- Anchor native text commands to the displayed viewport, not the last
    -- cursor position before pager scrolling.
    for _, key in ipairs { 'v', 'V', '<C-v>', 'n', 'N' } do
      local visual = key == 'v' or key == 'V' or key == '<C-v>'
      map('n', key, function()
        local st = states[buf]
        local count = vim.v.count
        if covered(st) and st.pager and api.nvim_get_current_win() == st.focus then
          if visual then
            set_pager(buf, false)
            if st.pager then return end
          elseif not html_anchor(buf, st) then
            return
          end
        end
        api.nvim_feedkeys((count > 0 and count or '') .. vim.keycode(key), 'ni', false)
      end, 'run text command at the viewer cursor')
    end
  else
    page_map(keys.next_page, function() jump_page(buf, 1, vim.v.count1) end, 'next page')
    page_map(keys.prev_page, function() jump_page(buf, -1, vim.v.count1) end, 'previous page')
    page_map('<LeftDrag>', function() end, 'ignore drags on the page', { mouse = true })
    map({ 'n', 'x' }, '<LeftMouse>', function()
      if not click(buf) then api.nvim_feedkeys(vim.keycode '<LeftMouse>', 'n', false) end
    end, 'move the cursor to the clicked character')
  end
end

--- Show `buf`'s file as a document: PDF pages, or HTML laid out by Chromium.
--- Runs on open, on :e and :e!, and when the file changes on disk.
load = function(buf)
  local path = canonical(api.nvim_buf_get_name(buf))
  local ok, reason = kitty.supported()
  if ok and not kitty.cell_size() then ok, reason = false, 'the terminal does not report its size in pixels' end
  if not ok then error('no page view: ' .. reason, 0) end
  local st = states[buf]
  if is_html_path(path) then
    local win = vim.fn.bufwinid(buf)
    local viewport = html_pane_size(win ~= -1 and win or api.nvim_get_current_win())
    viewport.key, viewport.path = buf, path
    local res = browser.call('open', viewport)
    if not st then st = { html = true, pager = true, top = 0, left = 0, html_anchor = true, follow_lnum = 1, follow_col = 0 } end
    st.lines, st.layout, st.mark_views, st.render_key, st.view = res.lines, res, {}, nil, nil
    st.html_width, st.top_height, st.html_scale = viewport.width, viewport.height, viewport.scale
    if not st.pager then st.follow_lnum = nil end
  else
    local res = call('open', { key = buf, path = path })
    st = st or { pager = true }
    st.lines, st.info, st.pages, st.annots = res.lines, res.info, res.pages, res.annots
    reset_history(st, buf, res.state)
    st.version = (st.version or 0) + 1
    -- Line numbers can change: drop views remembered per line.
    st.layout, st.headers, st.views, st.follow_lnum = nil, {}, {}, nil
    for lnum, info in ipairs(st.info) do
      if info[4] then st.headers[info[1] + 1] = lnum end
    end
  end
  states[buf] = st
  st.path, st.stat, st.warned, st.search_lines = path, stat_key(path), nil, nil

  -- After :HtmlSource, the source's language server and parser must not see the view's text.
  for _, client in ipairs(vim.lsp.get_clients { bufnr = buf }) do
    vim.lsp.buf_detach_client(buf, client.id)
  end
  pcall(vim.treesitter.stop, buf)
  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
  end
  -- No swap file: the text is derived from the file, and a swap left by another
  -- nvim on the same file would otherwise raise E325 on the first set_lines.
  vim.bo[buf].swapfile, vim.bo[buf].undolevels = false, -1
  set_text(buf, st.lines)
  -- PDFs write annotations with :w; the HTML view cannot be written.
  vim.bo[buf].buftype = st.html and 'nofile' or 'acwrite'
  vim.bo[buf].filetype = st.html and 'htmlview' or 'pdfview'
  for win, view in pairs(views) do
    api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
  end

  if not st.html then decorate(buf) end
  setup_buffer(buf)
  if not st.poll then
    st.poll = assert(uv.new_fs_poll())
    st.poll:start(path, 500, function()
      vim.schedule(function() on_disk_change(buf) end)
    end)
  end
  refresh(buf)
end

--- Read the HTML source into `buf` the way :edit reads a file (from BufReadCmd).
local function read_source(buf)
  local path = api.nvim_buf_get_name(buf)
  vim.bo[buf].buftype, vim.bo[buf].swapfile, vim.bo[buf].modifiable = '', vim.go.swapfile, true
  vim.bo[buf].undolevels = -1
  if uv.fs_stat(path) then
    vim.cmd('silent keepalt keepjumps read ++edit ' .. vim.fn.fnameescape(path))
    api.nvim_buf_set_lines(buf, 0, 1, false, {})
  end
  vim.bo[buf].undolevels = -123456 -- the global value
  vim.bo[buf].modified = false
  -- Replace the view's filetype: :setf in filetype detection would keep it.
  vim.bo[buf].filetype = vim.filetype.match { buf = buf, filename = path } or ''
  -- The user's BufReadPost autocommands, as after :edit.
  vim.cmd('doautocmd BufReadPost ' .. vim.fn.fnameescape(path))
end

--- BufReadCmd for PDF and HTML files. HTML falls back to its source when it
--- cannot be shown (and after :HtmlSource).
local function read(buf)
  local name = api.nvim_buf_get_name(buf)
  if name:match '^%w+://' then return end
  local html_file = is_html_path(name)
  if html_file and vim.b[buf].pdfview_html_source then
    unload(buf)
    return read_source(buf)
  end
  local ok, err = pcall(load, buf)
  if ok then return end
  -- Nothing left of a previous view: :e! has emptied the buffer.
  unload(buf)
  if html_file then
    vim.b[buf].pdfview_html_source = true
    read_source(buf)
    notify('Showing HTML source: ' .. err, vim.log.levels.WARN)
  else
    -- Keep :w from writing the empty buffer over the PDF.
    vim.bo[buf].buftype = 'nofile'
    notify('Cannot open ' .. name .. ': ' .. err, vim.log.levels.ERROR)
  end
end

--- Summary of the frames rendered while $PDFVIEW_PROFILE was set: their count, the
--- pages rasterized for them, and per stage the median, 95th percentile and
--- maximum in ms. `opts.reset` starts a new recording. See docs/benchmarking.md.
---@param opts? {reset?: boolean}
function M.profile(opts)
  local frames = profile.frames
  if opts and opts.reset then profile.frames = {} end
  local summary = { frames = #frames, rasterized = 0, stages = {} }
  for _, f in ipairs(frames) do
    summary.rasterized = summary.rasterized + f.rasterized
  end
  for _, stage in ipairs { 'prepare', 'pages', 'scrollbar', 'write', 'ipc', 'show', 'total' } do
    local values = {}
    for i, f in ipairs(frames) do
      values[i] = f[stage]
    end
    table.sort(values)
    local function at(q) return values[math.max(1, math.ceil(q * #values))] end
    if #values > 0 then summary.stages[stage] = { median = at(0.5), p95 = at(0.95), max = values[#values] } end
  end
  return summary
end

---@param opts? pdfview.Config
function M.setup(opts)
  if vim.fn.has 'nvim-0.12' ~= 1 then
    return notify(('needs Neovim 0.12 or newer (this is %s)'):format(tostring(vim.version())), vim.log.levels.ERROR)
  end
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  set_hls()
  -- An earlier ModeChanged handler (notably which-key) can wait in getchar()
  -- before our handler runs. Scheduled input callbacks still run during that
  -- wait, so repaint after input as well as on native cursor/mode events.
  -- <Esc> in normal mode on the page view also returns to pager mode; watched
  -- here rather than mapped, so the user's own <Esc> mapping (:nohlsearch) still runs.
  vim.on_key(function(_, typed)
    local buf = api.nvim_get_current_buf()
    local st = states[buf]
    if not st then return end
    if typed == '\27' and not st.pager and st.focus == api.nvim_get_current_win() and api.nvim_get_mode().mode == 'n' then
      st.pager = true
    end
    if st.input_refresh_pending then return end
    st.input_refresh_pending = true
    vim.schedule(function()
      st.input_refresh_pending = nil
      if states[buf] == st and api.nvim_get_current_buf() == buf then render(buf) end
    end)
  end, NS)
  api.nvim_create_autocmd('ColorScheme', { group = GROUP, callback = set_hls })
  api.nvim_create_autocmd('BufReadCmd', {
    group = GROUP,
    pattern = { '*.[pP][dD][fF]', '*.[hH][tT][mM][lL]', '*.[hH][tT][mM]' },
    callback = function(ev) read(ev.buf) end,
  })
  api.nvim_create_user_command('HtmlSource', function()
    local buf = api.nvim_get_current_buf()
    if not (states[buf] and states[buf].html) then return notify('Not an HTML view', vim.log.levels.WARN) end
    vim.b[buf].pdfview_html_source = true
    vim.cmd.edit()
  end, { desc = 'Edit the HTML source in place of the rendered view' })
  api.nvim_create_user_command('HtmlView', function(args)
    local path = args.args:match '^file://' and vim.uri_to_fname(args.args) or args.args
    local ok, err = pcall(function()
      if path ~= '' then vim.cmd.edit(vim.fn.fnameescape(path)) end
      local buf = api.nvim_get_current_buf()
      if states[buf] then return end
      if not is_html_path(api.nvim_buf_get_name(buf)) then error('not an HTML file', 0) end
      vim.b[buf].pdfview_html_source = nil
      local edited, e = pcall(vim.cmd.edit, { bang = args.bang })
      if not edited then
        vim.b[buf].pdfview_html_source = true
        error(e, 0)
      end
    end)
    if not ok then notify(err, vim.log.levels.ERROR) end
  end, { nargs = '?', bang = true, complete = 'file', desc = 'Show a local HTML file in the rendered view' })
  api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = GROUP,
    callback = function()
      for buf, st in pairs(states) do
        if covered(st) then
          pcall(api.nvim_win_set_config, st.pane.win, pane_float(st.host))
          pcall(api.nvim_win_set_config, st.focus, focus_float(st.host))
          render(buf)
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
        render(buf)
      end
    end,
  })
  api.nvim_create_autocmd({ 'FocusLost', 'FocusGained' }, {
    group = GROUP,
    callback = function(ev)
      editor_focused = ev.event == 'FocusGained'
      for buf in pairs(states) do
        render(buf)
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
  api.nvim_create_autocmd('CmdlineEnter', {
    group = GROUP,
    pattern = { '/', '?' },
    callback = function()
      local buf = api.nvim_get_current_buf()
      local st = states[buf]
      if st and st.html and st.pager and covered(st) then html_anchor(buf, st) end
    end,
  })
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
        if states[buf] == st and api.nvim_get_current_buf() == buf then render(buf) end
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
        render(buf)
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
      render(api.nvim_get_current_buf())
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
        render(buf)
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
