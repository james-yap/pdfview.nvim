-- Scrolling benchmark: renders a PDF through the real helper in headless Neovim
-- and prints how long each stage of a frame takes. See docs/benchmarking.md.
--
--   nvim --headless -u NONE -i NONE -l tests/bench.lua FILE.pdf [--frames=N] [--grid=COLSxROWS] [--cell=WxH]
--
-- Only the terminal is replaced: frames are written as usual, then deleted.
local api, uv = vim.api, vim.uv
local opts = { frames = 40, grid = '200x50', cell = '16x34' }
local pdf
for _, a in ipairs(arg) do
  local k, v = a:match '^%-%-(%w+)=(.+)$'
  if k and opts[k] then
    opts[k] = v
  elseif not k and not pdf then
    pdf = a
  else
    io.stderr:write('unknown argument: ' .. a .. '\n')
    os.exit(2)
  end
end
if not pdf then
  io.stderr:write 'usage: nvim --headless -u NONE -i NONE -l tests/bench.lua FILE.pdf [--frames=N] [--grid=COLSxROWS] [--cell=WxH]\n'
  os.exit(2)
end
local function size(s) return s:match '^(%d+)x(%d+)$' end
local cols, rows = size(opts.grid)
local cw, ch = size(opts.cell)
local frames = tonumber(opts.frames)
if not (cols and cw and frames) then
  io.stderr:write 'bad --grid, --cell or --frames\n'
  os.exit(2)
end

vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)))))
vim.o.columns, vim.o.lines = tonumber(cols) + 1, tonumber(rows) + 2
vim.o.laststatus, vim.o.cmdheight = 0, 1
vim.env.PDFVIEW_PROFILE = '1'
local errors = {}
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
end
local kitty = require 'pdfview.kitty'
kitty.supported = function() return true end
kitty.cell_size = function() return { width = tonumber(cw), height = tonumber(ch) } end
kitty.show = function(path)
  os.remove(path)
  return 1
end
kitty.delete = function() end
local pdfview = require 'pdfview'
pdfview.setup()

local function fail(msg)
  io.stderr:write(msg .. '\n' .. table.concat(errors, '\n') .. '\n')
  os.exit(1)
end

--- Wait for the next frame; false when none comes (the view did not change).
local function next_frame(seen, timeout)
  return vim.wait(timeout or 3000, function() return #errors > 0 or pdfview.profile().frames > seen end, 1) and #errors == 0
end

local function report(name, note)
  local s = pdfview.profile { reset = true }
  io.stdout:write(('\n%s: %d frames, %d pages rasterized%s\n\n'):format(name, s.frames, s.rasterized, note or ''))
  io.stdout:write '| stage | median ms | p95 ms | max ms |\n|---|---:|---:|---:|\n'
  for _, stage in ipairs { 'prepare', 'pages', 'scrollbar', 'write', 'ipc', 'show', 'total' } do
    local v = s.stages[stage]
    if v then io.stdout:write(('| %s | %.2f | %.2f | %.2f |\n'):format(stage, v.median, v.p95, v.max)) end
  end
end

--- Type `keys` `frames` times, waiting for each frame before the next.
local function scenario(name, keys)
  pdfview.profile { reset = true }
  local done = 0
  for _ = 1, frames do
    api.nvim_feedkeys(vim.keycode(keys), 'mx', false)
    if not next_frame(done) then break end
    done = done + 1
  end
  if #errors > 0 then fail(name .. ' failed') end
  report(name, done < frames and ' (stopped at the end of the document)' or nil)
end

local function to_start()
  api.nvim_feedkeys('gg', 'mx', false)
  next_frame(pdfview.profile().frames, 500)
end

io.stdout:write(('%s at %sx%s cells of %sx%s px\n'):format(pdf, cols, rows, cw, ch))
local t0 = uv.hrtime()
vim.cmd.edit(vim.fn.fnameescape(pdf))
if not next_frame(0, 120000) then fail 'the first frame never came' end
io.stdout:write(('\nopen to first frame: %.0f ms\n'):format((uv.hrtime() - t0) / 1e6))
report 'first frame'

scenario('scroll (3<C-e>)', '3<C-e>')
to_start()
scenario('page down (<C-f>)', '<C-f>')
to_start()
vim.fn.setreg('/', 'e')
vim.o.hlsearch = true
vim.v.hlsearch = 1
scenario('scroll with a search for "e" highlighted', '3<C-e>')
vim.cmd 'qa!'
