-- End-to-end: open a markdown file in a real editor and assert on what is PAINTED.
-- The padding is inline virtual text, so it is in neither `t:lines()` (the buffer) nor
-- `t:screen()` (the buffer's glyphs): `painted` splices the window's inline
-- placements back into each screen row, giving the row as the user sees it.

local md = require("bemtvi-md-table")
local expect = btv.test.expect

-- Tables are found by the markdown treesitter grammar, so a test that expects any to
-- be drawn skips (with the reason) on a machine without it.
local function needs_markdown(t)
  if not btv.tbl.contains(btv.await(btv.treesitter.installed()), "markdown") then
    t:skip("no markdown treesitter grammar installed")
  end
end

-- Write `lines` to a fresh `name` (default `t.md`) and open it. A markdown file needs
-- the grammar (see `needs_markdown`).
local function open(t, lines, name)
  name = name or "t.md"
  if name:match("%.md$") then
    needs_markdown(t)
  end
  local path = btv.test.tempdir() .. "/" .. name
  btv.await(btv.fs.write(path, table.concat(lines, "\n") .. "\n"))
  t:cmd("edit " .. path)
  return path
end

-- The inline virtual text on screen row `row`, as `{ col, text }` (display columns).
local function inline(row)
  local out = {}
  for _, place in ipairs((btv._ui.virt_text or {})[row] or {}) do
    if place[1] == 1 then
      local parts = {}
      for _, chunk in ipairs(place[4] or {}) do
        parts[#parts + 1] = chunk[1]
      end
      out[#out + 1] = { col = place[2], text = table.concat(parts) }
    end
  end
  return out
end

-- Screen row `row` with its inline virtual text spliced in at its display columns.
local function painted(t, row)
  local text = t:screen()[row] or ""
  local places = inline(row)
  table.sort(places, function(a, b)
    return a.col > b.col
  end)
  for _, place in ipairs(places) do
    -- Display column -> byte offset, walking the row a character at a time.
    local byte, w = #text + 1, 0
    for pos, cp in utf8.codes(text) do
      if w >= place.col then
        byte = pos
        break
      end
      w = w + btv.str.displaywidth(utf8.char(cp))
    end
    text = text:sub(1, byte - 1) .. place.text .. text:sub(byte)
  end
  return text
end

-- The display columns of every `|` in a painted row.
local function pipe_cols(s)
  local out, w = {}, 0
  for _, cp in utf8.codes(s) do
    if cp == 124 then
      out[#out + 1] = w
    end
    w = w + btv.str.displaywidth(utf8.char(cp))
  end
  return out
end

-- Whether screen rows `first..last` paint their pipes in the same columns.
local function aligned(t, first, last)
  local want = table.concat(pipe_cols(painted(t, first)), ",")
  for row = first + 1, last do
    if table.concat(pipe_cols(painted(t, row)), ",") ~= want then
      return false
    end
  end
  return true
end

local function wait_aligned(t, first, last, message)
  t:wait_for(function()
    return aligned(t, first, last) or nil
  end, { message = message or ("rows %d-%d never lined up"):format(first, last) })
end

local USER_TABLE = {
  "# Queues",
  "",
  "| Queue | Upstream | Applied by |",
  "|---|---|---|",
  "| a | b | c |",
}

btv.test.describe("bemtvi-md-table", function()
  btv.test.before_each(function()
    btv.g.md_table_align = nil
    btv.g.md_table_fillchars = nil
    md.setup({})
  end)

  btv.test.it("pads the delimiter row out to the header", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    expect(painted(t, 3)).to_be("| Queue | Upstream | Applied by |")
    expect(painted(t, 4)).to_be("|-------|----------|------------|")
    expect(painted(t, 5)).to_be("| a ····| b ·······| c ·········|")
  end)

  btv.test.it("leaves the buffer text exactly as written", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    expect(t:lines()).to_equal(USER_TABLE)
    expect(btv.bo.modified).to_be(false)
  end)

  btv.test.it("draws the delimiter dashes in MdTableDelimiter", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    local groups = {}
    for _, m in ipairs(btv._decor.last.marks) do
      groups[m.opts.virt_text[1][2]] = true
    end
    expect(groups.MdTableDelimiter).to_be(true)
    expect(groups.MdTablePad).to_be(true)
  end)

  btv.test.it("re-aligns as a cell grows while typing", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    -- Grow the body's first cell past the header's.
    t:feed("5G03|ilonger cell <Esc>")
    expect(t:lines()[5]).to_be("| longer cell a | b | c |")
    wait_aligned(t, 3, 5, "the table did not re-align after the edit")
    expect(painted(t, 3)).to_be("| Queue ········| Upstream | Applied by |")
  end)

  btv.test.it("measures a table in full when it runs past the screen", function(t)
    local lines = { "| k | v |", "|---|---|", "| a very wide key | 1 |" }
    for i = 1, 60 do
      lines[#lines + 1] = "| k" .. i .. " | " .. i .. " |"
    end
    open(t, lines)
    t:feed("50Gzt")
    t:wait_for(function()
      return (#inline(1) > 0) or nil
    end, { message = "the scrolled-to rows were never padded" })
    -- Row 50 is `| k47 | 47 |`; the widest cell is far above the viewport.
    expect(painted(t, 1)).to_be("| k47 ············| 47 |")
  end)

  btv.test.it("lines up wide characters", function(t)
    open(t, { "| 名前 | x |", "|---|---|", "| ab | yy |" })
    wait_aligned(t, 1, 3)
    expect(pipe_cols(painted(t, 2))).to_equal({ 0, 7, 12 })
  end)

  btv.test.it("honors column alignment in the cells", function(t)
    open(t, { "| r | c |", "|--:|:-:|", "| xxxxx | xxxxx |" })
    wait_aligned(t, 1, 3)
    expect(painted(t, 1)).to_be("|···· r |·· c ··|")
    expect(painted(t, 2)).to_be("|------:|:-----:|")
  end)

  btv.test.it("leaves a table inside a fenced code block alone", function(t)
    open(t, {
      "```",
      "| a | bbbbbb |",
      "|---|---|",
      "```",
      "",
      "| c | d |",
      "|---|---|",
      "| long | x |",
    })
    wait_aligned(t, 6, 8)
    expect(#inline(2)).to_be(0)
    expect(#inline(3)).to_be(0)
  end)

  btv.test.it("leaves pipes that are not a table alone", function(t)
    open(t, { "a | b", "", "x | y", "no delimiter | here", "", "| a | b |", "|---|---|" })
    wait_aligned(t, 6, 7)
    for row = 1, 4 do
      expect(#inline(row)).to_be(0)
    end
  end)

  btv.test.it("finds tables in a list item and a block quote", function(t)
    open(t, {
      "- item",
      "",
      "  | a | bbbbbb |",
      "  |---|---|",
      "",
      "> | c | dddddd |",
      "> |---|---|",
    })
    wait_aligned(t, 3, 4)
    wait_aligned(t, 6, 7)
    expect(painted(t, 4)).to_be("  |---|--------|")
    expect(painted(t, 7)).to_be("> |---|--------|")
  end)

  btv.test.it("honors column alignment in a block quote", function(t)
    md.setup({ fillchars = "pad:." })
    open(t, { "> | a | bbbb |", "> |---|---:|", "> | ccc | d |" })
    wait_aligned(t, 1, 3)
    expect(painted(t, 3)).to_be("> | ccc |... d |")
  end)

  btv.test.it("lines up a block-quoted row written without outer pipes", function(t)
    md.setup({ fillchars = "pad:." })
    open(t, { "> | a | b |", "> |---|---|", "> more | text" })
    -- `> more |` closes column 1 at screen column 7, as `> | a .|` does.
    t:wait_for(function()
      return (painted(t, 2) == "> |----|-----|") or nil
    end, { message = "the delimiter row never lined up with the open row" })
    expect(painted(t, 1)).to_be("> | a .| b ..|")
  end)

  btv.test.it("lines up a table that starts on a list marker's line", function(t)
    md.setup({ fillchars = "pad:." })
    open(t, { "- | a | b |", "  |---|---|", "  | ccc | d |" })
    wait_aligned(t, 1, 3)
    expect(painted(t, 1)).to_be("- | a ..| b |")
    expect(painted(t, 2)).to_be("  |-----|---|")
  end)

  btv.test.it("lines up rows whose prefixes are written differently", function(t)
    md.setup({ fillchars = "pad:." })
    open(t, { "> | a | b |", ">|---|---|", ">| ccc | d |" })
    t:wait_for(function()
      return (painted(t, 1) == "> | a .| b |") or nil
    end, { message = "the header never lined up with the lazy rows" })
    expect(painted(t, 2)).to_be(">|-----|---|")
  end)

  btv.test.it("measures a tab from the column it sits at", function(t)
    md.setup({ fillchars = "pad:." })
    -- " abc<Tab>d " starts at screen column 5, so the tab runs to 16: 13 cells.
    open(t, { "| x | abc\td |", "|---|---|" })
    t:wait_for(function()
      return (painted(t, 2) == "|---|-------------|") or nil
    end, { message = "the delimiter row was not padded to the tab's width" })
  end)

  btv.test.it("leaves a table too wide for any screen unaligned", function(t)
    open(t, { "| " .. ("w"):rep(1200) .. " | b |", "|---|---|", "| a | b |" })
    t:sleep(300)
    expect(#inline(2)).to_be(0)
    expect(#inline(3)).to_be(0)
  end)

  btv.test.it("re-parses only the edited row of a big table", function(t)
    local doc = { "| k | v |", "|---|---|" }
    for i = 1, 2000 do
      doc[#doc + 1] = ("| %d | x |"):format(i)
    end
    open(t, doc)
    wait_aligned(t, 1, 3)
    local layout = require("bemtvi-md-table.layout")
    local real, parsed = layout.row, 0
    layout.row = function(...)
      parsed = parsed + 1
      return real(...)
    end
    t:feed("3GA!<Esc>")
    t:wait_for(function()
      return (painted(t, 3):find("!", 1, true) and parsed > 0) or nil
    end, { message = "the edit was never laid out" })
    layout.row = real
    expect(parsed <= 2).to_be(true)
  end)

  btv.test.it("parses none of a big table's rows for an edit next to it", function(t)
    local doc = { "Some text", "", "| k | v |", "|---|---|" }
    for i = 1, 2000 do
      doc[#doc + 1] = ("| %d | x |"):format(i)
    end
    open(t, doc)
    wait_aligned(t, 3, 5)
    local layout = require("bemtvi-md-table.layout")
    local real, parsed = layout.row, 0
    layout.row = function(...)
      parsed = parsed + 1
      return real(...)
    end
    local runs = 0
    local marks = md.marks
    md.marks = function(...)
      runs = runs + 1
      return marks(...)
    end
    t:feed("1GA more<Esc>")
    t:wait_for(function()
      return (runs > 0) or nil
    end, { message = "the provider never ran after the edit" })
    layout.row, md.marks = real, marks
    expect(parsed).to_be(0)
  end)

  btv.test.it("draws a table whose body row has more cells than the header", function(t)
    md.setup({ fillchars = "pad:." })
    open(t, { "| a | bbb |", "|---|---|", "| x | y ||" })
    t:wait_for(function()
      return (painted(t, 3) == "| x | y ..||") or nil
    end, { message = "the row with an extra empty cell was never padded" })
  end)

  btv.test.it("forgets a buffer's layout when the buffer is deleted", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    local buf = btv.buf.current()
    expect(md._cache[buf]).never.to_be_nil()
    t:cmd("enew")
    t:cmd("bwipeout! " .. buf)
    expect(md._cache[buf]).to_be_nil()
  end)

  btv.test.it("draws nothing where treesitter is off", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    expect(#inline(4)).never.to_be(0)
    t:cmd("lua btv.bo.ts_highlight = false")
    t:wait_for(function()
      return (#inline(4) == 0) or nil
    end, { message = "the padding stayed with no parse tree to find tables in" })
  end)

  btv.test.it("does nothing outside markdown", function(t)
    open(t, USER_TABLE, "t.txt")
    expect(btv.bo.filetype).never.to_be("markdown")
    t:sleep(200)
    expect(#inline(4)).to_be(0)
  end)

  btv.test.it("turns off and back on with :MdTableToggle", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    t:cmd("MdTableToggle")
    expect(btv.b.md_table_align).to_be(false)
    t:wait_for(function()
      return (#inline(4) == 0) or nil
    end, { message = "the padding stayed after toggling off" })
    t:cmd("MdTableToggle")
    wait_aligned(t, 3, 5, "the padding did not come back after toggling on")
  end)

  btv.test.it("is off everywhere with btv.g.md_table_align = false", function(t)
    btv.g.md_table_align = false
    open(t, USER_TABLE)
    t:sleep(200)
    expect(#inline(4)).to_be(0)
  end)

  btv.test.it("draws the padding in setup's fillchars, as a key:char list", function(t)
    md.setup({ fillchars = "pad: ,delimiter:-" })
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    expect(painted(t, 4)).to_be("|-------|----------|------------|")
    expect(painted(t, 5)).to_be("| a     | b        | c          |")
  end)

  btv.test.it("takes fillchars as a table, keeping the keys it leaves out", function(t)
    md.setup({ fillchars = { pad = "_" } })
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    expect(painted(t, 4)).to_be("|-------|----------|------------|")
    expect(painted(t, 5)).to_be("| a ____| b _______| c _________|")
  end)

  btv.test.it("takes a comma or a colon as a fill char", function(t)
    md.setup({ fillchars = "pad:,,delimiter::" })
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    expect(painted(t, 4)).to_be("|---::::|---:::::::|---:::::::::|")
    expect(painted(t, 5)).to_be("| a ,,,,| b ,,,,,,,| c ,,,,,,,,,|")
  end)

  btv.test.it("btv.g.md_table_fillchars overrides setup, and btv.b the global", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    btv.g.md_table_fillchars = "pad:."
    md.refresh()
    t:wait_for(function()
      return painted(t, 5) == "| a ....| b .......| c .........|" or nil
    end, { message = "the global fillchars were not drawn" })
    btv.b.md_table_fillchars = { pad = "+" }
    md.refresh(btv.buf.current())
    t:wait_for(function()
      return painted(t, 5) == "| a ++++| b +++++++| c +++++++++|" or nil
    end, { message = "the buffer's fillchars did not win over the global ones" })
  end)

  btv.test.it("refuses bad fillchars in a variable loudly and draws nothing", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    btv.b.md_table_fillchars = "pad:ab"
    md.refresh(btv.buf.current())
    t:wait_for(function()
      return (#inline(4) == 0) or nil
    end, { message = "the table stayed padded with invalid fillchars" })
    expect(t:message()).to_contain("E474")
    expect(t:message()).to_contain("pad:ab")
  end)

  btv.test.it("links both padding groups to NonText by default", function()
    expect(btv.hl.get(0, { name = "MdTablePad" }).link).to_be("NonText")
    expect(btv.hl.get(0, { name = "MdTableDelimiter" }).link).to_be("NonText")
  end)

  btv.test.it("rejects bad fillchars at setup", function()
    for _, bad in ipairs({
      "pad:ab",
      "dash:-",
      "pad",
      "pad:",
      "pad:x,",
      { pad = "ab" },
      { dash = "-" },
      3,
    }) do
      local ok, err = pcall(md.setup, { fillchars = bad })
      expect(ok).to_be(false)
      expect(tostring(err)).to_contain("fillchars")
    end
    local _, err = pcall(md.setup, { fillchars = "pad:x,dash:-" })
    expect(tostring(err)).to_contain("unknown key 'dash'")
    _, err = pcall(md.setup, { fillchars = "pad:名" })
    expect(tostring(err)).to_contain("one display cell")
  end)

  btv.test.it("rejects an unknown setup option", function()
    local ok, err = pcall(md.setup, { aling = true })
    expect(ok).to_be(false)
    expect(tostring(err)).to_contain("unknown option 'aling'")
  end)
end)
