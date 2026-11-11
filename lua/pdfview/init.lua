-- pdfview.nvim: a read-only text buffer for vim motions (hjkl, /, leap,
-- visual) plus a page pane that follows the cursor and tints the cursor line
-- or visual selection. The pane is drawn with the kitty graphics protocol
-- (lua/pdfview/kitty.lua).
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
-- Tints for the page pane / snapshot (multiplied over the page, so ink stays dark).
local COLORS = { cursor = 0xDDEBFF, cursor_char = 0x8AB8FF, selection = 0xA8D1FF }
local HL = { Highlight = 'PdfViewHighlight', Underline = 'PdfViewUnderline', StrikeOut = 'PdfViewStrikeOut', Squiggly = 'PdfViewSquiggly' }
local NOTE_TYPES = { Text = true, FreeText = true }

---@class pdfview.Config
M.config = {
  -- Buffer-local keys in PDF buffers; set any of them to false to skip it.
  keys = { prefix = '<leader>p', next_annotation = ']a', prev_annotation = '[a' },
  -- Page pane width: a fraction (< 1) of the columns it shares with the text window, or a
  -- number of columns. Reapplied when the terminal is resized; <C-w> resizes otherwise stick.
  pane_width = 0.6,
  -- Where snapshots are written. nil: $TMPDIR/pdfview.
  snapshot_dir = nil, ---@type string?
}

---@type table<integer, table> per PDF buffer
local states = {}

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

-- Page pane ------------------------------------------------------------------

local function pane_valid(st) return st.pane ~= nil and api.nvim_win_is_valid(st.pane.win) end

local function close_pane(st)
  if st.image then kitty.delete(st.image) end
  -- After :bd the pane can be the last window; it cannot close, so it shows an empty buffer.
  if pane_valid(st) and not pcall(api.nvim_win_close, st.pane.win, true) then
    vim.wo[st.pane.win].winfixbuf = false
    api.nvim_win_call(st.pane.win, vim.cmd.enew)
  end
  st.pane, st.image, st.grid, st.view, st.render_key = nil, nil, nil, nil, nil
end

local unsupported_reported = false
local MIN_TEXT_WIDTH = 20

--- Pane columns out of `total`, the columns the text window and pane share (separator excluded).
local function pane_columns(total)
  local w = M.config.pane_width
  local cols = w < 1 and math.floor(total * w + 0.5) or math.floor(w)
  return math.max(1, math.min(cols, total - MIN_TEXT_WIDTH))
end

local function open_pane(buf, win)
  local st = states[buf]
  if pane_valid(st) or api.nvim_win_get_config(win).relative ~= '' then return end
  local ok, reason = kitty.supported()
  if ok and not kitty.cell_size() then
    ok, reason = false, 'the terminal does not report its size in pixels'
  end
  if not ok then
    if not unsupported_reported then
      unsupported_reported = true
      notify('No page pane: ' .. reason, vim.log.levels.WARN)
    end
    return
  end
  local pbuf = api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = 'wipe'
  vim.bo[pbuf].filetype = 'pdfview_page'
  vim.bo[pbuf].modifiable = false
  local width = pane_columns(api.nvim_win_get_width(win) - 1)
  local pwin = api.nvim_open_win(pbuf, false, { split = 'right', win = win, width = width })
  -- :setlocal, so a buffer that later replaces the pane gets normal window options.
  local wo = {
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
    -- Keep the configured width through <C-w>= and other windows opening or closing.
    winfixwidth = true,
  }
  for option, value in pairs(wo) do
    vim.wo[pwin][0][option] = value
  end
  st.pane = { win = pwin, buf = pbuf }
end

--- First and last buffer lines `win` shows: what leap and / can reach.
local function window_lines(win) return { vim.fn.line('w0', win), vim.fn.line('w$', win) } end

--- Fit-width view of the cursor's page, panned to centre the lines the text
--- window shows; when they are taller than the pane, panned to keep the cursor
--- line in the middle 70% of the pane. Pages shorter than the pane are shown
--- whole. The image is rendered at exactly cols x rows cells of terminal pixels.
--- `lit` is the text window's line range, kept bright on the page.
local function view_for(buf, win)
  local st = states[buf]
  local info = st.info[api.nvim_win_get_cursor(win)[1]]
  local page = info[1]
  local pw, ph = st.pages[page + 1][1], st.pages[page + 1][2]
  local cell = assert(kitty.cell_size())
  local cols = math.min(api.nvim_win_get_width(st.pane.win), kitty.max_cells)
  local rows = math.min(api.nvim_win_get_height(st.pane.win), kitty.max_cells)
  local px_w = cols * cell.width
  local h = pw * rows * cell.height / px_w -- page points visible at fit-width
  local lit = window_lines(win)
  if h >= ph then
    local img_rows = math.max(1, math.ceil(ph * px_w / pw / cell.height))
    return { page = page, clip = { 0, 0, pw, ph }, width = math.floor(px_w), cols = cols, rows = img_rows, lit = lit }
  end
  local top, bottom
  for lnum = lit[1], lit[2] do
    local l = st.info[lnum]
    if l[1] == page and not l[4] then
      top, bottom = math.min(top or l[2], l[2]), math.max(bottom or l[3], l[3])
    end
  end
  local y0
  if top and bottom - top <= h then
    y0 = (top + bottom - h) / 2
  else
    local cy, v = info[4] and 0 or (info[2] + info[3]) / 2, st.view
    if v and v.page == page and v.h == h and cy >= v.y0 + h * 0.15 and cy <= v.y0 + h * 0.85 then
      y0 = v.y0
    else
      y0 = cy - h * 0.4
    end
  end
  y0 = math.max(0, math.min(ph - h, y0))
  return { page = page, y0 = y0, h = h, clip = { 0, y0, pw, y0 + h }, width = math.floor(px_w), cols = cols, rows = rows, lit = lit }
