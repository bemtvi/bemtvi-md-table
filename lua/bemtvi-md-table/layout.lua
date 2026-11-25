-- bemtvi-md-table.layout — the pure half of the plugin: parse GFM pipe-table rows and
-- work out the padding that lines a table's columns up. No editor state, no I/O; the
-- provider in `init.lua` finds each table with the treesitter grammar, feeds its lines
-- here and turns the result into marks.
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
  return { indent = #(line:match("^%s*")), lead = leading, cells = cells }
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
-- `opts.fillchars = { pad = " ", delimiter = "-" }` names the glyphs the padding is
-- drawn in (those are the defaults here); each must be one display cell wide, since a
-- pad's width is its glyph count.
--
-- An open last cell (a row with no trailing pipe) still counts toward its column's
-- width but is never padded: nothing follows it to line up.
function M.layout(lines, opts)
  local align = not (opts and opts.align == false)
  local chars = opts and opts.fillchars or {}
  local pad_char, dash_char = chars.pad or " ", chars.delimiter or "-"
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
          out[#out + 1] = { col = last, text = dash_char:rep(pad), delimiter = true }
        else
          local how = align and aligns[j] or "left"
          local before = (how == "right" and pad) or (how == "center" and math.floor(pad / 2)) or 0
          if before > 0 then
            out[#out + 1] = { col = cell.s - 1, text = pad_char:rep(before) }
          end
          if pad - before > 0 then
            out[#out + 1] = { col = cell.close - 1, text = pad_char:rep(pad - before) }
          end
        end
      end
    end
    pads[i] = out
  end
  return pads
end

-- Strip the whitespace around a cell's text.
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- `M.shrink(lines)` -> lines. The table written in the least space it takes: each
-- cell's text trimmed and set off from its pipes by one space (an empty cell is one
-- space), and each delimiter cell cut to three characters that keep its alignment,
-- with no spaces around them (`|---|:--|--:|:-:|`), so a one-character column needs
-- no padding. A row keeps its outer pipes, or their absence, and no
-- cell is added or dropped. `lines` is one whole table, as for `M.layout`, starting
-- at the table's first column (no block quote or list prefix).
function M.shrink(lines)
  local rows = {}
  for i, line in ipairs(lines) do
    rows[i] = M.row(line)
  end
  local delimiter = M.aligns(rows[2], lines[2]) ~= nil
  local out = {}
  for i, line in ipairs(lines) do
    local row = rows[i]
    if not row then
      out[i] = line
    else
      local parts = { row.lead and "|" or "" }
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

-- `M.expand(lines[, opts])` -> lines. The table written out as the aligned grid the
-- plugin draws, with real spaces and dashes: shrunk first (`M.shrink`), so stray
-- spacing is dropped, then every cell padded to its column's widest. `opts.align`
-- (default true) places the padding by the delimiter row's colons, as in `M.layout`.
function M.expand(lines, opts)
  local shrunk = M.shrink(lines)
  local pads = M.layout(shrunk, {
    align = not (opts and opts.align == false),
    fillchars = { pad = " ", delimiter = "-" },
  })
  local out = {}
  for i, line in ipairs(shrunk) do
    local row = pads[i]
    table.sort(row, function(a, b)
      return a.col > b.col
    end)
    for _, pad in ipairs(row) do
      line = line:sub(1, pad.col) .. pad.text .. line:sub(pad.col + 1)
    end
    out[i] = line
  end
  return out
end

return M
