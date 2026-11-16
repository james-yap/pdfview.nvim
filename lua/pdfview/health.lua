-- :checkhealth pdfview
local M = {}

local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local HELPER = vim.fs.joinpath(ROOT, 'python', 'helper.py')

local function trim(s) return s and vim.trim(s) ~= '' and vim.trim(s) or nil end

function M.check()
  local health = vim.health

  health.start 'Neovim'
  if vim.fn.has 'nvim-0.12' == 1 then
    health.ok('Neovim ' .. tostring(vim.version()))
  else
    health.error('Neovim ' .. tostring(vim.version()) .. ' is too old', 'pdfview requires Neovim 0.12 or newer')
  end

  health.start 'Terminal'
  local ok, reason = require('pdfview.kitty').supported()
  if ok then
    health.ok('kitty or Ghostty (' .. (os.getenv 'TERM_PROGRAM' or os.getenv 'TERM' or 'kitty') .. ')')
  else
    health.warn(reason, 'open Neovim in kitty or Ghostty, outside tmux')
  end
  if vim.o.termguicolors then
    health.ok "'termguicolors' is on"
  else
    health.warn("'termguicolors' is off", "set termguicolors (image ids are 24-bit colours)")
  end

  health.start 'uv'
  if vim.fn.executable 'uv' ~= 1 then
    health.error('uv not on PATH', 'install uv: https://docs.astral.sh/uv/')
    return
  end
  local ver = vim.system({ 'uv', '--version' }, { text = true }):wait(10000)
  if not ver or ver.code ~= 0 then
    health.error('uv --version failed', ver and trim(ver.stderr) or 'timed out')
    return
  end
  health.ok(trim(ver.stdout))

  health.start 'Helper'
  if vim.fn.filereadable(HELPER) ~= 1 then
    health.error('helper not found: ' .. HELPER)
    return
  end
  health.info 'first run downloads PyMuPDF and typst and can take a couple of minutes'
  -- Same invocation as the plugin. `close` of an unknown key is a no-op that
  -- still proves the process imported PyMuPDF and typst and speaks JSON lines.
  local proc = vim.system({ 'uv', 'run', '--quiet', '--script', HELPER }, { stdin = true, text = true })
  proc:write(vim.json.encode({ id = 1, method = 'close', params = { key = 0 } }) .. '\n')
  proc:write(nil)
  local res = proc:wait(120000)
  local line = res and res.stdout and res.stdout:match '[^\n]+'
  local msg = line and vim.json.decode(line, { luanil = { object = true, array = true } })
  if not res or res.code ~= 0 or type(msg) ~= 'table' or msg.id ~= 1 or msg.error then
    local detail = (msg and msg.error) or (res and trim(res.stderr)) or (res and trim(res.stdout)) or 'timed out'
    health.error('helper failed to start', detail)
    return
  end
  health.ok 'PyMuPDF and typst imported; helper answered close'

  health.start 'Snapshots'
  if vim.fn.has 'mac' == 1 then
    if vim.fn.executable 'osascript' == 1 then
      health.ok 'macOS clipboard copy via osascript'
    else
      health.warn('osascript not found; snapshots will not reach the clipboard')
    end
  else
    health.info 'snapshots are saved to a path (clipboard copy is macOS-only)'
  end
end

return M
