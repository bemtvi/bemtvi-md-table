-- The runnable example's notes, driven key for key against `examples/sample.md`.
-- (The example's `init.lua` only puts this repo on the runtimepath, which the test
-- runner already does, so the spec opens the sample directly.)

local md = require("bemtvi-md-table")
local expect = btv.test.expect

local ROOT = btv.utils.dirname(btv.utils.dirname(debug.getinfo(1, "S").source:sub(2)))
local SAMPLE = ROOT .. "/examples/sample.md"

-- The inline padding on screen row `row`, joined.
local function pad(row)
  local parts = {}
  for _, place in ipairs((btv._ui.virt_text or {})[row] or {}) do
    if place[1] == 1 then
      for _, chunk in ipairs(place[4] or {}) do
        parts[#parts + 1] = chunk[1]
      end
    end
  end
  return table.concat(parts)
end

-- The screen row showing buffer line `lnum` (the sample has no folds or wraps).
local function row_of(t, lnum)
  local row = lnum - btv.win.saveview().topline + 1
  expect(t:screen()[row]).to_be(t:lines()[lnum])
  return row
end

local function find(t, text)
  for i, line in ipairs(t:lines()) do
    if line == text then
      return i
    end
  end
  error("no line " .. text)
end

-- The tables are found by the markdown treesitter grammar; without it every note here
-- skips, with the reason.
local function open(t)
  if not btv.tbl.contains(btv.await(btv.treesitter.installed()), "markdown") then
    t:skip("no markdown treesitter grammar installed")
  end
  md.setup({})
  t:cmd("edit " .. SAMPLE)
  t:cmd("edit!")
  local delim = row_of(t, find(t, "|---|---|---|"))
  t:wait_for(function()
    return (pad(delim) ~= "") or nil
  end, { message = "section 1 was never padded" })
  return delim
end

btv.test.describe("examples/sample.md", function()
  btv.test.it("1. the delimiter row reads as a full-width rule", function(t)
    local delim = open(t)
    expect(pad(delim)).to_be(("-"):rep(6) .. ("-"):rep(13) .. ("-"):rep(9))
    expect(btv.bo.modified).to_be(false)
    t:feed(find(t, "|---|---|---|") .. "G$")
    expect(t:cursor()[2]).to_be(12)
  end)

  btv.test.it("2. editing a cell widens its column", function(t)
    local delim = open(t)
    t:feed("/ingest<CR>ea-and-more<Esc>")
    expect(t:lines()[find(t, "| ingest-and-more | kafka://events | worker-a |")]).never.to_be_nil()
    t:wait_for(function()
      return (pad(delim):sub(1, 14) == ("-"):rep(14)) or nil
    end, { message = "column 1 did not widen" })
  end)

  btv.test.it("6. :MdTableToggle turns it off and on", function(t)
    local delim = open(t)
    t:cmd("MdTableToggle")
    t:wait_for(function()
      return (pad(delim) == "") or nil
    end, { message = "the padding stayed" })
    t:cmd("MdTableToggle")
    t:wait_for(function()
      return (pad(delim) ~= "") or nil
    end, { message = "the padding did not come back" })
  end)

  btv.test.it("5. the fenced table is left alone", function(t)
    open(t)
    t:feed("Gzb")
    local first = find(t, "```markdown")
    -- The section-3 table above it is on screen too, and padded: the provider ran here.
    local wide = row_of(t, find(t, "| pho | Vietnamese |"))
    t:wait_for(function()
      return (pad(wide) ~= "") or nil
    end, { message = "the scrolled-to viewport was never decorated" })
    for lnum = first + 1, first + 3 do
      expect(pad(row_of(t, lnum))).to_be("")
    end
  end)
end)
