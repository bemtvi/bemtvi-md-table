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

  btv.test.it("draws the padding in opts.chars", function()
    local out = painted(
      { "| r | c |", "|--:|---|", "| xxxxx | xxxxx |" },
      { chars = { pad = "·", delimiter = "─" } }
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
