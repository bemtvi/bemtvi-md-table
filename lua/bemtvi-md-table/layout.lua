-- bemtvi-md-table.layout — the pure half of the plugin: parse GFM pipe-table rows and
-- work out the padding that lines a table's columns up. No editor state, no I/O; the
-- provider in `init.lua` finds each table with the treesitter grammar, feeds its lines
-- here and turns the result into marks.
--
-- Columns throughout are BYTE offsets into the line (what an extmark anchors on);
-- widths are DISPLAY cells (`btv.str.displaywidth`), so wide characters line up.

local M = {}

-- A table wider than this many display cells (its columns and pipes summed) is left
-- alone: it can't line up on any screen, and padding it would mean strings as long as
-- its widest cell on every row.
M.MAX_WIDTH = 1000

-- A table of more rows than this is left alone too: lining it up means reading every
-- row again whenever the buffer changes.
M.MAX_ROWS = 20000

-- And one of more cells than this, all rows together: each cell is parsed and kept,
-- and a table of many narrow columns stays under the other two caps.
M.MAX_CELLS = 200000

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

-- The byte offset (1-based) of the first unescaped `|` in `line` at or after `from`,
-- or nil. A pipe preceded by an odd run of backslashes is escaped (`\|` is a literal
-- pipe inside a cell, GFM's one way to put one there — including inside a code span,
-- where an unescaped pipe still splits the cell). Each backslash run is walked once.
local function next_pipe(line, from)
  while true do
    local p = line:find("|", from, true)
    if not p then
      return nil
    end
    local i = p - 1
    while i >= 1 and line:byte(i) == 92 do -- `\`
      i = i - 1
    end
    if (p - 1 - i) % 2 == 0 then
      return p
    end
    from = p + 1
  end
end

-- Whether byte `p` of `line` is an unescaped `|`.
local function is_pipe(line, p)
  return p ~= nil and line:byte(p) == 124 and next_pipe(line, p) == p
end

-- `M.row(line[, base[, limit]])` -> nil | row. Splits a table row into cells. `nil` when the
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
--
-- `tail` is what follows the last pipe when that is only whitespace (as written).
--
-- With `limit`, parsing stops once the row runs past that display column, and the
-- row is `{ wide = true, cells = {} }`: a table holding it is wider than any limit
-- worth aligning, so the rest of it doesn't matter. (Not for rewriting: that row has
-- lost its cells.) A cell is known to run past it before it is measured when it holds
-- more bytes than the cells left could (a character is at most 4 bytes), so one huge
-- cell costs nothing.
function M.row(line, base, limit)
  base = base or 0
  -- Plain ASCII without a tab: a cell's width is its byte count.
  local plain = not line:find("[\t\128-\255]")
  -- The width of `line`'s bytes `a`..`b` starting at screen column `col`, or nil when
  -- that would run past `limit`.
  local function measure(a, b, col)
    local n = b - a + 1
    if limit and n > (plain and 1 or 4) * (limit - col + 1) then
      return nil
    end
    return plain and n or width(line:sub(a, b), col)
  end
  local first_text = line:find("%S")
  if not first_text then
    return nil
  end
  local p = next_pipe(line, 1)
  if not p then
    return nil
  end
  -- The last non-space byte, found from the end (only trailing whitespace is walked).
  local last_text = #line
  local c = line:byte(last_text)
  while c == 32 or (c >= 9 and c <= 13) do
    last_text = last_text - 1
    c = line:byte(last_text)
  end
  local leading = first_text == p
  local trailing = is_pipe(line, last_text)
  local cells = {}
  local prev = 0
  if leading then
    prev, p = p, next_pipe(line, p + 1)
  end
  local seg_from, col = 1, base
  while p do
    local w = (not limit or col <= limit) and measure(seg_from, p - 1, col)
    if not w then
      return { wide = true, indent = "", cells = {} }
    end
    cells[#cells + 1] =
      { s = prev + 1, e = p - 1, close = p, seg = w + (seg_from == 1 and base or 0) }
    col = col + w + 1 -- the pipe
    prev, seg_from = p, p + 1
    p = next_pipe(line, p + 1)
  end
  if not trailing then
    local w = measure(seg_from, #line, col)
    if not w then
      return { wide = true, indent = "", cells = {} }
    end
    cells[#cells + 1] =
      { s = prev + 1, e = #line, close = nil, seg = w + (seg_from == 1 and base or 0) }
  end
  return {
    indent = line:match("^%s*"),
    lead = leading,
    cells = cells,
    tail = trailing and line:sub(last_text + 1) or "",
  }
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

-- Fold one row into column widths: `widths[j]` is the widest `seg` in column `j` and
-- `counts[j]` how many rows reach it. `sign` is 1 to add the row, -1 to take it out;
-- taking out the last row at a column's width leaves its count at 0 (`dirty[j]`).
local function fold(row, widths, counts, sign, dirty)
  for j, cell in ipairs(row.cells) do
    local seg, w = cell.seg, widths[j] or -1
    if sign > 0 then
      if seg > w then
        widths[j], counts[j] = seg, 1
      elseif seg == w then
        counts[j] = counts[j] + 1
      end
    elseif seg == w then
      counts[j] = counts[j] - 1
      if counts[j] == 0 then
        dirty[j] = true
      end
    end
  end
end

-- Finish a measure: the alignments, whether row 2 is a delimiter row at all, and
-- whether the table is too big to align.
local function finish(m, delimiter)
  local rows = m.rows
  local aligns = M.aligns(rows[2], delimiter or "")
  m.aligns, m.delimiter = aligns or {}, delimiter or ""
  -- A table is a header row then a delimiter row; anything else (the grammar handed
  -- over rows that aren't, say) is not padded, so nothing writes dashes into text.
  m.table = aligns ~= nil and rows[1] ~= nil and #rows[1].cells > 0
  local total = 0
  for _, w in ipairs(m.widths) do
    total = total + w + 1 -- and its pipe
  end
  m.wide = m.nwide > 0 or m.ncells > M.MAX_CELLS or #rows > M.MAX_ROWS or total > M.MAX_WIDTH
  return m
end

-- `M.measure_rows(rows, delimiter)` -> measured. The column widths of a table already
-- split into rows: `rows[i]` is `M.row` of line `i` (`false` for a line that isn't
-- one), and `delimiter` is the text of line 2, the delimiter row:
--
-- ```
-- measured = {
--   rows      = { row, ... },
--   widths    = { <display cells>, ... },  -- each column's widest `seg`
--   counts    = { <rows at that width>, ... },
--   aligns    = { "left" | "right" | "center", ... },  -- from the delimiter row
--   delimiter = <line 2's text>,
--   table     = <true when line 1 is a row and line 2 a delimiter row>,
--   ncells    = <cells in all rows>,
--   nwide     = <rows cut off past their limit (see `M.row`)>,
--   wide      = <true when the table is too big to align: its widths and pipes add
--                up past `M.MAX_WIDTH`, a row was cut off past it, or it has more
--                than `M.MAX_ROWS` rows or `M.MAX_CELLS` cells>,
-- }
-- ```
function M.measure_rows(rows, delimiter)
  local m = { rows = rows, widths = {}, counts = {}, ncells = 0, nwide = 0 }
  for i = 1, #rows do
    local row = rows[i] or NO_ROW
    rows[i] = row
    fold(row, m.widths, m.counts, 1)
    m.ncells = m.ncells + #row.cells
    if row.wide then
      m.nwide = m.nwide + 1
    end
  end
  return finish(m, delimiter)
end

-- `M.update(prev, rows, delimiter, gone, came)` -> measured. `prev` re-measured for an
-- edit, without walking every row again: `rows` is the new table (as for
-- `M.measure_rows`), `gone` the rows of `prev` the edit replaced and `came` the rows
-- that replaced them (both also in `rows`). Only a column whose widest cell went is
-- scanned again. `prev` is left as it was.
function M.update(prev, rows, delimiter, gone, came)
  local m = {
    rows = rows,
    widths = table.move(prev.widths, 1, #prev.widths, 1, {}),
    counts = table.move(prev.counts, 1, #prev.counts, 1, {}),
    ncells = prev.ncells,
    nwide = prev.nwide,
  }
  local dirty = {}
  for _, row in ipairs(gone) do
    fold(row, m.widths, m.counts, -1, dirty)
    m.ncells = m.ncells - #row.cells
    m.nwide = m.nwide - (row.wide and 1 or 0)
  end
  for i, row in ipairs(came) do
    row = row or NO_ROW
    came[i] = row
    fold(row, m.widths, m.counts, 1)
    m.ncells = m.ncells + #row.cells
    m.nwide = m.nwide + (row.wide and 1 or 0)
  end
  for i = 1, #rows do
    rows[i] = rows[i] or NO_ROW
  end
  local ncols = #prev.widths
  for _, row in ipairs(came) do
    ncols = math.max(ncols, #row.cells)
  end
  for j in pairs(dirty) do
    if m.counts[j] == 0 then
      local w, n = nil, 0
      for _, row in ipairs(rows) do
        local cell = row.cells[j]
        if cell then
          if not w or cell.seg > w then
            w, n = cell.seg, 1
          elseif cell.seg == w then
            n = n + 1
          end
        end
      end
      m.widths[j], m.counts[j] = w, n
    end
  end
  -- A column no row reaches any more ends the widths there. (Cells run from column 1
  -- up, so only the last columns can lose every cell.)
  for j = ncols, 1, -1 do
    if m.widths[j] ~= nil then
      break
    end
    m.counts[j] = nil
  end
  return finish(m, delimiter)
end

-- `M.measure(lines[, opts])` -> measured. Parses one whole table (the header row, the
-- delimiter row, then the body rows) and works out its column widths, as
-- `M.measure_rows`. `opts.base[i]` is the display column line `i` starts at, and
-- `opts.limit` how far past it a row is parsed (see `M.row`).
function M.measure(lines, opts)
  local base = opts and opts.base or {}
  local limit = opts and opts.limit
  local rows = {}
  for i, line in ipairs(lines) do
    local b = base[i] or 0
    rows[i] = M.row(line, b, limit and b + limit) or false
  end
  return M.measure_rows(rows, lines[2])
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
-- Nothing is padded in a table too big to align (`measured.wide`), or in one whose
-- first two lines aren't a header and a delimiter row (`measured.table`).
--
-- `opts.text_first` keeps the first cell of a row without a leading pipe padded on the
-- right whatever its column's alignment: padding written before its text would read
-- as indentation (and four spaces of it make the table an indented code block).
function M.row_pads(measured, i, opts)
  local out = {}
  if measured.wide or not measured.table then
    return out
  end
  local align = not (opts and opts.align == false)
  local widths, aligns = measured.widths, measured.aligns
  for j, cell in ipairs(measured.rows[i].cells) do
    local pad = widths[j] - cell.seg
    if pad > 0 and cell.close then
      if i == 2 then
        -- The last `-` of the delimiter cell; the dashes go right after it.
        local last = cell.s - 1
        for b = cell.e, cell.s, -1 do
          if measured.delimiter:byte(b) == 45 then -- `-`
            last = b
            break
          end
        end
        out[#out + 1] = { col = last, n = pad, delimiter = true }
      else
        local how = align and aligns[j] or "left"
        if j == 1 and not measured.rows[i].lead and opts and opts.text_first then
          how = "left"
        end
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
-- `nil` and the reason when `lines` doesn't start with a header row and a delimiter
-- row, or holds more than `M.MAX_ROWS` rows: nothing is rewritten that isn't a table.
function M.shrink(lines)
  if #lines > M.MAX_ROWS then
    return nil, ("the table is longer than %d rows"):format(M.MAX_ROWS)
  end
  local rows = {}
  for i, line in ipairs(lines) do
    rows[i] = M.row(line)
  end
  local delimiter = M.aligns(rows[2], lines[2] or "") ~= nil
  if not (delimiter and rows[1] and #rows[1].cells > 0) then
    return nil, "its first two lines aren't a header row and a delimiter row"
  end
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
      -- Spaces and tabs after the last pipe go; anything else there (a stray `\r`)
      -- is kept, since it may not be padding.
      parts[#parts + 1] = (row.tail:gsub("[ \t]", ""))
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
-- `nil` and the reason for what `M.shrink` refuses, a table too big to align (see
-- `M.MAX_WIDTH` and `M.MAX_CELLS`), or one with a tab in a cell: padding written before a tab moves it to another tab stop and
-- changes its width, so no padding lines it up for good.
--
-- The first cell of a row without a leading pipe is padded on the right whatever its
-- column's alignment (see `opts.text_first` on `M.row_pads`).
function M.expand(lines, opts)
  local shrunk, why = M.shrink(lines)
  if not shrunk then
    return nil, why
  end
  for _, line in ipairs(shrunk) do
    -- (A tab in the leading whitespace sits before any padding, so it never moves.)
    if line:find("\t", #line:match("^%s*") + 1, true) then
      return nil, "a cell holds a tab, which padding would move; replace it with spaces"
    end
  end
  local measured = M.measure(shrunk, { base = opts and opts.base, limit = M.MAX_WIDTH })
  if measured.wide then
    return nil,
      ("the table is wider than %d display cells or holds more than %d cells"):format(
        M.MAX_WIDTH,
        M.MAX_CELLS
      )
  end
  local pad_opts = { align = not (opts and opts.align == false), text_first = true }
  local out = {}
  for i, line in ipairs(shrunk) do
    local parts, pos = {}, 0
    for _, pad in ipairs(M.row_pads(measured, i, pad_opts)) do
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
