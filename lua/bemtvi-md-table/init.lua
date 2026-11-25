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

-- Per-buffer measurements, valid for one `changedtick`, dropped when the buffer is:
--   `{ tick, tables = { [first_row] = { first, last, col, measured } }, rows, prev_rows }`
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

-- The cache entry for `buf`, rebuilt when its text changes. Parsed rows carry over
-- from the entry before (keyed by their text and starting column), so an edit
-- re-parses only the lines it changed; a row neither entry saw is dropped with it.
local function cache_for(buf)
  local tick = btv.buf.changedtick(buf)
  local c = M._cache[buf]
  if not c or c.tick ~= tick then
    c = { tick = tick, tables = {}, rows = {}, prev_rows = c and c.rows or {} }
    M._cache[buf] = c
  end
  return c
end

-- A `layout.row` for the rows of `c`'s buffer, memoized as `cache_for` describes.
local function row_parser(c)
  return function(line, base)
    local key = base .. "\0" .. line
    local row = c.rows[key]
    if row == nil then
      row = c.prev_rows[key]
      if row == nil then
        row = layout.row(line, base) or false
      end
      c.rows[key] = row
    end
    return row or nil
  end
end

-- Whether `prefix`, what comes before the table's start column on row `i` (1-based),
-- is the kind of thing that can: whitespace and block-quote `>`s, and on the first row
-- also the list marker the table follows (`- | a |`, `1. | a |`).
local function prefix_ok(prefix, i)
  if prefix:find("^[%s>]*$") then
    return true
  end
  return i == 1
    and (prefix:find("^[%s>]*[-+*][ \t]+$") or prefix:find("^[%s>]*%d+[.)][ \t]+$")) ~= nil
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

-- Measure one table of `buf` for drawing. Each row is laid out from the table's start
-- column, the prefix before it counted by its width; a row whose prefix isn't one
-- (see `prefix_ok`) is left out of the alignment rather than misread.
local function measure_table(buf, c, tbl)
  local lines = btv.buf.lines(buf, tbl.first, tbl.last + 1)
  local bodies, base = {}, {}
  for i, line in ipairs(lines) do
    local prefix = line:sub(1, tbl.col)
    if #prefix == tbl.col and prefix_ok(prefix, i) then
      bodies[i], base[i] = line:sub(tbl.col + 1), layout.width(prefix)
    else
      bodies[i], base[i] = "", 0
    end
  end
  return layout.measure(bodies, { base = base, row = row_parser(c) })
end

-- `M.marks(buf, top, bot, matches[, fillchars])` -> the marks that align every table
-- touching rows `[top, bot]` of `buf`. `matches` is `ctx.query.matches` for
-- `(pipe_table) @table`: each table node with its full extent, even where it runs past
-- the viewport. `fillchars` defaults to setup's.
--
-- A table is measured whole, once per change to the buffer (and then only the rows
-- that changed are parsed again); its padding is built for the visible rows only.
function M.marks(buf, top, bot, matches, fillchars)
  fillchars = fillchars or M.config.fillchars
  local c = cache_for(buf)
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
          tbl.col + pad.col,
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
-- `layout.expand`), which returns the new bodies or nil and a reason. `col` is the
-- byte column the table starts at on its first row; every row keeps what's before
-- that column (a block quote's `> `, a list item's indent or marker), which must be
-- one (see `prefix_ok`). Returns the new lines, or raises naming the row it can't.
local function rewrite(lines, col, first, transform)
  local prefixes, bodies, base = {}, {}, {}
  for i, line in ipairs(lines) do
    local prefix = line:sub(1, col)
    if #prefix < col or not prefix_ok(prefix, i) then
      error(
        ("row %d doesn't share the table's prefix (its first %d bytes): %q"):format(
          first + i,
          col,
          line
        ),
        0
      )
    end
    prefixes[i], bodies[i], base[i] = prefix, line:sub(col + 1), layout.width(prefix)
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
    local tables = tables_of(buf, res.matches)
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
  return buf, first, last or first
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
