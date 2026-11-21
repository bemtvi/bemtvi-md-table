-- bemtvi-md-table.layout — the pure half of the plugin: parse GFM pipe-table rows and
-- work out the padding that lines a table's columns up. No editor state, no I/O; the
-- provider in `init.lua` feeds it buffer lines and turns its result into marks.
--
-- Columns throughout are BYTE offsets into the line (what an extmark anchors on);
-- widths are DISPLAY cells (`btv.str.displaywidth`), so wide characters line up.

local M = {}

local width = btv.str.displaywidth

-- The byte offsets (1-based) of every unescaped `|` in `line`. A pipe preceded by an
-- odd run of backslashes is escaped (`\|` is a literal pipe inside a cell, GFM's one
-- way to put one there — including inside a code span, where an unescaped pipe still
-- splits the cell).
local function pipes(line)
  local out, from = {}, 1
  while true do
    local p = line:find("|", from, true)
    if not p then
      return out
    end
    local slashes, i = 0, p - 1
    while i >= 1 and line:byte(i) == 92 do -- `\`
      slashes = slashes + 1
      i = i - 1
    end
    if slashes % 2 == 0 then
      out[#out + 1] = p
    end
    from = p + 1
  end
end

-- `M.row(line)` -> nil | row. Splits a table row into cells. `nil` when the line has
-- no unescaped pipe (so it cannot be a row) or is blank.
--
-- ```
-- row = {
--   indent  = <leading whitespace width>,
--   cells   = { cell, ... },
-- }
-- cell = {
--   s     = <first byte of the cell's text>,      -- between the pipes
--   e     = <last byte of the cell's text>,       -- s - 1 when the cell is empty
--   close = <byte of the closing pipe> | nil,     -- nil: the row's open last cell
--   seg   = <display width from the previous closing pipe (or the line start, for
--            the first cell) up to this cell's closing pipe>,
-- }
-- ```
--
-- `seg` is what the columns are aligned on. For the first cell it runs from the start
-- of the line, so a leading pipe and any indentation count toward column 1, and a row
-- written with a leading pipe lines up with one written without.
function M.row(line)
  if not line:find("%S") then
    return nil
  end
  local ps = pipes(line)
  if #ps == 0 then
    return nil
  end
  local first = line:sub(1, ps[1] - 1)
  local leading = not first:find("%S")
  local trailing = not line:sub(ps[#ps] + 1):find("%S")
  local cells = {}
  local prev, from = 0, 1
  if leading then
    prev, from = ps[1], 2
  end
  local seg_from = 1
  for k = from, #ps do
    local p = ps[k]
    cells[#cells + 1] =
      { s = prev + 1, e = p - 1, close = p, seg = width(line:sub(seg_from, p - 1)) }
    prev, seg_from = p, p + 1
  end
  if not trailing then
    cells[#cells + 1] = { s = prev + 1, e = #line, close = nil, seg = width(line:sub(seg_from)) }
  end
  return { indent = #(line:match("^%s*")), cells = cells }
end

-- `M.aligns(row, line)` -> nil | { "left" | "right" | "center", ... }. The column
-- alignments a delimiter row (`|:---|---:|:---:|`) spells, one per cell; `nil` when
-- `row` is not a delimiter row (every cell must be `:?-+:?`, padding aside).
function M.aligns(row, line)
  if not row or #row.cells == 0 then
    return nil
  end
  local out = {}
  for i, cell in ipairs(row.cells) do
    local text = line:sub(cell.s, cell.e):match("^%s*(.-)%s*$")
    if not text:find("^:?%-+:?$") then
      return nil
    end
    local l, r = text:sub(1, 1) == ":", text:sub(-1) == ":"
    out[i] = (l and r) and "center" or (r and "right" or "left")
  end
  return out
end

-- Whether `line` could be part of a table at all — the cheap pre-filter the provider
-- runs on every visible line before parsing anything.
function M.is_row(line)
  return line:find("|", 1, true) ~= nil and M.row(line) ~= nil
end

-- `M.table_at(lines)` -> nil | first. Given a run of consecutive row lines (every one
-- `M.is_row`), the index of the table's header row inside it, or `nil` when the run
-- holds no table. A table is a header row followed by a delimiter row with the same
-- number of cells, both indented at most three spaces (four is an indented code block);
-- lines in the run above the header are paragraph text that happens to hold a pipe.
function M.table_at(lines)
  for i = 2, #lines do
    local delim = M.row(lines[i])
    if delim and delim.indent <= 3 and M.aligns(delim, lines[i]) then
      local header = M.row(lines[i - 1])
      if header and header.indent <= 3 and #header.cells == #delim.cells then
        return i - 1
      end
    end
  end
  return nil
end

-- `M.layout(lines[, opts])` -> pads. `lines` is one whole table: the header row, the
-- delimiter row, then the body rows. Returns, per line, the padding to draw in it:
--
-- ```
-- pads[i] = { { col = <0-based byte col>, text = "   ", delimiter = <bool> }, ... }
-- ```
--
-- Each column is widened to its widest cell. A cell that falls short gets the
-- difference as padding: spaces before its closing pipe (or before its text, or split
-- around it, for a right- or center-aligned column when `opts.align` is on, the
-- default), and on the delimiter row, dashes after the cell's last `-` — so `:---:`
-- stays a centered marker and the colons stay at the edges.
--
-- An open last cell (a row with no trailing pipe) still counts toward its column's
-- width but is never padded: nothing follows it to line up.
function M.layout(lines, opts)
  local align = not (opts and opts.align == false)
  local rows = {}
  for i, line in ipairs(lines) do
    rows[i] = M.row(line) or { indent = 0, cells = {} }
  end
  local aligns = M.aligns(rows[2], lines[2]) or {}

  local widths = {}
  for _, row in ipairs(rows) do
    for j, cell in ipairs(row.cells) do
      if cell.seg > (widths[j] or 0) then
        widths[j] = cell.seg
      end
    end
  end

  local pads = {}
  for i, row in ipairs(rows) do
    local out = {}
    for j, cell in ipairs(row.cells) do
      local pad = widths[j] - cell.seg
      if pad > 0 and cell.close then
        if i == 2 then
          -- The last `-` of the delimiter cell; the dashes go right after it.
          local last = cell.s - 1
          for b = cell.e, cell.s, -1 do
            if lines[i]:byte(b) == 45 then -- `-`
              last = b
              break
            end
          end
          out[#out + 1] = { col = last, text = ("-"):rep(pad), delimiter = true }
        else
          local how = align and aligns[j] or "left"
          local before = (how == "right" and pad) or (how == "center" and math.floor(pad / 2)) or 0
          if before > 0 then
            out[#out + 1] = { col = cell.s - 1, text = (" "):rep(before) }
          end
          if pad - before > 0 then
            out[#out + 1] = { col = cell.close - 1, text = (" "):rep(pad - before) }
          end
        end
      end
    end
    pads[i] = out
  end
  return pads
end

return M
