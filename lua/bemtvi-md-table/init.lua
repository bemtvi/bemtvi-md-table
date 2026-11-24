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

-- Per-buffer layouts, valid for one `changedtick` and one set of fill chars:
--   `{ tick, fill, tables = { [first_row] = { first, last, pads } } }`
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

-- The cache entry for `buf`, reset when the buffer or the fill chars have changed
-- since it was built.
local function cache_for(buf, fill)
  local tick = btv.buf.changedtick(buf)
  local key = fill.pad .. "\0" .. fill.delimiter
  local c = M._cache[buf]
  if not c or c.tick ~= tick or c.fill ~= key then
    c = { tick = tick, fill = key, tables = {} }
    M._cache[buf] = c
  end
  return c
end

-- The rows (0-based, inclusive) a captured node covers. A node ending at column 0
-- stops before that row: it ends with the previous line's newline.
local function node_rows(node)
  local last = node[3]
  if node[4] == 0 and last > node[1] then
    last = last - 1
  end
  return node[1], last
end

-- `M.marks(buf, top, bot, matches[, fillchars])` -> the marks that align every table
-- touching rows `[top, bot]` of `buf`. `matches` is `ctx.query.matches` for
-- `(pipe_table) @table`: each table node with its full extent, even where it runs past
-- the viewport. `fillchars` defaults to setup's.
function M.marks(buf, top, bot, matches, fillchars)
  fillchars = fillchars or M.config.fillchars
  local c = cache_for(buf, fillchars)
  local marks = {}
  for _, m in ipairs(matches) do
    for _, node in ipairs(m.captures.table or {}) do
      local first, last = node_rows(node)
      local tbl = c.tables[first]
      if not tbl or tbl.last ~= last then
        tbl = {
          first = first,
          last = last,
          pads = layout.layout(
            btv.buf.lines(buf, first, last + 1),
            { align = M.config.align, fillchars = fillchars }
          ),
        }
        c.tables[first] = tbl
      end
      for row = math.max(top, first), math.min(bot, last) do
        for _, pad in ipairs(tbl.pads[row - first + 1]) do
          marks[#marks + 1] = {
            row,
            pad.col,
            virt_text = { { pad.text, pad.delimiter and "MdTableDelimiter" or "MdTablePad" } },
            virt_text_pos = "inline",
          }
        end
      end
    end
  end
  return marks
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
  btv.on("ColorScheme", { group = btv.augroup.create("bemtvi-md-table") }, define_highlights)

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

  M.refresh()
end

return M
