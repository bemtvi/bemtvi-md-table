-- bemtvi-md-table — line up the columns of markdown pipe tables, without touching the
-- text. Built entirely on the native `btv.*` plugin API.
--
-- A `btv.decor` provider runs whenever a markdown window's viewport changes (scroll,
-- resize, an edit). For every table on screen it measures each column's widest cell
-- and draws the shortfall of every other cell as INLINE virtual text — spaces in the
-- cells, dashes in the delimiter row — so
--
-- ```
-- | Queue | Upstream | Applied by |
-- |---|---|---|
-- | a | b | c |
-- ```
--
-- reads as an aligned grid while the buffer still holds exactly what you typed. Save
-- it and the file is unchanged; the padding exists only on screen, and it looks it:
-- the added spaces are drawn as a faint `·` and the added dashes as a faint `-`, like
-- the separator itself (the fill chars below and the `MdTablePad` / `MdTableDelimiter`
-- groups restyle them).
--
-- Where the tables are comes from the markdown treesitter grammar: the provider asks
-- for `(pipe_table) @table` over the visible rows, and a table crossing the edge of the
-- screen comes back whole, so its columns agree past it. The grammar already knows a
-- table inside a code fence or an indented code block is not one, and finds the ones
-- in list items and block quotes. Without a markdown grammar nothing is drawn
-- (`:TSInstall markdown`).
--
-- The work is bounded by what is visible: only tables that touch the viewport are
-- measured (a table is read in full), and each table's layout is cached until the
-- buffer next changes.
--
-- Toggles (read on every run; `:MdTableToggle` flips the buffer one and repaints):
--   * `btv.g.md_table_align = false` turns it off globally (default: on).
--   * `btv.b[bufnr].md_table_align = false` turns it off for one buffer; a buffer's
--     explicit value (true/false) overrides the global one.
--
-- Fill chars, global-local like the core's `'fillchars'` and `'listchars'`: a
-- `"pad:·,delimiter:-"` key:char list (or the table `{ pad = "·", delimiter = "-" }`),
-- where a key left out keeps its default. `setup({ fillchars = ... })` sets the base,
-- `btv.g.md_table_fillchars` overrides it, and `btv.b[bufnr].md_table_fillchars` the
-- global one, all read on every run.

local layout = require("bemtvi-md-table.layout")

local M = {}

local PROVIDER = "bemtvi-md-table"
local DEFAULTS = {
  filetypes = { "markdown" },
  align = true,
  fillchars = { pad = "·", delimiter = "-" },
}

-- The live configuration (`setup` replaces it).
M.config =
  { filetypes = DEFAULTS.filetypes, align = DEFAULTS.align, fillchars = DEFAULTS.fillchars }

-- The last fill-chars error reported per buffer, so a bad variable is reported once,
-- not on every repaint.
M._fill_errors = {}

-- Per-buffer measurements, dropped when the buffer is: the tables measured at `tick`,
-- and those of the tick before, whose parsed rows the next measure reuses:
--   `{ tick, tables = { [first_row] = { first, last, col, lines, offs, measured } }, prev }`
M._cache = {}

-- The query the provider asks the parse tree.
local QUERY = "(pipe_table) @table"

-- ----- toggles ----------------------------------------------------------------

-- `M.enabled(bufnr)` -> whether tables are aligned in `bufnr` (0 = current). The
-- buffer's explicit `btv.b[bufnr].md_table_align` wins over `btv.g.md_table_align`;
-- both unset means on.
function M.enabled(bufnr)
  local b = btv.b[bufnr == 0 and btv.buf.current() or bufnr].md_table_align
  if b ~= nil then
    return b ~= false
  end
  return btv.g.md_table_align ~= false
end

-- `M.refresh([bufnr])` — repaint now, after a toggle or a config change. With no
-- argument every visible window is re-run.
function M.refresh(bufnr)
  if bufnr then
    btv.decor.invalidate({ buf = bufnr })
  else
    btv.decor.invalidate()
  end
end

