-- Runnable example for bemtvi-md-table.
--
--   BEMTVI_CONFIG=examples bemtvi examples/sample.md
--
-- Each section has a *type-this / see-that* note.
--
-- Tables are found by the markdown treesitter grammar. Without it nothing is aligned:
-- run `:TSInstall markdown` once first.

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned, and
-- adding it to the runtimepath auto-sources `plugin/`, which calls `setup({})`). A real
-- config would instead use `{ "bemtvi/bemtvi-md-table" }` + :PluginSync — there is
-- nothing to configure.
btv.plugins({
  {
    name = "bemtvi-md-table",
    dir = btv.expand("<sfile>:p:h:h"), -- the repo root (this file's grandparent dir)
  },
})

--------------------------------------------------------------------------------
-- 1. Open the sample.
--
--    SEE THAT: section 1's table is a grid. Its delimiter row reads
--    `|---------|----------------|------------|` although the file holds `|---|---|---|`,
--    and the short cells are padded out to the widest one in their column with a dim
--    `·`. The padding is inline virtual text, dimmed so it can't pass for what you
--    typed: `:w` writes exactly the file, and `$` on the delimiter row still lands on
--    its 13th character.
--
-- 2. Edit a cell.
--
--    TYPE THIS: `/ingest<CR>` then `ea-and-more<Esc>`.
--    SEE THAT:  the whole first column widens to fit, on every row.
--
-- 3. Column alignment (section 2).
--
--    SEE THAT: `---:` right-aligns the Qty column and `:---:` centers Status. The
--    padding goes before or around the text, and the delimiter dashes go inside
--    the colons. `setup({ align = false })` pads every cell on the right instead.
--
-- 4. Wide characters (section 3) line up by display width, not by byte count.
--
-- 5. The table inside the code fence (section 4) is left exactly as written.
--
-- 6. Toggle it.
--
--    TYPE THIS: `:MdTableToggle`  -> the padding disappears from this buffer.
--               `:MdTableToggle`  -> and comes back.
--    `btv.g.md_table_align = false` in a config turns it off everywhere;
--    `btv.b.md_table_align = false` in one buffer.
--------------------------------------------------------------------------------

-- 7. The padding's look: the dashes are `MdTableDelimiter` and the spaces `MdTablePad`,
--    both linked to `NonText`. Restyle either; uncomment to see the dashes in red:
-- btv.hl.define(0, "MdTableDelimiter", { fg = "#f38ba8" })
--
--    The glyphs are fill chars, a `'fillchars'`-style key:char list. Set them for
--    every buffer, or one (the buffer's wins), then repaint:
--
--    TYPE THIS: `:lua btv.g.md_table_fillchars = "pad:.,delimiter:="`
--               `:lua require("bemtvi-md-table").refresh()`
--    SEE THAT:  the padding turns to dots and the delimiter fill to `=`.
--               `:lua btv.g.md_table_fillchars = nil` and refresh to go back.
--
--    Or from a config: `require("bemtvi-md-table").setup({ fillchars = "pad: " })` draws
--    the added spaces as plain spaces (still dimmed, like the dashes).
