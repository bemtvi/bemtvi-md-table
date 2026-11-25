-- End-to-end: `:MdTableShrink` / `:MdTableExpand` rewrite the buffer's text, found
-- through the markdown treesitter grammar.

local md = require("bemtvi-md-table")
local expect = btv.test.expect

local function open(t, lines)
  if not btv.tbl.contains(btv.await(btv.treesitter.installed()), "markdown") then
    t:skip("no markdown treesitter grammar installed")
  end
  local path = btv.test.tempdir() .. "/rewrite.md"
  btv.await(btv.fs.write(path, table.concat(lines, "\n") .. "\n"))
  t:cmd("edit! " .. path)
  -- Wait for the grammar to have parsed the file, so a query finds its tables.
  t:wait_for(function()
    local ok, res = pcall(btv.await, btv.treesitter.query(0, "(pipe_table) @t"))
    return ok and #res.matches > 0 or nil
  end, { message = "the markdown parse never found a table" })
end

-- Wait until buffer line `n` reads `want`.
local function wait_line(t, n, want)
  t:wait_for(function()
    return t:lines()[n] == want or nil
  end, { message = ("line %d never became %q (is %q)"):format(n, want, tostring(t:lines()[n])) })
end

local TWO_TABLES = {
  "| Queue | Upstream |",
  "|---|---|",
  "| ingest | kafka://events |",
  "",
  "text between",
  "",
  "| a | b |",
  "|---|---|",
  "| long cell | x |",
}

btv.test.describe("MdTableShrink / MdTableExpand", function()
  btv.test.before_each(function()
    md.setup({})
  end)

  btv.test.it("expands the table under the cursor, and only it", function(t)
    open(t, TWO_TABLES)
    t:feed("2G")
    t:cmd("MdTableExpand")
    wait_line(t, 2, "|--------|----------------|")
    expect(t:lines()).to_equal({
      "| Queue  | Upstream       |",
      "|--------|----------------|",
      "| ingest | kafka://events |",
      "",
      "text between",
      "",
      "| a | b |",
      "|---|---|",
      "| long cell | x |",
    })
  end)

  btv.test.it("shrinks it back", function(t)
    open(t, {
      "| Queue  | Upstream       |",
      "|:-------|---------------:|",
      "| ingest | kafka://events |",
    })
    t:cmd("MdTableShrink")
    wait_line(t, 2, "|:--|--:|")
    expect(t:lines()).to_equal({
      "| Queue | Upstream |",
      "|:--|--:|",
      "| ingest | kafka://events |",
    })
  end)

  btv.test.it("rewrites every table a range touches", function(t)
    open(t, TWO_TABLES)
    t:cmd("%MdTableExpand")
    wait_line(t, 8, "|-----------|---|")
    expect(t:lines()[2]).to_be("|--------|----------------|")
    expect(t:lines()[7]).to_be("| a         | b |")
  end)

  btv.test.it("keeps a block quote's prefix on every row", function(t)
    open(t, { "> | a | b |", "> |---|---|", "> | ccc | d |" })
    t:feed("2G")
    t:cmd("MdTableExpand")
    wait_line(t, 2, "> |-----|---|")
    expect(t:lines()).to_equal({ "> | a   | b |", "> |-----|---|", "> | ccc | d |" })
  end)

  btv.test.it("keeps a list item's indent on every row", function(t)
    open(t, { "- item", "", "  | a | b |", "  |---|---|", "  | ccc | d |" })
    t:feed("4G")
    t:cmd("MdTableShrink | MdTableExpand")
    wait_line(t, 4, "  |-----|---|")
    expect(t:lines()[3]).to_be("  | a   | b |")
    expect(t:lines()[5]).to_be("  | ccc | d |")
  end)

  btv.test.it("fails loud off a table, leaving the buffer alone", function(t)
    open(t, TWO_TABLES)
    t:feed("5G")
    local ok, err = pcall(btv.await, md.expand())
    expect(ok).to_be(false)
    expect(tostring(err)).to_match("no markdown table on line 5")
    expect(t:lines()).to_equal(TWO_TABLES)
  end)

  btv.test.it("resolves 0 when the table is already in that form", function(t)
    open(t, { "| a | b |", "|---|---|" })
    expect(btv.await(md.shrink())).to_be(0)
    expect(btv.await(md.expand())).to_be(0)
  end)
end)
