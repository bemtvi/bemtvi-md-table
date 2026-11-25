-- bemtvi-md-table.layout — the pure half of the plugin: parse GFM pipe-table rows and
-- work out the padding that lines a table's columns up. No editor state, no I/O; the
-- provider in `init.lua` finds each table with the treesitter grammar, feeds its lines
-- here and turns the result into marks.
--
-- Columns throughout are BYTE offsets into the line (what an extmark anchors on);
-- widths are DISPLAY cells (`btv.str.displaywidth`), so wide characters line up.

local M = {}

-- A table wider than this many display cells, its columns summed, is left alone: it
-- can't line up on any screen, and padding it would mean strings as long as its widest
-- cell on every row.
M.MAX_WIDTH = 1000

local displaywidth = btv.str.displaywidth

-- The display cells `s` takes when it starts at screen column `col` (tabs expand from
-- there). Plain ASCII without a tab is one cell a byte, which skips the per-character
-- walk for the common cell.
local function width(s, col)
  if not s:find("[\t\128-\255]") then
    return #s
  end
  return displaywidth(s, col or 0)
end
M.width = width

-- `s` without the whitespace around it. A scan rather than `^%s*(.-)%s*$`, whose lazy
-- capture rescans a run of inner spaces at every step (quadratic on a long one).
local function trim(s)
  local a = s:find("%S")
  if not a then
    return ""
  end
  local b = #s
  -- `%s`: tab, newline, vertical tab, form feed, carriage return, space. The scan
  -- stops at `a`, a non-space, at the latest.
  local c = s:byte(b)
  while c == 32 or (c >= 9 and c <= 13) do
    b = b - 1
    c = s:byte(b)
  end
  return s:sub(a, b)
end

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