-- `M.toggle([bufnr])` — flip alignment for one buffer (default: the current one) and
-- repaint it. Returns the new state.
function M.toggle(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and btv.buf.current() or bufnr
  local on = not M.enabled(bufnr)
  btv.b[bufnr].md_table_align = on
  M.refresh(bufnr)
  return on
end

-- ----- fill chars -------------------------------------------------------------

-- One fill char: a string one display cell wide, since a pad's width is its glyph
-- count. Returns the reason it isn't, or nil.
local function bad_char(key, c)
  if type(c) ~= "string" or btv.str.displaywidth(c) ~= 1 then
    return "'" .. key .. "' must be one display cell wide"
  end
end

-- `parse_fillchars(value)` -> fillchars | nil, reason. `value` is a key:char list
-- (`"pad:·,delimiter:-"`, read like `'fillchars'`: the char is the one character after
-- the colon, so a `,` or `:` is a fill char too) or a table of the same keys; keys left
-- out keep their defaults.
local function parse_fillchars(value)
  local out = { pad = DEFAULTS.fillchars.pad, delimiter = DEFAULTS.fillchars.delimiter }
  if type(value) == "table" then
    for k, c in pairs(value) do
      if out[k] == nil then
        return nil, "unknown key '" .. tostring(k) .. "'"
      end
      local why = bad_char(k, c)
      if why then
        return nil, why
      end
      out[k] = c
    end
    return out
  end
  if type(value) ~= "string" then
    return nil, "expects a key:char list or a table, got " .. type(value)
  end
  local i = 1
  while i <= #value do
    local key = value:match("^(%a+):", i)
    if not key then
      return nil, "expected key:char at '" .. value:sub(i) .. "'"
    end
    if out[key] == nil then
      return nil, "unknown key '" .. key .. "'"
    end
    i = i + #key + 1
    local c = value:match("^" .. utf8.charpattern, i)
    if not c then
      return nil, "no char after '" .. key .. ":'"
    end
    local why = bad_char(key, c)
    if why then
      return nil, why
    end
    out[key] = c
    i = i + #c
    if i <= #value then
      if value:sub(i, i) ~= "," then
        return nil, "'" .. key .. "' takes one char, got more at '" .. value:sub(i) .. "'"
      end
      i = i + 1
      if i > #value then
        return nil, "trailing comma"
      end
    end
  end
  return out
end

-- `M.fillchars(bufnr)` -> fillchars | nil, error. The fill chars in effect for `bufnr`
-- (0 = current): `btv.b[bufnr].md_table_fillchars`, else `btv.g.md_table_fillchars`,
-- else setup's. An invalid variable gives nil and an `E474` message naming it.
function M.fillchars(bufnr)
  bufnr = bufnr == 0 and btv.buf.current() or bufnr
  local scope, value = "b", btv.b[bufnr].md_table_fillchars
  if value == nil then
    scope, value = "g", btv.g.md_table_fillchars
  end
  if value == nil then
    return M.config.fillchars
  end
  local fc, why = parse_fillchars(value)
  if not fc then
    local shown = type(value) == "string" and value or btv.inspect(value)
    return nil, ("E474: Invalid argument: %s:md_table_fillchars=%s (%s)"):format(scope, shown, why)
  end
  return fc
end

-- ----- analysis ---------------------------------------------------------------

-- The cache entry for `buf`. `tables` holds what was measured at `tick`; on a change
-- they join `prev`, where a later measure of each finds the rows the edit left alone
-- (see `measure_table`). `prev` keeps older measures too, so a big table scrolled
-- away from while editing elsewhere is still found, up to a budget of cells: past it
-- the measures used longest ago go.
local function cache_for(buf, tabstop)
  local tick = btv.buf.changedtick(buf)
  local c = M._cache[buf]
  -- A tab's width follows `'tabstop'`, so a change to it re-measures from scratch.
  if not c or c.tabstop ~= tabstop then
    c = { tick = tick, tabstop = tabstop, tables = {}, prev = {}, clock = 0 }
    M._cache[buf] = c
  elseif c.tick ~= tick then
    -- Only what a later measure can reuse: a table measured whole, or one found too big
    -- with the rows it was read from (see `too_big`).
    for first, tbl in pairs(c.tables) do
      if tbl.complete or tbl.too_big then
        c.prev[first] = tbl
      end
    end
    local list = {}
    for first, tbl in pairs(c.prev) do
      -- A too-big table keeps its rows rather than its cells: they are its cost.
      local cost = tbl.too_big and #tbl.lines or tbl.measured.ncells
      list[#list + 1] = { first = first, stamp = tbl.stamp, cells = cost }
    end
    table.sort(list, function(x, y)
      return x.stamp > y.stamp
    end)
    local budget = 2 * layout.MAX_CELLS
    for i, e in ipairs(list) do
      budget = budget - e.cells
      if budget < 0 and i > 1 then
        c.prev[e.first] = nil
      end
    end
    c.tick, c.tables = tick, {}
  end
  return c
end

-- What comes before the table on each of its rows: the container markup a block
-- quote or list puts there. The grammar says where the table starts on its first row
-- (`col`, after a list marker or `> ` there); on the rows after it, the prefix is the
-- run of block-quote `>`s and whitespace the row opens with, which can be written
-- differently from row to row (`> ` then a lazy `>`, a tab for a list's indent).
local function prefix_len(line, i, col)
  if i == 1 then
    return math.min(col, #line)
  end
  return #line:match("^[ \t>]*")
end

-- The rows (0-based, inclusive) a captured node covers. A node can end at the start
-- of the line after its last row: at column 0, or inside the next row's block-quote
-- `>`s. That row isn't part of the table.
local function node_rows(buf, node)
  local first, last = node[1], node[3]
  if last > first then
    local text = btv.buf.lines(buf, last, last + 1)[1]
    if node[4] == 0 or not text or text:sub(1, node[4]):find("^[%s>]*$") then
      last = last - 1
    end
  end
  return first, last
end

-- The tables a query answered, as `{ first, last, col }`: rows (0-based, inclusive)
-- and the byte column the table starts at.
local function tables_of(buf, matches)
  local out = {}
  for _, m in ipairs(matches) do
    for _, node in ipairs(m.captures.table or {}) do
      local first, last = node_rows(buf, node)
      out[#out + 1] = { first = first, last = last, col = node[2] }
    end
  end
  return out
end

-- A row too wide to align, for a row whose prefix alone is past the width limit.
local WIDE_ROW = { wide = true, indent = "", cells = {} }

-- What a table too big to align measures as. With the `lines` it was read from kept, an
-- edit elsewhere finds the same rows and reuses the verdict instead of reading the
-- table again up to where it gave up (a too-big table on screen would otherwise cost
-- that on every keystroke). Nothing else of it is kept.
local function too_big(t, lines)
  t.lines, t.offs, t.complete, t.too_big = lines or {}, {}, false, lines ~= nil
  return {
    rows = {},
    widths = {},
    counts = {},
    aligns = {},
    delimiter = "",
    table = false,
    ncells = 0,
    nwide = 1,
    wide = true,
  }
end

-- The earlier measure that `t` most likely is now, given its `header` line: the one
-- that started on the same row, else one with the same header line (lines added or
-- removed above it moved it), else the nearest. `measure_table` checks the rows
-- themselves, so a wrong guess only costs a full parse.
local function previous(c, t, header)
  local same = c.prev[t.first]
  if same and same.col == t.col then
    return same
  end
  local best, dist = nil, math.huge
  for first, p in pairs(c.prev) do
    if p.col == t.col and (p.complete or p.too_big) then
      local d = math.abs(first - t.first) + (p.lines[1] == header and 0 or 1e9)
      if d < dist then
        best, dist = p, d
      end
    end
  end
  return best
end

-- Measure one table of `buf` for drawing. Each row is laid out from where the table
-- starts on it (see `prefix_len`), the prefix before it counted by its width.
--
-- A buffer line the edit didn't touch is the very same string as before, so the rows
-- matching an earlier measure's from either end (`==` on those is a pointer check)
-- keep their parse, and only the rows in between are parsed again; the column widths
-- are updated from those rows alone (`layout.update`). The table an edit was made in
-- costs the changed rows, and a table next to the edit, none. Row 1 is never taken
-- from the other end, since its prefix is read differently.
--
-- Parsing stops as soon as the table is known to be too big to align.
local function measure_table(buf, c, t)
  c.clock = c.clock + 1
  t.stamp = c.clock
  if t.last - t.first + 1 > layout.MAX_ROWS then
    return too_big(t)
  end
  local lines = btv.buf.lines(buf, t.first, t.last + 1)
  local n, rows, offs = #lines, {}, {}
  local head, tail = 0, 0
  local prev = previous(c, t, lines[1])
  -- The same rows as a table already found too big: the same verdict, without a read.
  if prev and prev.too_big and prev.col == t.col and #prev.lines == n then
    local same = true
    for i = 1, n do
      if lines[i] ~= prev.lines[i] then
        same = false
        break
      end
    end
    if same then
      return too_big(t, lines)
    end
  end
  if prev and prev.complete then
    local pl, pn = prev.lines, #prev.lines
    while head < n and head < pn and lines[head + 1] == pl[head + 1] do
      head = head + 1
      rows[head], offs[head] = prev.measured.rows[head], prev.offs[head]
    end
    while
      n - tail > math.max(head, 1)
      and pn - tail > math.max(head, 1)
      and lines[n - tail] == pl[pn - tail]
    do
      rows[n - tail], offs[n - tail] = prev.measured.rows[pn - tail], prev.offs[pn - tail]
      tail = tail + 1
    end
  end
  local came, cells = {}, 0
  for i = head + 1, n - tail do
    local line = lines[i]
    local p = prefix_len(line, i, t.col)
    local row
    -- A body row may be written without any pipe (`lone`).
    if p == 0 then
      row = layout.row(line, 0, layout.MAX_WIDTH, i > 2)
    elseif p > layout.MAX_WIDTH then
      row = WIDE_ROW -- (each byte of a prefix is at least one cell)
    else
      local base = layout.width(line:sub(1, p))
      row = layout.row(line:sub(p + 1), base, base + layout.MAX_WIDTH, i > 2)
    end
    if row and row.wide then
      return too_big(t, lines)
    end
    cells = cells + (row and #row.cells or 0)
    if cells > layout.MAX_CELLS then
      return too_big(t, lines)
    end
    rows[i], offs[i] = row or false, p
    came[#came + 1] = row or false
  end
  t.lines, t.offs, t.complete = lines, offs, true
  local delimiter = lines[2] and lines[2]:sub((offs[2] or 0) + 1)
  if prev and prev.complete and head + tail > 0 then
    local gone = table.move(prev.measured.rows, head + 1, #prev.lines - tail, 1, {})
    return layout.update(prev.measured, rows, delimiter, gone, came)
  end
  return layout.measure_rows(rows, delimiter)
end

-- `M.marks(buf, top, bot, matches[, fillchars])` -> the marks that align every table
-- touching rows `[top, bot]` of `buf`. `matches` is `ctx.query.matches` for
-- `(pipe_table) @table`: each table node with its full extent, even where it runs past
-- the viewport. `fillchars` defaults to setup's.
--
-- A table is measured once per change to the buffer, parsing only the rows that
-- changed (see `measure_table`); its padding is built for the visible rows only.
function M.marks(buf, top, bot, matches, fillchars)
  fillchars = fillchars or M.config.fillchars
  local tabstop = btv.bo[buf].tabstop
  layout.tabstop = tabstop
  local c = cache_for(buf, tabstop)
  local opts = { align = M.config.align }
  local marks = {}
  for _, t in ipairs(tables_of(buf, matches)) do
    local tbl = c.tables[t.first]
    if not tbl or tbl.last ~= t.last or tbl.col ~= t.col then
      tbl = t
      tbl.measured = measure_table(buf, c, t)
      c.tables[t.first] = tbl
    end
    for row = math.max(top, tbl.first), math.min(bot, tbl.last) do
      for _, pad in ipairs(layout.row_pads(tbl.measured, row - tbl.first + 1, opts)) do
        local text = (pad.delimiter and fillchars.delimiter or fillchars.pad):rep(pad.n)
        marks[#marks + 1] = {
          row,
          tbl.offs[row - tbl.first + 1] + pad.col,
          virt_text = { { text, pad.delimiter and "MdTableDelimiter" or "MdTablePad" } },
          virt_text_pos = "inline",
        }
      end
    end
  end
  return marks
end

-- ----- rewriting --------------------------------------------------------------

-- Rewrite one table's lines with `transform(bodies, base)` (`layout.shrink` /
-- `layout.expand`), which returns the new bodies or nil and a reason. Each row keeps
-- what comes before the table on it (see `prefix_len`) exactly as written. Returns
-- the new lines, or raises naming the table it can't rewrite.
local function rewrite(lines, col, first, transform)
  local prefixes, bodies, base = {}, {}, {}
  for i, line in ipairs(lines) do
    local n = prefix_len(line, i, col)
    prefixes[i], bodies[i] = line:sub(1, n), line:sub(n + 1)
    base[i] = layout.width(prefixes[i])
  end
  local out, why = transform(bodies, base)
  if not out then
    error(("the table on line %d: %s"):format(first + 1, why), 0)
  end
  for i, body in ipairs(out) do
    out[i] = prefixes[i] .. body
  end
  return out
end

-- Reformat every table touching the 0-based rows `[first, last]` of `buf` with
-- `transform`. Resolves with the number of tables whose text changed; rejects when
-- there is no table there, or no answer from the grammar. All or nothing: every table
-- is rewritten before any edit is made, so one that can't be leaves the buffer alone.
local function reformat(name, transform, buf, first, last)
  local tick = btv.buf.changedtick(buf)
  return btv.treesitter.query(buf, QUERY, { rows = { first, last + 1 } }):next(function(res)
    if res.tick ~= tick or btv.buf.changedtick(buf) ~= tick then
      error(name .. ": the buffer changed while its tables were being found; run it again", 0)
    end
    -- The query counts a table as touching a row its node merely ends in (the `>` of
    -- the line after a block-quoted table); only tables whose rows meet the range count.
    local tables = {}
    for _, tbl in ipairs(tables_of(buf, res.matches)) do
      if tbl.first <= last and tbl.last >= first then
        tables[#tables + 1] = tbl
      end
    end
    if #tables == 0 then
      if first == last then
        error(name .. ": no markdown table on line " .. (first + 1), 0)
      end
      error(("%s: no markdown table in lines %d-%d"):format(name, first + 1, last + 1), 0)
    end
    -- Bottom-up, so an edit never moves the rows of a table still to come.
    table.sort(tables, function(x, y)
      return x.first > y.first
    end)
    layout.tabstop = btv.bo[buf].tabstop
    local edits = {}
    for _, tbl in ipairs(tables) do
      local lines = btv.buf.lines(buf, tbl.first, tbl.last + 1)
      local ok, out = pcall(rewrite, lines, tbl.col, tbl.first, transform)
      if not ok then
        error(name .. ": " .. out, 0)
      end
      for i = 1, #lines do
        if lines[i] ~= out[i] then
          edits[#edits + 1] = { tbl.first, tbl.last + 1, out }
          break
        end
      end
    end
    if #edits > 0 and btv.bo[buf].modifiable == false then
      error(name .. ": E21: Cannot make changes, 'modifiable' is off", 0)
    end
    for _, e in ipairs(edits) do
      btv.buf.set_lines(buf, e[1], e[2], true, e[3])
    end
    return #edits
  end)
end

-- The buffer and rows a `shrink` / `expand` call names: `bufnr` (default the current
-- buffer) and rows `first`..`last`, which default to the cursor's row in the current
-- buffer. Another buffer has no cursor to default to, so it needs `first`.
local function target(name, bufnr, first, last)
  local buf = (bufnr == nil or bufnr == 0) and btv.buf.current() or bufnr
  if first == nil then
    if buf ~= btv.buf.current() then
      error(name .. ": give the rows to rewrite in a buffer other than the current one", 3)
    end
    first = btv.cursor.get()[1] - 1
  end
  last = last or first
  if last < first then
    first, last = last, first
  end
  return buf, first, last
end

-- `M.shrink([bufnr[, first, last]])` -> promise of the number of tables changed. Writes
-- every table touching the 0-based rows `[first, last]` of `bufnr` (default: the
-- current buffer, at the cursor) in the least space it takes: one space between each
-- cell's text and its pipes, three-character delimiter cells (`---`, `:--`, `--:`,
-- `:-:`). Rejects when there is no table there.
function M.shrink(bufnr, first, last)
  local buf, a, b = target("MdTableShrink", bufnr, first, last)
  return reformat("MdTableShrink", layout.shrink, buf, a, b)
end

-- `M.expand([bufnr[, first, last]])` -> promise of the number of tables changed. Writes
-- every table touching the 0-based rows `[first, last]` of `bufnr` (default: the
-- current buffer, at the cursor) as the aligned grid the plugin draws, with real
-- spaces and dashes: stray spacing dropped, then each cell padded to its column's
-- widest, by the column's alignment when `setup`'s `align` is on. Rejects when there
-- is no table there, or a table is too wide to align.
function M.expand(bufnr, first, last)
  local buf, a, b = target("MdTableExpand", bufnr, first, last)
  return reformat("MdTableExpand", function(bodies, base)
    return layout.expand(bodies, { align = M.config.align, base = base })
  end, buf, a, b)
end

-- ----- setup ------------------------------------------------------------------

-- The highlight groups the padding draws in, dimmed like other glyphs that aren't
-- text (`NonText`). Both are `default` links, so a colorscheme (or the user) can
-- restyle them; they are re-linked after a colorscheme loads, since loading one clears
-- groups it does not define.
local function define_highlights()
  btv.hl.define(0, "MdTablePad", { link = "NonText", default = true })
  btv.hl.define(0, "MdTableDelimiter", { link = "NonText", default = true })
end

-- `M.setup(opts)` — (re)configure and (re)register the provider. Called with `{}` by
-- `plugin/bemtvi-md-table.lua`, so it is on out of the box; calling it again from a
-- config just re-applies.
--
-- ```lua
-- require("bemtvi-md-table").setup({
--   filetypes = { "markdown" },  -- the filetypes whose tables are aligned
--   align = true,                -- honor `:---:` / `---:` in the cells; false pads
--                                -- every cell on the right
--   fillchars = "pad:·,delimiter:-",  -- the glyphs the padding is drawn in, one
--                                -- display cell each, as a key:char list or a table;
--                                -- "pad: " draws the spaces as plain spaces
-- })
-- ```
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("bemtvi-md-table.setup: expects a table", 2)
  end
  for k in pairs(opts) do
    if DEFAULTS[k] == nil then
      error("bemtvi-md-table.setup: unknown option '" .. tostring(k) .. "'", 2)
    end
  end
  local fts = opts.filetypes or DEFAULTS.filetypes
  if type(fts) == "string" then
    fts = { fts }
  end
  local base_fill = DEFAULTS.fillchars
  if opts.fillchars ~= nil then
    local why
    base_fill, why = parse_fillchars(opts.fillchars)
    if not base_fill then
      error("bemtvi-md-table.setup: fillchars: " .. why, 2)
    end
  end
  M.config = { filetypes = fts, align = opts.align ~= false, fillchars = base_fill }
  M._fill_errors = {}
  M._cache = {}

  define_highlights()
  local group = btv.augroup.create("bemtvi-md-table")
  btv.on("ColorScheme", { group = group }, define_highlights)
  btv.on("BufDelete", { group = group }, function(ev)
    M._cache[ev.buf] = nil
    M._fill_errors[ev.buf] = nil
  end)

  btv.decor.provider({
    name = PROVIDER,
    bufs = { filetype = fts },
    query = QUERY,
    on_range = function(ctx, publish)
      if not M.enabled(ctx.buf) then
        publish({})
        return
      end
      local q = ctx.query
      if q.pending then
        return -- the grammar is loading or a big file's parse is unfinished: keep what's drawn
      end
      if not q.matches then
        publish({}) -- no markdown grammar, or treesitter is off here: no tables to align
        return
      end
      local fill, err = M.fillchars(ctx.buf)
      if not fill then
        if M._fill_errors[ctx.buf] ~= err then
          M._fill_errors[ctx.buf] = err
          btv.notify(err, btv.log.levels.ERROR)
        end
        publish({})
        return
      end
      M._fill_errors[ctx.buf] = nil
      publish(M.marks(ctx.buf, ctx.top, ctx.bot, q.matches, fill))
    end,
  })

  btv.command("MdTableToggle", function()
    local on = M.toggle(0)
    btv.notify("markdown table alignment " .. (on and "on" or "off"))
  end, { desc = "Toggle markdown table alignment in this buffer" })

  -- `:[range]MdTableShrink` / `:[range]MdTableExpand`: the table under the cursor, or
  -- every table the range touches.
  local function rewrite_command(fn)
    return function(o)
      fn(0, o.line1 - 1, o.line2 - 1):next(function(n)
        if n == 0 then
          btv.notify("markdown table already formatted")
        end
      end, function(err)
        btv.notify(tostring(err), btv.log.levels.ERROR)
      end)
    end
  end
  btv.command("MdTableShrink", rewrite_command(M.shrink), {
    desc = "Rewrite the markdown table at the cursor (or in the range) in the least space",
  })
  btv.command("MdTableExpand", rewrite_command(M.expand), {
    desc = "Rewrite the markdown table at the cursor (or in the range) padded into a grid",
  })

  M.refresh()
end

return M
