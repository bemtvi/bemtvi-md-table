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
-- it and the file is unchanged; the padding exists only on screen.
--
-- The work is bounded by what is visible: only tables that touch the viewport are
-- measured (a table is read in full, so its columns agree past the edge of the
-- screen), and the per-table layout is cached until the buffer next changes. The one
-- whole-buffer pass is the fenced-code-block scan that keeps a table inside a code
-- fence from being padded, and it runs at most once per change, only when a table is
-- on screen.
--
-- Toggles (read on every run; `:MdTableToggle` flips the buffer one and repaints):
--   * `btv.g.md_table_align = false` turns it off globally (default: on).
--   * `btv.b[bufnr].md_table_align = false` turns it off for one buffer; a buffer's
--     explicit value (true/false) overrides the global one.

local layout = require("bemtvi-md-table.layout")

local M = {}

local PROVIDER = "bemtvi-md-table"
local DEFAULTS = { filetypes = { "markdown" }, align = true }

-- The live configuration (`setup` replaces it).
M.config = { filetypes = DEFAULTS.filetypes, align = DEFAULTS.align }

-- Per-buffer analysis, valid for one `changedtick`:
--   `{ tick, tables = { [run_start] = { first, last, pads } | false }, fences }`
M._cache = {}

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

-- ----- analysis ---------------------------------------------------------------

-- The rows (0-based) that sit inside a fenced code block, as a set — so a table
-- written inside ``` is left as text. An unclosed fence runs to the end of the buffer.
local function fenced_rows(buf)
  local set, open_char, open_len = {}, nil, 0
  for i, line in ipairs(btv.buf.lines(buf, 0, -1)) do
    local fence = line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)")
    if open_char then
      set[i - 1] = true
      if
        fence
        and fence:sub(1, 1) == open_char
        and #fence >= open_len
        and not line:match("^%s*[`~]+(.*)$"):find("%S")
      then
        open_char = nil
      end
    elseif fence then
      open_char, open_len = fence:sub(1, 1), #fence
      set[i - 1] = true
    end
  end
  return set
end

-- The cache entry for `buf`, reset when the buffer has changed since it was built.
local function cache_for(buf)
  local tick = btv.buf.changedtick(buf)
  local c = M._cache[buf]
  if not c or c.tick ~= tick then
    c = { tick = tick, tables = {} }
    M._cache[buf] = c
  end
  return c
end

-- Lay out the table (if any) in the run of row lines `[first, last]` (0-based), whose
-- text is `lines`. Returns `{ first, last, pads }` with absolute rows, or `false`.
local function analyze_run(c, buf, first, lines)
  local at = layout.table_at(lines)
  if not at then
    return false
  end
  c.fences = c.fences or fenced_rows(buf)
  if c.fences[first] then
    return false
  end
  local rows = {}
  for i = at, #lines do
    rows[#rows + 1] = lines[i]
  end
  return {
    first = first + at - 1,
    last = first + #lines - 1,
    pads = layout.layout(rows, { align = M.config.align }),
  }
end

-- The marks that align every table touching rows `[top, bot]` of `buf`; `visible` is
-- `ctx.lines`, the snapshot of exactly that slice.
function M.marks(buf, top, bot, visible)
  local c = cache_for(buf)
  local n = btv.buf.line_count(buf)
  local function get(row)
    if row >= top and row <= bot then
      return visible[row - top + 1]
    end
    return btv.buf.lines(buf, row, row + 1)[1]
  end

  local marks = {}
  local r = top
  while r <= bot do
    local line = visible[r - top + 1]
    if line and layout.is_row(line) then
      -- The whole run of row lines around `r`, reaching past the viewport so a table
      -- cut by the screen edge is still measured in full.
      local first, last = r, r
      while first > 0 and layout.is_row(get(first - 1)) do
        first = first - 1
      end
      while last + 1 < n and layout.is_row(get(last + 1)) do
        last = last + 1
      end
      local tbl = c.tables[first]
      if tbl == nil then
        local lines = {}
        for row = first, last do
          lines[#lines + 1] = get(row)
        end
        tbl = analyze_run(c, buf, first, lines)
        c.tables[first] = tbl
      end
      if tbl then
        for row = math.max(top, tbl.first), math.min(bot, tbl.last) do
          for _, pad in ipairs(tbl.pads[row - tbl.first + 1]) do
            marks[#marks + 1] = {
              row,
              pad.col,
              virt_text = { { pad.text, pad.delimiter and "MdTableDelimiter" or "MdTablePad" } },
              virt_text_pos = "inline",
            }
          end
        end
      end
      r = last + 1
    else
      r = r + 1
    end
  end
  return marks
end

-- ----- setup ------------------------------------------------------------------

-- The highlight groups the padding draws in. Both are `default` links, so a
-- colorscheme (or the user) can restyle them; they are re-linked after a colorscheme
-- loads, since loading one clears groups it does not define.
local function define_highlights()
  btv.hl.define(0, "MdTablePad", { link = "Normal", default = true })
  btv.hl.define(0, "MdTableDelimiter", { link = "@punctuation.special", default = true })
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
  M.config = { filetypes = fts, align = opts.align ~= false }
  M._cache = {}

  define_highlights()
  btv.on("ColorScheme", { group = btv.augroup.create("bemtvi-md-table") }, define_highlights)

  btv.decor.provider({
    name = PROVIDER,
    bufs = { filetype = fts },
    on_range = function(ctx, publish)
      if not M.enabled(ctx.buf) then
        publish({})
        return
      end
      publish(M.marks(ctx.buf, ctx.top, ctx.bot, ctx.lines))
    end,
  })

  btv.command("MdTableToggle", function()
    local on = M.toggle(0)
    btv.notify("markdown table alignment " .. (on and "on" or "off"))
  end, { desc = "Toggle markdown table alignment in this buffer" })

  M.refresh()
end

return M
