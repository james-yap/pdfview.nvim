local api = vim.api
local M = {}

function M.set_spans(layout, spans)
  if #spans == 0 then spans[1] = {} end
  layout.spans = spans
end

-- Look up the wrap fragment containing a logical column. Collapsed spaces and
-- blank lines have no rectangle; use the nearest painted part of the text.
function M.fragment(layout, lnum, char)
  local lines = layout.spans
  local best
  for _, r in ipairs(lines[lnum]) do
    if char < r[2] then return r end
    best = r
  end
  if best then return best end
  for i = lnum - 1, 1, -1 do
    local spans = lines[i]
    if #spans > 0 then return spans[#spans] end
  end
  for i = lnum + 1, #lines do
    if #lines[i] > 0 then return lines[i][1] end
  end
  return { 0, 0, 0, 0 }
end

function M.visible(layout, top, height)
  local lnums, bottom = {}, top + height
  for lnum, spans in ipairs(layout.spans) do
    for _, r in ipairs(spans) do
      if r[3] < bottom and r[4] > top then
        lnums[#lnums + 1] = lnum
        break
      end
    end
  end
  return lnums
end

-- Choose a text cursor for the requested screen position, including when the
-- nearest painted row is in the middle of a wrapped buffer line.
function M.nearest(layout, y, edge)
  local best_line, best_char, distance
  for lnum, spans in ipairs(layout.spans) do
    for _, r in ipairs(spans) do
      local a, b = r[3], r[4]
      local d = math.abs((edge == 0 and a or edge == 1 and b or (a + b) / 2) - y)
      if not distance or d < distance then
        best_line, best_char, distance = lnum, r[1], d
      end
    end
  end
  return best_line, best_char
end

return M
