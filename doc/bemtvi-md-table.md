<!-- DO NOT EDIT doc/bemtvi-md-table.txt BY HAND. It is generated from this file by
panvimdoc — run `scripts/gen-vimdoc.sh` after editing. -->

Lines up the columns of markdown pipe tables on screen without changing the text. Built entirely on
the native `btv.*` plugin API.

A table typed without padding:

```markdown
| Queue | Upstream | Applied by |
|---|---|---|
| ingest | kafka://events | worker-a |
```

is drawn as:

```markdown
| Queue ·| Upstream ······| Applied by |
|--------|----------------|------------|
| ingest | kafka://events | worker-a ··|
```

The padding is inline virtual text, drawn dimmed so it can't be mistaken for text you typed: the
added spaces as `·`, the added dashes as `-` like the separator itself. The buffer holds exactly
what you typed, so writing the file leaves it unchanged, and motions move over the real characters
only. Both the glyphs (see [Fill chars](#fill-chars)) and the colours (see
[Highlights](#highlights)) can be changed.

<!-- Passed through verbatim so `:help bemtvi-md-table` lands on this page
     (panvimdoc derives per-section tags but no bare project tag). -->
```vimdoc
                                                              *bemtvi-md-table*
```

# Install

Put the repo on your `runtimepath` with `btv.plugins` or any plugin manager.
`plugin/bemtvi-md-table.lua` auto-sources on load and turns alignment on with the defaults, so
there is nothing to configure:

```lua
btv.plugins({
  { "bemtvi/bemtvi-md-table" },
})
```

Run `:PluginSync` to clone it, then open a markdown file.

Tables are found by the markdown treesitter grammar. Without it nothing is aligned: install it once
with `:TSInstall markdown`.

# What it aligns

A GFM pipe table, as the markdown treesitter grammar finds it: a header row, a delimiter row with
the same number of cells, then body rows, at the top level or inside a list item or block quote.
Each column is widened to its widest cell, measured
in display cells, so CJK text and emoji line up. A shorter cell gets the difference as padding:

- spaces before its closing `|`, in a left-aligned (or unmarked) column;
- spaces before its text in a right-aligned column (`---:`), split on both sides in a centered
  one (`:---:`);
- on the delimiter row, dashes after the cell's last `-`, so alignment colons stay at the edges.

Rows with and without outer pipes line up with each other, since column 1 is measured from the
start of the line. That includes what comes before the table on each row: a block quote's `>`, a
list item's indent, or the list marker a table starts right after (`- | a | b |`), each counted by
its width, so rows that write them differently (`> ` then a lazy `>`, a tab for a list's indent)
still line up their columns. Only the leading pipes of such rows can't agree. A `\|` is a
literal pipe, not a cell boundary. A tab counts from the screen column it sits at, on a tabstop of
8 (the editor's display-width measure doesn't read `'tabstop'` yet).

Left alone, because the grammar doesn't call them tables:

- tables inside a fenced code block (`` ``` `` or `~~~`);
- tables indented four or more spaces (an indented code block);
- lines that hold a `|` but are not part of a table (no delimiter row under a header).

Buffers where treesitter is off (`btv.bo.ts_highlight = false`) get no alignment either.

The last cell of a row with no trailing pipe counts toward its column's width but is not padded,
because nothing after it needs lining up.

A table whose columns and pipes add up to more than 1000 display cells, that has more than 20000
rows, or that holds more than 200000 cells in all is left unaligned: a table that wide can't line up
on any screen, and padding it would mean a string as long as its widest cell on every row; one that
long or that dense costs too much to read again as the buffer changes. Reading such a table stops as
soon as it's known to be one.

So does anything whose first two lines aren't a header row and a delimiter row, should the grammar
ever hand one over: nothing is padded, and neither command rewrites it.

# Toggles

```lua
btv.g.md_table_align = false          -- off everywhere (default: on)
btv.b.md_table_align = false          -- off in the current buffer
btv.b[bufnr].md_table_align = false   -- ...or a specific buffer
```

A buffer's explicit value wins over the global one. Both are read on every repaint; after
changing one from Lua, call `require("bemtvi-md-table").refresh()` to repaint straight away.

## :MdTableToggle

`:MdTableToggle` flips alignment for the current buffer and repaints it.

# Rewriting a table

The alignment above is only drawn. Two commands change the text itself, for when the file should
hold a grid (or should stop holding one).

## :MdTableExpand

`:[range]MdTableExpand` writes the table under the cursor as the aligned grid the plugin draws,
with real spaces and dashes:

```markdown
| Queue  | Upstream       | Applied by |
|--------|----------------|------------|
| ingest | kafka://events | worker-a   |
```

Stray spacing in the cells is dropped first, then each cell is padded to its column's widest,
before its text in a right-aligned column and on both sides in a centered one (with `align = false`
in `setup`, always on the right). The first cell of a row written without a leading pipe is always
padded on the right: spaces before it would read as indentation, and four of them would turn the
table into an indented code block.

A table with a tab inside a cell is refused: padding written before a tab moves it to another tab
stop and changes its width, so no padding lines it up. Replace the tab with spaces first. Once the text is a grid there is nothing left to pad, so no
padding is drawn over it.

## :MdTableShrink

`:[range]MdTableShrink` writes the table in the least space it takes: each cell's text one space
from its pipes (an empty cell is a single space), and each delimiter cell cut to three characters
that keep its alignment, `---`, `:--`, `--:` or `:-:`, with no spaces around them:

```markdown
| Queue | Upstream | Applied by |
|---|---|---|
| ingest | kafka://events | worker-a |
```

Alignment, if on, keeps drawing the shrunk table as a grid.

Both commands:

- rewrite every table the range touches when given one (`:%MdTableExpand` does the whole buffer);
- keep each row's outer pipes, or their absence, and never add or drop a cell;
- keep what comes before the table on each row: a block quote's `>` and a list item's indent;
- find tables through the markdown treesitter grammar, as the alignment does, so a table in a code
  fence is never touched;
- keep each row's leading whitespace, and anything after its last pipe other than spaces and tabs
  (a stray `\r`);
- fail with an error, leaving the buffer alone, when there is no table at the cursor or in the
  range, when the buffer isn't modifiable, or when a table in it can't be rewritten: both refuse one
  over 20000 rows or that doesn't start with a header and a delimiter row, and `:MdTableExpand` also
  one too big to align (see [What it aligns](#what-it-aligns)) or with a tab in a cell. It's all or nothing: when one table of a range fails, none is changed;
- leave an already-formatted table untouched (the buffer isn't marked modified) and say so.

Each table a range rewrites is its own edit, so it takes one `u` per table to undo the command.

# Configuration

`require("bemtvi-md-table").setup(opts)` reconfigures. `plugin/bemtvi-md-table.lua` calls it with
`{}` for you; calling it again from a config re-applies. Unknown keys are an error.

```lua
require("bemtvi-md-table").setup({
  filetypes = { "markdown" },  -- the filetypes whose tables are aligned
  align = true,                -- honor ---: and :---: in the cells; false pads
                               -- every cell on the right
  fillchars = "pad:·,delimiter:-",  -- the glyphs the padding is drawn in
})
```

# Fill chars

The glyphs the padding is drawn in, set like the core's `'fillchars'` and `'listchars'`: a
comma-separated `key:char` list.

```lua
require("bemtvi-md-table").setup({ fillchars = "pad:·,delimiter:-" })
```

- `pad` — drawn in place of the spaces added to the cells. Default `·`.
- `delimiter` — drawn in place of the dashes added to the delimiter row. Default `-`.

The char is the one character after the colon, so `,` and `:` work as fill chars too
(`"pad:,"`). Each must be one display cell wide. A key left out keeps its default, so
`"pad: "` changes only the spaces. The table form `btv.opt` gives map options works too:
`{ pad = " " }`. `"pad: "` draws the padding as plain spaces, its colour aside.

Like a global-local option, it can be set at three levels, the most specific winning:

```lua
require("bemtvi-md-table").setup({ fillchars = "pad: " })  -- the base
btv.g.md_table_fillchars = "pad:."                          -- overrides setup
btv.b[bufnr].md_table_fillchars = { pad = "+" }             -- one buffer
```

The variables are read on every repaint; after changing one from Lua, call
`require("bemtvi-md-table").refresh()` to repaint straight away. An invalid value is an error:
`setup` raises it, and a variable is reported once on the message line as `E474`, with that
buffer's tables left unaligned until it is fixed.

# Highlights

- `MdTableDelimiter` — the dashes added to the delimiter row. Linked by default to `NonText`.
- `MdTablePad` — the spaces added to the cells. Linked by default to `NonText`.

`NonText` is the dim group for glyphs that aren't part of the text, which keeps the padding
visibly apart from what you typed.

Both are `default` links, so a colorscheme or your config can restyle them. They are re-linked
after a colorscheme loads.

# API

## setup

`require("bemtvi-md-table").setup(opts)`

See [Configuration](#configuration).

## enabled

`require("bemtvi-md-table").enabled(bufnr)`

Whether tables are aligned in `bufnr` (`0` = the current buffer), from the toggles above.

## toggle

`require("bemtvi-md-table").toggle(bufnr)`

Flip alignment for `bufnr` (default: the current buffer), repaint it, and return the new state.

## refresh

`require("bemtvi-md-table").refresh(bufnr)`

Repaint `bufnr`'s windows now, or every visible window with no argument.

## shrink

`require("bemtvi-md-table").shrink(bufnr, first, last)`

What `:MdTableShrink` runs. Rewrites every table touching the 0-based rows `first` to `last`
(inclusive) of `bufnr` (default: the current buffer, at the cursor). Another buffer has no cursor
to default to, so it needs `first`. Returns a promise of the
number of tables whose text changed; it rejects when there is no table there.

## expand

`require("bemtvi-md-table").expand(bufnr, first, last)`

What `:MdTableExpand` runs, with the same arguments and result as [shrink](#shrink).

## fillchars

`require("bemtvi-md-table").fillchars(bufnr)`

The fill chars in effect for `bufnr` (`0` = the current buffer), as `{ pad = ..., delimiter = ... }`:
the buffer's variable, else the global one, else setup's. An invalid variable returns `nil` and
the `E474` message. See [Fill chars](#fill-chars).

# How it works

A `btv.decor.provider` scoped to the configured filetypes runs whenever a window's viewport
changes: on scroll, resize, or an edit. It declares the treesitter query `(pipe_table) @table`, so
each run is handed the tables that touch the viewport, each with its full extent even where it runs
above or below the screen. It reads each table's rows, so the columns agree past the edge, and
publishes one inline `virt_text` mark per padded cell. Each publish replaces the previous one, so
nothing is left behind when a cell shrinks. While the grammar is still loading, or a large file's
first parse is unfinished, it keeps what is drawn and runs again when the tree is ready.

Only tables on screen are measured, and each table's column widths are cached until the buffer next
changes (keyed on `btv.buf.changedtick`). Its parsed rows outlive that: after an edit the table's
rows are compared with the previous ones from both ends, only those in between are parsed again, and
the column widths are updated from those rows alone, so a table next to an edit isn't parsed at all.
Earlier measures are kept, up to a budget of cells, so a big table scrolled away from while you edit
elsewhere isn't parsed again when you come back. Parsing a row stops once it runs past the width
limit, and a cell too long to fit is known to be without measuring it. The padding itself is built for the visible rows only. The cache is dropped when the buffer
is deleted.

# Tests

```sh
bemtvi --test-plugin .
```

The suite runs in a real headless editor. It opens markdown files and checks the painted rows, with
the inline padding put back in, and also drives the runnable example in `examples/`. The tests that
draw tables need the markdown grammar and are reported as skipped without it.
