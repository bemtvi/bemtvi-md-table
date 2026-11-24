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
    md.setup({})
  end)

  btv.test.it("pads the delimiter row out to the header", function(t)
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    expect(painted(t, 3)).to_be("| Queue | Upstream | Applied by |")
    expect(painted(t, 4)).to_be(
      "|---────|---───────|---─────────|"
    )
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
    expect(painted(t, 2)).to_be("|--────:|:-────:|")
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
    expect(painted(t, 4)).to_be("  |---|---─────|")
    expect(painted(t, 7)).to_be("> |---|---─────|")
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

  btv.test.it("draws the padding in the glyphs setup names", function(t)
    md.setup({ chars = { pad = " ", delimiter = "-" } })
    open(t, USER_TABLE)
    wait_aligned(t, 3, 5)
    expect(painted(t, 4)).to_be("|-------|----------|------------|")
    expect(painted(t, 5)).to_be("| a     | b        | c          |")
  end)

  btv.test.it("links both padding groups to NonText by default", function()
    expect(btv.hl.get(0, { name = "MdTablePad" }).link).to_be("NonText")
    expect(btv.hl.get(0, { name = "MdTableDelimiter" }).link).to_be("NonText")
  end)

  btv.test.it("rejects a padding glyph that isn't one cell wide", function()
    local ok, err = pcall(md.setup, { chars = { pad = "ab" } })
    expect(ok).to_be(false)
    expect(tostring(err)).to_contain("chars.pad")
    ok, err = pcall(md.setup, { chars = { dash = "-" } })
    expect(ok).to_be(false)
    expect(tostring(err)).to_contain("unknown chars key 'dash'")
  end)

  btv.test.it("rejects an unknown setup option", function()
    local ok, err = pcall(md.setup, { aling = true })
    expect(ok).to_be(false)
    expect(tostring(err)).to_contain("unknown option 'aling'")
  end)
end)
