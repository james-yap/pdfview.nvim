local M = {}

function M.new(script, label, on_event)
  local helper = { seq = 0, pending = {} }

  local function start()
    if helper.proc then return end
    if vim.fn.executable 'uv' ~= 1 then
      error('pdfview needs uv on $PATH (https://docs.astral.sh/uv/getting-started/installation/)', 0)
    end
    local chunks, stderr = {}, ''
    local function dispatch(line)
      local msg = vim.json.decode(line, { luanil = { object = true, array = true } })
      if msg.event then
        if on_event then on_event(msg) end
        return
      end
      local cb = helper.pending[msg.id]
      helper.pending[msg.id] = nil
      if cb then cb(msg.error, msg.result) end
    end
    local function stdout(_, data)
      if not data then return end
      -- A reply can be hundreds of KB in small reads: join only at a newline.
      local first = 1
      while true do
        local nl = data:find('\n', first, true)
        if not nl then break end
        chunks[#chunks + 1] = data:sub(first, nl - 1)
        local line = table.concat(chunks)
        chunks = {}
        vim.schedule(function() dispatch(line) end)
        first = nl + 1
      end
      if first <= #data then chunks[#chunks + 1] = data:sub(first) end
    end
    helper.proc = vim.system({ 'uv', 'run', '--quiet', '--script', script }, {
      stdin = true,
      stdout = stdout,
      stderr = function(_, data)
        if data then stderr = (stderr .. data):sub(-2000) end
      end,
    }, function(res)
      vim.schedule(function()
        helper.proc = nil
        local pending, err = helper.pending, ('%s helper exited (%d): %s'):format(label, res.code, stderr)
        helper.pending = {}
        for _, cb in pairs(pending) do
          cb(err)
        end
      end)
    end)
  end

  function helper.request(method, params, cb)
    start()
    helper.seq = helper.seq + 1
    helper.pending[helper.seq] = cb
    helper.proc:write(vim.json.encode { id = helper.seq, method = method, params = params } .. '\n')
  end

  function helper.call(method, params)
    local done, err, result
    helper.request(method, params, function(e, r) done, err, result = true, e, r end)
    if not vim.wait(120000, function() return done end, 5) then error(label .. ' helper timed out: ' .. method, 0) end
    if err then error(err, 0) end
    return result
  end

  return helper
end

return M
