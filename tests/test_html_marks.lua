-- Invoked by test_html_helper.py with a generated local HTML document.
local api = vim.api
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.columns, vim.o.lines, vim.o.mouse = 80, 24, 'a'
local kitty = require 'pdfview.kitty'
kitty.supported = function() return true end
kitty.cell_size = function() return { width = 10, height = 20 } end
kitty.show = function(path) os.remove(path); return 1 end
kitty.delete = function() end
local messages = {}
vim.notify = function(msg) messages[#messages + 1] = msg end
local pdfview = require 'pdfview'
pdfview.setup()
local states
for i = 1, 100 do
  local name, value = debug.getupvalue(pdfview.setup, i)
  if name == 'states' then states = value; break end
end
vim.cmd.edit(vim.fn.fnameescape(vim.env.PDFVIEW_TEST_HTML))

local function keys(s) api.nvim_feedkeys(vim.keycode(s), 't', false) end
local function ready()
  local st = states[api.nvim_get_current_buf()]
  if st and st.view and not st.busy and api.nvim_get_current_win() == st.focus then return st.view end
end
local function wait_for(label, predicate, next_step)
  local deadline = vim.uv.now() + 15000
  local function fail(message)
    io.stderr:write(label .. ': ' .. message .. '\n' .. table.concat(messages, '\n') .. '\n')
    vim.cmd 'cquit!'
  end
  local function check()
    local ok, view = pcall(function()
      local v = ready()
      return v and predicate(v) and v
    end)
    if not ok then return fail(view) end
    if view then
      local done, err = pcall(next_step, view)
      if not done then fail(err) end
    elseif vim.uv.now() > deadline then
      fail('timed out')
    else
      vim.defer_fn(check, 20)
    end
  end
  vim.defer_fn(check, 20)
end

local function pan(dir) api.nvim_input_mouse('wheel', dir, '', 0, 4, 4) end
wait_for('open HTML view', function() return true end, function()
  keys('15j')
  pan('right')
  wait_for('pan to the marked viewport', function(v) return v.top > 0 and v.left > 0 end, function(marked)
    keys('ma')
    wait_for('mark a position in a wrapped line', function()
      local pos = vim.fn.getpos "'a"
      return pos[2] > 1 and pos[3] > 1
    end, function()
      local mark = vim.fn.getpos "'a"
      keys('G')
      pan('left')
      wait_for('pan away in both directions', function(v)
        return v.top > marked.top + v.height and v.left == 0
      end, function(away)
        keys("'a")
        wait_for('linewise mark jump restores both offsets', function(v)
          local cursor = api.nvim_win_get_cursor(0)
          return v.top == marked.top and v.left == marked.left and cursor[1] == mark[2] and cursor[2] == 0
        end, function()
          keys("''")
          wait_for('previous-context jump restores the viewport left behind', function(v)
            return v.top == away.top and v.left == away.left
          end, function()
            keys('`a')
            wait_for('exact mark jump restores the viewport and byte column', function(v)
              local cursor = api.nvim_win_get_cursor(0)
              return v.top == marked.top and v.left == marked.left and cursor[1] == mark[2] and cursor[2] == mark[3] - 1
            end, function() vim.cmd 'qa!' end)
          end)
        end)
      end)
    end)
  end)
end)
