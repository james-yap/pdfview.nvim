-- Kitty graphics protocol with Unicode placeholders (kitty, Ghostty).
--
-- An image is sent once (a=T, U=1: transmit and create a virtual placement of
-- cols x rows cells). It appears wherever the buffer contains placeholder
-- cells (U+10EEEE + row/column diacritics) whose foreground colour encodes the
-- image id. Because those cells are ordinary text to Nvim, splits, scrolling
-- and floating windows cover and clip the image correctly.
-- Spec: https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders
local M = {}

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
-- Row/column numbers are encoded as these combining marks (kitty's rowcolumn-diacritics.txt).
-- stylua: ignore
local DIACRITICS = vim.split(table.concat({
  '0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357',
  '035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484',
  '0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1',
  '05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658',
  '0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2',
  '06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743',
  '0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819',
  '081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C',
  '082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76',
  '1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1',
  '1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1',
  '1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1',
  '1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7',
  '20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA',
  '2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA',
  '2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5',
  'A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7',
  'AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187',
  '1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244',
}, ','), ',')
for i, hex in ipairs(DIACRITICS) do
  DIACRITICS[i] = vim.fn.nr2char(tonumber(hex, 16))
end
M.max_cells = #DIACRITICS

-- Ids cycle through a small range so highlight groups (one per id) stay bounded;
-- a pane holds at most two images at once. The base keeps clear of small ids
-- other programs tend to use.
local ID_BASE, ID_COUNT = 0x5D0000, 1024
local next_id = 0
local cell ---@type {width: number, height: number}?

--- Whether images can be shown here, and why not.
---@return boolean ok, string? reason
function M.supported()
  if os.getenv 'TMUX' then return false, 'tmux is not supported' end
  local ui = vim.api.nvim_list_uis()[1]
  if not ui then return false, 'no UI attached' end
  if not ui.stdout_tty then return false, 'the UI is not a local terminal' end
  local term, program = os.getenv 'TERM' or '', os.getenv 'TERM_PROGRAM' or ''
  if not (program == 'ghostty' or term == 'xterm-ghostty' or term == 'xterm-kitty' or os.getenv 'KITTY_WINDOW_ID') then
    return false, 'needs kitty or Ghostty (kitty graphics protocol with Unicode placeholders)'
  end
  if not vim.o.termguicolors then return false, "needs 'termguicolors' (image ids are encoded as 24-bit colours)" end
  return true
end

--- Terminal cell size in pixels, from TIOCGWINSZ on the server's tty.
---@return {width: number, height: number}?
function M.cell_size()
  if cell then return cell end
  local ffi = require 'ffi'
  pcall(ffi.cdef, 'typedef struct { unsigned short row, col, xpixel, ypixel; } pdfview_winsize; int ioctl(int, unsigned long, ...);')
  local request = vim.fn.has 'linux' == 1 and 0x5413 or 0x40087468 -- TIOCGWINSZ
  local size = ffi.new 'pdfview_winsize'
  for fd = 0, 2 do
    if ffi.C.ioctl(fd, request, size) == 0 and size.col > 0 and size.xpixel > 0 then
      cell = { width = size.xpixel / size.col, height = size.ypixel / size.row }
      return cell
    end
  end
end

local group = vim.api.nvim_create_augroup('pdfview.kitty', { clear = true })
vim.api.nvim_create_autocmd('VimResized', {
  group = group,
  callback = function() cell = nil end, -- font size changes also resize the grid
})

-- Images are sent with q=1: the terminal answers only on failure.
local reported = {}
vim.api.nvim_create_autocmd('TermResponse', {
  group = group,
  callback = function(ev)
    local id, msg = (ev.data and ev.data.sequence or ''):match '^\27_Gi=(%d+);(.*)$'
    id = tonumber(id)
    if not id or id < ID_BASE or id >= ID_BASE + ID_COUNT or msg == 'OK' or reported[msg] then return end
    reported[msg] = true
    vim.notify('Terminal could not show the page: ' .. msg, vim.log.levels.ERROR, { title = 'pdfview' })
  end,
})

local function command(keys, payload) vim.api.nvim_ui_send('\27_G' .. keys .. (payload and ';' .. payload or '') .. '\27\\') end

--- Directory the terminal accepts temporary image files from.
function M.tmpdir() return vim.fs.normalize(os.getenv 'TMPDIR' or '/tmp') end

--- Show the PNG at `path` as a new image of cols x rows cells; returns its id.
--- `path` must be in M.tmpdir() and contain "tty-graphics-protocol": the
--- terminal reads it and then deletes it (t=t).
---@return integer id
function M.show(path, cols, rows)
  next_id = (next_id + 1) % ID_COUNT
  local id = ID_BASE + next_id
  command(('a=T,U=1,f=100,t=t,q=1,i=%d,c=%d,r=%d'):format(id, cols, rows), vim.base64.encode(path))
  vim.api.nvim_set_hl(0, M.hl(id), { fg = ('#%06x'):format(id) })
  return id
end

--- Free an image and its data in the terminal.
function M.delete(id) command(('a=d,d=I,q=2,i=%d'):format(id)) end

--- Highlight group whose foreground selects image `id`.
function M.hl(id) return 'PdfViewImage' .. id end

--- Buffer lines of placeholder cells for a cols x rows image.
---@return string[]
function M.placeholders(cols, rows)
  local lines = {}
  for r = 1, rows do
    local row = {}
    for c = 1, cols do
      row[c] = PLACEHOLDER .. DIACRITICS[r] .. DIACRITICS[c]
    end
    lines[r] = table.concat(row)
  end
  return lines
end

return M
