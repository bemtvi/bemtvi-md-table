-- The pure layout: rows in, padding out. No buffer, no provider.

local layout = require("bemtvi-md-table.layout")
local expect = btv.test.expect

-- Apply `pads` to `lines`, giving the text as it would be painted.
local function paint(lines, pads)
  local out = {}
  for i, line in ipairs(lines) do
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

local function painted(lines, opts)
  return paint(lines, layout.layout(lines, opts))
end

btv.test.describe("layout.row", function()
  btv.test.it("splits cells between pipes", function()
    local row = layout.row("| a | bb |")
    expect(#row.cells).to_be(2)
    expect(row.cells[1].close).to_be(5)
    expect(row.cells[2].close).to_be(10)
    -- column 1 runs from the line start, so it includes the leading pipe
    expect(row.cells[1].seg).to_be(4)
    expect(row.cells[2].seg).to_be(4)
  end)

  btv.test.it("takes a row without outer pipes", function()
    local row = layout.row("a | b")
    expect(#row.cells).to_be(2)
    expect(row.cells[2].close).to_be_nil()
  end)

  btv.test.it("does not split on an escaped pipe", function()
    local row = layout.row([[| a \| b | c |]])
    expect(#row.cells).to_be(2)
  end)

  btv.test.it("splits on a pipe preceded by an escaped backslash", function()
    local row = layout.row([[| a \\| b |]])
    expect(#row.cells).to_be(2)
  end)

  btv.test.it("is nil for a line with no pipe, or a blank one", function()
    expect(layout.row("just text")).to_be_nil()
    expect(layout.row("   ")).to_be_nil()
  end)
end)

btv.test.describe("layout.aligns", function()
  btv.test.it("reads left, right and center", function()
    local line = "| --- | :-- | --: | :-: |"
    expect(layout.aligns(layout.row(line), line)).to_equal({ "left", "left", "right", "center" })
  end)

  btv.test.it("rejects a row that is not a delimiter row", function()
    local line = "| --- | x |"
    expect(layout.aligns(layout.row(line), line)).to_be_nil()
  end)
end)

btv.test.describe("layout.layout", function()
  btv.test.it("widens the delimiter row to the header", function()
    expect(painted({ "| Queue | Upstream | Applied by |", "|---|---|---|" })).to_equal({
      "| Queue | Upstream | Applied by |",
      "|-------|----------|------------|",
    })
  end)

  btv.test.it("pads every short cell to its column's widest", function()
    expect(painted({ "| a | b |", "|---|---|", "| long cell | x |" })).to_equal({
      "| a         | b |",
      "|-----------|---|",
      "| long cell | x |",
    })
  end)

  btv.test.it("keeps alignment colons at the edges of the delimiter cells", function()
    expect(painted({ "| left | center | right |", "|:-|:-:|-:|" })).to_equal({
      "| left | center | right |",
      "|:-----|:------:|------:|",
    })
  end)

  btv.test.it("puts right-aligned padding before the text, centered around it", function()
    expect(painted({ "| r | c |", "|--:|:-:|", "| xxxxx | xxxxx |" })).to_equal({
      "|     r |   c   |",
      "|------:|:-----:|",
      "| xxxxx | xxxxx |",
    })
  end)

  btv.test.it("pads every cell on the right with align = false", function()
    local out = painted({ "| r |", "|--:|", "| xxxxx |" }, { align = false })
    expect(out[1]).to_be("| r     |")
  end)

  btv.test.it("draws the padding in opts.fillchars", function()
    local out = painted(
      { "| r | c |", "|--:|---|", "| xxxxx | xxxxx |" },
      { fillchars = { pad = "·", delimiter = "─" } }
    )
    expect(out[1]).to_be("|···· r | c ····|")
    expect(out[2]).to_be("|--────:|---────|")
  end)

  btv.test.it("puts delimiter dashes before the cell's own trailing space", function()
    expect(painted({ "| Header |", "| --- |" })).to_equal({ "| Header |", "| ------ |" })
  end)

  btv.test.it("measures wide characters in display cells", function()
    local pads = layout.layout({ "| 日本 | b |", "|---|---|" })
    -- "| 日本 " is 2 + 4 + 1 = 7 cells; "|---" is 4: three dashes short
    expect(pads[2][1].text).to_be("---")
  end)

  btv.test.it("lines up rows written with and without outer pipes", function()
    expect(painted({ "| a | b |", "|---|---|", "xyzw | 1" })).to_equal({
      "| a  | b |",
      "|----|---|",
      "xyzw | 1",
    })
  end)

  btv.test.it("never pads an open last cell", function()
    local pads = layout.layout({ "| a | b |", "|---|---|", "| a | long" })
    expect(#pads[3]).to_be(0)
  end)
end)

btv.test.describe("layout.shrink", function()
  btv.test.it("trims every cell to one space from its pipes", function()
    expect(layout.shrink({
      "| Queue  | Upstream       |",
      "|--------|----------------|",
      "|   ingest | kafka://events |",
    })).to_equal({
      "| Queue | Upstream |",
      "|---|---|",
      "| ingest | kafka://events |",
    })
  end)

  btv.test.it("keeps each delimiter cell's alignment in three characters", function()
    local out = layout.shrink({ "| a | b | c | d |", "| ----- | :---- | ----: | :---: |" })
    expect(out[2]).to_be("|---|:--|--:|:-:|")
  end)

  btv.test.it("keeps a row's outer pipes, or their absence", function()
    expect(layout.shrink({ "a   |   b", "---|---", "|  x |  y  " })).to_equal({
      "a | b",
      "---|---",
      "| x | y",
    })
  end)

  btv.test.it("writes an empty cell as one space, and keeps escaped pipes", function()
    expect(layout.shrink({ [[|  | a \| b   |]], "|---|---|" })).to_equal({
      [[| | a \| b |]],
      "|---|---|",
    })
  end)
end)

btv.test.describe("layout.expand", function()
  btv.test.it("pads every cell with real spaces and dashes", function()
    expect(layout.expand({
      "| Queue | Upstream | Applied by |",
      "|---|---|---|",
      "| ingest | kafka://events | worker-a |",
    })).to_equal({
      "| Queue  | Upstream       | Applied by |",
      "|--------|----------------|------------|",
      "| ingest | kafka://events | worker-a   |",
    })
  end)

  btv.test.it("drops stray spacing before it pads", function()
    expect(layout.expand({ "|    a |b|", "|-|-|", "| ccc | d |" })).to_equal({
      "| a   | b |",
      "|-----|---|",
      "| ccc | d |",
    })
  end)

  btv.test.it("places the padding by the column's alignment", function()
    expect(layout.expand({ "| r | c |", "|--:|:-:|", "| xxxxx | xxxxx |" })).to_equal({
      "|     r |   c   |",
      "|------:|:-----:|",
      "| xxxxx | xxxxx |",
    })
    expect(layout.expand({ "| r |", "|--:|", "| xxxxx |" }, { align = false })[1]).to_be(
      "| r     |"
    )
  end)

  btv.test.it("pads wide characters by display width", function()
    expect(layout.expand({ "| 日本 | b |", "|---|---|", "| x | y |" })).to_equal({
      "| 日本 | b |",
      "|------|---|",
      "| x    | y |",
    })
  end)

  btv.test.it("undoes a shrink", function()
    local grid = { "| a   | bb |", "|:----|---:|", "| ccc |  d |" }
    expect(layout.expand(layout.shrink(grid))).to_equal(grid)
  end)
end)

btv.test.describe("layout: hostile input stays fast", function()
  local function timed(fn)
    local t0 = os.clock()
    local out = fn()
    return out, os.clock() - t0
  end

  btv.test.it("trims a cell with a long run of inner spaces in linear time", function()
    local line = "| a" .. (" "):rep(40000) .. "b |"
    local out, secs = timed(function()
      return layout.shrink({ line, "|---|" })
    end)
    expect(out[1]).to_be("| a" .. (" "):rep(40000) .. "b |")
    expect(secs < 0.5).to_be(true)
  end)

  btv.test.it("refuses to expand a table wider than MAX_WIDTH", function()
    local out, why = layout.expand({ "| " .. ("w"):rep(1200) .. " |", "|---|" })
    expect(out).to_be_nil()
    expect(why).to_match("wider than 1000")
  end)

  btv.test.it("pads nothing in a table wider than MAX_WIDTH", function()
    local pads = layout.layout({ "| " .. ("w"):rep(1200) .. " |", "|---|", "| a |" })
    expect(#pads[2]).to_be(0)
    expect(#pads[3]).to_be(0)
  end)
end)

btv.test.describe("layout: columns", function()
  btv.test.it("starts column 1 at the given base column", function()
    expect(layout.row("| a |", 2).cells[1].seg).to_be(6)
  end)

  btv.test.it("measures a tab in a later cell from its screen column", function()
    -- " abc<Tab>d " starts at column 5: four cells to 9, the tab to the next stop, then
    -- two: to 16 on stops of 8, to 12 on stops of 4.
    layout.tabstop = 8
    expect(layout.row("| x | abc\td |").cells[2].seg).to_be(13)
    layout.tabstop = 4
    expect(layout.row("| x | abc\td |").cells[2].seg).to_be(9)
    layout.tabstop = nil
  end)

  btv.test.it("keeps a row's leading whitespace when shrinking", function()
    expect(layout.shrink({ "   |  a | b |", "   |---|---|" })).to_equal({
      "   | a | b |",
      "   |---|---|",
    })
  end)
end)

btv.test.describe("layout.expand: shapes that broke it", function()
  btv.test.it("pads a first cell without a leading pipe after its text, aligned or not", function()
    local out = layout.expand({ "a | b", "--:|---", "abcdefgh | x" })
    expect(out).to_equal({ "a        | b", "--------:|---", "abcdefgh | x" })
    -- Nothing became indentation, so shrinking gives back the shrunk table.
    expect(layout.shrink(out)).to_equal({ "a | b", "--:|---", "abcdefgh | x" })
    expect(layout.expand({ "a | b", ":-:|---", "abcdefghij | x" })[1]).to_be("a          | b")
  end)

  btv.test.it("refuses a table with a tab in a cell", function()
    local out, why = layout.expand({ "| a | x\ty |", "|---|---|", "| bbbbbbb | z |" })
    expect(out).to_be_nil()
    expect(why).to_match("tab")
  end)

  btv.test.it("is stable: expanding an expanded table changes nothing", function()
    local once = layout.expand({ "| a | bb |", "|:-|--:|", "| ccc | d |", "x | y" })
    expect(layout.expand(once)).to_equal(once)
  end)
end)

btv.test.describe("layout: rows the header doesn't account for", function()
  btv.test.it("pads a table whose body row has more empty cells than the header", function()
    local pads = layout.layout({ "| a | b |", "|---|---|", "| x | y ||" })
    expect(#pads[1]).to_be(0)
    expect(layout.expand({ "| a | b |", "|---|---|", "| x | y ||" })).to_equal({
      "| a | b |",
      "|---|---|",
      "| x | y | |",
    })
  end)

  btv.test.it("counts each pipe toward MAX_WIDTH, so a row of empty cells is wide", function()
    local m = layout.measure({ "| a |", "|---|", ("|"):rep(1200) })
    expect(m.wide).to_be(true)
  end)

  btv.test.it("stops parsing a row past its limit", function()
    local t0 = os.clock()
    local row = layout.row(("|"):rep(400000), 0, 1000)
    expect(row.wide).to_be(true)
    expect(os.clock() - t0 < 0.1).to_be(true)
  end)

  btv.test.it("is wide past MAX_ROWS", function()
    local lines = { "| a |", "|---|" }
    for i = 1, layout.MAX_ROWS do
      lines[#lines + 1] = "| x |"
    end
    expect(layout.measure(lines).wide).to_be(true)
  end)

  btv.test.it("keeps a stray carriage return after the last pipe when shrinking", function()
    expect(layout.shrink({ "|  a |\r", "|---|" })).to_equal({ "| a |\r", "|---|" })
  end)
end)

btv.test.describe("layout.update", function()
  -- A random row: 0-6 cells of 0-9 letters, with or without outer pipes.
  local function random_row(rand)
    local cells = {}
    for i = 1, rand(0, 6) do
      cells[i] = (" x"):rep(rand(0, 9))
    end
    if #cells == 0 then
      return "no pipes here"
    end
    local body = table.concat(cells, "|")
    return (rand(0, 1) == 1 and "|" or "") .. body .. (rand(0, 1) == 1 and "|" or "")
  end

  btv.test.it("agrees with a full measure after any edit", function()
    local seed = 12345
    local function rand(a, b)
      seed = (seed * 1103515245 + 12345) % 2147483648
      return a + seed % (b - a + 1)
    end
    for _ = 1, 300 do
      local lines = { "| a | b | c |", "|---|:-:|--:|" }
      for i = 3, rand(2, 12) do
        lines[i] = random_row(rand)
      end
      local rows = {}
      for i, line in ipairs(lines) do
        rows[i] = layout.row(line) or false
      end
      local prev = layout.measure_rows(rows, lines[2])
      -- Replace a random run of rows (never the delimiter) with a random new run.
      local a = rand(3, #lines + 1)
      local b = rand(a - 1, #lines)
      local new_lines, gone, came = {}, {}, {}
      for i = 1, a - 1 do
        new_lines[#new_lines + 1] = lines[i]
      end
      for i = a, b do
        gone[#gone + 1] = prev.rows[i]
      end
      for _ = 1, rand(0, 4) do
        new_lines[#new_lines + 1] = random_row(rand)
        came[#came + 1] = layout.row(new_lines[#new_lines]) or false
      end
      for i = b + 1, #lines do
        new_lines[#new_lines + 1] = lines[i]
      end
      local new_rows, k = {}, 0
      for i = 1, a - 1 do
        new_rows[i] = prev.rows[i]
      end
      for i = 1, #came do
        new_rows[a - 1 + i] = came[i]
        k = i
      end
      for i = b + 1, #lines do
        new_rows[a + k + (i - b - 1)] = prev.rows[i]
      end
      local got = layout.update(prev, new_rows, new_lines[2], gone, came)
      local fresh = {}
      for i, line in ipairs(new_lines) do
        fresh[i] = layout.row(line) or false
      end
      local want = layout.measure_rows(fresh, new_lines[2])
      expect(got.widths).to_equal(want.widths)
      expect(got.ncells).to_be(want.ncells)
      expect(got.wide).to_be(want.wide)
      for j, w in ipairs(want.widths) do
        local n = 0
        for _, row in ipairs(want.rows) do
          if row.cells[j] and row.cells[j].seg == w then
            n = n + 1
          end
        end
        expect(got.counts[j]).to_be(n)
      end
    end
  end)
end)

btv.test.describe("layout: caps that stop the work early", function()
  local function timed(fn)
    local t0 = btv.now_ms()
    local out = fn()
    return out, btv.now_ms() - t0
  end

  btv.test.it("knows a huge cell runs past the limit without measuring it", function()
    local cjk = ("日"):rep(1000000)
    local row, ms = timed(function()
      return layout.row(cjk .. " | b |", 0, 1000)
    end)
    expect(row.wide).to_be(true)
    expect(ms < 50).to_be(true)
    row, ms = timed(function()
      return layout.row("| a | " .. cjk, 0, 1000)
    end)
    expect(row.wide).to_be(true)
    expect(ms < 50).to_be(true)
  end)

  btv.test.it("is wide past MAX_CELLS", function()
    local rows = {}
    local narrow = ("|x"):rep(400) .. "|"
    for i = 1, layout.MAX_CELLS // 400 + 2 do
      rows[i] = layout.row(narrow)
    end
    expect(layout.measure_rows(rows, narrow).wide).to_be(true)
  end)

  btv.test.it("pads nothing when line 2 isn't a delimiter row", function()
    local m = layout.measure({ "| a | bb |", "| ccc | d |", "| e | f |" })
    expect(m.table).to_be(false)
    for i = 1, 3 do
      expect(#layout.row_pads(m, i)).to_be(0)
    end
  end)

  btv.test.it("refuses to rewrite what doesn't start with a header and a delimiter", function()
    for _, fn in ipairs({ layout.shrink, layout.expand }) do
      local out, why = fn({ "| a | bb |", "| ccc | d |" })
      expect(out).to_be_nil()
      expect(why).to_match("delimiter row")
    end
  end)
end)

btv.test.describe("layout: what a row's width counts", function()
  btv.test.it("doesn't count spaces after an open last cell", function()
    local pads = layout.layout({ "| a | b |", "|---|---|", "| c | d          " })
    expect(#pads[1]).to_be(0)
    expect(#pads[2]).to_be(0)
  end)

  btv.test.it("counts a body row written without any pipe as one cell", function()
    local m = layout.measure({ "| a | b |", "|---|---|", "a lazy row" }, { lone = true })
    expect(m.widths[1]).to_be(#"a lazy row")
    -- Not without `lone`: the header and delimiter rows can't be pipeless.
    expect(layout.row("a lazy row")).to_be_nil()
  end)

  btv.test.it("expands a table with a tab in a row without pipes", function()
    local out = layout.expand({ "| a | b |", "|---|---|", "lazy\trow" })
    expect(out).never.to_be_nil()
    expect(out[3]).to_be("lazy\trow")
  end)
end)

btv.test.describe("layout: characters that aren't plain", function()
  btv.test.it("measures a control character at the width it is drawn", function()
    -- `| a<C-a> `: `^A` is two cells, so column 1 is 6 cells wide.
    expect(layout.row("| a\1 | b |").cells[1].seg).to_be(6)
    local pads = layout.layout({ "| a\1 | b |", "|---|---|", "| abcdef | x |" })
    expect(pads[1][1].n).to_be(3)
  end)

  btv.test.it("keeps a carriage return, trimming only spaces and tabs", function()
    expect(layout.shrink({ "| a\r | b\r", "|---|---|\r", "| abcdef | x |\r", "c | d  \r" })).to_equal({
      "| a\r | b\r",
      "|---|---|\r",
      "| abcdef | x |\r",
      "c | d\r",
    })
  end)

  btv.test.it("measures a long cell of combining marks as the narrow cell it is", function()
    local cell = "x" .. ("\u{301}"):rep(3000)
    local m = layout.measure({ "| " .. cell .. " | b |", "|---|---|" }, { limit = 1000 })
    expect(m.wide).to_be(false)
    expect(m.rows[1].cells[1].seg).to_be(4)
  end)

  btv.test.it("refuses to shrink a row of more cells than MAX_CELLS", function()
    local out, why = layout.shrink({ ("|"):rep(layout.MAX_CELLS + 10), "|---|" })
    expect(out).to_be_nil()
    expect(why).to_match("more than")
  end)
end)
