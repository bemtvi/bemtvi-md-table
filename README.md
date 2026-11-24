# bemtvi-md-table

Aligned markdown tables for [bemtvi](https://github.com/bemtvi/bemtvi), built **entirely on the
native `btv.*` plugin API**.

Type a table without bothering to pad it:

```markdown
| Queue | Upstream | Applied by |
|---|---|---|
| ingest | kafka://events | worker-a |
```

and it is drawn as a grid:

```markdown
| Queue ·| Upstream ······| Applied by |
|--------|----------------|------------|
| ingest | kafka://events | worker-a ··|
```

The padding is inline virtual text, drawn dimmed so you can tell it from what you typed: the added
spaces as `·`, the added dashes as `-` like the separator itself. The glyphs are fill chars, set
like `'fillchars'`: `setup({ fillchars = "pad: " })` draws the spaces as plain spaces. The buffer
still holds exactly what you typed, so `:w` writes it unchanged. Columns re-align as you type, respect `---:` / `:---:` alignment, measure wide
characters by display width, and are left alone inside code fences.

Tables are found by the markdown treesitter grammar, so they are aligned only where it is
installed: run `:TSInstall markdown` once.

## Install

Declare it with the built-in `:Plugins` manager and run `:PluginSync`, and install the markdown
grammar with `:TSInstall markdown` if you haven't. There is nothing to configure:

```lua
btv.plugins({
  { "bemtvi/bemtvi-md-table" },
})
```

Turn it off with `btv.g.md_table_align = false` (everywhere) or `:MdTableToggle` (this buffer).

## Try it

```sh
BEMTVI_CONFIG=examples bemtvi examples/sample.md
```

## Documentation

Full docs live in the help file. The same source renders on GitHub and in the editor:

- In editor: `:help bemtvi-md-table`
- On GitHub: [doc/bemtvi-md-table.md](./doc/bemtvi-md-table.md) (the help source)

## Development

Run the suite (a real editor, headless):

```sh
bemtvi --test-plugin .
```

The tests that draw tables need the markdown grammar and are reported as skipped without it.

The help file is generated: edit `doc/bemtvi-md-table.md`, never the `.txt`, then run
`bash scripts/gen-vimdoc.sh`. Enable the hooks once after cloning:

```sh
pre-commit install --hook-type pre-commit --hook-type pre-push
```

## License

MIT