end

--- The selection (visual mode in `win`) or else the cursor line, plus the character under the cursor.
local function marks_for(buf, win, page)
  local st = states[buf]
  local lnum, col = unpack(api.nvim_win_get_cursor(win))
  local marks = {}
  local ranges = win == api.nvim_get_current_win() and selection(buf)
  if ranges then
    ranges = vim.tbl_filter(function(r) return st.info[r[1]][1] == page end, ranges)
    marks[1] = { ranges = ranges, color = COLORS.selection }
  end
  if st.info[lnum][4] then return marks end
  local text = st.lines[lnum]
  if not ranges then marks[1] = { ranges = { { lnum, 0, vim.str_utfindex(text, 'utf-32') - 1 } }, color = COLORS.cursor } end
  local ci = char_index(text, col)
  marks[#marks + 1] = { ranges = { { lnum, ci, ci } }, color = COLORS.cursor_char }
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

--- Render the page pane for `buf` as seen from `win`. At most one render is in
--- flight per buffer; requests arriving meanwhile collapse into one rerun.
local function render(buf, win)
  local st = states[buf]
  if not (st and pane_valid(st) and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf) then return end
  if st.busy then
    st.again = win
    return
  end
  local view = view_for(buf, win)
  local marks = marks_for(buf, win, view.page)
  local key = vim.json.encode { view.page, view.clip, view.width, view.rows, view.lit, marks, st.version }
  if key == st.render_key then return end
  st.view, st.render_key, st.busy = view, key, true
  render_id = render_id + 1
  -- kitty and Ghostty only accept temporary files named like this, in $TMPDIR.
  local png = vim.fs.joinpath(kitty.tmpdir(), ('tty-graphics-protocol-pdfview-%d-%d.png'):format(vim.fn.getpid(), render_id))
  local params = { key = buf, page = view.page, clip = view.clip, width = view.width, marks = marks, lit = view.lit, scrollbar = true, out = png }
  request('render', params, function(err)
    st.busy = false
    if err then
      st.render_key = nil
      notify(err, vim.log.levels.ERROR)
    elseif pane_valid(st) then
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
    local wins = vim.fn.win_findbuf(buf)
    if #wins == 0 or not states[buf] then return end
    local win = vim.tbl_contains(wins, api.nvim_get_current_win()) and api.nvim_get_current_win() or wins[1]
    open_pane(buf, win)
    render(buf, win)
  end)
end

-- leap.nvim labels on the page pane ------------------------------------------

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
    if virt_text and t.pos and st and st.view and pane_valid(st) then
      local lnum = t.pos[1]
      if not st.info[lnum][4] and st.info[lnum][1] == st.view.page then
        by_buf[buf] = by_buf[buf] or {}
        table.insert(by_buf[buf], { lnum = lnum, char = char_index(st.lines[lnum], t.pos[2] - 1 + t.beacon[1]), virt_text = virt_text })
      end
    end
  end
  local cell = kitty.cell_size()
  if not cell then return end
  for buf, labels in pairs(by_buf) do
    local st = states[buf]
    local boxes = try_call('char_boxes', { key = buf, chars = vim.tbl_map(function(l) return { l.lnum, l.char } end, labels) })
    if boxes then
      local v = st.view
      local zoom = v.width / (v.clip[3] - v.clip[1])
      for i, l in ipairs(labels) do
        local b = boxes[i]
        local width = 0
        for _, chunk in ipairs(l.virt_text) do
          width = width + api.nvim_strwidth(chunk[1])
        end
        local row = math.floor(((b[2] + b[4]) / 2 - v.clip[2]) * zoom / cell.height)
        local col = math.min(math.floor((b[1] - v.clip[1]) * zoom / cell.width), v.cols - width)
        if row >= 0 and row < v.rows and col >= 0 then
          api.nvim_buf_set_extmark(st.pane.buf, NS_LABELS, row, 0, { virt_text = l.virt_text, virt_text_win_col = col, strict = false })
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

-- Annotation actions ---------------------------------------------------------

local function apply(buf, res)
  local st = states[buf]
  st.annots = vim.tbl_filter(function(a) return a.page ~= res.page end, st.annots)
  vim.list_extend(st.annots, res.annots)
  st.version = st.version + 1
  vim.bo[buf].modified = true
  decorate(buf)
  render(buf, api.nvim_get_current_win())
end

local function under_cursor(buf)
  local st = states[buf]
  local lnum, col = unpack(api.nvim_win_get_cursor(0))
  local ci = char_index(st.lines[lnum], col)
  local best, best_len
  for _, a in ipairs(st.annots) do
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
  return best
end

local note_id = 0

local function edit_note(buf, annot)
  note_id = note_id + 1
  local nbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(nbuf, ('pdfview-note://%d'):format(note_id))
  vim.bo[nbuf].buftype = 'acwrite'
  vim.bo[nbuf].bufhidden = 'wipe'
  vim.bo[nbuf].filetype = 'markdown'
  api.nvim_buf_set_lines(nbuf, 0, -1, false, vim.split(annot.contents, '\n', { plain = true }))
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

--- PNG of what the page pane shows (the cursor's whole page without a pane),
--- plus a caption (path, page, view, selection box, note texts). On macOS it
--- is copied to the clipboard as an image.
local function snapshot(buf)
  local st, ranges = states[buf], selection(buf)
  if ranges then vim.cmd 'normal! \27' end
  local view = st.view
  if not view then
    local page = st.info[api.nvim_win_get_cursor(0)[1]][1]
    view = { page = page, clip = { 0, 0, st.pages[page + 1][1], st.pages[page + 1][2] }, width = 0 }
  end
  if ranges and ranges_page(st, ranges) ~= view.page then return notify('Selection must be on the page being shown', vim.log.levels.WARN) end
  local dir = M.config.snapshot_dir or vim.fs.joinpath(kitty.tmpdir(), 'pdfview')
  vim.fn.mkdir(dir, 'p')
  local png = vim.fs.joinpath(dir, ('snap-%s-%03d.png'):format(os.date '%Y%m%d-%H%M%S', uv.now() % 1000))
  local params =
    { key = buf, page = view.page, clip = view.clip, width = math.max(view.width, 1600), ranges = ranges or {}, color = COLORS.selection, out = png }
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
  states[buf] = nil
  if st.poll then st.poll:close() end
  close_pane(st)
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
  vim.bo[buf].modified = false
end

local function setup_buffer(buf)
  local group = api.nvim_create_augroup('pdfview.' .. buf, { clear = true })
  local function au(events, fn) api.nvim_create_autocmd(events, { group = group, buffer = buf, callback = fn }) end
  au({ 'CursorMoved', 'ModeChanged' }, function() render(buf, api.nvim_get_current_win()) end)
  au('BufWinEnter', function() refresh(buf) end)
  au('BufWinLeave', function()
    vim.schedule(function()
      if states[buf] and #vim.fn.win_findbuf(buf) == 0 then close_pane(states[buf]) end
    end)
  end)
  -- Close the pane first so :q in the last text window exits nvim.
  au('QuitPre', function()
    if #vim.fn.win_findbuf(buf) == 1 then close_pane(states[buf]) end
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
    if lhs then vim.keymap.set(mode, lhs, fn, { buffer = buf, desc = 'PDF: ' .. desc }) end
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
  map('n', keys.next_annotation, function() jump(buf, 1, vim.v.count1) end, 'next annotation')
  map('n', keys.prev_annotation, function() jump(buf, -1, vim.v.count1) end, 'previous annotation')
end

load = function(buf)
  local path = canonical(api.nvim_buf_get_name(buf))
  local res = call('open', { key = buf, path = path })
  local st = states[buf] or {}
  states[buf] = st
  st.path, st.lines, st.info, st.pages, st.annots = path, res.lines, res.info, res.pages, res.annots
  st.stat, st.warned, st.version = stat_key(path), nil, (st.version or 0) + 1

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
        local win = vim.fn.win_findbuf(buf)[1]
        if win and ev.event == 'VimResized' and pane_valid(st) then
          local total = api.nvim_win_get_width(win) + api.nvim_win_get_width(st.pane.win)
          api.nvim_win_set_width(st.pane.win, pane_columns(total))
        end
        if win then render(buf, win) end
      end
    end,
  })
  -- The pane frames the text window's lines, so scrolling without moving the cursor moves it too.
  api.nvim_create_autocmd('WinScrolled', {
    group = GROUP,
    callback = function()
      for id in pairs(vim.v.event) do
        local win = tonumber(id)
        if win and api.nvim_win_is_valid(win) and states[api.nvim_win_get_buf(win)] then render(api.nvim_win_get_buf(win), win) end
      end
    end,
  })
  -- leap fires LeapRedraw before drawing each round of labels, and LeapLeave at the end.
  -- Leap can move the cursor and then keep waiting for keys (autojump to the first
  -- target, traversal), and CursorMoved only fires once it returns. Render on
  -- LeapRedraw so the pane follows; it also sets st.view before the labels are mirrored.
  api.nvim_create_autocmd('User', { group = GROUP, pattern = 'LeapEnter', callback = hook_leap })
  api.nvim_create_autocmd('User', {
    group = GROUP,
    pattern = 'LeapRedraw',
    callback = function()
      clear_labels()
      render(api.nvim_get_current_buf(), api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd('User', { group = GROUP, pattern = 'LeapLeave', callback = clear_labels })
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