-- `M.row(line[, base])` -> nil | row. Splits a table row into cells. `nil` when the
-- line has no unescaped pipe (so it cannot be a row) or is blank. `base` is the display
-- column `line` starts at (default 0): the width of a block quote's `> ` or a list
-- item's indent cut off before it, so column 1 is measured from the real line start
-- and tabs expand from the column they sit at.
--
-- ```
-- row = {
--   indent  = <the leading whitespace, as written>,
--   lead    = <true when the row opens with a pipe>,
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
-- `lead` is whether the row opens with a pipe (`| a |` as opposed to `a |`).
--
-- `seg` is what the columns are aligned on. For the first cell it runs from the start
-- of the line, `base` included, so a leading pipe and any indentation count toward
-- column 1, and a row written with a leading pipe lines up with one written without.
function M.row(line, base)
  base = base or 0
  if not line:find("%S") then
    return nil
  end
  local ps = pipes(line)
  if #ps == 0 then
    return nil
  end
  local leading = line:find("%S") == ps[1]
  local trailing = not line:find("%S", ps[#ps] + 1)
  local cells = {}
  local prev, from = 0, 1
  if leading then
    prev, from = ps[1], 2
  end
  local seg_from, col = 1, base
  for k = from, #ps do
    local p = ps[k]
    local w = width(line:sub(seg_from, p - 1), col)
    cells[#cells + 1] =
      { s = prev + 1, e = p - 1, close = p, seg = w + (seg_from == 1 and base or 0) }
    col = col + w + 1 -- the pipe
    prev, seg_from = p, p + 1
  end
  if not trailing then
    local w = width(line:sub(seg_from), col)
    cells[#cells + 1] =
      { s = prev + 1, e = #line, close = nil, seg = w + (seg_from == 1 and base or 0) }
  end
  return { indent = line:match("^[ \t]*"), lead = leading, cells = cells }
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
    local text = trim(line:sub(cell.s, cell.e))
    if not text:find("^:?%-+:?$") then
      return nil
    end
    local l, r = text:sub(1, 1) == ":", text:sub(-1) == ":"
    out[i] = (l and r) and "center" or (r and "right" or "left")
  end
  return out
end

local NO_ROW = { indent = "", cells = {} }

-- `M.measure(lines[, opts])` -> measured. Parses one whole table (the header row, the
-- delimiter row, then the body rows) and works out its column widths:
--
-- ```
-- measured = {
--   lines  = lines,
--   rows   = { row, ... },     -- `M.row` of each line (an empty row for a non-row)
--   widths = { <display cells>, ... },  -- each column's widest `seg`
--   aligns = { "left" | "right" | "center", ... },  -- from the delimiter row
--   wide   = <true when the widths add up past `M.MAX_WIDTH`>,
-- }
-- ```
--
-- `opts.base[i]` is the display column line `i` starts at (see `M.row`). `opts.row`,
-- when given, stands in for `M.row` (a caller memoizing rows across edits).
function M.measure(lines, opts)
  local base = opts and opts.base or {}
  local parse = opts and opts.row or M.row
  local rows, widths = {}, {}
  for i, line in ipairs(lines) do
    local row = parse(line, base[i] or 0) or NO_ROW
    rows[i] = row
    for j, cell in ipairs(row.cells) do
      if cell.seg > (widths[j] or 0) then
        widths[j] = cell.seg
      end
    end
  end
  local total = 0
  for _, w in ipairs(widths) do
    total = total + w
  end
  return {
    lines = lines,
    rows = rows,
    widths = widths,
    aligns = M.aligns(rows[2], lines[2] or "") or {},
    wide = total > M.MAX_WIDTH,
  }
end

-- `M.row_pads(measured, i[, opts])` -> the padding line `i` of a measured table needs,
-- in ascending column order:
--
-- ```
-- { { col = <0-based byte col>, n = <display cells>, delimiter = <bool> }, ... }
-- ```
--
-- A cell that falls short of its column gets the difference: before its closing pipe
-- (or before its text, or split around it, for a right- or center-aligned column when
-- `opts.align` is on, the default), and on the delimiter row (line 2) after the cell's
-- last `-`, so `:---:` stays a centered marker and the colons stay at the edges. An
-- open last cell (no trailing pipe) is never padded: nothing follows it to line up.
-- Nothing is padded in a table too wide to align (`measured.wide`).
function M.row_pads(measured, i, opts)
  local out = {}
  if measured.wide then
    return out
  end
  local align = not (opts and opts.align == false)
  local line, widths, aligns = measured.lines[i], measured.widths, measured.aligns
  for j, cell in ipairs(measured.rows[i].cells) do
    local pad = widths[j] - cell.seg
    if pad > 0 and cell.close then
      if i == 2 then
        -- The last `-` of the delimiter cell; the dashes go right after it.
        local last = cell.s - 1
        for b = cell.e, cell.s, -1 do
          if line:byte(b) == 45 then -- `-`
            last = b
            break
          end
        end
        out[#out + 1] = { col = last, n = pad, delimiter = true }
      else
        local how = align and aligns[j] or "left"
        local before = (how == "right" and pad) or (how == "center" and math.floor(pad / 2)) or 0
        if before > 0 then
          out[#out + 1] = { col = cell.s - 1, n = before }
        end
        if pad - before > 0 then
          out[#out + 1] = { col = cell.close - 1, n = pad - before }
        end
      end
    end
  end
  return out
end

-- `M.layout(lines[, opts])` -> pads. Every line's padding as text, for the whole
-- table at once (`M.measure` + `M.row_pads`):
--
-- ```
-- pads[i] = { { col = <0-based byte col>, text = "   ", delimiter = <bool> }, ... }
-- ```
--
-- `opts.fillchars = { pad = " ", delimiter = "-" }` names the glyphs the padding is
-- drawn in (those are the defaults here); each must be one display cell wide, since a
-- pad's width is its glyph count. `opts.align` and `opts.base` are as for
-- `M.row_pads` and `M.measure`.
function M.layout(lines, opts)
  local chars = opts and opts.fillchars or {}
  local pad_char, dash_char = chars.pad or " ", chars.delimiter or "-"
  local measured = M.measure(lines, opts)
  local pads = {}
  for i = 1, #lines do
    local row = M.row_pads(measured, i, opts)
    for _, pad in ipairs(row) do
      pad.text = (pad.delimiter and dash_char or pad_char):rep(pad.n)
    end
    pads[i] = row
  end
  return pads
end

-- `M.shrink(lines)` -> lines. The table written in the least space it takes: each
-- cell's text trimmed and set off from its pipes by one space (an empty cell is one
-- space), and each delimiter cell cut to three characters that keep its alignment,
-- with no spaces around them (`|---|:--|--:|:-:|`), so a one-character column needs
-- no padding. A row keeps its leading whitespace and its outer pipes, or their
-- absence, and no cell is added or dropped. `lines` is one whole table, as for
-- `M.layout`, starting at the table's first column (no block quote or list prefix).
function M.shrink(lines)
  local rows = {}
  for i, line in ipairs(lines) do
    rows[i] = M.row(line)
  end
  local delimiter = M.aligns(rows[2], lines[2] or "") ~= nil
  local out = {}
  for i, line in ipairs(lines) do
    local row = rows[i]
    if not row then
      out[i] = line
    else
      local parts = { row.indent, row.lead and "|" or "" }
      for j, cell in ipairs(row.cells) do
        local text = trim(line:sub(cell.s, cell.e))
        if i == 2 and delimiter then
          local l, r = text:sub(1, 1) == ":", text:sub(-1) == ":"
          text = (l and ":" or "-") .. "-" .. (r and ":" or "-")
        end
        local left = j > 1 or row.lead
        if i == 2 and delimiter then
          parts[#parts + 1] = text -- dashes run pipe to pipe
        elseif text == "" then
          parts[#parts + 1] = " "
        else
          parts[#parts + 1] = (left and " " or "") .. text .. (cell.close and " " or "")
        end
        if cell.close then
          parts[#parts + 1] = "|"
        end
      end
      out[i] = table.concat(parts)
    end
  end
  return out
end

-- `M.expand(lines[, opts])` -> lines | nil, reason. The table written out as the
-- aligned grid the plugin draws, with real spaces and dashes: shrunk first
-- (`M.shrink`), so stray spacing is dropped, then every cell padded to its column's
-- widest. `opts.align` (default true) places the padding by the delimiter row's
-- colons, and `opts.base` gives each line's starting column, as for `M.measure`.
-- `nil` and the reason for a table too wide to align (see `M.MAX_WIDTH`).
function M.expand(lines, opts)
  local shrunk = M.shrink(lines)
  local measured = M.measure(shrunk, { base = opts and opts.base })
  if measured.wide then
    return nil, ("the table is wider than %d display cells"):format(M.MAX_WIDTH)
  end
  local out = {}
  for i, line in ipairs(shrunk) do
    local parts, pos = {}, 0
    for _, pad in ipairs(M.row_pads(measured, i, opts)) do
      parts[#parts + 1] = line:sub(pos + 1, pad.col)
      parts[#parts + 1] = (pad.delimiter and "-" or " "):rep(pad.n)
      pos = pad.col
    end
    parts[#parts + 1] = line:sub(pos + 1)
    out[i] = table.concat(parts)
  end
  return out
end

return M
