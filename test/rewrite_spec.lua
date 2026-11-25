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

-- The screen columns of every unescaped `|` in `line`, tabs expanded from column 0.
local function pipe_cols(line)
  local out = {}
  for p in line:gmatch("()|") do
    if line:sub(p - 1, p - 1) ~= "\\" then
      out[#out + 1] = btv.str.displaywidth(line:sub(1, p - 1))
    end
  end
  return table.concat(out, ",")
end

-- Whether lines `first`..`last` put their pipes in the same screen columns, the
-- leading pipe aside: rows whose prefixes differ in width (`> ` and a lazy `>`) can't
-- line that one up.
local function grid(lines, first, last)
  local function inner(line)
    return (pipe_cols(line):gsub("^%d+,?", ""))
  end
  for i = first + 1, last do
    if inner(lines[i]) ~= inner(lines[first]) then
      return false
    end
  end
  return true
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

  btv.test.it("rewrites a block-quoted table with more of the quote after it", function(t)
    open(t, { "> | a | b |", "> |---|--:|", "> | ccc | d |", ">", "> after" })
    t:feed("2G")
    t:cmd("MdTableExpand")
    wait_line(t, 2, "> |-----|--:|")
    expect(t:lines()).to_equal({
      "> | a   | b |",
      "> |-----|--:|",
      "> | ccc | d |",
      ">",
      "> after",
    })
  end)

  btv.test.it("rewrites a table that starts on a list marker's line", function(t)
    open(t, { "- | a | b |", "  |---|---|", "  | ccc | d |" })
    t:cmd("MdTableExpand")
    wait_line(t, 2, "  |-----|---|")
    expect(t:lines()).to_equal({ "- | a   | b |", "  |-----|---|", "  | ccc | d |" })
  end)

  btv.test.it("changes nothing when one table of a range can't be rewritten", function(t)
    local doc = {
      "| " .. ("w"):rep(1200) .. " | b |",
      "|---|---|",
      "",
      "| a | b |",
      "|---|---|",
      "| ccc | d |",
    }
    open(t, doc)
    local ok, err = pcall(btv.await, md.expand(0, 0, 5))
    expect(ok).to_be(false)
    expect(tostring(err)).to_match("wider than 1000")
    t:sleep(100)
    expect(t:lines()).to_equal(doc)
    expect(btv.bo.modified).to_be(false)
  end)

  btv.test.it("needs the rows to rewrite in another buffer", function(t)
    open(t, TWO_TABLES)
    local other = btv.buf.current()
    t:cmd("enew")
    local ok, err = pcall(md.expand, other)
    expect(ok).to_be(false)
    expect(tostring(err)).to_match("give the rows")
  end)

  for _, case in ipairs({
    { "a lazy `>` with no space", { "> | a | b |", ">|---|---|", ">| ccc | d |" } },
    { "a tab for a list's indent", { "- | a | b |", "\t|---|---|", "\t| ccc | d |" } },
    { "a quote inside a list item", { "- > | a | b |", "  > |---|---|", "  > | ccc | d |" } },
  }) do
    btv.test.it("rewrites a table whose rows open with " .. case[1], function(t)
      open(t, case[2])
      t:feed("2G")
      t:cmd("MdTableExpand")
      t:wait_for(function()
        return grid(t:lines(), 1, 3) or nil
      end, { message = "never lined up: " .. table.concat(case[2], " / ") })
      -- What comes before the table on each row is kept as written.
      for i, line in ipairs(case[2]) do
        local before = line:match("^(.-)|")
        expect(t:lines()[i]:sub(1, #before)).to_be(before)
      end
    end)
  end

  btv.test.it("takes a range given bottom first", function(t)
    open(t, TWO_TABLES)
    expect(btv.await(md.expand(0, 2, 0))).to_be(1)
    wait_line(t, 2, "|--------|----------------|")
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
